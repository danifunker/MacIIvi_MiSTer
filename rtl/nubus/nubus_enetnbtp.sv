/*
 * nubus_enetnbtp.sv — Apple Ethernet NB Twisted Pair card (820-0511-A),
 * NuBus slot $C.
 *
 * NuBus sibling of the MacLC core's PDS Ethernet front-end (that card's
 * rtl/pds/pds_enet.sv is the donor; docs/enetnbtp_scope.md is the contract).
 * The FPGA side is a dumb front-end — slot decode, register doorbell + read
 * shadows, MAC PROM, declaration ROM, and the 128 KiB on-card RAM served from
 * a DDR3 shared-memory window. The DP83932 SONIC model (descriptors, CAM,
 * filters, TX/RX) and the bridge to a real network interface run on the ARM
 * inside the modified Main_MiSTer (support/mac), which serves the same DDR3
 * window. Unlike the LC card there is NO guest-RAM DMA engine: this SONIC
 * bus-masters only into the card's own RAM (MAME enetnbtp.cpp), so the model
 * reads and writes the CARDRAM window directly and the SDRAM controller is
 * never involved.
 *
 * Everything runs in clk_sys and the top drives DDRAM_CLK = clk_sys — no CDC.
 *
 * Guest-visible map (MAME enetnbtp.cpp ground truth; standard slot space
 * $FC00'0000-$FCFF'FFFF only — MAME installs no super-slot map. The IIvi's
 * 68030 PMMU translates 24-bit-mode slot windows itself, so unlike the LC
 * card no 24-bit decode exists here):
 *   $FC00'0000-$FC01'FFFF  card RAM (128 KiB; also the SONIC's buffer space)
 *   $FC0C'0000-$FC0C'00FF  SONIC registers: 64 x 16-bit at consecutive WORD
 *       addresses (index = A[6:1], first $80 bytes; $80-$FF unmapped -> $FFFF)
 *   $FC40'0000-$FC40'000F  MAC PROM on the 16-bit LOW lanes (umask32
 *       $00ff00ff): PROM byte k at guest byte 2k+1, even bytes read $00.
 *       Bytes 0-5 = bit-swizzled MAC (OUI 08:00:07), 6 = $00, 7 = XOR
 *       checksum complemented; cooked by Main into the MACPROM control word.
 *   $FCC2'0000-$FCC3'FFFF  card RAM alias
 *   $FCFE'0000-$FCFF'FFFF  declaration ROM 341-1096: 32 KiB raw, byteLanes
 *       $D2 = LANE 1 ONLY, so the guest footprint is x4-expanded — raw byte
 *       i at guest byte 4i+1, every other lane $00. The RAW image sits in
 *       the DDR3 ROMRAW region; the lane expansion happens here on reads.
 *   IRQ: SONIC INT (level) -> slot $C /NMRQ -> pseudoVIA slot IRQ.
 *
 * DDR3 window v3 (ARM phys 0x1FF00000 — layout is THE contract, mirrored in
 * docs/enetnbtp_scope.md and Main's support/mac/mac_eth.h):
 *   +0x00000  128K CARDRAM  card RAM (window byte i = card byte i)
 *   +0x20000   32K ROMRAW   raw declROM (window byte i = ROM byte i)
 *   +0x28000       control block, 64-bit words:
 *       w0  +0x00 MAGIC    (ARM->FPGA) 64'h4D634E42_45544833 "McNBETH3"
 *       w1  +0x08 CMD_WPTR (FPGA->ARM) doorbell ring write index, monotonic
 *       w2..w17   SHADOWS  (ARM->FPGA) 64 regs x 16-bit: word n = regs
 *                 4n..4n+3, register 4n+k at bits [16k+15:16k]
 *       w18 +0x90 INT      (ARM->FPGA) bit0 = SONIC INT line state
 *       w19 +0x98 MACPROM  (ARM->FPGA) 8 cooked PROM bytes, byte k = PROM k
 *       w20 +0xA0 GEOMETRY (ARM only) layout version = 3
 *       w21 +0xA8 RPTR     (ARM->FPGA) ring read index (backpressure)
 *       w22/w23            reserved (the LC layout's DMA words; unused here)
 *   +0x28800  2K   CMD ring, 256 x 64-bit, entry:
 *       bit0 = valid, [3:1] = tag, [9:4] = SONIC reg index, [31:16] = data,
 *       [39:32] = seq (reserved, 0)
 *       tags: 0 = REG_WR    1 = RESET (guest warm restart)
 *
 * Doorbell discipline (unchanged from the donor): register writes stretch
 * DTACK only until the ring entry + write pointer are IN DDR3 — never until
 * the ARM runs. Register and PROM reads are answered instantly from the
 * shadows/PROM word. Card RAM and declROM accesses stretch for one DDR3
 * round trip. No path waits on host software, so a dead host can never wedge
 * the guest (the ~4 ms watchdog retires any cycle a dead DDR3 leaves parked).
 *
 * Presence: the card decodes only if MAGIC was valid at the moment the guest
 * came out of reset (and the OSD option is on). No service = slot $C stays
 * exactly as today (open-bus $FFFF ack in the tops). The v3 MAGIC value means
 * an LC-layout host and this card (or vice versa) can never half-pair.
 */

module nubus_enetnbtp #(parameter [3:0] SLOT_ID = 4'hC) (
	input             clk_sys,
	input             rst_core,      // hard reset (POR / core load), active high
	input             rst_guest,     // guest reset (RESET instruction etc.), active high
	input             ena_osd,       // OSD "Ethernet" option

	// CPU bus (clk_sys, TG68 16-bit bus conventions of the tops)
	input      [31:0] cpuAddr,
	input      [15:0] cpuDataIn,     // CPU write data (cpuDataOut of the tops)
	input             _cpuAS,
	input             _cpuUDS,
	input             _cpuLDS,
	input             _cpuRW,        // 1 = read

	output            card_sel,      // card claims this bus cycle (mux ahead of the mdc824)
	output            card_ack,      // cycle may complete (data valid on reads)
	output     [15:0] card_dout,
	output            irq,           // active high -> pseudoVIA slot_irq_c

	// DDR3 / DDRAM port (clk_sys — top must drive DDRAM_CLK = clk_sys)
	output reg [28:0] mem_addr,
	output reg  [7:0] mem_burst,
	output reg        mem_rd,
	output reg        mem_we,
	output reg [63:0] mem_wdata,
	output reg  [7:0] mem_be,
	input      [63:0] mem_rdata,
	input             mem_rvalid,
	input             mem_busy
);

	// ── DDR3 window layout (64-bit word addresses) ──────────────────────────
	localparam [28:0] AV_BASE    = 29'h03FE0000;   // ARM 0x1FF00000
	localparam [14:0] AV_CARD    = 15'h0000;       // +0x00000, 16384 words
	localparam [14:0] AV_ROM     = 15'h4000;       // +0x20000, 4096 words
	localparam [14:0] AV_MAGIC   = 15'h5000;       // control block
	localparam [14:0] AV_WPTR    = 15'h5001;
	localparam [14:0] AV_SHAD    = 15'h5002;       // 16 words (64 regs)
	localparam [14:0] AV_INT     = 15'h5012;
	localparam [14:0] AV_MACPROM = 15'h5013;
	localparam [14:0] AV_GEO     = 15'h5014;       // ARM-only, not polled
	localparam [14:0] AV_RPTR    = 15'h5015;
	localparam [14:0] AV_RING    = 15'h5100;       // 256 words

	localparam [63:0] MAGIC_V  = 64'h4D634E42_45544833;   // "McNBETH3"

	localparam [2:0] TAG_REG_WR = 3'd0;
	localparam [2:0] TAG_RESET  = 3'd1;

	// ── slot decode ─────────────────────────────────────────────────────────
	// 32-bit standard slot space only (MAME installs no super-slot map, and
	// the PMMU owns the 24-bit forms). Unclaimed slot cycles keep the top's
	// hardware-validated open-bus $FFFF timeout ack.
	wire        form32 = (cpuAddr[31:24] == {4'hF, SLOT_ID});
	wire [23:0] sub    = cpuAddr[23:0];

	wire sel_ram = form32 && ((sub[23:17] == 7'h00)     // $000000-$01FFFF
	                       || (sub[23:17] == 7'h61));   // $C20000-$C3FFFF alias
	wire sel_reg = form32 && (sub[23:8]  == 16'h0C00);  // $0C0000-$0C00FF
	wire sel_mac = form32 && (sub[23:4]  == 20'h40000); // $400000-$40000F
	wire sel_rom = form32 && (sub[23:17] == 7'h7F);     // $FE0000-$FFFFFF

	wire ds_any  = ~_cpuUDS | ~_cpuLDS;
	wire cyc     = !_cpuAS && ds_any;   // strobes valid: direction + data good

	assign card_sel = present && (sel_ram | sel_reg | sel_mac | sel_rom) && !_cpuAS;

	wire req = present && (sel_ram | sel_reg | sel_mac | sel_rom) && cyc;

	// Register-window access classification: 64 x 16-bit at consecutive word
	// addresses in the first $80 bytes (index = A[6:1] — this card wires the
	// SONIC's 16 data lines across both lanes of every word, unlike the LC's
	// one-register-per-longword layout). Reads are shadow-served whatever the
	// strobes (a byte read just takes its half). Writes must be full words —
	// partial register writes don't exist on the real card; they (and the
	// unmapped $80-$FF half) fall through to K_STUB: $FFFF on reads, ignored
	// on writes, never a stall, never a doorbell.
	wire word_acc = !_cpuUDS && !_cpuLDS;
	wire reg_map  = sel_reg && (sub[7] == 1'b0);
	wire reg_rd   = reg_map && _cpuRW;
	wire reg_wr   = reg_map && !_cpuRW && word_acc;

	wire [5:0] reg_idx = sub[6:1];

	// ── shadows / PROM / INT / MAGIC (poll results) ─────────────────────────
	reg [63:0] shad [0:15];
	reg [63:0] macprom;
	reg        int_state;
	reg        magic_ok;

	// presence: latched while the guest is in reset, held stable across the
	// whole session so the Slot Manager never sees the card flicker.
	reg        present;

	wire [63:0] shad_word   = shad[reg_idx[5:2]];
	wire [15:0] shad_rdata  = shad_word[{reg_idx[1:0], 4'b0000} +: 16];

	// ── timed ISR clear-mask: acks must read back clear IMMEDIATELY ─────────
	// The .ENET driver's dispatch loop re-reads ISR after acking each bit and
	// spins until the acked bits read back clear — written for silicon where a
	// register write takes effect in its own bus cycle. Here the ack round-
	// trips through the doorbell to Main's model before the pushed shadow
	// changes (~1-2 ms), and in that window the loop re-acks at full CPU
	// speed, flooding the ring and starving Main (measured live on the LC
	// card: 80,000 doorbell writes/s). Fix: OR the bits of every guest ISR
	// write into isr_mask and serve ISR READS as shadow & ~mask, so an ack
	// sticks on the very next read. The mask expires on a TIMER (one IRQ_SUPP
	// round trip after the last ack) — long enough for Main to apply the ack
	// into the shadow it pushes. Time-based expiry is load-bearing: a mask
	// reconciled by VALUE cannot tell "my ack not applied yet" from "a new
	// event re-set it" and wedged the LC's RX under load. A timed mask cannot
	// deadlock: worst case a NEW event on a just-acked bit reads as clear for
	// one window (~1.85 ms) — a short interrupt DELAY, never a loss.
	// Only ISR (reg 5) reads are masked; every other register serves raw.
	reg  [15:0] isr_mask;       // guest-acked ISR bits still awaiting Main's apply
	reg  [16:0] isr_mask_tmr;   // mask lifetime countdown
	wire [15:0] sonic_rdata = (reg_idx == 6'd5) ? (shad_rdata & ~isr_mask)
	                                            : shad_rdata;
	reg  [16:0] irq_supp;       // irq-suppression countdown (see the FSM decls)

	// ── card-RAM u64 read cache ─────────────────────────────────────────
	// Every card RAM read is a full DDR3 round trip for 16 of a u64's 64
	// bits — the guest's RX copy loop fetches each u64 FOUR times, and that
	// per-word tax is the bulk of this card's CPU cost next to the PDS card
	// (whose frames land in guest RAM). Cache the last u64 read: tag = card
	// u64 index (the $C2 alias shares sub[16:3], so it hits the same line —
	// correct, same RAM). Coherence with the ARM's concurrent writes leans
	// on the descriptor protocol — payload and descriptor words are final
	// BEFORE the status publish, and the guest reads them only AFTER its
	// interrupt, milliseconds later — plus a TTL that bounds any polled-
	// word staleness to ~7.9 us. Any guest card-RAM write invalidates.
	// Fill only from a non-aborted DDR3 answer: a watchdog-abandoned read
	// lands after req_sub has moved on and must not tag the next address.
	reg  [63:0] rc_data;
	reg  [13:0] rc_tag;         // card u64 index = sub[16:3]
	reg         rc_valid;
	reg  [7:0]  rc_ttl;         // ~7.9 us at clk_sys ~32.5 MHz
	reg         rc_hit;         // registered verdict for the request in flight

	// ── CPU-side request handshake (all clk_sys, no CDC) ────────────────────
	localparam H_IDLE = 2'd0, H_RUN = 2'd1, H_DONE = 2'd2;
	reg  [1:0] hstate;

	// ── host-access watchdog ──────────────────────────────────────
	// card_ack IS the guest's DTACK. Every wait in H_RUN is bounded in theory
	// (a ring slot via cmd_wait_ctr ~2 ms; a DDR3 round trip in well under a
	// microsecond) — but a dead DDR3 backend would park this FSM in H_RUN,
	// and a 68030 that never sees DTACK never comes back. Retire the cycle
	// with open-bus data instead: a dropped access can confuse a driver, a
	// frozen Mac cannot recover at all. Sized ~2x the longest legitimate wait
	// so it only fires on a genuine stall. Fire on a power-of-two rollover so
	// the test is ONE BIT, not an 18-bit equality comparator (donor lesson:
	// a wide compare in this cone cost hold slack).
	localparam H_WD_BIT = 17;   // 2^17 = 131072 cyc ~ 4.0 ms at clk_sys ~32.5 MHz
	reg  [17:0] h_wd;
	reg         h_abort;         // this cycle was abandoned by the watchdog:
	                             // a late DDR3 answer must not retire the NEXT one

	reg [15:0] dout_r;
	reg [23:0] req_sub;
	reg  [1:0] req_be;         // {UDS, LDS}
	reg [15:0] req_wdata;
	reg  [2:0] req_kind;
	localparam K_ROM = 3'd0, K_REGRD = 3'd1, K_REGWR = 3'd2, K_MACRD = 3'd3,
	           K_STUB = 3'd4, K_RAMRD = 3'd5, K_RAMWR = 3'd6, K_ROM0 = 3'd7;

	assign card_ack  = (hstate == H_DONE);
	assign card_dout = dout_r;

	// MAC PROM byte select: PROM byte k lives at guest byte 2k+1 (the odd /
	// LDS lane), so the index is the word address bits and the even lane
	// serves $00 (MAME's unmapped-lane fill). One 16-bit pattern covers word
	// and byte reads alike — a UDS-only read takes the $00 half.
	wire [7:0] prom_byte = macprom[{req_sub[3:1], 3'b000} +: 8];

	// Card RAM / declROM lane picks (the "guest byte A = window byte A"
	// mailbox convention: u64 byte k = window byte 8w+k).
	wire [2:0] lane     = req_sub[2:0];        // byte lane of the D[15:8] byte
	// declROM: raw byte index = guest offset / 4; its u64 word and lane.
	wire [14:0] rom_ridx = req_sub[16:2];      // raw ROM byte 0..0x7FFF
	wire  [2:0] rom_lane = rom_ridx[2:0];

	wire [28:0] ram_word = AV_BASE + {14'b0, AV_CARD} + {15'b0, req_sub[16:3]};
	wire [28:0] rom_word = AV_BASE + {14'b0, AV_ROM}  + {17'b0, rom_ridx[14:3]};

	// ── doorbell / mailbox FSM ──────────────────────────────────────────────
	localparam S_IDLE      = 4'd0;
	localparam S_CMD_W     = 4'd1;   // ring entry write in flight
	localparam S_WPTR_W    = 4'd2;   // wptr publish in flight
	localparam S_MEM_RD_W  = 4'd3;
	localparam S_MEM_RD_D  = 4'd4;
	localparam S_POLL_W    = 4'd5;
	localparam S_POLL_D    = 4'd6;
	localparam S_WPTR_INIT = 4'd7;
	localparam S_RAM_W     = 4'd8;   // card RAM u64 write in flight

	reg  [3:0] state;
	// 32-bit monotonic doorbell count (ring index = wptr[7:0]); published in
	// full so the host can tell a ring wrap from an FPGA reset.
	reg [31:0] wptr;
	reg        wptr_published;
	reg [63:0] cmd_entry;      // pending ring entry (one deep)
	reg        cmd_queued;
	reg        cmd_for_cpu;    // the stalled CPU cycle completes on publish
	reg [15:0] poll_div;
	reg  [4:0] poll_step;      // walks MAGIC, SHAD0-15, INT, MACPROM, RPTR
	reg  [4:0] poll_step_q;
	reg        rst_guest_d;

	// ring backpressure: the host publishes its read index (AV_RPTR, polled
	// below); if a doorbell burst gets ~200 entries ahead the publish stalls —
	// bounded by cmd_wait_ctr (~2 ms) so a dead host can never hang the
	// guest, it just loses entries it wasn't reading anyway.
	reg [31:0] rptr_sh;
	reg [15:0] cmd_wait_ctr;
	wire       ring_full = (wptr - rptr_sh) >= 32'd200;

	// fast polling while the doorbell is backpressured (rptr_sh must refresh
	// to release it).
	wire       poll_due  = (cmd_queued && ring_full) ? (poll_div[4:0] == 5'h1F)
	                     : magic_ok ? (poll_div[9:0] == 10'h3FF)
	                     : (poll_div == 16'hFFFF);

	// ── interrupt-ack livelock fix: irq suppression timer ───────────────────
	// The INT line the guest sees comes from Main's INT word, which lags the
	// guest's own ISR write-1-to-clear by ~1.6 ms. In that window the 68k
	// RTEs, still sees the IPL asserted, re-enters its handler and re-clears —
	// a livelock under load (measured ~120x per real interrupt on the LC
	// card). Fix: when the guest writes ISR (write-1-to-clear), hold irq LOW
	// for one round trip (IRQ_SUPP), then let irq follow Main's INT word
	// again. Delay only: never masks a bit, never fabricates or sticks an
	// interrupt (irq is always ANDed with Main's INT word), cannot deadlock.
	wire        isr_wr_now  = (hstate == H_RUN) && (req_kind == K_REGWR)
	                          && (reg_idx == 6'd5) && !cmd_queued;
	// ~1.85 ms at clk_sys ~32.5 MHz — covers the shadow round trip while staying
	// far below the RX descriptor-ring fill time at 10BASE-T rates.
	localparam [16:0] IRQ_SUPP = 17'd60000;

	integer i;
	always @(posedge clk_sys) begin
		if (rst_core) begin
			state       <= S_IDLE;
			hstate      <= H_IDLE;
			h_wd        <= 0;
			h_abort     <= 1'b0;
			mem_rd      <= 0;
			mem_we      <= 0;
			mem_burst   <= 8'd1;
			mem_addr    <= 0;
			mem_wdata   <= 0;
			mem_be      <= 8'hFF;
			wptr        <= 0;
			wptr_published <= 0;
			cmd_queued  <= 0;
			cmd_for_cpu <= 0;
			poll_div    <= 0;
			poll_step   <= 0;
			poll_step_q <= 0;
			rst_guest_d <= 0;
			magic_ok    <= 0;
			int_state   <= 0;
			present     <= 0;
			macprom     <= 0;
			rptr_sh     <= 0;
			cmd_wait_ctr<= 0;
			dout_r      <= 16'hFFFF;
			req_sub     <= 0;
			req_be      <= 0;
			req_wdata   <= 0;
			req_kind    <= K_STUB;
			irq_supp    <= 17'h0;
			isr_mask    <= 16'h0;
			isr_mask_tmr<= 17'h0;
			rc_data     <= 64'h0;
			rc_tag      <= 14'h0;
			rc_valid    <= 1'b0;
			rc_ttl      <= 8'h0;
			rc_hit      <= 1'b0;
			for (i = 0; i < 16; i = i + 1) shad[i] <= 64'h0;
		end else begin
			mem_rd <= 0;
			mem_we <= 0;
			poll_div <= poll_div + 1'b1;

			// irq suppression timer (the ONLY driver of irq_supp): a guest ISR
			// write-1-to-clear (re)arms it to IRQ_SUPP so irq is held low for one
			// shadow round trip; otherwise it counts down to 0, at which point irq
			// again follows Main's INT word. Never masks a bit, never sticks.
			if (isr_wr_now)          irq_supp <= IRQ_SUPP;
			else if (irq_supp != 0)  irq_supp <= irq_supp - 17'd1;

			// timed ISR clear-mask (see the decl block): the acked bits read
			// back clear at once; the mask lives one IRQ_SUPP round trip past
			// the LAST ack, by which time Main has applied it into the shadow.
			if (isr_wr_now) begin
				isr_mask     <= isr_mask | req_wdata;
				isr_mask_tmr <= IRQ_SUPP;
			end
			else if (isr_mask_tmr != 0) isr_mask_tmr <= isr_mask_tmr - 17'd1;
			else                        isr_mask     <= 16'h0;

			// read-cache lifetime: the TTL bounds ARM-write staleness, any
			// guest card-RAM write invalidates. The DDR3-answer fill in
			// S_MEM_RD_D below is later in the block, so a same-cycle fill
			// wins over the expiry — and a fill can never coincide with a
			// write's classification (one CPU request at a time).
			if (rc_valid) begin
				if (rc_ttl == 8'd0) rc_valid <= 1'b0;
				else                rc_ttl   <= rc_ttl - 8'd1;
			end
			if (hstate == H_IDLE && req && sel_ram && !_cpuRW)
				rc_valid <= 1'b0;

			// presence can only change while the guest is held in reset; once
			// running it is frozen so the Slot Manager never sees the card
			// flicker. Sticky-rise on MAGIC within the reset window: rst_core
			// is hard-reset only, so a warm restart keeps the mailbox state
			// and just re-evaluates presence (and a host death mid-session
			// deliberately does NOT clear it — DDR3 keeps serving the RAM and
			// registers, writes still complete since they only wait on DDR3).
			rst_guest_d <= rst_guest;
			if (rst_guest) begin
				if (!ena_osd)      present <= 1'b0;
				else if (magic_ok) present <= 1'b1;
				// tell the host to reset its SONIC model (once per reset entry)
				if (!rst_guest_d && present && !cmd_queued && magic_ok) begin
					cmd_entry   <= {60'b0, TAG_RESET, 1'b1};
					cmd_queued  <= 1'b1;
					cmd_for_cpu <= 1'b0;
				end
			end

			// ── CPU handshake ────────────────────────────────────────────
			case (hstate)
			H_IDLE: if (req) begin
				req_sub   <= sub;
				req_be    <= {~_cpuUDS, ~_cpuLDS};
				req_wdata <= cpuDataIn;
				dout_r    <= 16'hFFFF;
				// registered cache verdict for this request (consumed in H_RUN)
				rc_hit    <= rc_valid && _cpuRW && sel_ram && (rc_tag == sub[16:3]);
				// classify. declROM: only guest bytes 4k/4k+1 carry data (the
				// lane-1 x4 expansion), so words at sub[1]==1 are a constant
				// $0000 with no DDR3 trip.
				if (sel_ram)                 req_kind <= _cpuRW ? K_RAMRD : K_RAMWR;
				else if (reg_rd)             req_kind <= K_REGRD;
				else if (reg_wr)             req_kind <= K_REGWR;
				else if (sel_mac && _cpuRW)  req_kind <= K_MACRD;
				else if (sel_rom && _cpuRW)  req_kind <= sub[1] ? K_ROM0 : K_ROM;
				else                         req_kind <= K_STUB;
				h_abort <= 1'b0;
				hstate  <= H_RUN;
			end
			H_RUN: begin
				case (req_kind)
				K_REGRD: begin
					dout_r <= sonic_rdata;
					hstate <= H_DONE;
				end
				K_REGWR: begin
					if (!cmd_queued) begin
						cmd_entry   <= {24'b0, 8'b0, req_wdata, 6'b0, reg_idx, TAG_REG_WR, 1'b1};
						cmd_queued  <= 1'b1;
						cmd_for_cpu <= 1'b1;   // H_DONE comes from the publish path
						// (an ISR write also arms the irq suppression timer via
						// isr_wr_now above, killing the interrupt-ack livelock.)
					end
				end
				K_MACRD: begin
					dout_r <= {8'h00, prom_byte};
					hstate <= H_DONE;
				end
				K_ROM0: begin
					dout_r <= 16'h0000;
					hstate <= H_DONE;
				end
				K_STUB: begin
					dout_r <= 16'hFFFF;
					hstate <= H_DONE;
				end
				K_RAMRD: if (rc_hit) begin
					// cache hit: serve the lanes straight from the held u64
					dout_r[15:8] <= rc_data[{lane,        3'b000} +: 8];
					dout_r[7:0]  <= rc_data[{lane + 3'd1, 3'b000} +: 8];
					hstate <= H_DONE;
				end
				default: ;   // K_ROM / K_RAMRD-miss / K_RAMWR complete via the mailbox FSM
				endcase
			end
			H_DONE: begin
				if (_cpuAS || !ds_any) hstate <= H_IDLE;
			end
			default: hstate <= H_IDLE;
			endcase

			// ── mailbox FSM ──────────────────────────────────────────────
			if (cmd_queued && ring_full && state == S_IDLE) begin
				if (!(&cmd_wait_ctr)) cmd_wait_ctr <= cmd_wait_ctr + 1'b1;
			end else if (!cmd_queued)
				cmd_wait_ctr <= 0;

			case (state)
			S_IDLE: begin
				if (!wptr_published) begin
					mem_addr  <= AV_BASE + {14'b0, AV_WPTR};
					mem_wdata <= 64'd0;
					mem_be    <= 8'hFF;
					mem_we    <= 1;
					state     <= S_WPTR_INIT;
				end else if (cmd_queued && (!ring_full || (&cmd_wait_ctr))) begin
					mem_addr  <= AV_BASE + {14'b0, AV_RING} + {21'b0, wptr[7:0]};
					mem_wdata <= cmd_entry;
					mem_be    <= 8'hFF;
					mem_we    <= 1;
					state     <= S_CMD_W;
				end else if (hstate == H_RUN && req_kind == K_ROM) begin
					mem_addr <= rom_word;
					mem_rd   <= 1;
					state    <= S_MEM_RD_W;
				end else if (hstate == H_RUN && req_kind == K_RAMRD && !rc_hit) begin
					mem_addr <= ram_word;
					mem_rd   <= 1;
					state    <= S_MEM_RD_W;
				end else if (hstate == H_RUN && req_kind == K_RAMWR) begin
					mem_addr  <= ram_word;
					mem_wdata <= {2{req_wdata[7:0], req_wdata[15:8],
					               req_wdata[7:0], req_wdata[15:8]}};
					mem_be    <= ({6'b0, req_be[0], req_be[1]} << lane);
					mem_we    <= 1;
					state     <= S_RAM_W;
				end else if (poll_due) begin
					poll_step_q <= poll_step;
					mem_addr <= AV_BASE + {14'b0,
					            (poll_step == 5'd0)  ? AV_MAGIC   :
					            (poll_step == 5'd17) ? AV_INT     :
					            (poll_step == 5'd18) ? AV_MACPROM :
					            (poll_step == 5'd19) ? AV_RPTR    :
					                                   AV_SHAD + {10'b0, poll_step - 5'd1}};
					mem_rd   <= 1;
					state    <= S_POLL_W;
				end
			end

			S_CMD_W: begin
				if (!mem_busy) begin
					mem_addr  <= AV_BASE + {14'b0, AV_WPTR};
					mem_wdata <= {32'b0, wptr + 32'd1};
					mem_be    <= 8'hFF;
					mem_we    <= 1;
					wptr      <= wptr + 32'd1;
					state     <= S_WPTR_W;
				end else mem_we <= 1;
			end

			S_WPTR_W: begin
				if (!mem_busy) begin
					cmd_queued <= 0;
					if (cmd_for_cpu) begin
						cmd_for_cpu <= 0;
						hstate      <= H_DONE;   // register write retires
					end
					state <= S_IDLE;
				end else mem_we <= 1;
			end

			S_WPTR_INIT: begin
				if (!mem_busy) begin
					wptr_published <= 1;
					state <= S_IDLE;
				end else mem_we <= 1;
			end

			S_MEM_RD_W: begin
				if (!mem_busy) state <= S_MEM_RD_D;
				else mem_rd <= 1;
			end

			S_MEM_RD_D: begin
				if (mem_rvalid) begin
					// A watchdog-abandoned read still lands here later. Consume and
					// drop it: retiring here would ack the NEXT access early, with
					// this read's stale data.
					if (!h_abort) begin
						if (req_kind == K_ROM) begin
							// lane-1 expansion: guest word 4k+{0,1} = {$00, raw[k]}
							dout_r <= {8'h00, mem_rdata[{rom_lane, 3'b000} +: 8]};
						end else begin
							dout_r[15:8] <= mem_rdata[{lane,        3'b000} +: 8];
							dout_r[7:0]  <= mem_rdata[{lane + 3'd1, 3'b000} +: 8];
							// cache fill: the u64 this answer carries (K_RAMRD
							// only — h_abort answers never land here)
							rc_data  <= mem_rdata;
							rc_tag   <= req_sub[16:3];
							rc_valid <= 1'b1;
							rc_ttl   <= 8'd255;
						end
						hstate <= H_DONE;
					end
					state <= S_IDLE;
				end
			end

			S_RAM_W: begin
				if (!mem_busy) begin
					mem_be <= 8'hFF;   // restore the default for other writers
					// posted: the cycle retires once the controller accepts it
					if (!h_abort) hstate <= H_DONE;
					state <= S_IDLE;
				end else mem_we <= 1;
			end

			S_POLL_W: begin
				if (!mem_busy) state <= S_POLL_D;
				else mem_rd <= 1;
			end

			S_POLL_D: begin
				if (mem_rvalid) begin
					case (poll_step_q)
					5'd0:  magic_ok  <= (mem_rdata == MAGIC_V);
					5'd17: int_state <= mem_rdata[0];
					5'd18: macprom   <= mem_rdata;
					5'd19: rptr_sh   <= mem_rdata[31:0];
					default: shad[poll_step_q[3:0] - 4'd1] <= mem_rdata;
					endcase
					// walk the full set only when the card is live; otherwise
					// just keep sampling MAGIC.
					if (magic_ok || poll_step_q != 5'd0)
						poll_step <= (poll_step_q == 5'd19) ? 5'd0 : poll_step_q + 5'd1;
					state <= S_IDLE;
				end
			end

			default: state <= S_IDLE;
			endcase

			// ── host-access watchdog ─────────────────────────────
			// Last assignment in the block, so it wins over either FSM above.
			if (hstate == H_RUN) begin
				if (h_wd[H_WD_BIT]) begin
					hstate      <= H_DONE;   // retire the cycle: open bus
					dout_r      <= 16'hFFFF;
					cmd_for_cpu <= 1'b0;     // must not retire a LATER access
					h_abort     <= 1'b1;
					h_wd        <= 0;
				end else h_wd <= h_wd + 1'b1;
			end else h_wd <= 0;
		end
	end

	// irq = Main's INT word, but held low for one shadow round trip after each
	// guest ISR write (irq_supp) so the guest can't re-enter its handler on the
	// stale-high line — the interrupt-ack livelock fix. Delay only: never sticks.
	assign irq = present && int_state && (irq_supp == 17'd0);

endmodule
