//
// sdram.v
//
// sdram controller implementation for the MiST board
//
// Copyright (c) 2015 Till Harbaum <till@harbaum.org>
//
// This source file is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This source file is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

module sdram
(
	// interface to the MT48LC16M16 chip
	output              sd_clk,
	inout  reg [15:0]   sd_data,    // 16 bit bidirectional data bus
	output reg [12:0]   sd_addr,    // 13 bit multiplexed address bus
	output     [1:0]    sd_dqm,     // two byte masks
	output reg [1:0]    sd_ba,      // two banks
	output              sd_cs,      // a single chip select
	output              sd_we,      // write enable
	output              sd_ras,     // row address select
	output              sd_cas,     // columns address select

	// cpu/chipset interface
	input               init,       // init signal after FPGA config to initialize RAM
	input               clk_64,     // sdram is accessed at 64MHz
	input               clk_8,      // 8MHz chipset clock to which sdram state machine is synchonized

	input [15:0]        din,        // data input from chipset/cpu
	output reg [15:0]   dout,       // data output to chipset/cpu
	input [25:0]        addr,       // 26 bit word address (bit 24 = col A9, 64MB+
	                                // modules; bit 25 = second chip, 128MB modules)
	input [1:0]         ds,         // upper/lower data strobe
	input               oe,         // cpu/chipset requests read
	input               we,         // cpu/chipset requests write
	output              ram_ready,  // 1 = dout holds valid data for the address on `addr`

	// Video burst read port (mdc824 scanline prefetch — docs/VRAM_1MB_OPTIONS.md
	// Option A). STRICTLY lowest priority: it only ever uses a command window in
	// which the cpu/chipset presented NO op, never two windows in a row, and
	// yields to the forced-refresh credit. In its window it runs a self-
	// contained ACTIVE @T0 / up to 4 chained BL1 READs @T2..T5 / explicit
	// single-bank PRECHARGE @T6 sequence (tRCD 2ck=31ns>20, tRAS 6ck=92ns>42,
	// tRP 2ck=31ns>20 — all satisfied with margin, and the DQ bus is free again
	// 2 cycles before the next window's earliest write data). Chained groups
	// start at vid_addr and run to the next 4-word boundary, so a group can
	// never cross a row. Served words stream out on vid_data/vid_tog at one
	// word per 2 clk_64 (= one per clk_sys), each held 2 clk_64; vid_tog flips
	// once per word so the 32.5MHz consumer can count words even when the data
	// repeats. The controller starts a new group only when the client's
	// vid_addr has caught up with base+n of the previous group (or vid_seq
	// changed = client restarted on a new line), so a stale-sampled vid_addr
	// can never produce a duplicated/overlapping group.
	input               vid_rd,     // level: fetch engine wants words at vid_addr
	input [25:0]        vid_addr,   // word address of the next unserved word
	input               vid_seq,    // flips when the client restarts (new line)
	output reg [15:0]   vid_data,   // served word (held 2 clk_64)
	output reg          vid_dseq,   // vid_seq of the group this word belongs to
	output reg          vid_tog     // flips once per served word
);

localparam RASCAS_DELAY   = 3'd2;   // tRCD=20ns -> 3 cycles@128MHz
localparam BURST_LENGTH   = 3'b000; // 000=1, 001=2, 010=4, 011=8
localparam ACCESS_TYPE    = 1'b0;   // 0=sequential, 1=interleaved
localparam CAS_LATENCY    = 3'd2;   // 2/3 allowed
localparam OP_MODE        = 2'b00;  // only 00 (standard operation) allowed
localparam NO_WRITE_BURST = 1'b1;   // 0= write burst enabled, 1=only single access write

localparam MODE = { 3'b000, NO_WRITE_BURST, OP_MODE, CAS_LATENCY, ACCESS_TYPE, BURST_LENGTH};


// ---------------------------------------------------------------------
// ------------------------ cycle state machine ------------------------
// ---------------------------------------------------------------------

// The state machine runs at 128Mhz synchronous to the 8 Mhz chipset clock.
// It wraps from T15 to T0 on the rising edge of clk_8

localparam STATE_FIRST     = 3'd0;   // first state in cycle
localparam STATE_CMD_START = 3'd0;   // state in which a new command can be started
localparam STATE_CMD_CONT  = STATE_CMD_START  + RASCAS_DELAY; // command can be continued
localparam STATE_READ      = STATE_CMD_CONT + CAS_LATENCY + 4'd2;  // +2 for 65MHz margin (was +1)
localparam STATE_LAST      = 3'd7;  // last state in cycle

reg [2:0] t;
always @(posedge clk_64) begin
	// 128Mhz counter synchronous to 8 Mhz clock
	// force counter to pass state 0 exactly after the rising edge of clk_8
	if(((t == STATE_LAST)  && ( clk_8 == 0)) ||
		((t == STATE_FIRST) && ( clk_8 == 1)) ||
		((t != STATE_LAST) && (t != STATE_FIRST)))
			t <= t + 3'd1;
end

// ---------------------------------------------------------------------
// --------------------------- startup/reset ---------------------------
// ---------------------------------------------------------------------

// JEDEC SDR-SDRAM init: ~118us of NOPs after the clock starts (the chip
// wants 100us of stable clock before the first command — the FPGA was just
// reconfigured, so the SDRAM clock was dead/floating until now), then
// PRECHARGE ALL -> 8x AUTO REFRESH -> LOAD MODE. The previous sequence
// (31 chipset cycles ~4us, ZERO refreshes; its "wait 1ms" comment was wrong)
// relied on the chip state the PREVIOUS core left behind; whether the mode
// register write took was per-load luck — suspected cause of the cold-load
// flakiness that clears after loading a different core first.
// The ladder is content-preserving (NOPs/refreshes/MRS only), so it is also
// safe to re-run via `init` on a warm user reset while the ROM is in SDRAM.
reg [9:0] reset;
always @(posedge clk_64) begin
	if(init)	reset <= 10'h3ff;
	else if((t == STATE_LAST) && (reset != 0))
		reset <= reset - 10'd1;
end

initial reset = 10'h3FF;

// ---------------------------------------------------------------------
// ------------------ generate ram control signals ---------------------
// ---------------------------------------------------------------------

// all possible commands
localparam CMD_INHIBIT         = 4'b1111;
localparam CMD_NOP             = 4'b0111;
localparam CMD_ACTIVE          = 4'b0011;
localparam CMD_READ            = 4'b0101;
localparam CMD_WRITE           = 4'b0100;
localparam CMD_BURST_TERMINATE = 4'b0110;
localparam CMD_PRECHARGE       = 4'b0010;
localparam CMD_AUTO_REFRESH    = 4'b0001;
localparam CMD_LOAD_MODE       = 4'b0000;

reg [3:0] sd_cmd;   // current command sent to sd ram

// Chip targeting (2026-07-15, 68MB support): nCS is now driven from its own
// register instead of sd_cmd[3]. MiSTer 128MB modules carry TWO 64MB chips
// (2x AS4C32M16SB) and INVERT nCS into the second one (PSX_MiSTer sdram.sv
// precedent: `SDRAM_nCS = chip`), so the nCS LEVEL selects the chip a
// command goes to: 0 = chip 0 (all of a 32/64MB module), 1 = chip 1 (upper
// 64MB of a 128MB module). The idle level stays 1 exactly like the old
// CMD_INHIBIT encoding: chip 0 sees INHIBIT, chip 1 sees NOP — both no-ops.
// On 32/64MB modules a chip-1 command is simply ignored (nCS=1 = deselected);
// the OSD gating in MacIIvi.sv keeps addr[25] at 0 for those modules.
reg sd_cs_r = 1'b1;

// drive control signals according to current command
assign sd_cs  = sd_cs_r;
assign sd_ras = sd_cmd[2];
assign sd_cas = sd_cmd[1];
assign sd_we  = sd_cmd[0];
// DQM shares pins with A12/A11 BY BOARD DESIGN: the SDRAM module PCB shorts
// A12/A11 to DQMH/DQML to save connector pins, and both chips' column space
// stops at A9 (+A10 auto-precharge), so A12/A11 are column don't-cares. The
// row phase uses them as real row bits (DQM is ignored outside data phases).
assign sd_dqm = sd_addr[12:11];

reg oe_latch, we_latch;
reg rfsh_chip = 1'b0;   // idle-slot refresh alternates between the two chips

// Address-capture latch (2026-06-25): the SDRAM column (issued at the CAS phase,
// STATE_CMD_CONT) must use the address sampled at the command slot
// (STATE_CMD_START), NOT a live `addr`. A normal CPU access holds `addr` stable
// across the whole slot, so for it latched == live and this changes nothing. But
// the BORROWED PMMU-walk bus cycle's address is not stable from the slot to the
// CAS phase: taking the column from live `addr` row/column-mismatched and returned
// the WRONG location's data -> bad page-table descriptor -> the 10MB-boot Sad Mac
// / intermittent boot (the failure point shifts with bus phase, so it sometimes
// happens to align and boots). The row is already taken at the slot
// (sd_addr <= {addr[23],addr[19:8]} below), so the access already relies on `addr`
// being valid then; this just makes the column use that same instant. Write DATA
// and byte strobes stay LIVE (valid only at the CAS phase). This replaces the
// 2026-06-24 pending-service latch, whose late re-service path corrupted normal
// SDRAM accesses (gray-stall, builds #13/#14/#16).
reg [25:0] addr_latch;

// Read-data-valid handshake (2026-06-25): a RAM/VRAM READ's DTACK (in MacIIvi.sv)
// must wait for the SDRAM to ACTUALLY finish the read, not fire at slot-start. The
// borrowed PMMU-walk read otherwise gets a slot-start DTACK and the walker latches
// `dout` before the read completes -> it captures stale bus data (the 10MB-boot Sad
// Mac). That the re-read retry boots PROVES the data is in SDRAM and the single read
// was merely mis-timed. dout_addr/dout_valid record which address `dout` currently
// holds; any write invalidates it, so a read can never return pre-write data.
reg [25:0] dout_addr;
reg        dout_valid;
assign ram_ready = dout_valid && (dout_addr == addr);

// Redundant-window release (Option A v2, 2026-08-07 HW finding): a 68030 bus
// cycle holds oe/we presented across 2-3 command windows while only the first
// window's execution matters — the extra windows used to re-execute the op
// idempotently, and under a drawing-loop workload that occupancy starved the
// video port to ~73% of each scanline (frozen right-edge band on hardware).
// Track write completion the same way read completion is tracked (address
// AND data compared — a back-to-back write of different data to the same
// address never matches, so it executes), and release a window whose
// presented op is already served. Only provably-redundant re-executions are
// skipped: the first window of every op still executes it, so every existing
// completion contract (slot-start DTACK, ext 3-edge write count, PMMU-walk
// ram_ready wait) holds unchanged.
reg [25:0] wr_done_addr;
reg [15:0] wr_done_din;
reg        wr_done_valid;
wire wr_served = wr_done_valid && (wr_done_addr == addr) && (wr_done_din == din);
wire cpu_window_needed = (we && !wr_served) || (oe && !ram_ready);

// ---- video burst port state (Option A) ------------------------------------
// vid_* inputs are launched from clk_sys registers; clk_sys and clk_64 come
// from the same PLL (2:1), so a single clk_64 sampling register is a timed
// synchronous crossing (STA-covered), not an async CDC.
reg        vid_rd_m;
reg [25:0] vid_addr_m;
reg        vid_seq_m;
reg        vid_win;         // the current window is a video window
reg        vid_win_d;       // the PREVIOUS window was video (cooldown + tail captures)
reg [3:0]  vid_issue;       // bit k: a READ was issued at T(2+k) (col base+k)
reg [25:0] vid_base;        // group base, latched at T0 of the video window
// group-completion handshake (see the port comment): next group only when the
// client caught up or restarted
reg        vid_expect_valid;
reg [25:0] vid_expect_addr;
reg        vid_expect_seq;
reg        vid_grp_seq;     // vid_seq latched with the group — tags served words
// capture queue (up to 4 words land at T6,T7,T0',T1'; drained 1 per 2 clk_64).
// Entries carry {group seq, data}: after a line restart (vid_seq flip) the
// client drops any still-draining words of the aborted group by tag, with no
// timing assumptions.
reg [16:0] vid_q [0:3];
reg [1:0]  vid_q_wr, vid_q_rd;
reg [2:0]  vid_q_cnt;
reg        vid_drain_ph;
// forced-refresh credit: refresh used to fire on EVERY idle window; with the
// video port competing for idle windows, refresh gets a hard credit instead —
// one forced refresh at least every RF_FORCE windows (24 windows = 2.95us,
// alternating chips = each chip every 5.9us, still well inside the 7.8us
// JEDEC cadence). Truly idle windows (no video pending) still refresh
// opportunistically exactly like before.
localparam [4:0] RF_FORCE = 5'd24;
reg [4:0]  rf_cnt;

// video queue push/pop, computed once so the count stays coherent when a
// capture and a drain land on the same edge. Captures for READs issued at
// T2/T3 land at T6/T7 of the same window; the T4/T5 reads land at T0/T1 of
// the NEXT window — at the T0 edge `vid_win` still holds the video window's
// value (its new value is assigned on that same edge), at T1 `vid_win_d`
// (updated at T0 from the old vid_win) carries it. The cooldown (`!vid_win`
// in the grant term) guarantees the window after a video window is never
// video, so vid_issue is stable through both tail captures.
wire vid_pop  = (vid_q_cnt != 3'd0) && vid_drain_ph;
wire vid_push = (reset == 0) && (
	(t == 3'd6 && vid_win   && vid_issue[0]) ||
	(t == 3'd7 && vid_win   && vid_issue[1]) ||
	(t == 3'd0 && vid_win   && vid_issue[2]) ||
	(t == 3'd1 && vid_win_d && vid_issue[3]));

always @(posedge clk_64) begin
	sd_cmd <= CMD_INHIBIT;  // default: idle (with nCS=1: INHIBIT to chip 0,
	sd_cs_r <= 1'b1;        // NOP to a 128MB module's inverted-nCS chip 1)
	sd_data <= 16'bZZZZZZZZZZZZZZZZ;

	// video port input sampling + word drain run unconditionally (drain is
	// inert while the queue is empty)
	vid_rd_m   <= vid_rd;
	vid_addr_m <= vid_addr;
	vid_seq_m  <= vid_seq;
	vid_drain_ph <= ~vid_drain_ph;
	if (vid_pop) begin
		{vid_dseq, vid_data} <= vid_q[vid_q_rd];
		vid_q_rd  <= vid_q_rd + 2'd1;
		vid_tog   <= ~vid_tog;
	end
	if (vid_push) begin
		vid_q[vid_q_wr] <= {vid_grp_seq, sd_data};
		vid_q_wr <= vid_q_wr + 2'd1;
	end
	if (!vid_rd_m) vid_expect_valid <= 1'b0;

	if(reset != 0) begin
		dout_valid <= 1'b0;
		wr_done_valid <= 1'b0;
		vid_win    <= 1'b0;
		vid_win_d  <= 1'b0;
		vid_q_cnt  <= 3'd0;
		vid_q_wr   <= 2'd0;
		vid_q_rd   <= 2'd0;
		vid_expect_valid <= 1'b0;
		rf_cnt     <= 5'd0;
		// init ladder, one command slot per chipset cycle (~123ns apart), run
		// for BOTH chips of a 128MB module (even slot = chip 0, odd = chip 1;
		// on 32/64MB modules the chip-1 slots land on a deselected nCS and are
		// inert): 1023..67 = NOP wait, 66/65 = PRECHARGE ALL, 58..43 = 8x AUTO
		// REFRESH each, 4/3 = LOAD MODE. Same-chip commands are >=246ns apart,
		// so tRP/tRFC/tMRD are satisfied by orders of magnitude.
		if(t == STATE_CMD_START) begin

			if(reset == 66 || reset == 65) begin
				sd_cmd <= CMD_PRECHARGE;
				sd_cs_r <= reset[0];
				sd_addr[10] <= 1'b1;      // precharge all banks
			end

			if(reset >= 43 && reset <= 58) begin
				sd_cmd <= CMD_AUTO_REFRESH;
				sd_cs_r <= reset[0];
			end

			if(reset == 4 || reset == 3) begin
				sd_cmd <= CMD_LOAD_MODE;
				sd_cs_r <= reset[0];
				sd_addr <= MODE;
			end

		end
	end else begin
		// normal operation

		// RAS phase
		// -------------------  cpu/chipset read/write ----------------------
		if(t == STATE_CMD_START) begin
			{oe_latch, we_latch} <= cpu_window_needed ? {oe, we} : 2'b00;
			vid_win_d <= vid_win;
			vid_win   <= 1'b0;
			rf_cnt    <= (rf_cnt == 5'd31) ? rf_cnt : rf_cnt + 5'd1;
			if (we) dout_valid <= 1'b0;   // a write invalidates the read-data cache
			if (cpu_window_needed) begin
				// Capture the access address NOW for the CAS column (see the
				// addr_latch comment above). A12 = addr[23] (13th row bit);
				// nCS level = addr[25] picks the chip on 128MB modules.
				addr_latch <= addr;
				sd_cmd <= CMD_ACTIVE;
				sd_cs_r <= addr[25];
				sd_addr <= { addr[23], addr[19:8] };
				sd_ba <= addr[21:20];
		// ------------------ no access: video / refresh ---------------
			end else if (rf_cnt < RF_FORCE && vid_rd_m && !vid_win &&
			             (!vid_expect_valid || (vid_seq_m != vid_expect_seq) ||
			              (vid_addr_m == vid_expect_addr))) begin
				// Video window (lowest priority): the refresh credit is not
				// due, a fetch is pending, the previous window was not video
				// (drain/capture separation), and the client has consumed the
				// previous group (or restarted a line = vid_seq flipped).
				vid_win  <= 1'b1;
				vid_base <= vid_addr_m;
				// chained READs run from addr to the next 4-word boundary
				vid_issue <= (vid_addr_m[1:0] == 2'd0) ? 4'b1111 :
				             (vid_addr_m[1:0] == 2'd1) ? 4'b0111 :
				             (vid_addr_m[1:0] == 2'd2) ? 4'b0011 : 4'b0001;
				vid_expect_addr  <= vid_addr_m + {23'd0,
				                    (vid_addr_m[1:0] == 2'd0) ? 3'd4 :
				                    (vid_addr_m[1:0] == 2'd1) ? 3'd3 :
				                    (vid_addr_m[1:0] == 2'd2) ? 3'd2 : 3'd1};
				vid_expect_seq   <= vid_seq_m;
				vid_expect_valid <= 1'b1;
				vid_grp_seq      <= vid_seq_m;
				sd_cmd  <= CMD_ACTIVE;
				sd_cs_r <= vid_addr_m[25];
				sd_addr <= { vid_addr_m[23], vid_addr_m[19:8] };
				sd_ba   <= vid_addr_m[21:20];
			end else begin
				// Idle slot: refresh, alternating chips so BOTH chips of a
				// 128MB module get their full 8192/64ms cadence (a chip-1
				// refresh is inert on 32/64MB modules). Forced at the first
				// idle window once rf_cnt hits RF_FORCE, opportunistic when
				// no video fetch is pending — the CPU can hold at most 3 of
				// 4 slots, so an idle window always arrives in time.
				sd_cmd <= CMD_AUTO_REFRESH;
				sd_cs_r <= rfsh_chip;
				rfsh_chip <= ~rfsh_chip;
				rf_cnt <= 5'd0;
			end
		end

		// Video window command phases: chained BL1 READs at T2..T5 (columns
		// base+0..3, A10=0 = no auto precharge, DQM open), then an explicit
		// single-bank PRECHARGE at T6. sd_ba was set at the ACTIVE and is
		// held by register through the whole window.
		if (vid_win) begin
			if (t == 3'd2 && vid_issue[0]) begin
				sd_cmd <= CMD_READ; sd_cs_r <= vid_base[25];
				sd_addr <= {2'b00, 1'b0, vid_base[24], vid_base[22], vid_base[7:2], vid_base[1:0]};
			end
			if (t == 3'd3 && vid_issue[1]) begin
				sd_cmd <= CMD_READ; sd_cs_r <= vid_base[25];
				sd_addr <= {2'b00, 1'b0, vid_base[24], vid_base[22], vid_base[7:2], vid_base[1:0] + 2'd1};
			end
			if (t == 3'd4 && vid_issue[2]) begin
				sd_cmd <= CMD_READ; sd_cs_r <= vid_base[25];
				sd_addr <= {2'b00, 1'b0, vid_base[24], vid_base[22], vid_base[7:2], vid_base[1:0] + 2'd2};
			end
			if (t == 3'd5 && vid_issue[3]) begin
				sd_cmd <= CMD_READ; sd_cs_r <= vid_base[25];
				sd_addr <= {2'b00, 1'b0, vid_base[24], vid_base[22], vid_base[7:2], vid_base[1:0] + 2'd3};
			end
			if (t == 3'd6) begin
				sd_cmd <= CMD_PRECHARGE; sd_cs_r <= vid_base[25];
				sd_addr <= 13'd0;   // A10=0: single-bank precharge (sd_ba held)
			end
		end

		// CAS phase. The column comes from the LATCHED address, so a borrowed
		// walk read's row and column always reference the same location. Write
		// DATA and the byte strobes stay LIVE — they are only valid at CAS.
		if(t == STATE_CMD_CONT && (we_latch || oe_latch)) begin
			sd_cmd <= we_latch?CMD_WRITE:CMD_READ;
			sd_cs_r <= addr_latch[25];   // same chip as the ACTIVE row
			if (we_latch) begin
				sd_data <= din;
				// record the served write for the window-release compare
				wr_done_addr  <= addr_latch;
				wr_done_din   <= din;
				wr_done_valid <= 1'b1;
			end
			// always return both bytes in a read. The cpu may not
			// need it, but the caches need to be able to store everything
			// Column: A10=1 (auto precharge), A9=addr[24] (the 10th column
			// bit on 64MB+ chips; always 0 for accesses below 32MB, so 32MB
			// MT48LC16M16 modules are unaffected).
			sd_addr <= { we_latch ? ~ds : 2'b00, 1'b1, addr_latch[24],
			             addr_latch[22], addr_latch[7:0] };  // auto precharge
		end

		// Data ready: latch dout AND publish it as valid for addr_latch, so the
		// RAM-read DTACK in MacIIvi.sv only fires once this read has truly completed.
		if (t == STATE_READ && oe_latch) begin
			dout       <= sd_data;
			dout_addr  <= addr_latch;
			dout_valid <= 1'b1;
		end

		// video queue occupancy (push and pop can coincide)
		vid_q_cnt <= vid_q_cnt + (vid_push ? 3'd1 : 3'd0) - (vid_pop ? 3'd1 : 3'd0);

	end
end

altddio_out
#(
	.extend_oe_disable("OFF"),
	.intended_device_family("Cyclone V"),
	.invert_output("OFF"),
	.lpm_hint("UNUSED"),
	.lpm_type("altddio_out"),
	.oe_reg("UNREGISTERED"),
	.power_up_high("OFF"),
	.width(1)
)
sdramclk_ddr
(
	.datain_h(1'b0),
	.datain_l(1'b1),
	.outclock(clk_64),
	.dataout(sd_clk),
	.aclr(1'b0),
	.aset(1'b0),
	.oe(1'b1),
	.outclocken(1'b1),
	.sclr(1'b0),
	.sset(1'b0)
);

endmodule
