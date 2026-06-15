/*
 * cpu030_wrapper — Mac-bus wrapper for the MC68030 TG68K kernel (MacIIvi).
 *
 * Adapted from MacLC's tg68k.v. Drives the kernel's clkena/busstate engine onto
 * the Mac async bus (AS/UDS/LDS/DTACK), generates the 6800 E clock + VMA for the
 * VIA, supplies auto-vectors (the kernel runs non-autovector), and holds BERR
 * across the bus cycle (berr_hold) so the chipset's async BERR — e.g. the FC=7
 * CPU-space ROM probe and the NuBus empty-slot timeout — is not missed at the
 * kernel's s_state-7 sample point.
 *
 * Phase 2 scope: MMU + cache are BYPASSED.
 *   - TC.E = 0 out of reset, so the kernel's addr_out is already the physical
 *     address (logical = physical). The PMMU table-walker bus is tied idle.
 *   - The 030 data/instruction caches live in TG68K.vhd, not the bare kernel,
 *     so this wrapper has no cache in the bus path yet.
 * Phase 3 adds the cache (wrap TG68K instead of the bare kernel, connect the
 * cache-fill bus to SDRAM). Phase 4 routes pmmu_addr_phys once translation is on.
 */

module cpu030_wrapper (
	input clk,
	input reset,
	input phi1,
	input phi2,

	input  dtack_n,
	output rw_n,
	output as_n,
	output uds_n,
	output lds_n,
	output [2:0] fc,
	output reset_n,

	output reg E,
	input E_div,
	output E_PosClkEn,
	output E_NegClkEn,
	output vma_n,
	input vpa_n,

	input br_n,
	output bg_n,
	input bgack_n,

	input [2:0] ipl,
	input berr,
	input [15:0] din,
	output [15:0] dout,
	output longword,        // 1 = current access is a 32-bit (longword) access
	output reg [31:0] addr,

	// Debug
	output [1:0] busstate
);

wire  [1:0] tg68_busstate;
wire        tg68_clkena = phi1 && (s_state == 7 || tg68_busstate == 2'b01);
wire [31:0] tg68_addr;
wire [15:0] tg68_din;
reg  [15:0] tg68_din_r;
wire        tg68_uds_n;
wire        tg68_lds_n;
wire        tg68_rw;

// The kernel uses non-autovector interrupts; provide the auto-vectors here.
wire auto_iack = fc == 3'b111 && !vpa_n;
wire [7:0] auto_vector = {4'h1, 1'b1, addr[3:1]};
assign tg68_din = auto_iack ? {auto_vector, auto_vector} : din;

reg         uds_n_r;
reg         lds_n_r;
reg         rw_r;
reg         as_n_r;

assign      as_n = as_n_r;
assign      uds_n = uds_n_r;
assign      lds_n = lds_n_r;
assign      rw_n = rw_r;

reg   [2:0] s_state;

always @(posedge clk) begin
	if (reset) begin
		s_state <= 0;
		as_n_r <= 1;
		rw_r <= 1;
		uds_n_r <= 1;
		lds_n_r <= 1;
	end else begin
		addr <= tg68_addr;

		if (phi1) begin

			if (s_state != 4) s_state <= s_state + 1'd1;
			if (busreq_ack || bus_granted) s_state <= s_state;
			if (tg68_busstate == 2'b01) s_state <= 0;

			case (s_state)
				1: if (tg68_busstate != 2'b01) begin
					rw_r <= tg68_rw;
					if (tg68_rw) begin
						uds_n_r <= tg68_uds_n;
						lds_n_r <= tg68_lds_n;
					end
					as_n_r <= 0;
				end
				3: if (tg68_busstate != 2'b01) begin
					if (!tg68_rw) begin
						uds_n_r <= tg68_uds_n;
						lds_n_r <= tg68_lds_n;
					end
				end
				7: rw_r <= 1;
				default :;
			endcase

		end else if (phi2) begin

			if (s_state != 4 || tg68_busstate == 2'b01 || !dtack_n || xVma || berr)
				s_state <= s_state + 1'd1;
			if ((busreq_ack || bus_granted) && !busrel_ack) s_state <= s_state;
			if (tg68_busstate == 2'b01) s_state <= 0;

			case (s_state)
				6: begin
					tg68_din_r <= tg68_din;
					uds_n_r <= 1;
					lds_n_r <= 1;
					as_n_r <= 1;
				end
				default :;
			endcase

		end
	end
end

// E clock and counter, VMA (from FX68K)
reg [3:0] eCntr;
reg rVma;
reg Vpai;
assign vma_n = rVma;

wire xVma = ~rVma & (eCntr == 8) & en_E;

assign E_PosClkEn = (phi2 & (eCntr == 5) & en_E);
assign E_NegClkEn = (phi2 & (eCntr == 9) & en_E);

reg en_E;

always @( posedge clk) begin
	if (reset) begin
		E <= 1'b0;
		eCntr <=0;
		rVma <= 1'b1;
		en_E <= 1'b1;
	end else begin
		if (phi1) begin
			Vpai <= vpa_n;
			if (E_div) en_E <= !en_E; else en_E <= 1'b1;
		end

		if (phi2 & en_E) begin
			if (eCntr == 9)
				E <= 1'b0;
			else if (eCntr == 5)
				E <= 1'b1;

			if (eCntr == 9)
				eCntr <= 0;
			else
				eCntr <= eCntr + 1'b1;
		end

		if (phi2 & s_state != 0 & ~Vpai & (eCntr == 3) & en_E)
			rVma <= 1'b0;
		else if (phi1 & eCntr == 0 & en_E)
			rVma <= 1'b1;
	end
end

// Bus arbitration
reg bg_n_r;
assign bg_n = bg_n_r;

wire busreq_ack = !br_n && s_state == 0;
wire busrel_ack = bus_acked && !bgack;

reg bgack, bus_granted, bus_acked, bus_acked_d;

always @(posedge clk) begin
	if (reset) begin
		bg_n_r <= 1;
		bus_granted <= 0;
		bus_acked <= 0;
	end else begin
		if (phi1) begin
			bgack <= ~bgack_n;
			bus_acked_d <= bus_acked;
		end
		if (phi2) begin
			if (busreq_ack) begin
				bg_n_r <= 0;
				bus_granted <= 1;
				bus_acked <= bgack;
			end
			if (bus_granted && bgack) bus_acked <= 1;
			if (bus_granted && bus_acked_d) bg_n_r <= 1;
			if (busrel_ack) begin
				bus_acked <= 0;
				bus_granted <= 0;
			end
		end
	end
end

// Hold BERR across the bus cycle. AS deasserts at s_state 6 but the kernel only
// samples berr at s_state 7 (tg68_clkena pulse). Without holding it, the kernel
// sees berr=0 at the sample point and never latches make_berr, so the bus-error
// exception is missed. Latch berr for the cycle.
//
// CRITICAL for the 68030 kernel: release the hold the instant the kernel latches
// the fault (make_berr) or starts the trap (trap_berr). Otherwise the held berr
// is still asserted when the kernel enters its bus-error exception window
// (berr_exception_active), where it re-samples make_berr and mistakes the SAME
// fault for a *second* one -> DOUBLE BUS FAULT -> cpu_halted (a halted-but-clocked
// CPU only prefetches, which looks like a PC runaway). The ROM's FC=7 MOVES probe
// hits this on every boot. (Verified + fixed in MacLC: commit c050221.)
wire kernel_make_berr;
wire kernel_trap_berr;
reg berr_hold;
always @(posedge clk) begin
	if (reset)
		berr_hold <= 1'b0;
	else if (kernel_make_berr || kernel_trap_berr || (phi1 && s_state == 0))
		berr_hold <= 1'b0;
	else if (berr)
		berr_hold <= 1'b1;
end
wire berr_held = (berr | berr_hold) & ~(kernel_make_berr | kernel_trap_berr);

TG68KdotC_Kernel cpu (
	.clk            ( clk           ),
	.nReset         ( ~reset        ),
	.clkena_in      ( tg68_clkena   ),
	.data_in        ( tg68_din_r    ),
	.IPL            ( ipl           ),
	.IPL_autovector ( 1'b0          ),
	.berr           ( berr_held     ),
	.CPU            ( 2'b10         ), // 68030
	.addr_out       ( tg68_addr     ),
	.data_write     ( dout          ),
	.nUDS           ( tg68_uds_n    ),
	.nLDS           ( tg68_lds_n    ),
	.nWr            ( tg68_rw       ),
	.busstate       ( tg68_busstate ), // 00 fetch 10 read 11 write 01 idle
	.longword       ( longword      ),
	.nResetOut      ( reset_n       ),
	.FC             ( fc            ),
	// PMMU table-walker bus tied idle (TC.E=0 -> no walks while MMU is off).
	// Phase 4 will route these to a memory arbiter (see MacLC tg68k.v walker).
	.pmmu_walker_ack ( 1'b0         ),
	.pmmu_walker_data( 32'b0        ),
	.pmmu_walker_berr( 1'b0         ),
	// Bus-error status used by the berr-hold release above (prevents the spurious
	// 030 double bus fault on the ROM's FC=7 MOVES probe).
	.debug_make_berr ( kernel_make_berr ),
	.debug_trap_berr ( kernel_trap_berr )
	// other cache_* / cacr_* / pmmu_reg_* / pmmu_addr_* / debug_* outputs left open
);

assign busstate = tg68_busstate;

endmodule
