/*
 68000 compatible bus-wrapper for TG68K
 */

module tg68k (
	input clk,
	input reset,
	input phi1,
	input phi2,
	input [1:0] cpu,
	// Performa 600 mode (latched at core reset by the top): pulse the kernel's
	// clkena on BOTH phi edges for beats that never touch the Mac bus (internal
	// busstate=01 micro-cycles and cache read-hits) — "32 MHz" core, 16 MHz bus.
	// That is the real P600/IIvx shape: 32 MHz 68030 on the IIvi's 16 MHz bus,
	// so bus cycles, the phi grid, E/VIA pacing and every peripheral rate are
	// UNTOUCHED. With cpu_turbo=0 the arm is inert and the design is the IIvi.
	input cpu_turbo,
	// Contiguous RAM size (from the top's OSD-latched memory config): bounds the
	// cacheable-region decode so the open-bus tail of the $0xxxxxxx RAM window
	// ($FFFF pattern-probe space) can never be cached.
	input [26:0] ram_size_bytes,
	// Line-fill capture STROBE (level, may be true on several edges per word
	// cycle): "the SDRAM dout currently holds THIS cycle's word AND din is the
	// live passthrough of it". MacIIvi.sv wires sdram_ram_ready & cpuBusControl
	// & memoryLatch & ~download_cycle & ~card_ext_slot & (selectRAM|selectROM);
	// the sim twin drops ram_ready (sim_ram serves combinationally). Every
	// term is load-bearing: ram_ready's compare is against the LIVE sdram addr
	// input, which follows the floppy staging address through every extra slot
	// and collapses when AS deasserts, and din is a LATCH except during the
	// memoryLatch passthrough edge — an unqualified ram_ready can be true for
	// ANOTHER master's word. Fill bus cycles keep the NORMAL slot-start DTACK
	// (a fill must never be able to stall the CPU); the FILL FSM latches the
	// word + a sticky served flag on any strobe-true edge and the end-of-cycle
	// verdict reads the flag. Unserved word -> per-line-budget retry; budget
	// spent -> line poisoned and dropped at completion, never installed (a
	// dropped fill is only a future miss; a poisoned line would be silent
	// corruption).
	input fill_data_valid,

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
	output [1:0] busstate,
	// 1 while the cache line-fill engine is borrowing the bus. The top's DTACK
	// glue gates fill READS on real SDRAM data-valid, exactly like the PMMU
	// walker's dbg_walk_cycle_o: both are borrowed, phase-misaligned accesses
	// that would otherwise latch stale SDRAM dout (the 10MB-boot Sad Mac class).
	output        dbg_fill_cycle_o,
	// continue-past first-fault diagnostic taps (-> dbg_probes)
	output        dbg_make_berr,
	output [31:0] dbg_berr_frame_pc,
	output [31:0] dbg_exe_pc,
	output [15:0] dbg_exe_opcode,
	output [15:0] dbg_berr_opcode,
	output [31:0] dbg_tg68_pc,          // LOGICAL prefetch pointer (pre-MMU) -> dbg_probes
	// PMMU mode-switch mistranslation capture (FPGA, always available):
	output [31:0] dbg_pmmu_log,         // pmmu_addr_log  (LOGICAL fetch addr = A5/jmp target)
	output [31:0] dbg_pmmu_phys,        // pmmu_addr_phys (PHYSICAL translated = derail target)
	// MMU-input forensics at the derail (which input is wrong: TC? CRP? table?):
	output [31:0] dbg_pmmu_tc_o,        // TC register
	output [31:0] dbg_pmmu_crp_o,       // CRP_lo (root table base)
	output [31:0] dbg_pmmu_wda_o,       // last walk descriptor ADDRESS read
	output [31:0] dbg_pmmu_wdd_o,       // last walk descriptor DATA read
	output [31:0] dbg_pmmu_st_o,        // {11'b0, walk wstate[4:0], fault_status[15:0]}
	output        dbg_walk_cycle_o,     // BUILD#10: 1 while the PMMU walker is borrowing the bus
	// F-line (vector 11) trap capture — System 7.x "bad F-Line instruction" hunt.
	// Latches the FIRST and most-recent line-1111 trap dispatch since CPU reset.
	// op = the faulting F-line opcode (fline_opcode_latch when the trap came from
	// the PMMU ext-word sub-decode, else the live opcode register), ext = the PMMU
	// extension word (meaningful only when the ctx flag is set), pc = matching
	// instruction PC. meta = {count[15:0], 7'b0, first_ctx, 7'b0, last_ctx}.
	output [31:0] dbg_fline_first_pc,
	output [31:0] dbg_fline_first_op,   // {op[15:0], ext[15:0]}
	output [31:0] dbg_fline_last_pc,
	output [31:0] dbg_fline_last_op,    // {op[15:0], ext[15:0]}
	output [31:0] dbg_fline_meta
);

	assign dbg_walk_cycle_o = walk_cycle;
	assign dbg_fill_cycle_o = fill_active;

	// The latest 030_mmu kernel removed these two forensic taps (replaced by the
	// debug_rte_fmt_a_* family); keep the wrapper ports for the probe deck.
	assign dbg_berr_frame_pc = 32'h0;
	assign dbg_berr_opcode   = 16'h0;
	assign dbg_exe_opcode    = k_opcode;   // live opcode register (debug_opcode)

wire  [1:0] tg68_busstate;

// ---------------------------------------------------------------------------
// 68030 on-chip I/D cache enable (TG68K_Cache_030).
//   0 = run uncached (every fetch/load hits the Mac bus)
//   1 = caches live (read-hit bypass + line fill).
// ENABLED 2026-08-15 (speed session Phase 1) after the glue audit fixed:
// IIvi 32-bit cacheable decode (was the stale V8 24-bit map), xlate_ready
// gating (stale-phys fill hazard in the PMMU busy window), FC=7 exclusion
// (a cached CPU-space line would complete the ROM's MOVES probes that MUST
// bus-error), and the halfword serve/write byte-lane maps. With it 0 the
// cache subsystem is in the generate `else` arm (cache_read_hit tied 0), so
// the bus FSM is provably identical to the uncached design.
// ---------------------------------------------------------------------------
// RE-ENABLED 2026-08-16 (capture-on-ready): the 2026-08-15 "fills never
// install on HW" mystery is CLOSED, analytically. ram_ready (sdram.v:173,
// dout_valid && dout_addr == addr) is address-compare-qualified against the
// LIVE addr input, and three top-level mechanisms make it structurally ZERO
// at the old fixed sample points:
//   1. the addrDecoder is AS-gated, so the moment the fill cycle deasserts
//      AS (s_state 6 phi2) every select drops and memoryAddr collapses —
//      capture-v2's s7-phi1 sample point read a CONSTANT 0 on HW;
//   2. dskReadAckInt/Ext assert UNCONDITIONALLY during every extra slot
//      (idle floppy included), which both muxes memoryAddr away AND issues a
//      real SDRAM read that OVERWRITES dout with the staging word — dout
//      persistence dies every 4th slot;
//   3. the CPU din path is LATCHED in dataController (cpu_data): din equals
//      live sdram dout ONLY during the cpuBusControl && memoryLatch
//      passthrough edge (once per CPU slot — exactly the old s6-phi2 edge),
//      so sampling "later where it's safe" was never an option.
// Friday's s6-phi2 single-sample (91s boots) worked because it hit the one
// edge where compare + live data coincide — a razor. The fix removes the
// point-sample entirely: fill_data_valid is now the QUALIFIED strobe
// (ram_ready & cpuBusControl & memoryLatch & ~download & ~card_ext &
// RAM|ROM selects, wired in MacIIvi.sv/sim.v) and the FILL FSM captures
// on ANY strobe-true edge with a sticky per-word served flag; the s7
// verdict reads the flag. A word served late persists in dout (writes are
// the only invalidator) so the retry cycle's first passthrough edge
// recaptures it without re-racing the SDRAM — self-healing. Stability
// invariants unchanged: slot-start DTACK (fills can never stall), per-line
// retry budget, clean-only install (25/25 sad-Mac-free boots night-of).
localparam USE_68030_CACHE = 1'b1;
wire        cache_read_hit;     // current CPU access is a cacheable read that HIT the cache
wire [15:0] cache_kernel_data;  // 16-bit word fed to the kernel on a cache hit (skips the bus)
wire        cache_fill_pending; // a line-fill request is latched awaiting service (gates turbo)
// A hit may bypass the bus ONLY while no cycle has launched (s_state 0). The
// unqualified form wedged real hardware (2026-08-15, both boots, sim+STA
// clean): a fill's install pulse lands on a phi2 edge; if that same edge
// advances s_state 0->1 for the still-pending missed access (pre-install
// i_hit=0), the next phi1 asserts AS at s_state 1 while the now-visible hit
// forces s_state back to 0 — AS is stranded asserted with the FSM parked,
// nothing reaches the s_state 6 deassert, and dtack_en latches early off the
// stale AS-low window, so the NEXT real cycle passes s_state 4 instantly and
// captures data the SDRAM hasn't served (sim_ram serves combinationally, so
// simulation cannot see it). With the s_state==0 qualifier a just-launched
// cycle simply completes on the bus — same fresh data, one redundant read.
wire        cache_hit_beat = cache_read_hit & (s_state == 3'd0);

// clkena discipline for the 030_mmu LATEST kernel (Minimig lineage, imported
// 2026-08-15). The old LCII kernel carried in-kernel "walk-hold" latch gates so
// clkena edges during a page-table walk were harmless; the new kernel dropped
// those in favor of a WRAPPER-side contract (mirrors Minimig cpu_wrapper.v):
//  - hold clkena while the walker has an outstanding request (pmmu_walker_req),
//    not just while the borrowed transfer runs (walk_cycle): between descriptor
//    levels the kernel must NOT advance, or stream latches re-fire on walk
//    edges and consume descriptor words as opcodes/extension words.
//  - hold clkena while the PMMU is busy translating (covers the 1-cycle ATC-miss
//    gap before the walker request rises, their BUG #407) UNLESS it faulted:
//    on pmmu_fault the CPU must advance to dispatch the bus-error exception.
//  - a pmmu_fault force-released beat carries NO real data; beat_valid=0 marks
//    it (see below) so the kernel consumes nothing from the bus.
wire        kernel_pmmu_busy;                        // kernel debug_pmmu_busy
wire        kernel_pmmu_fault = dbg_pmmu_fault_o;    // kernel debug_pmmu_fault
// cpu_turbo (Performa 600 mode) adds a phi2 beat for OFF-BUS work only:
// internal busstate=01 micro-cycles and cache read-hits, i.e. the kernel core
// runs at the 32.5 MHz phi-edge rate while every bus cycle keeps the 16 MHz
// grid (s_state 7 completion and the pmmu_fault force-release stay phi1-only,
// preserving the proven cycle-start parity). All hold terms (walker request,
// walk/fill bus borrow, PMMU busy) gate both arms identically.
// ~cache_fill_pending on the phi2 arm: the line-fill engine samples its start
// window (busstate=01 @ phi1, s_state 0) at phi1 only — an ungated turbo arm
// consumes every 1-beat internal window at phi2 first, so fills STARVE and the
// cache never populates (measured: 14 fills/18 hits vs 200 fills/2M hits over
// the same boot window). With a fill pending, internal beats fall back to phi1
// pace until the line is filled; fills are rare once the working set is warm.
wire        tg68_clkena = (   (phi1 && (s_state == 7 || tg68_busstate == 2'b01 || cache_hit_beat
                                        || kernel_pmmu_fault))
                           || (cpu_turbo && phi2 && s_state == 3'd0
                               && (tg68_busstate == 2'b01 || cache_hit_beat)
                               && !cache_fill_pending) )
                          && !walk_cycle && !fill_active
                          && !pmmu_walker_req
                          && (!kernel_pmmu_busy || kernel_pmmu_fault);
// TRUE ready-ack qualifier (new-kernel beat_valid contract): high only when the
// beat completed via a REAL ack — a bus cycle that reached s_state 7 (DTACK- or
// BERR-terminated), an internal no-memaccess cycle, or a cache read-hit. The
// pmmu_fault force-release arm of clkena above is NOT a real ack: beat_valid=0
// there, so stream latches, extension capture, directPC and opcode retire all
// skip the garbage beat (their hardware capture: $1B00/$FFFF junk as opcodes).
wire        tg68_beat_valid = (s_state == 7) || (tg68_busstate == 2'b01) || cache_hit_beat;
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
assign dbg_make_berr = kernel_make_berr;
wire [31:0] kernel_tg68_pc;             // kernel TG68_PC (logical prefetch ptr), non-sim
assign dbg_tg68_pc   = kernel_tg68_pc;  // -> dbg_probes (works in FPGA build; dbg_pc is sim-only)
wire        kernel_trap_berr;

// F-line trap capture taps (always connected; consumed by the latch block below)
wire        k_trap_1111, k_trapmake, k_fline_ctx;
wire [15:0] k_opcode, k_fline_op_latch, k_pmmu_brief;
wire [31:0] k_fline_op_pc;

`ifdef A30_TRACE
// --- A30 alias-bit divergence probe (LC II post-MMU; sim-only) ---
wire [31:0] dbg_pc = kernel_tg68_pc;   // alias (kernel TG68_PC now lands on kernel_tg68_pc)
wire [31:0] dbg_reg_qa, dbg_memaddr_reg, dbg_memaddr_delta, dbg_data_read;
wire [31:0] dbg_rf_wdata, dbg_a2, dbg_a5, dbg_a7;
wire        dbg_directPC, dbg_rf_we;
wire  [3:0] dbg_rf_waddr;
wire  [7:0] dbg_ustate;
wire        dbg_use_base;
wire  [1:0] dbg_setstate, dbg_state;
wire        dbg_pmmu_busy = kernel_pmmu_busy;  // kernel pmmu_busy (now tapped unconditionally)
wire [31:0] dbg_memaddr_drega;    // memaddr_delta_rega (held by the bsr.w fix)
// move.b decode-sequence probes: find where the absolute-EA (ld_nn / set_addrlong)
// transition is lost when the instruction fetch stalls on a PMMU walk.
wire  [7:0] dbg_next_ustate;      // next_micro_state
wire [15:0] dbg_last_opc;
wire [15:0] dbg_opcode = k_opcode;  // kernel opcode now tapped unconditionally (F-line capture)
wire        dbg_set_addrlong, dbg_decodeOPC, dbg_get_2ndopc, dbg_clkena_lw;
`endif

// PMMU debug taps made UNCONDITIONAL (2026-06-23) for the FPGA mistranslation capture.
// Expose the PMMU's per-walk logical address + live CRP-aptr/TC + walk state so the
// PMMU REQ trace shows whether a wrong root index comes from a bad logical address
// (debug_pmmu_saved_addr) or a bad loaded CRP (debug_pmmu_crp_lo).
wire [31:0] dbg_pmmu_saddr, dbg_pmmu_crplo, dbg_pmmu_tc;
wire  [4:0] dbg_pmmu_wstate;
// Fault-source forensics: the MMUSR fault class (sticky = FIRST fault), the raw
// pmmu_fault edge (catches a SECOND, suppressed fault during exception entry), and
// the last descriptor addr/data the walker read. Decides desc_valid(I) vs limit(L)
// vs supervisor(S) vs buserr(B) for the $40A03F18 root[10] early-term fault.
wire [15:0] dbg_pmmu_fstat;
wire        dbg_pmmu_fault_o;
wire [31:0] dbg_pmmu_wddata, dbg_pmmu_wdaddr;

reg         walk_cycle;   // 1 = a walker word transfer is borrowing the bus
reg         walk_word;    // 0 = high word @addr, 1 = low word @addr+2
reg  [15:0] walk_hi;      // captured high word (big-endian: bits 31:16)
// Re-read-until-stable (2026-06-24): the borrowed walk READ is intermittently
// missed by the SDRAM controller (it samples oe only at its t==STATE_CMD_START
// clk_8 edge; a phase-misaligned borrowed access falls through to AUTO_REFRESH,
// leaving `dout` stale = $0000, yet DTACK still fires). Result: the PMMU reads a
// zero descriptor and derails (10MB boot Sad Mac) / faults+retries (slow boot,
// build #11 2026-06-24). Fix: re-issue the descriptor READ until two consecutive
// full-32-bit reads agree (each retry lands at a fresh phase, so a missed access
// is caught), capped so a genuinely-stable descriptor (incl. a real 0) still
// completes. READS only — descriptor WRITES (U/M bits) keep single-shot.
reg  [31:0] walk_desc;    // full descriptor captured this read pass
reg  [31:0] walk_prev;    // previous read pass (for the stable-compare)
reg  [2:0]  walk_tries;   // read passes so far (0 = first; compare needs >=1)
localparam [2:0] WALK_MAX_TRIES = 3'd6;

wire [31:0] walk_word_addr = walk_word ? (pmmu_walker_addr | 32'd2) : (pmmu_walker_addr & ~32'd2);
wire [15:0] walk_dout_word = walk_word ? pmmu_walker_wdat[15:0]     : pmmu_walker_wdat[31:16];

// 68030 cache line-fill bus master (Phase 3). On a cacheable read miss the CPU
// stalls and the fill engine reads the 16-byte line (8 x 16-bit words) at the
// line-aligned physical address, then hands it to the cache (i/d_fill_valid).
// Like the PMMU walker it borrows the Mac bus via the eff_* overrides below.
// All of these are tied 0 when USE_68030_CACHE=0 (no_cache arm), so eff_*,
// clkena and the s_state FSM reduce exactly to the uncached design.
wire        fill_active;     // 1 = fill engine is reading a line on the (parked) bus
wire [31:0] fill_bus_addr;   // current 16-bit read address during a fill

// Effective bus controls: the walker (highest priority) or the fill engine drive
// the (otherwise CPU-owned) main bus; outside both these are the kernel's signals.
wire [1:0]  eff_busstate = walk_cycle ? (pmmu_walker_we ? 2'b11 : 2'b10) : (fill_active ? 2'b10 : tg68_busstate);
wire        eff_rw       = walk_cycle ? ~pmmu_walker_we : (fill_active ? 1'b1  : tg68_rw);
wire        eff_uds_n    = walk_cycle ? 1'b0 : (fill_active ? 1'b0 : tg68_uds_n);
wire        eff_lds_n    = walk_cycle ? 1'b0 : (fill_active ? 1'b0 : tg68_lds_n);
wire [31:0] eff_addr     = walk_cycle ? walk_word_addr : (fill_active ? fill_bus_addr : tg68_addr);

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
			// Cache read-hit BEAT (hit qualified with s_state==0 — see the
			// cache_hit_beat note): no external bus cycle — hold s_state at 0
			// exactly like a busstate=01 no-access cycle; clkena pulses this
			// phi1 and the cache supplies the data via the kernel data_in mux.
			// A hit that appears after a cycle launched does NOT park the FSM
			// (that stranded AS asserted and wedged HW); the cycle completes.
			if (cache_hit_beat) s_state <= 0;

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
			if (cache_hit_beat) s_state <= 0;   // qualified hit only (see phi1 branch)
			// PMMU busy/fault: park the bus FSM at s_state 0 so no cycle launches
			// with an untranslated/stale physical address, and a FAULTED access
			// runs no bus cycle at all (the new kernel dispatches the exception
			// off the force-released clkena; mirrors Minimig pmmu_suppress_bus).
			// Only ever parks — the s_state==0 guard means a cycle already in
			// flight always completes. walk_cycle/fill_active own the FSM for
			// borrowed walker/line-fill transfers and are exempt.
			if (pmmu_bus_park) s_state <= 0;

			case (s_state)

				6: begin
					// During a walk or a cache line-fill the read word is captured by
					// that engine's own FSM (from din); don't clobber the CPU data latch.
					if (!walk_cycle && !fill_active) tg68_din_r <= tg68_din;
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
	// Only a bus error on the KERNEL'S OWN cycle may be latched for the kernel
	// (MacLCII, walk-hold family; imported 2026-08-07 with the kernel fixes).
	// While the PMMU walker has borrowed the bus (walk_cycle), a berr belongs to
	// the WALKER — the kernel is frozen and its access has not been issued yet.
	// Latching it as the kernel's own turns a walker table-fetch fault into a
	// spurious bus error against whatever instruction happens to be mid-flight.
	// fill_active is the same argument for a cache line fill; it is tied 0 here
	// (USE_68030_CACHE=0), so this stays cache-free and matches LCII's
	// expression verbatim for future syncs.
	wire berr_kernel_cycle = berr & ~walk_cycle & ~fill_active;
	// Bus-FSM park term for the clkena contract above (declared here, next to
	// its sibling berr gate; used in the phi2 branch of the s_state FSM).
	wire pmmu_bus_park = (kernel_pmmu_busy | kernel_pmmu_fault)
	                     & ~walk_cycle & ~fill_active & (s_state == 3'd0);
	reg berr_hold;
	always @(posedge clk) begin
		if (reset)
			berr_hold <= 1'b0;
		else if (kernel_make_berr || kernel_trap_berr || (phi1 && s_state == 0))
			berr_hold <= 1'b0;
		else if (berr_kernel_cycle)
			berr_hold <= 1'b1;
	end
	wire berr_held = (berr_kernel_cycle | berr_hold) & ~(kernel_make_berr | kernel_trap_berr);

	// 68030 cache-control taps from the kernel. These kernel outputs were
	// previously left unconnected; they feed the cache subsystem in the generate
	// block below. When USE_68030_CACHE=0 the cache is not elaborated and these
	// are simply unused nets (the kernel itself is unaffected by being tapped).
	wire [31:0] cache_addr_log;     // pmmu_addr_log  (logical  -> cache index/tag)
	wire [31:0] cache_addr_phys;    // pmmu_addr_phys (physical -> cacheable decode + line fill)
	wire        cache_inhibit_pmmu; // pmmu_cache_inhibit
	wire        cacr_ie, cacr_de, cacr_ifreeze, cacr_dfreeze, cacr_wa;
	// PMMU logical/physical taps out to the JTAG probe deck (mode-switch capture)
	assign      dbg_pmmu_log  = cache_addr_log;
	assign      dbg_pmmu_phys = cache_addr_phys;
	assign      dbg_pmmu_tc_o  = dbg_pmmu_tc;
	assign      dbg_pmmu_crp_o = dbg_pmmu_crplo;
	assign      dbg_pmmu_wda_o = dbg_pmmu_wdaddr;
	assign      dbg_pmmu_wdd_o = dbg_pmmu_wddata;
	assign      dbg_pmmu_st_o  = {11'b0, dbg_pmmu_wstate, dbg_pmmu_fstat};
	wire        cache_inv_req;
	wire [1:0]  cache_op_scope, cache_op_cache;
	wire [31:0] cache_op_addr;

	TG68KdotC_Kernel tg68k (
		.clk            ( clk           ),
		.nReset         ( ~reset        ),
		.clkena_in      ( tg68_clkena   ),
		.beat_valid     ( tg68_beat_valid ),
		// On a cache read-hit BEAT the kernel takes data straight from the
		// cache (no bus cycle ran, so tg68_din_r is stale); otherwise the
		// latched bus word. cache_hit_beat is constant 0 when USE_68030_CACHE=0.
		.data_in        ( cache_hit_beat ? cache_kernel_data : tg68_din_r ),
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
		.debug_trap_berr ( kernel_trap_berr ),

		// PMMU busy: clkena hold while a translation is pending (new-kernel
		// contract, their BUG #407 — see the tg68_clkena block above).
		.debug_pmmu_busy ( kernel_pmmu_busy ),

		// 68030 cache control + PMMU address taps (consumed by the cache below).
		.pmmu_addr_log      ( cache_addr_log     ),
		.pmmu_addr_phys     ( cache_addr_phys    ),
		.pmmu_cache_inhibit ( cache_inhibit_pmmu ),
		.cacr_ie            ( cacr_ie            ),
		.cacr_de            ( cacr_de            ),
		.cacr_ifreeze       ( cacr_ifreeze       ),
		.cacr_dfreeze       ( cacr_dfreeze       ),
		.cacr_wa            ( cacr_wa            ),
		.cache_inv_req      ( cache_inv_req      ),
		.cache_op_scope     ( cache_op_scope     ),
		.cache_op_cache     ( cache_op_cache     ),
		.cache_op_addr      ( cache_op_addr      ),
		// continue-past diagnostic taps (always connected). The latest kernel
		// dropped debug_berr_frame_pc/debug_exe_opcode/debug_berr_opcode (the
		// richer debug_rte_fmt_a_* family replaced them); the wrapper-level
		// taps are kept for the MacIIvi.sv/dbg_probes deck — frame-PC and
		// berr-opcode tie off, exe_opcode maps to the live opcode register.
		.debug_exe_PC        ( dbg_exe_pc         ),

		// F-line trap capture taps (always connected; latch block below)
		.debug_trap_1111           ( k_trap_1111     ),
		.debug_trapmake            ( k_trapmake      ),
		.debug_opcode              ( k_opcode        ),
		.debug_pmmu_brief          ( k_pmmu_brief    ),
		.debug_fline_context_valid ( k_fline_ctx     ),
		.debug_fline_opcode_latch  ( k_fline_op_latch ),
		.debug_fline_opcode_pc     ( k_fline_op_pc   )

`ifdef A30_TRACE
		// --- A30 alias-bit divergence probe (LC II post-MMU; sim-only) ---
		,
		.debug_TG68_PC       ( kernel_tg68_pc ),
		.debug_reg_QA        ( dbg_reg_qa    ),
		.debug_memaddr_reg   ( dbg_memaddr_reg ),
		.debug_memaddr_delta ( dbg_memaddr_delta ),
		.debug_data_read     ( dbg_data_read ),
		.debug_exec_directPC ( dbg_directPC  ),
		.debug_regfile_we    ( dbg_rf_we     ),
		.debug_regfile_waddr ( dbg_rf_waddr  ),
		.debug_regfile_wdata ( dbg_rf_wdata  ),
		.debug_regfile_a2    ( dbg_a2        ),
		.debug_regfile_a5    ( dbg_a5        ),
		.debug_regfile_a7    ( dbg_a7        ),
		.debug_micro_state   ( dbg_ustate    ),
		.debug_use_base      ( dbg_use_base  ),
		.debug_setstate      ( dbg_setstate  ),
		.debug_state         ( dbg_state     ),
		.debug_memaddr_delta_rega ( dbg_memaddr_drega ),
		.debug_next_micro_state ( dbg_next_ustate ),
		.debug_last_opc_read ( dbg_last_opc    ),
		.debug_set_addrlong  ( dbg_set_addrlong ),
		.debug_decodeOPC     ( dbg_decodeOPC   ),
		.debug_get_2ndopc    ( dbg_get_2ndopc  ),
		.debug_clkena_lw     ( dbg_clkena_lw   )
`endif
		// PMMU debug connections UNCONDITIONAL (2026-06-23) for FPGA capture
		,
		.debug_pmmu_saved_addr ( dbg_pmmu_saddr  ),
		.debug_pmmu_crp_lo     ( dbg_pmmu_crplo  ),
		.debug_pmmu_tc         ( dbg_pmmu_tc     ),
		.debug_pmmu_wstate     ( dbg_pmmu_wstate ),
		.debug_pmmu_fault_status ( dbg_pmmu_fstat ),
		.debug_pmmu_fault        ( dbg_pmmu_fault_o ),
		.debug_pmmu_walk_desc_addr ( dbg_pmmu_wdaddr ),
		.debug_pmmu_walk_desc_data ( dbg_pmmu_wddata )

		// Cache control + PMMU address taps are connected above. The remaining
		// new-030 outputs (skipFetch, regin_out, CACR_out, VBR_out, cacr_ibe/dbe,
		// pmmu_reg_*) are left unconnected. The on-chip caches are instantiated in
		// the generate block below, only when USE_68030_CACHE=1.
	);

	// =======================================================================
	// F-line (vector 11) trap capture — System 7.x "bad F-Line instruction"
	// hunt. trap_1111+trapmake assert combinationally through the whole trap
	// microcode of one instruction, so a rising-edge detect counts each
	// dispatch exactly once. When the trap comes from the PMMU ext-word
	// sub-decode (pmove_decode), fline_context_valid=1 and the latched
	// fline_opcode_latch/fline_opcode_pc identify the instruction (the live
	// opcode register may already hold prefetched data there); otherwise the
	// live opcode/exe_pc are the faulting instruction.
	// =======================================================================
	wire [15:0] fline_ev_op = k_fline_ctx ? k_fline_op_latch : k_opcode;
	wire [31:0] fline_ev_pc = k_fline_ctx ? k_fline_op_pc    : dbg_exe_pc;
	wire        fline_ev    = k_trap_1111 && k_trapmake;
	reg  [31:0] fline_first_pc = 32'd0, fline_last_pc = 32'd0;
	reg  [31:0] fline_first_op = 32'd0, fline_last_op = 32'd0;
	reg  [15:0] fline_cnt = 16'd0;
	reg         fline_first_ctx = 1'b0, fline_last_ctx = 1'b0, fline_ev_d = 1'b0;
	always @(posedge clk) begin
		if (reset) begin
			fline_cnt      <= 16'd0;  fline_ev_d     <= 1'b0;
			fline_first_pc <= 32'd0;  fline_first_op <= 32'd0;  fline_first_ctx <= 1'b0;
			fline_last_pc  <= 32'd0;  fline_last_op  <= 32'd0;  fline_last_ctx  <= 1'b0;
		end else begin
			fline_ev_d <= fline_ev;
			if (fline_ev && !fline_ev_d) begin
				if (fline_cnt == 16'd0) begin
					fline_first_pc  <= fline_ev_pc;
					fline_first_op  <= {fline_ev_op, k_pmmu_brief};
					fline_first_ctx <= k_fline_ctx;
				end
				fline_last_pc  <= fline_ev_pc;
				fline_last_op  <= {fline_ev_op, k_pmmu_brief};
				fline_last_ctx <= k_fline_ctx;
				if (fline_cnt != 16'hFFFF) fline_cnt <= fline_cnt + 16'd1;
`ifdef SIMULATION
				$display("FLINE[%0d]: op=%04x ext=%04x pc=%08x ctx=%b t=%0t",
				         fline_cnt, fline_ev_op, k_pmmu_brief, fline_ev_pc, k_fline_ctx, $time);
`endif
			end
		end
	end
	assign dbg_fline_first_pc = fline_first_pc;
	assign dbg_fline_first_op = fline_first_op;
	assign dbg_fline_last_pc  = fline_last_pc;
	assign dbg_fline_last_op  = fline_last_op;
	assign dbg_fline_meta     = {fline_cnt, 7'b0, fline_first_ctx, 7'b0, fline_last_ctx};

	// =======================================================================
	// 68030 on-chip Instruction + Data cache (TG68K_Cache_030)
	//
	// Phase 2: controller glue + READ-HIT bypass only. The cache indexes by the
	// kernel's logical address (cache_addr_log) qualified by FC, allocation-gated
	// to cacheable physical regions. On a read that hits a present line we hand
	// the word straight to the kernel: cache_read_hit holds the bus FSM at
	// s_state 0 and clkena pulses immediately, so NO external/SDRAM cycle runs.
	// Misses and writes fall through to the normal Mac bus cycle.
	//
	// Until the Phase 3 line-fill engine lands, the fill-return inputs are tied
	// inert, so no line is ever populated -> the cache never reports a hit ->
	// this block is functionally inert even with USE_68030_CACHE=1.
	// =======================================================================
	generate if (USE_68030_CACHE) begin : gen_cache

		wire        is_030      = (cpu == 2'b10);
		// D-cache disabled for AREA (2026-08-15): with both caches the design
		// needs 4353 LABs on a 4191-LAB device (fitter 170012). The measured
		// boot win is entirely I-side (the ROM enables only CACR.IE; dhit=0
		// across the whole 40-frame window), while the D side carries the
		// heaviest fabric — 2.5k array regs + the 16-line alias-invalidate
		// comparators. Tying DE off INTO the cache instance sweeps the whole
		// D side at synthesis with zero VHDL changes (kernel sync law intact);
		// the kernel's CACR register still accepts and reads back DE writes,
		// so software-visible semantics are unchanged (a D-cache that never
		// hits is architecturally transparent). Re-enable path: M10K-backed
		// cache arrays (follow-up), then flip this localparam.
		localparam  USE_68030_DCACHE = 1'b0;
		wire        cacr_de_eff = cacr_de & USE_68030_DCACHE;
		// Translation freshness: the cache module latches i/d_fill_addr from
		// cache_addr_phys AT MISS-DETECT TIME. While the PMMU is busy (the 1-2
		// clk ATC-hit freshness window after the kernel presents a new address,
		// their BUG #416) cache_addr_phys is STALE — a miss latched there would
		// fill the new logical tag from the OLD physical page. And a FAULTED
		// access has no physical address at all (and must consume nothing: a
		// logical-tag hit on a faulted translation would hand the kernel data
		// for an access that is dispatching a bus-error). Gate every cache
		// request on a settled, successful translation.
		wire        xlate_ready = ~kernel_pmmu_busy & ~kernel_pmmu_fault;

		wire i_req = is_030 & cacr_ie & (tg68_busstate == 2'b00) & xlate_ready;
		// FC=7 (CPU space) is never cached on a real 68030. Critically for the
		// Mac: the ROM's hardware-presence probes are `moves` reads in CPU space
		// at ordinary RAM addresses that MUST terminate in a bus error (the top
		// suppresses DTACK). A cached FC=7 line would complete a later probe
		// from the cache — no bus cycle, no BERR, machine-config corruption.
		wire d_req = is_030 & cacr_de_eff & (tg68_busstate == 2'b10 || tg68_busstate == 2'b11)
		             & (fc != 3'b111) & xlate_ready;
		wire d_we  = (tg68_busstate == 2'b11);

		// Cacheable physical regions on the IIvi 32-bit VASP map (must mirror
		// rtl/addrDecoder.v): fitted RAM (contiguous at $00000000, bounded by
		// ram_size_bytes so the open-bus probe tail of the $0xxxxxxx window
		// stays uncached) + ROM ($40000000-$4FFFFFFF, 1MB mirrored). Everything
		// else — VASP I/O $50xxxxxx, box-ID $5FFFFFFC, onboard VRAM $6xxxxxxx,
		// NuBus super/slot space $C-$E/$FC-$FE (the mdc824 framebuffer lives
		// there), unmapped open bus — is never cacheable. The OS's 24-bit-mode
		// I/O mirrors are PMMU pages onto $50xxxxxx, so they are excluded here
		// by their PHYSICAL address (and carry CI in the MMU tables besides).
		// As on the real 030, cache-inhibit blocks new ALLOCATION, not hits on
		// already-present lines.
		wire        phys_cacheable =
		            ((cache_addr_phys[31:27] == 5'b00000) &&
		             (cache_addr_phys[26:0] < ram_size_bytes))    // RAM
		          || (cache_addr_phys[31:28] == 4'h4);            // ROM
		wire        fill_inhibit   = cache_inhibit_pmmu | ~phys_cacheable;

		wire [31:0] i_data, d_data_out;
		wire        i_hit, d_hit;
		wire        i_fill_req, d_fill_req;     // Phase 3 services these
		wire [31:0] i_fill_addr, d_fill_addr;   // line-aligned physical fill address

		// ---- Line-fill engine state ----
		// Services the cache's OWN fill requests (i_fill_req/d_fill_req) during IDLE
		// bus cycles, like the PMMU walker. The miss is delivered by the normal bus
		// cycle; the fill only POPULATES the line for future hits, so there is no
		// hit-wait and the engine can never deadlock.
		localparam FILL_IDLE = 1'b0, FILL_READ = 1'b1;
		reg          fill_st;        // FILL_IDLE / FILL_READ
		reg   [2:0]  fill_word;      // 0..7: which 16-bit word of the line
		reg          fill_is_i;      // 1 = fill the I-cache, 0 = the D-cache
		reg  [31:0]  fill_base;      // line-aligned (16-byte) physical base (cache's i/d_fill_addr)
		reg  [127:0] fill_buf;       // accumulates the 8 read words (word k -> [16k +: 16])
		reg          fill_dirty;     // a word FAILED past its retry budget -> drop the line
		reg   [2:0]  fill_retry;     // per-line retry budget spent (a late word re-reads its slot)
		reg          fill_served;    // sticky: THIS word was captured off a strobe-true edge
		reg          i_fill_valid_r, d_fill_valid_r;

		assign       fill_active   = (fill_st == FILL_READ);             // bus-owning read phase
		assign       fill_bus_addr = {fill_base[31:4], fill_word, 1'b0};  // base + 2*word

		wire [127:0] i_fill_data  = fill_buf;
		wire [127:0] d_fill_data  = fill_buf;
		wire         i_fill_valid = i_fill_valid_r;
		wire         d_fill_valid = d_fill_valid_r;

		// Write-through byte lanes into the D-cache. The cache line stores the
		// eight bus words verbatim (fill_buf packing below): 32-bit cache word j
		// = {bus word 2j+1, bus word 2j}, each bus word = {even byte [15:8],
		// odd byte [7:0]} exactly as on the 68k bus. A write beat is therefore
		// fully described by WHICH bus word (addr[1] picks the halfword) and
		// the UDS/LDS lanes — addr[0] carries no extra information (the bus
		// encodes it in the strobes), and keying data placement on it corrupted
		// the offset-3 lanes in the original map (audited 2026-08-15, was
		// unvalidated Phase-4 scaffolding).
		reg  [31:0] d_data_in;
		reg  [3:0]  d_be;
		always @* begin
			if (!cache_addr_log[1]) begin
				d_data_in = {16'h0000, tg68_dout_k};
				d_be      = {2'b00, ~tg68_uds_n, ~tg68_lds_n};
			end else begin
				d_data_in = {tg68_dout_k, 16'h0000};
				d_be      = {~tg68_uds_n, ~tg68_lds_n, 2'b00};
			end
		end

		TG68K_Cache_030 cache_inst (
			.clk             ( clk             ),
			.nreset          ( ~reset          ),
			.cacr_ie         ( cacr_ie         ),
			.cacr_de         ( cacr_de_eff     ),   // tied 0: D side swept (area; see above)
			.cacr_ifreeze    ( cacr_ifreeze    ),
			.cacr_dfreeze    ( cacr_dfreeze    ),
			.cacr_wa         ( cacr_wa         ),
			.inv_req         ( cache_inv_req   ),
			.cache_op_scope  ( cache_op_scope  ),
			.cache_op_cache  ( cache_op_cache  ),
			.cache_op_addr   ( cache_op_addr   ),

			.i_addr          ( cache_addr_log  ),
			.i_addr_phys     ( cache_addr_phys ),
			.i_fc            ( fc              ),
			.i_req           ( i_req           ),
			.i_cache_inhibit ( fill_inhibit    ),
			.i_data          ( i_data          ),
			.i_hit           ( i_hit           ),
			.i_fill_req      ( i_fill_req      ),
			.i_fill_addr     ( i_fill_addr     ),
			.i_fill_data     ( i_fill_data     ),
			.i_fill_valid    ( i_fill_valid    ),

			.d_addr          ( cache_addr_log  ),
			.d_addr_phys     ( cache_addr_phys ),
			.d_fc            ( fc              ),
			.d_req           ( d_req           ),
			.d_we            ( d_we            ),
			.d_cache_inhibit ( fill_inhibit    ),
			.d_data_in       ( d_data_in       ),
			.d_data_out      ( d_data_out      ),
			.d_be            ( d_be            ),
			.d_hit           ( d_hit           ),
			.d_fill_req      ( d_fill_req      ),
			.d_fill_addr     ( d_fill_addr     ),
			.d_fill_data     ( d_fill_data     ),
			.d_fill_valid    ( d_fill_valid    )
		);

		// 16-bit serve demux from the 32-bit cache word: hand the kernel the
		// FULL bus halfword containing the addressed byte(s), exactly as RAM
		// would drive both lanes — the kernel then picks its own lane per the
		// access (even byte from [15:8], odd from [7:0], words whole), which is
		// the identical contract to a real bus read. addr[1] selects the bus
		// word inside the 32-bit cache word; addr[0] is deliberately unused
		// (the original per-byte {8'h00, x} cases served the WRONG byte for
		// odd addresses — audited 2026-08-15).
		wire [31:0] serve_word   = (tg68_busstate == 2'b00) ? i_data : d_data_out;
		wire [15:0] data_out_16  = cache_addr_log[1] ? serve_word[31:16] : serve_word[15:0];

		// Read-hit = present I-line on a fetch, or present D-line on a data read
		// (never a write). Suppressed during a walk and during a fill.
		assign cache_read_hit    = ~walk_cycle & ~fill_active &
		                           ((i_hit & i_req) | (d_hit & d_req & ~d_we));
		assign cache_kernel_data = data_out_16;
		assign cache_fill_pending = i_fill_req | d_fill_req;

		// Line-fill FSM. The cache asserts i_fill_req/d_fill_req (with i/d_fill_addr,
		// line-aligned physical) on a read miss and holds it until filled. We service
		// it only when the kernel bus is PARKED (busstate=01, no walk/walker pending) —
		// the same stable phi1 @ s_state 0 window the walker uses — and borrow the bus
		// for 8 sequential 16-bit reads, stalling the CPU (clkena gated by fill_active).
		// Because the cache chose the address+line, our fill data lands in exactly the
		// line it will hit on; and because the original miss was already delivered by a
		// normal bus cycle, there is no hit-wait -> no deadlock (worst case = the line
		// just isn't populated yet, i.e. a future miss).
		always @(posedge clk) begin
			if (reset) begin
				fill_st        <= FILL_IDLE;
				fill_word      <= 3'd0;
				fill_is_i      <= 1'b0;
				fill_base      <= 32'd0;
				fill_buf       <= 128'd0;
				fill_dirty     <= 1'b0;
				fill_retry     <= 3'd0;
				fill_served    <= 1'b0;
				i_fill_valid_r <= 1'b0;
				d_fill_valid_r <= 1'b0;
			end else begin
				i_fill_valid_r <= 1'b0;   // single-cycle valid pulses
				d_fill_valid_r <= 1'b0;
				case (fill_st)
					FILL_IDLE:
						// fc != 7: if the kernel's FC output lingers in CPU space on
						// this internal beat, the top's fc7_berr would suppress DTACK
						// on the fill's bus reads and the line would fill with junk.
						if (phi1 && s_state == 3'd0 && tg68_busstate == 2'b01 &&
						    fc != 3'b111 &&
						    !walk_cycle && !pmmu_walker_req && (i_fill_req | d_fill_req)) begin
							fill_st     <= FILL_READ;
							fill_word   <= 3'd0;
							fill_dirty  <= 1'b0;
							fill_retry  <= 3'd0;
							fill_served <= 1'b0;
							fill_is_i   <= i_fill_req;                       // I-cache has priority
							fill_base   <= i_fill_req ? i_fill_addr : d_fill_addr;
						end
					FILL_READ: begin
						// CAPTURE-ON-STROBE (2026-08-16, the fix for the parked-era
						// 2x drag): fill_data_valid is the qualified "din is the
						// live passthrough of THIS word's just-served data" strobe
						// (see the port comment). Latch the word and the sticky
						// served flag on ANY strobe-true edge of the word's cycle —
						// there is exactly one passthrough edge per CPU slot
						// (memoryLatch), and a word served late persists in sdram
						// dout (writes are the only invalidator), so the RETRY
						// cycle recaptures it on its first passthrough edge without
						// re-racing the SDRAM: self-healing. The parked-era designs
						// point-sampled ram_ready at one fixed edge instead:
						// s7-phi1 is structurally AFTER the AS-gated decode
						// collapses memoryAddr (a constant-0 sample — the cache
						// never installed, 213-225s boots), and s6-phi2 was the
						// single coinciding edge (a razor — 91s boots, mostly).
						// Capture and verdict are now different edges, so neither
						// races the SDRAM completion.
						if (fill_data_valid) begin
							fill_buf[fill_word*16 +: 16] <= din;   // live line word k
							fill_served <= 1'b1;
						end
						// End-of-cycle verdict at phi1 && s_state 7 (the fill
						// cycle's fixed completion point — slot-start DTACK pacing,
						// a fill can never stall). Reads the sticky flag, never the
						// live level (0 here by construction: AS dropped at s6-phi2
						// and the decode collapsed with it).
						if (phi1 && s_state == 3'd7) begin
							if (!fill_served && fill_retry != 3'd7)
								fill_retry <= fill_retry + 1'b1;     // unserved: re-run this word's slot
							else begin
								if (!fill_served) fill_dirty <= 1'b1; // budget spent -> poison
								fill_served <= 1'b0;                  // consume for the next word
								if (fill_word != 3'd7)
									fill_word <= fill_word + 1'b1;   // next word
								else begin
									fill_st <= FILL_IDLE;             // 16 bytes read -> done
									// Install only a fully-clean line (fill_dirty =
									// earlier words, fill_served = THIS word). The
									// cache holds i/d_fill_req asserted until a
									// valid pulse arrives (BUG #132 keeps the same
									// latched line/addr), so a dropped line simply
									// RETRIES on a later idle window — future
									// misses, never corruption. (cache_fill_pending
									// keeps the turbo phi2 arm off meanwhile.)
									if (!fill_dirty && fill_served) begin
										if (fill_is_i) i_fill_valid_r <= 1'b1;
										else           d_fill_valid_r <= 1'b1;
									end
								end
							end
						end
					end
				endcase
			end
		end

`ifdef SIMULATION
		// Cache effectiveness counters (2026-08-15 speed-session measurement
		// harness): one line per 2^22 clk (~4 frames) — per-window beat/hit/
		// fill rates + cumulative totals. Costs nothing in synthesis.
		reg [31:0] cs_cyc;
		reg [31:0] cs_ihit, cs_dhit, cs_ifill, cs_dfill, cs_beats, cs_busbeats;
		reg [31:0] ct_ihit, ct_dhit, ct_ifill, ct_dfill;
		always @(posedge clk) begin
			if (reset) begin
				cs_cyc<=0; cs_ihit<=0; cs_dhit<=0; cs_ifill<=0; cs_dfill<=0;
				cs_beats<=0; cs_busbeats<=0;
				ct_ihit<=0; ct_dhit<=0; ct_ifill<=0; ct_dfill<=0;
			end else begin
				cs_cyc <= cs_cyc + 1'b1;
				if (tg68_clkena) begin
					cs_beats <= cs_beats + 1'b1;
					if (cache_hit_beat) begin
						if (tg68_busstate == 2'b00) begin cs_ihit <= cs_ihit+1'b1; ct_ihit <= ct_ihit+1'b1; end
						else                        begin cs_dhit <= cs_dhit+1'b1; ct_dhit <= ct_dhit+1'b1; end
					end
					if (s_state == 3'd7) cs_busbeats <= cs_busbeats + 1'b1;
				end
				if (i_fill_valid_r) begin cs_ifill <= cs_ifill+1'b1; ct_ifill <= ct_ifill+1'b1; end
				if (d_fill_valid_r) begin cs_dfill <= cs_dfill+1'b1; ct_dfill <= ct_dfill+1'b1; end
				if (cs_cyc[21:0] == 22'h3FFFFF) begin
					$display("CACHE STAT win: beats=%0d bus=%0d ihit=%0d dhit=%0d ifill=%0d dfill=%0d | cum ihit=%0d dhit=%0d ifill=%0d dfill=%0d cacr(ie=%b de=%b) @%0t",
						cs_beats, cs_busbeats, cs_ihit, cs_dhit, cs_ifill, cs_dfill,
						ct_ihit, ct_dhit, ct_ifill, ct_dfill, cacr_ie, cacr_de, $time);
					cs_ihit<=0; cs_dhit<=0; cs_ifill<=0; cs_dfill<=0; cs_beats<=0; cs_busbeats<=0;
				end
			end
		end
`endif

`ifdef CACHE_TRACE
		// Cache fill-FSM probe: every state transition (capped) + a stuck-detector
		// that fires if the FSM sits out of IDLE too long (the suspected deadlock).
		reg        ct_fst_d;
		reg [31:0] ct_busy_cnt, ct_tr_cnt;
		always @(posedge clk) begin
			if (reset) begin ct_fst_d <= FILL_IDLE; ct_busy_cnt <= 0; ct_tr_cnt <= 0; end
			else begin
				ct_fst_d    <= fill_st;
				ct_busy_cnt <= (fill_st == FILL_IDLE) ? 32'd0 : (ct_busy_cnt + 1'b1);
				if (fill_st != ct_fst_d && ct_tr_cnt < 32'd4000) begin
					ct_tr_cnt <= ct_tr_cnt + 1'b1;
					$display("CACHE fst %0d->%0d word=%0d is_i=%b ireq=%b dreq=%b ihit=%b dhit=%b crh=%b ifreq=%b dfreq=%b ss=%0d bs=%b alog=%h aphys=%h fi_inh=%b @%0t",
						ct_fst_d, fill_st, fill_word, fill_is_i, i_req, d_req, i_hit, d_hit,
						cache_read_hit, i_fill_req, d_fill_req, s_state, tg68_busstate,
						cache_addr_log, cache_addr_phys, fill_inhibit, $time);
				end
				// Deadlock detector: FSM stuck out of IDLE for >2000 cycles.
				if (ct_busy_cnt == 32'd2000)
					$display("CACHE *** STUCK *** fst=%0d word=%0d is_i=%b ireq=%b dreq=%b ihit=%b dhit=%b ivld=%b dvld=%b ss=%0d bs=%b alog=%h aphys=%h @%0t",
						fill_st, fill_word, fill_is_i, i_req, d_req, i_hit, d_hit,
						i_fill_valid_r, d_fill_valid_r, s_state, tg68_busstate,
						cache_addr_log, cache_addr_phys, $time);
			end
		end
`endif

	end else begin : no_cache
		assign cache_read_hit    = 1'b0;
		assign cache_kernel_data = 16'h0;
		assign cache_fill_pending = 1'b0;
		assign fill_active       = 1'b0;
		assign fill_bus_addr     = 32'd0;
	end endgenerate

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
					walk_tries <= 3'd0;   // re-read pass counter (READs)
				end
			end else begin
				// Capture the read word at the data phase (s_state 6, phi2). The low
				// word completes the 32-bit descriptor into walk_desc (compared below).
				if (phi2 && s_state == 3'd6) begin
					if (!walk_word) walk_hi   <= din;
					else            walk_desc <= {walk_hi, din};
				end
				// Word transfer completes at s_state 7 (phi1).
				if (phi1 && s_state == 3'd7) begin
					if (!walk_word) begin
						walk_word <= 1'b1;        // proceed to low word
					end else if (pmmu_walker_we) begin
						// descriptor WRITE: single-shot (no read-back to verify)
						walk_cycle      <= 1'b0;
						pmmu_walker_ack <= 1'b1;
					end else if ((walk_tries != 3'd0 && walk_desc == walk_prev) ||
					             walk_tries >= WALK_MAX_TRIES) begin
						// descriptor READ stable (two passes agree) or retry cap hit:
						// accept it. walk_desc was latched at s_state 6 above.
						walk_cycle       <= 1'b0;
						pmmu_walker_data <= walk_desc;
						pmmu_walker_ack  <= 1'b1;
					end else begin
						// not yet stable: re-issue the read from the high word. Each
						// retry lands at a fresh SDRAM phase, so a missed (refresh-
						// shadowed) access is caught on a subsequent pass.
						walk_prev  <= walk_desc;
						walk_tries <= walk_tries + 3'd1;
						walk_word  <= 1'b0;
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

`ifdef SIMULATION
	// Orphaned-AS tripwire (permanent guard; found 2026-08-15): AS asserted
	// while the bus FSM is parked at s_state 0 with no borrowed master means a
	// launched cycle was abandoned — the exact hit-vs-launch race that wedged
	// hardware while simulation stayed green (sim_ram's combinational serve
	// masks the resulting early-DTACK data hazard, so only this invariant
	// makes the bug visible in sim). Capped, loud, non-fatal.
	reg [7:0] orphan_as_cnt = 8'd0;
	always @(posedge clk) begin
		if (reset) orphan_as_cnt <= 8'd0;
		else if (!as_n_r && s_state == 3'd0 && !walk_cycle && !fill_active &&
		         orphan_as_cnt != 8'hFF) begin
			orphan_as_cnt <= orphan_as_cnt + 8'd1;
			$display("TG68K *** ORPHANED AS *** s_state=0 as_n=0 busstate=%b addr=%h hit=%b @%0t",
			         tg68_busstate, tg68_addr, cache_read_hit, $time);
		end
	end
`endif

	`ifdef PMMU_TRACE
	// Focused PMMU table-walk + stall probe (does NOT spam per-fetch).
	//  * logs each walk request/ack (capped) with the descriptor addr/data,
	//  * logs make_berr/trap_berr edges,
	//  * a heartbeat dump of the CPU/walker bus state so a post-pmove(tc) stall
	//    is visible (the main cpu_trace goes blind once the kernel parks the bus
	//    in a never-completing walk). Enable with +define+PMMU_TRACE.
	reg        walk_cycle_d, mberr_d, tberr_d, wreq_d, pfault_d;
	reg [31:0] dbg_cyc;
	reg [31:0] dbg_walks;
	always @(posedge clk) begin
		if (reset) begin
			walk_cycle_d <= 0; mberr_d <= 0; tberr_d <= 0; wreq_d <= 0; pfault_d <= 0;
			dbg_cyc <= 0; dbg_walks <= 0;
		end else begin
			dbg_cyc      <= dbg_cyc + 1'b1;
			walk_cycle_d <= walk_cycle;
			wreq_d       <= pmmu_walker_req;
			mberr_d      <= kernel_make_berr;
			tberr_d      <= kernel_trap_berr;

			// walk request edge (kernel asked for a descriptor) — gated on the
			// descriptor address being in the top-of-RAM page-table region
			// ($3F0000-$3FFFFF, where the CRP table $3FE820 lives), NOT on the PC,
			// so the $0CB2 DATA-access walk (PC=$0CB2) is captured. Determines
			// walk-vs-stale-ATC for the $0CB2->$fffffff2 mistranslation.
			if (pmmu_walker_req && !wreq_d && dbg_walks < 32'd4000 &&
			    pmmu_walker_addr >= 32'h003F0000 && pmmu_walker_addr <= 32'h003FFFFF) begin
				$display("PMMU REQ #%0d addr=%h we=%b log=%h crp=%h tc=%h ws=%0d (PC~%h) @%0t",
				         dbg_walks, pmmu_walker_addr, pmmu_walker_we,
				         dbg_pmmu_saddr, dbg_pmmu_crplo, dbg_pmmu_tc, dbg_pmmu_wstate,
				         tg68_addr, $time);
				dbg_walks <= dbg_walks + 1'b1;
			end
			// walk completion (ack pulse)
			if (pmmu_walker_ack &&
			    pmmu_walker_addr >= 32'h003F0000 && pmmu_walker_addr <= 32'h003FFFFF)
				$display("PMMU ACK  data=%h kpc=%h waddr=%h @%0t", pmmu_walker_data, tg68_addr, pmmu_walker_addr, $time);

			if (kernel_make_berr && !mberr_d)
				$display("PMMU make_berr  addr=%h s_state=%0d busstate=%b @%0t", tg68_addr, s_state, tg68_busstate, $time);
			if (kernel_trap_berr && !tberr_d)
				$display("PMMU trap_berr  addr=%h @%0t", tg68_addr, $time);

			// Raw pmmu_fault rising edge — fires for EVERY walker fault, including a
			// second one suppressed during exception entry (trap_berr already pending).
			// fstat = MMUSR class (sticky=FIRST fault): B=bit15 L=14 S=13 W=11 I=10.
			// saddr = the faulting logical addr (live per-walk); wddata = last desc word.
			pfault_d <= dbg_pmmu_fault_o;
			if (dbg_pmmu_fault_o && !pfault_d)
				$display("PMMU FAULT  saddr=%h fstat=%h (B=%b L=%b S=%b W=%b I=%b) ws=%0d descaddr=%h descdata=%h @%0t",
				         dbg_pmmu_saddr, dbg_pmmu_fstat,
				         dbg_pmmu_fstat[15], dbg_pmmu_fstat[14], dbg_pmmu_fstat[13],
				         dbg_pmmu_fstat[11], dbg_pmmu_fstat[10], dbg_pmmu_wstate,
				         dbg_pmmu_wdaddr, dbg_pmmu_wddata, $time);

			// heartbeat: periodic bus-state dump (catches a stalled/looping walk)
			if (dbg_cyc[17:0] == 18'd0)
				$display("PMMU HB cyc=%0d kpc=%h sstate=%0d bs=%b walk=%b wreq=%b waddr=%h berrh=%b dtack=%b @%0t",
				         dbg_cyc, tg68_addr, s_state, tg68_busstate, walk_cycle,
				         pmmu_walker_req, pmmu_walker_addr, berr_held, dtack_n, $time);
		end
	end
	`endif
`ifdef A30_TRACE
	// --- A30 alias-bit divergence probe (LC II post-MMU; sim-only) ---
	// Goal: find where the $40 ROM-alias bit (A30) is dropped on the way to the
	// post-MMU continuation jmp. Logs (sampled on the kernel clkena edge):
	//  (1) control flow ENTERING the $x0A0xxxx continuation page (PC[27:16]==0x0A0):
	//      shows the new PC + the EA source register (reg_QA) + memaddr_reg/delta
	//      so we can see whether the jmp target carried $40 (alias) or $00A (bare).
	//  (2) every address-register WRITE whose value lands in the $x0Axxxxx region
	//      (wdata[23:20]==0xA): catches the load that sets A5/A2 to the continuation
	//      pointer, revealing if bit30 ($40) is present at the moment it is stored.
	//  (3) any An write of a $40000000-set value (bit31:28==0x4): proof the regfile
	//      can hold A30 at all, and which register/value.
	reg [31:0] a30_pc_d;
	reg [31:0] a30_cyc;
	always @(posedge clk) begin
		if (reset) begin
			a30_pc_d <= 32'hFFFFFFFF;
			a30_cyc  <= 32'h0;
		end else if (tg68_clkena) begin
			a30_cyc <= a30_cyc + 1'b1;

			// (1) entered the $x0A0xxxx continuation page
			if (dbg_pc[27:16] == 12'h0A0 && a30_pc_d[27:16] != 12'h0A0)
				$display("A30[ENTER-A0] cyc=%0d PC=%h (was %h) reg_QA=%h memreg=%h memdelta=%h data_read=%h A7=%h directPC=%b @%0t",
				         a30_cyc, dbg_pc, a30_pc_d, dbg_reg_qa, dbg_memaddr_reg,
				         dbg_memaddr_delta, dbg_data_read, dbg_a7, dbg_directPC, $time);

			// (1b) every rts/return PC-load (directPC) while executing in the $x0A
			//      ROM region — shows the popped return value (data_read) + live SP (A7),
			//      to settle whether the $a00948 rts pops a clobbered/low return.
			if (dbg_directPC && (dbg_pc[27:20] == 8'h0A))
				$display("A30[RTS] cyc=%0d pop=%h newPC=%h A7=%h @%0t",
				         a30_cyc, dbg_data_read, dbg_pc, dbg_a7, $time);

			// Per-cycle micro-state + address-source dump around the failing bsr.w push
			// ($40A0012C bsr $a00910, ~cyc 12359300-12359325). Shows the exact cycle the
			// push write fires and which EA it uses (memaddr_reg+delta vs branch target).
			if (a30_cyc > 32'd12359298 && a30_cyc < 32'd12359330)
				$display("A30[UST] cyc=%0d ust=%0d pc=%h memreg=%h memdelta=%h use_base=%b setstate=%b state=%b rfwe=%b waddr=%h wdata=%h",
				         a30_cyc, dbg_ustate, dbg_pc, dbg_memaddr_reg, dbg_memaddr_delta,
				         dbg_use_base, dbg_setstate, dbg_state, dbg_rf_we, dbg_rf_waddr, dbg_rf_wdata);

			// Per-cycle EA-build dump around the failing `move.b d1,$cb2.w` ($40A03F18,
			// right after `pmove (8,A0),TC`, ~cyc 12462805-12462825). CONFIRM whether the
			// bsr.w-fix HOLD (pmmu_busy='1' AND state(1)='1' -> freeze memaddr_delta_rega)
			// engages during the absolute-short operand fetch, pinning the EA at the PC
			// instead of letting $0CB2 latch. Logs the hold gate (pmmu_busy + state) and
			// the held value (memaddr_delta_rega) vs the combined memaddr_delta / addr.
			if (a30_cyc > 32'd12462795 && a30_cyc < 32'd12462830)
				$display("A30[MOVB] cyc=%0d ust=%0d nxt=%0d pc=%h opc=%h lopc=%h dec=%b g2=%b addrl=%b clw=%b pbusy=%b ubase=%b ss=%b st=%b drega=%h memdelta=%h addr=%h",
				         a30_cyc, dbg_ustate, dbg_next_ustate, dbg_pc, dbg_opcode, dbg_last_opc,
				         dbg_decodeOPC, dbg_get_2ndopc, dbg_set_addrlong, dbg_clkena_lw,
				         dbg_pmmu_busy, dbg_use_base, dbg_setstate, dbg_state,
				         dbg_memaddr_drega, dbg_memaddr_delta, addr);

			a30_pc_d <= dbg_pc;
		end
	end

	// --- Stack-region ($1FF380-$1FF3FF) bus-cycle logger ---
	// The failing rts has A7=$1FF3C4 (correct/high) yet pops $0 -> derail. So the
	// stacked return at $1FF3C4 is wrong. Watch every data read/write to the stack
	// region: the bsr push should WRITE $40A00130 to $1FF3C4; the rts should READ it
	// back. If the push writes the wrong value/addr, or the read sees $0, this shows it.
	always @(posedge clk) begin
		if (!reset && phi2 && s_state == 3'd6 && !walk_cycle && eff_busstate != 2'b01 &&
		    // (a) anything aliasing the $1FF3xx stack region (any top nibble), OR
		    //     (b) ALL data cycles during the continuation window (cyc ~12.359M)
		    //     so the bsr push is captured wherever its address lands.
		    (addr[27:8] == 20'h1FF3 ||
		     (a30_cyc > 32'd12359150 && a30_cyc < 32'd12359650))) begin
			$display("A30[STK] %s addr=%h data=%h busstate=%b kpc=%h cyc=%0d @%0t",
			         tg68_rw ? "RD" : "WR", addr,
			         tg68_rw ? tg68_din : tg68_dout_k, tg68_busstate, tg68_addr, a30_cyc, $time);
		end
	end

	// --- $1FF35A dispatch probe (LC II post-MMU, NEXT blocker) ---
	// After the (now-fixed) bsr.w push, trace the path through the $00A1491E
	// jump-table dispatcher (jmp ($2,PC,D5.w)) to the $001FF35A wedge. Logs each
	// instruction boundary in the continuation/dispatcher/stack pages ($x0A0xxxx,
	// $x0A1xxxx, $xx1FF3xx) + every PC-load (directPC) + EA context (memaddr_reg/
	// delta/use_base/reg_QA/data_read) + PMMU-walk status (walk_cycle/walker_req).
	// Answers: is the jmp target (D5/computed EA) right vs MAME ($40A07A5A), and
	// does the EA/target-fetch stall on a PMMU walk (same address-corruption class)?
	// Bounded: arms just before the push, stops 1500 cyc after PC first enters $1FF3xx.
	reg        disp_armed;
	reg        disp_wedged;
	reg [15:0] disp_cnt;
	reg [31:0] disp_pc_d;
	always @(posedge clk) begin
		if (reset) begin
			disp_armed  <= 1'b0;
			disp_wedged <= 1'b0;
			disp_cnt    <= 16'd0;
			disp_pc_d   <= 32'hFFFFFFFF;
		end else if (tg68_clkena) begin
			if (a30_cyc > 32'd12359000) disp_armed <= 1'b1;
			if (disp_armed && (dbg_pc[23:8] == 16'h1FF3 || dbg_pc[31:24] == 8'hFF)) disp_wedged <= 1'b1;
			if (disp_wedged) disp_cnt <= disp_cnt + 1'b1;

			if (disp_armed && !(disp_wedged && disp_cnt > 16'd1500)) begin
				if (((dbg_pc[23:16] == 8'hA0 || dbg_pc[23:16] == 8'hA1 ||
				      dbg_pc[23:8] == 16'h1FF3) && dbg_pc != disp_pc_d)
				    || dbg_directPC || walk_cycle)
					$display("A30[DISP] cyc=%0d pc=%h(was %h) dPC=%b ust=%0d memreg=%h memdelta=%h ubase=%b QA=%h dread=%h a2=%h a7=%h ss=%b st=%b walk=%b wreq=%b waddr=%h bs=%b addr=%h",
					         a30_cyc, dbg_pc, disp_pc_d, dbg_directPC, dbg_ustate,
					         dbg_memaddr_reg, dbg_memaddr_delta, dbg_use_base, dbg_reg_qa,
					         dbg_data_read, dbg_a2, dbg_a7, dbg_setstate, dbg_state,
					         walk_cycle, pmmu_walker_req, pmmu_walker_addr, tg68_busstate, tg68_addr);
			end
			disp_pc_d <= dbg_pc;
		end
	end

	// --- $0CB0-$0CBF byte-lane watchpoint (LC II post-MMU, $1FF35A wedge root) ---
	// The A-trap MMU-mode flag $0CB2 is $46 in our core but 0 in MAME, sending us into
	// a spurious pmove-TC reconfig -> bus error. The setup `move.b #$1,$cb2.w` ($A03E14)
	// is a BYTE write to an EVEN address; suspect it lands on the wrong byte lane (odd),
	// leaving $0CB2 stale. Log every bus access to $0CB0-$0CBF with the UDS/LDS lane and
	// both data bytes, so we can see exactly which lane the byte write/read uses.
	always @(posedge clk) begin
		if (!reset && phi2 && s_state == 3'd6 && !walk_cycle && eff_busstate != 2'b01 &&
		    addr[27:4] == 24'h0000CB) begin
			$display("A30[CB] %s addr=%h uds=%b lds=%b data=%h(hi=%h lo=%h) bs=%b kpc=%h cyc=%0d",
			         tg68_rw ? "RD" : "WR", addr, tg68_uds_n, tg68_lds_n,
			         tg68_rw ? din : tg68_dout_k,
			         (tg68_rw ? din : tg68_dout_k) >> 8, (tg68_rw ? din : tg68_dout_k) & 16'hFF,
			         tg68_busstate, tg68_addr, a30_cyc);
		end
	end
`endif

// Expose busstate for debugging
assign busstate = tg68_busstate;

endmodule
