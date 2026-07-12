// Macintosh IIvi (VASP) Pseudo-VIA — base-RBV variant.
//
// Faithful port of MAME's pseudovia_device BASE class
// (src/devices/machine/pseudovia.cpp, APPLE_PSEUDOVIA) — which is what
// vasp.cpp instantiates. NOT the V8 variant the Mac LC II uses; the
// differences that matter (see docs/VASP_RETARGET.md):
//
//   * ASC IRQ (IFR bit 4) is EDGE-set on the source's rising edge and
//     cleared only by the IFR ack write (W1C includes bit 4). The V8
//     variant level-follows the source and NOPs the bit-4 ack.
//   * Writes decode `offset & 0x13` exactly like reads — the base class
//     has NO V8-style (offset>>9)==1 port-A window.
//   * The IER "write $FF => $1F" quirk applies (base-RBV/IIci behavior).
//   * Three NuBus slot inputs: reg2 bits 3/4/5 = slots $C/$D/$E
//     (active low), driven level-wise by the cards; VBL stays bit 6.
//   * Reg $01 (config): VASP connects no in/out_config handlers — reads
//     return $00, writes are dropped. (The V8 RAM-config machinery the
//     LC II carried here does not exist on this machine.)
//   * Reg $00 (port B): in/out_b unconnected on VASP — reads $00.
//   * Reg $10 (video): read = stored value with bits [5:3] replaced by
//     montype<<3 (MAME base read: data &= ~0x38; data |= in_video()).
//
// Lessons carried from the MacLCII 2026-07-06 rewrite (all verified
// against current MAME source):
//   1. READS alias EVERY offset via `offset & 0x13` — the ROM's slot
//      dispatcher reads the IFR at (base+$203) and must see it.
//   2. The IFR readback is the RECALC'd view: while an enabled interrupt
//      is pending the value is (pending & IER & $1B) | $80, so the
//      dispatcher only ever sees ENABLED sources.
//   3. The VBL slot source is STATE (reg2 bit 6, active low): set active
//      by the vblank edge, cleared by vblank end AND by the ROM's $40
//      ack write to reg 2. A live wire would make the ack a no-op and
//      storm ~950 acks/frame.
//
// Reset values per pseudovia_device::device_reset(): regs[2]=$7F,
// regs[3]=$1B (yes, IFR bits 0/1/3/4 start SET; MAME-true — the ROM
// acks them).
//
// Reached at CPU $50026000 (+$00F00000 mirrors), byte on both lanes.

module pseudovia(
    input clk_sys,
    input reset,

    // CPU interface - full offset within the $2000 window
    input [12:0] addr,
    input [7:0] data_in,
    output reg [7:0] data_out,
    input we,
    input req,

    // Interrupt sources
    input vblank_irq,    // active-high VBL level (edge-detected here)  -> reg2 bit 6
    input slot_irq_c,    // NuBus slot $C IRQ (active high, level)      -> reg2 bit 3
    input slot_irq_d,    // NuBus slot $D IRQ                           -> reg2 bit 4
    input slot_irq_e,    // NuBus slot $E IRQ                           -> reg2 bit 5
    input asc_irq,       // ASC IRQ (edge-SET into IFR bit 4, W1C ack)
    input scsi_irq,      // NCR5380 latched interrupt (LEVEL) -> IFR bit 3
    input scsi_drq,      // NCR5380 DREQ (LEVEL)              -> IFR bit 0
    output reg irq_out,

    // Video config: montype sense (read bits [5:3]) + stored config byte
    input [3:0] monitor_id,
    output reg [7:0] video_config   // bits 2:0 = bpp mode (consumed by video)
);

// ---------------------------------------------------------------------
// Register state, mirroring MAME m_pseudovia_regs[]:
//   reg2 = slot status (ACTIVE LOW): bit6 VBL (latched), bits 5/4/3 =
//          slots $E/$D/$C (level from the cards)
//   reg3 = IFR; bit4 (ASC) is the only stored source bit, the LEVEL
//          sources (0=DRQ, 3=SCSI) and the summaries (1=any-slot,
//          7=IRQ) are derived live each cycle
//   reg $12 = slot IER, reg $13 = IER
// ---------------------------------------------------------------------
reg [7:0] slot_ier;
reg [7:0] ier;
reg [7:0] reg_b;        // reg $00 (Port B) — stored; init $4F per MAME 0.264
reg [7:0] reg_config;   // reg $01 (config) — stored; init $06 per MAME 0.264
reg       vbl_pending_n;   // reg2 bit 6 (active low, latched)
reg       ifr_asc;         // reg3 bit 4 (edge-set, W1C)
reg       ifr_b2, ifr_b5, ifr_b6; // stored-only bits: no VASP source ever
                                  // sets them (reset 0; W1C can clear) —
                                  // kept for structural fidelity

reg asc_irq_d, vblank_irq_d;

// reg2 live view (active low)
wire [7:0] slot_pending = {1'b0, vbl_pending_n, ~slot_irq_e, ~slot_irq_d,
                           ~slot_irq_c, 3'b111};

// --- pseudovia_recalc_irqs(), evaluated combinationally ---
wire [7:0] slot_irqs = (~slot_pending) & 8'h78 & (slot_ier & 8'h78);
wire any_slot_irq = |slot_irqs;
wire [7:0] ifr_live = {1'b0, ifr_b6, ifr_b5, ifr_asc, scsi_irq, ifr_b2,
                       any_slot_irq, scsi_drq};
wire [7:0] ifr_masked = ifr_live & ier & 8'h1B;
wire irq_pending = |ifr_masked;
// IFR readback = the recalc'd view (MAME replaces regs[3] with the masked
// set | $80 while pending — the dispatcher must only see enabled sources).
wire [7:0] ifr_read = irq_pending ? (ifr_masked | 8'h80) : (ifr_live & 8'h7F);

// Register select: MAME read()/write() both do `offset &= 0x13`, i.e.
// only address bits 4,1,0 matter — every other offset in the whole
// window aliases onto the 8 registers.
wire [2:0] reg_sel = {addr[4], addr[1:0]};

always @(posedge clk_sys) begin
    if (reset) begin
        slot_ier <= 8'h00;
        ier <= 8'h00;
        vbl_pending_n <= 1'b1;      // reg2 = $7F
        ifr_asc <= 1'b1;            // reg3 = $1B: bit 4 set...
        ifr_b2 <= 1'b0;
        ifr_b5 <= 1'b0;
        ifr_b6 <= 1'b0;             // (bits 0/1/3 of $1B are live-derived)
        irq_out <= 1'b0;
        video_config <= 8'h00;
        asc_irq_d <= 1'b0;
        vblank_irq_d <= 1'b0;
        data_out <= 8'h00;
        // Reg $00/$01 initial values from the RUNNING MAME 0.264 oracle
        // (tap capture /tmp/mame_pvia_rw.txt, 2026-07-12): reg0 reads $4F
        // before any write, reg1 (config) reads $06. The local ../mame
        // source tree has both unconnected-read-0 — the packaged binary
        // predates that rework; we align to the binary the goldens come
        // from. The IIvi ROM's POST fingerprints the machine partly by
        // writing these regs and reading patterns back (pc $40802Fxx at
        // F15, the $4084AB78 BCLR, F149 config probe) — hardwired zeros
        // corrupt the signature word the F663 identity check verifies
        // (sad Mac $0F/$33).
        reg_b <= 8'h4F;
        reg_config <= 8'h06;
    end else begin
        asc_irq_d <= asc_irq;
        vblank_irq_d <= vblank_irq;

        // ASC: edge-SET (base-RBV asc_irq_w fires only on 0->1 of the
        // source; deassertion does NOT clear the flag — the ack does).
        if (asc_irq && !asc_irq_d)
            ifr_asc <= 1'b1;

        // VBL state: active (0) at vblank start, inactive (1) at vblank
        // end; the reg2 ack write below also sets it inactive.
        if (vblank_irq && !vblank_irq_d)
            vbl_pending_n <= 1'b0;
        else if (!vblank_irq && vblank_irq_d)
            vbl_pending_n <= 1'b1;

        // IRQ output follows the recalc
        irq_out <= irq_pending;

        if (req) begin
            if (we) begin
                case (reg_sel)
                    3'b000: reg_b      <= data_in;  // $00: Port B (stored — see reset note)
                    3'b001: reg_config <= data_in;  // $01: config (stored — see reset note)

                    3'b010: begin  // $02: slot status — writing 1 to bit 6
                                   // ACKS (deactivates) the VBL flag; slot
                                   // bits are card-level-driven, not ackable
                                   // here (MAME: regs[2] |= data & 0x40)
                        if (data_in[6]) vbl_pending_n <= 1'b1;
                    end

                    3'b011: begin  // $03: IFR — write-1-to-clear, mask $7F.
                                   // Base-RBV: bit 4 (ASC) IS clearable
                                   // (the V8 ack-NOP does not apply).
                        if (data_in[4]) ifr_asc <= 1'b0;
                        if (data_in[2]) ifr_b2  <= 1'b0;
                        if (data_in[5]) ifr_b5  <= 1'b0;
                        if (data_in[6]) ifr_b6  <= 1'b0;
                        // bits 0/1/3/7 are derived; level sources re-assert
                        // by construction (MAME callbacks re-set them)
                        `ifdef VERBOSE_TRACE
                        $display("PVIA: IFR ACK %02x @%0t", data_in & 8'h7F, $time);
                        `endif
                    end

                    3'b100: begin  // $10: video config (stored; read merges montype)
                        video_config <= data_in;
                        `ifdef VERBOSE_TRACE
                        $display("PVIA: WRITE Video Config = %02x (bpp=%0d) @%0t",
                                 data_in, data_in[2:0], $time);
                        `endif
                    end

                    3'b101: ;  // $11: unused

                    3'b110: begin  // $12: slot IER (bit7 = set/clear)
                        if (data_in[7])
                            slot_ier <= slot_ier | (data_in & 8'h7F);
                        else
                            slot_ier <= slot_ier & ~(data_in & 8'h7F);
                        `ifdef VERBOSE_TRACE
                        $display("PVIA: WRITE Slot IER %s%02x @%0t",
                                 data_in[7] ? "+" : "-", data_in & 8'h7F, $time);
                        `endif
                    end

                    3'b111: begin  // $13: IER (bit7 = set/clear; $FF => $1F
                                   // — the base-RBV/IIci POST quirk)
                        if (data_in == 8'hFF)
                            ier <= 8'h1F;
                        else if (data_in[7])
                            ier <= ier | (data_in & 8'h7F);
                        else
                            ier <= ier & ~(data_in & 8'h7F);
                        `ifdef VERBOSE_TRACE
                        $display("PVIA: WRITE IER %s%02x @%0t",
                                 data_in[7] ? "+" : "-", data_in & 8'h7F, $time);
                        `endif
                    end
                endcase
            end else begin
                case (reg_sel)
                    3'b000: data_out <= reg_b;          // Port B (stored — see reset note)
                    3'b001: data_out <= reg_config;     // config (stored — see reset note)
                    3'b010: data_out <= slot_pending;   // slot status (active low)
                    3'b011: data_out <= ifr_read;       // IFR (recalc'd view)
                    // $10: stored config with bits [5:3] replaced by the
                    // monitor sense (MAME: data &= ~0x38; data |= montype<<3)
                    3'b100: data_out <= (video_config & 8'hC7) |
                                        {2'b00, monitor_id[2:0], 3'b000};
                    3'b101: data_out <= 8'h00;          // $11: unused
                    3'b110: data_out <= slot_ier & 8'h7F;
                    3'b111: data_out <= ier & 8'h7F;    // bit 7 reads 0
                endcase
            end
        end
    end
end

endmodule
