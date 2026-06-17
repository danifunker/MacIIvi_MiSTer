/*
 68000 compatible bus-wrapper for TG68K
 */

module tg68k (
	input clk,
	input reset,
	input phi1,
	input phi2,
	input [1:0] cpu,

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

	// Debug outputs
	output [1:0] busstate
);

wire  [1:0] tg68_busstate;
// Suppress clkena while the walker is borrowing the bus so the (stalled) CPU
// pipeline does not advance during a page-table walk.
wire        tg68_clkena = phi1 && (s_state == 7 || tg68_busstate == 2'b01) && !walk_cycle;
wire [31:0] tg68_addr;
wire [15:0] tg68_din;
reg  [15:0] tg68_din_r;
wire        tg68_uds_n;
wire        tg68_lds_n;
wire        tg68_rw;

// ---------------------------------------------------------------------------
// 68030 PMMU table-walk bus master
//
// On an ATC miss the kernel's PMMU walks the page tables: it asserts
// pmmu_walker_req with a 32-bit *physical* descriptor address (page tables live
// in RAM) and waits for pmmu_walker_ack + pmmu_walker_data; pmmu_walker_we marks
// a descriptor write-back (Used/Modified bits). While walking, the kernel forces
// busstate="01" and deasserts UDS/LDS, so the main bus state machine below is
// parked (s_state stays 0, AS high). We borrow the Mac 68K bus during that
// window to transfer the 32-bit descriptor as two big-endian 16-bit cycles,
// reusing the proven s_state timing via the eff_* overrides.
// ---------------------------------------------------------------------------
wire        pmmu_walker_req;
wire        pmmu_walker_we;
wire [31:0] pmmu_walker_addr;
wire [31:0] pmmu_walker_wdat;
reg         pmmu_walker_ack;
reg  [31:0] pmmu_walker_data;
wire        pmmu_walker_berr = 1'b0;   // walker bus errors unreported (PMMU has a 500-cycle timeout)
wire [15:0] tg68_dout_k;               // kernel data_write, muxed with walker write data

// Kernel bus-error status (from the kernel's debug outputs). Used by the berr
// hold logic below to release the held berr the instant the kernel latches the
// fault, so the 030 double-bus-fault detector doesn't see the same fault twice.
wire        kernel_make_berr;
wire        kernel_trap_berr;

reg         walk_cycle;   // 1 = a walker word transfer is borrowing the bus
reg         walk_word;    // 0 = high word @addr, 1 = low word @addr+2
reg  [15:0] walk_hi;      // captured high word (big-endian: bits 31:16)

wire [31:0] walk_word_addr = walk_word ? (pmmu_walker_addr | 32'd2) : (pmmu_walker_addr & ~32'd2);
wire [15:0] walk_dout_word = walk_word ? pmmu_walker_wdat[15:0]     : pmmu_walker_wdat[31:16];

// Effective bus controls: the walker drives the (otherwise parked) main bus
// during a walk; outside a walk these are exactly the kernel's signals.
wire [1:0]  eff_busstate = walk_cycle ? (pmmu_walker_we ? 2'b11 : 2'b10) : tg68_busstate;
wire        eff_rw       = walk_cycle ? ~pmmu_walker_we : tg68_rw;
wire        eff_uds_n    = walk_cycle ? 1'b0 : tg68_uds_n;
wire        eff_lds_n    = walk_cycle ? 1'b0 : tg68_lds_n;
wire [31:0] eff_addr     = walk_cycle ? walk_word_addr : tg68_addr;

// The tg68k core doesn't reliably support mixed usage of autovector and non-autovector
// interrupts, so the TG68K kernel switched to non-autovector interrupts, and the 
// auto-vectors are provided here.
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
		addr <= eff_addr;

		if (phi1) begin

			// The cycle micro-sequencer relies on a fixed parity: AS is asserted at
			// s_state 1 in THIS phi1 branch and deasserted at s_state 6 in the phi2
			// branch, i.e. odd s_state must fall on phi1 and even on phi2. The
			// variable-length wait at s_state 4 (DTACK is slot-aligned, so it can
			// last an ODD number of phi edges) and PMMU walks (clkena suppressed)
			// can flip that parity; a subsequent cycle then passes s_state 1 on a
			// phi2 edge, the AS-assert is skipped, and the access runs to s_state 4
			// with AS deasserted and never gets DTACK (LC II PMMU-enable deadlock,
			// docs/findings_pmmu_walk_stall_2026-06-15.md). Re-sync every cycle by
			// only LEAVING s_state 0 on phi2 (`s_state != 0` here), exactly as a
			// clkena-gated kernel cycle already does — guaranteeing s_state 1 lands
			// on phi1 and AS asserts, regardless of any prior parity flip.
			if (s_state != 4 && s_state != 3'd0) s_state <= s_state + 1'd1;
			if (busreq_ack || bus_granted) s_state <= s_state;
			if (eff_busstate == 2'b01) s_state <= 0;

			case (s_state)
				1: if (eff_busstate != 2'b01) begin
					rw_r <= eff_rw;
					if (eff_rw) begin
						uds_n_r <= eff_uds_n;
						lds_n_r <= eff_lds_n;
					end
					as_n_r <= 0;
				end
				3: if (eff_busstate != 2'b01) begin
					if (!eff_rw) begin
						uds_n_r <= eff_uds_n;
						lds_n_r <= eff_lds_n;
					end
				end
				7: rw_r <= 1;
				default :;
			endcase

		end else if (phi2) begin

			if (s_state != 4 || eff_busstate == 2'b01 || !dtack_n || xVma || berr)
				s_state <= s_state + 1'd1;
			if ((busreq_ack || bus_granted) && !busrel_ack) s_state <= s_state;
			if (eff_busstate == 2'b01) s_state <= 0;

			case (s_state)

				6: begin
					// During a walk the descriptor word is captured by the walker
					// FSM (from din); don't clobber the CPU's data_in latch.
					if (!walk_cycle) tg68_din_r <= tg68_din;
					uds_n_r <= 1;
					lds_n_r <= 1;
					as_n_r <= 1;
				end
				default :;
			endcase

		end
	end
end

// from FX68K
// E clock and counter, VMA
reg [3:0] eCntr;
reg rVma;
reg Vpai;
assign vma_n = rVma;

// Internal stop just one cycle before E falling edge
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

// process the bus request at the start of any bus cycle
// (start at only instruction fetch doesn't work well with ACSI DMA)
wire busreq_ack = !br_n /*&& tg68_busstate == 0*/ && s_state == 0;
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

	// Hold BERR across the bus cycle. The external berr (e.g. FC=7 CPU-space probe)
	// is gated on AS being asserted, but AS deasserts at s_state 6 while the kernel
	// only samples berr at s_state 7 (when tg68_clkena pulses). Without holding it,
	// the kernel sees berr=0 at the sample point and never latches make_berr, so the
	// bus-error exception is missed. Latch berr for the duration of the cycle.
	//
	// CRITICAL for the 68030 kernel: release the hold as soon as the kernel latches
	// the fault (make_berr) or starts the trap (trap_berr). Otherwise the held berr
	// is still asserted when the kernel enters its bus-error exception window
	// (berr_exception_active), where it re-samples make_berr and mistakes the SAME
	// fault for a *second* one -> double bus fault -> cpu_halted. (The old 68000/020
	// kernel had no double-fault detector, so holding to s_state 0 was harmless.)
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

	TG68KdotC_Kernel tg68k (
		.clk            ( clk           ),
		.nReset         ( ~reset        ),
		.clkena_in      ( tg68_clkena   ),
		.data_in        ( tg68_din_r    ),
		.IPL            ( ipl           ),
		.IPL_autovector ( 1'b0          ),
		.berr           ( berr_held     ),
		.clr_berr       ( /*tg68_clr_berr*/ ),
		.CPU            ( cpu           ), // 00->68000  01->68010  10->68030 (PMMU+caches, 030_mmu branch)
		.addr_out       ( tg68_addr     ),
		.data_write     ( tg68_dout_k   ),
		.nUDS           ( tg68_uds_n    ),
		.nLDS           ( tg68_lds_n    ),
		.nWr            ( tg68_rw       ),
		.busstate       ( tg68_busstate ), // 00-> fetch code 10->read data 11->write data 01->no memaccess
		.longword       ( longword      ),
		.nResetOut      ( reset_n       ),
		.FC             ( fc            ),

		// 68030 PMMU table-walker memory interface — wired to the Mac bus via the
		// walker bus master below, so page-table walks read/write real RAM.
		.pmmu_walker_req  ( pmmu_walker_req  ),
		.pmmu_walker_we   ( pmmu_walker_we   ),
		.pmmu_walker_addr ( pmmu_walker_addr ),
		.pmmu_walker_wdat ( pmmu_walker_wdat ),
		.pmmu_walker_ack  ( pmmu_walker_ack  ),
		.pmmu_walker_data ( pmmu_walker_data ),
		.pmmu_walker_berr ( pmmu_walker_berr ),

		// Bus-error status used by the berr-hold release logic above (prevents a
		// spurious 030 double bus fault on the ROM's FC=7 MOVES probe).
		.debug_make_berr ( kernel_make_berr ),
		.debug_trap_berr ( kernel_trap_berr )

		// All other new 030 ports (skipFetch, regin_out, CACR_out, VBR_out,
		// cache_*/cacr_*, pmmu_reg_*/pmmu_addr_*, cache_op_addr and the debug_*
		// bus) are outputs left intentionally unconnected. The on-chip caches
		// (TG68K_Cache_030) are not instantiated; the kernel runs uncached.
	);

	// Drive the Mac data bus from the walker during descriptor write-backs,
	// otherwise from the kernel.
	assign dout = walk_cycle ? walk_dout_word : tg68_dout_k;

	// Walker control FSM: sequence two 16-bit transfers per 32-bit descriptor.
	// Starts only when the kernel requests a walk AND the main bus is parked
	// (busstate="01" while pmmu_busy), guaranteeing no conflict with a CPU cycle.
	always @(posedge clk) begin
		if (reset) begin
			walk_cycle       <= 1'b0;
			walk_word        <= 1'b0;
			walk_hi          <= 16'h0;
			pmmu_walker_ack  <= 1'b0;
			pmmu_walker_data <= 32'h0;
		end else begin
			pmmu_walker_ack <= 1'b0;   // single-cycle ack pulse

			if (!walk_cycle) begin
				// Start the walk cycle ONLY on phi1, matching the kernel's own
				// clkena (phi1) cycle-start alignment. The main bus FSM asserts AS
				// at s_state 1 in its phi1 branch only; if walk_cycle instead rises
				// on a phi2 sub-edge, s_state passes through 1 on a phi2 edge where
				// the AS-assert is skipped, so the walker read runs to s_state 4
				// (wait-DTACK) with AS deasserted, never gets a DTACK, and deadlocks
				// the page-table walk (the second back-to-back descriptor read hung
				// exactly this way — see docs/findings_pmmu_walk_stall_2026-06-15.md).
				if (phi1 && pmmu_walker_req && !pmmu_walker_ack &&
				    s_state == 3'd0 && tg68_busstate == 2'b01) begin
					walk_cycle <= 1'b1;
					walk_word  <= 1'b0;   // high word first
				end
			end else begin
				// Capture the read word at the data phase (s_state 6, phi2).
				if (phi2 && s_state == 3'd6) begin
					if (!walk_word) walk_hi          <= din;
					else            pmmu_walker_data <= {walk_hi, din};
				end
				// Word transfer completes at s_state 7 (phi1).
				if (phi1 && s_state == 3'd7) begin
					if (!walk_word) begin
						walk_word <= 1'b1;        // proceed to low word
					end else begin
						walk_cycle      <= 1'b0;  // descriptor done
						pmmu_walker_ack <= 1'b1;  // data already latched at s_state 6
					end
				end
			end
		end
	end

	`ifdef VERBOSE_TRACE
	always @(posedge clk) begin
		if (tg68_clkena && tg68_busstate == 2'b00)
			$display("TG68: FETCH PC=%h opcode=%h @%0t", tg68_addr, tg68_din_r, $time);
	end
	`endif

	`ifdef PMMU_TRACE
	// Focused PMMU table-walk + stall probe (does NOT spam per-fetch).
	//  * logs each walk request/ack (capped) with the descriptor addr/data,
	//  * logs make_berr/trap_berr edges,
	//  * a heartbeat dump of the CPU/walker bus state so a post-pmove(tc) stall
	//    is visible (the main cpu_trace goes blind once the kernel parks the bus
	//    in a never-completing walk). Enable with +define+PMMU_TRACE.
	reg        walk_cycle_d, mberr_d, tberr_d, wreq_d;
	reg [31:0] dbg_cyc;
	reg [31:0] dbg_walks;
	always @(posedge clk) begin
		if (reset) begin
			walk_cycle_d <= 0; mberr_d <= 0; tberr_d <= 0; wreq_d <= 0;
			dbg_cyc <= 0; dbg_walks <= 0;
		end else begin
			dbg_cyc      <= dbg_cyc + 1'b1;
			walk_cycle_d <= walk_cycle;
			wreq_d       <= pmmu_walker_req;
			mberr_d      <= kernel_make_berr;
			tberr_d      <= kernel_trap_berr;

			// walk request edge (kernel asked for a descriptor)
			if (pmmu_walker_req && !wreq_d && dbg_walks < 32'd400) begin
				$display("PMMU REQ #%0d addr=%h we=%b (kernel PC~%h) @%0t",
				         dbg_walks, pmmu_walker_addr, pmmu_walker_we, tg68_addr, $time);
				dbg_walks <= dbg_walks + 1'b1;
			end
			// walk completion (ack pulse)
			if (pmmu_walker_ack && dbg_walks < 32'd400)
				$display("PMMU ACK  data=%h @%0t", pmmu_walker_data, $time);

			if (kernel_make_berr && !mberr_d)
				$display("PMMU make_berr  addr=%h s_state=%0d busstate=%b @%0t", tg68_addr, s_state, tg68_busstate, $time);
			if (kernel_trap_berr && !tberr_d)
				$display("PMMU trap_berr  addr=%h @%0t", tg68_addr, $time);

			// heartbeat: periodic bus-state dump (catches a stalled/looping walk)
			if (dbg_cyc[17:0] == 18'd0)
				$display("PMMU HB cyc=%0d kpc=%h sstate=%0d bs=%b walk=%b wreq=%b waddr=%h berrh=%b dtack=%b @%0t",
				         dbg_cyc, tg68_addr, s_state, tg68_busstate, walk_cycle,
				         pmmu_walker_req, pmmu_walker_addr, berr_held, dtack_n, $time);
		end
	end
	`endif
// Expose busstate for debugging
assign busstate = tg68_busstate;

endmodule
