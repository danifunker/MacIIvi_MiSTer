/* tb_enetnbtp.v — unit test for the NuBus Ethernet card front-end
 * (rtl/nubus/nubus_enetnbtp.sv, Apple Ethernet NB Twisted Pair / SONIC)
 * against the behavioral DDR3 model (sim_ddr3.v).
 *
 * The TB plays BOTH sides: it drives TG68-style bus cycles (address + AS +
 * UDS/LDS, waiting on card_ack = the top's stretched DTACK) and plays the
 * Main_MiSTer support/mac host (stages MAGIC / shadows / MACPROM / INT /
 * card RAM in the DDR3 window, decodes doorbell ring entries).
 *
 * WHAT IT CHECKS:
 *   1. Presence gate: without MAGIC the card never claims; the LC-layout
 *      MAGIC ("McLCETH2") is REJECTED (family/version gate); v3 MAGIC + a
 *      guest-reset window latches presence (sticky-rise).
 *   2. SONIC registers: 64 x 16-bit at consecutive word addresses (index =
 *      A[6:1], the NB card's layout — NOT the LC's one-per-longword); UDS/LDS
 *      byte reads serve the right halves; the unmapped $80-$FF half serves
 *      $FFFF with no doorbell; word write posts a REG_WR ring entry + wptr
 *      publish; byte writes are ignored (complete, no doorbell).
 *   3. Timed ISR clear-mask + irq suppression: an ISR ack reads back clear
 *      immediately and drops irq for one round trip; both expire on the
 *      timer (delay-only, nothing sticks).
 *   4. MAC PROM: {$00, PROM byte} on the 16-bit low lanes at $Fs40'0000
 *      (byte k at guest byte 2k+1); writes inert; $Fs40'0010 not claimed.
 *   5. Card RAM: guest word/byte writes land at the right DDR3 window bytes
 *      (and nowhere else), reads round-trip, the $C2'0000 alias hits the
 *      same storage, host-poked bytes are guest-visible, the top word works,
 *      $02'0000 is not claimed.
 *   6. declROM: byteLanes $D2 lane-1 expansion — guest word 4k+{0,1} serves
 *      {$00, raw[k]}, words at 4k+2 serve $0000 with no DDR3 trip; the
 *      format-block byteLanes byte lands at $FsFF'FFFD; below-window not
 *      claimed.
 *   7. Doorbell: warm guest reset posts TAG_RESET (the presence-establishing
 *      reset posts nothing); ring backpressure force-publishes after the
 *      saturating wait so a dead host can never hang the guest.
 *   8. Watchdog: a stalled DDR3 read retires open-bus in ~4 ms and the card
 *      recovers on the next access.
 *   9. OSD gate at reset; MAGIC removal mid-session (or across a warm reset)
 *      does NOT drop a latched presence — only OSD-off-at-reset or a core
 *      reload does; the host's startup purge owns stale-MAGIC un-arming.
 *  10. Card-RAM u64 read cache: a same-u64 re-read (and its $C2 alias)
 *      serves with no DDR3 trip, any guest card-RAM write invalidates,
 *      and a host-side poke is stale only inside the ~255-cycle TTL.
 *
 * Build + run (Verilator 5.x, from verilator/):
 *   verilator --binary -j 0 -Wno-fatal --timescale 1ns/1ps \
 *     --Mdir obj_enettb --top-module tb_enetnbtp \
 *     tb_enetnbtp.v sim_ddr3.v ../rtl/nubus/nubus_enetnbtp.sv
 *   obj_enettb/Vtb_enetnbtp
 */
`timescale 1ns/1ps

module tb_enetnbtp;

	reg clk = 0;
	always #5 clk = ~clk;

	reg rst_core = 1, rst_guest = 1, ena_osd = 1;

	reg  [31:0] cpuAddr = 0;
	reg  [15:0] cpuDataIn = 0;
	reg  _cpuAS = 1, _cpuUDS = 1, _cpuLDS = 1, _cpuRW = 1;

	wire card_sel, card_ack, irq;
	wire [15:0] card_dout;
	wire [28:0] m_addr;  wire [7:0] m_burst, m_be;
	wire m_rd, m_we, m_rvalid, m_busy;
	wire [63:0] m_wdata, m_rdata;

	nubus_enetnbtp dut (
		.clk_sys(clk), .rst_core(rst_core), .rst_guest(rst_guest), .ena_osd(ena_osd),
		.cpuAddr(cpuAddr), .cpuDataIn(cpuDataIn),
		._cpuAS(_cpuAS), ._cpuUDS(_cpuUDS), ._cpuLDS(_cpuLDS), ._cpuRW(_cpuRW),
		.card_sel(card_sel), .card_ack(card_ack), .card_dout(card_dout), .irq(irq),
		.mem_addr(m_addr), .mem_burst(m_burst), .mem_rd(m_rd), .mem_we(m_we),
		.mem_wdata(m_wdata), .mem_be(m_be), .mem_rdata(m_rdata),
		.mem_rvalid(m_rvalid), .mem_busy(m_busy)
	);

	sim_ddr3 dd (
		.clk(clk), .addr(m_addr), .burst(m_burst), .rd(m_rd), .we(m_we),
		.wdata(m_wdata), .be(m_be), .rdata(m_rdata), .rvalid(m_rvalid), .busy(m_busy)
	);

	localparam [63:0] MAGIC_LC = 64'h4D634C43_45544832;   // "McLCETH2"
	localparam [63:0] MAGIC    = 64'h4D634E42_45544833;   // "McNBETH3"
	localparam W_CARD = 15'h0000, W_ROM = 15'h4000,
	           W_MAGIC = 15'h5000, W_WPTR = 15'h5001, W_SHAD = 15'h5002,
	           W_INT = 15'h5012, W_MACPROM = 15'h5013, W_RPTR = 15'h5015,
	           W_RING = 15'h5100;

	integer fails = 0;
	task check(input cond, input [511:0] name);
		if (!cond) begin
			$display("FAIL: %0s", name);
			fails = fails + 1;
		end else
			$display("pass: %0s", name);
	endtask

	// ── TG68-flavored bus cycles ────────────────────────────────────────────
	task cpu_cycle(input [31:0] addr, input rw, input uds, input lds,
	               input [15:0] wdata, input expect_claim,
	               output [15:0] rdata, output claimed);
		integer n;
		begin
			@(negedge clk);
			cpuAddr  = addr; _cpuRW = rw; cpuDataIn = wdata;
			_cpuAS   = 0; _cpuUDS = !uds; _cpuLDS = !lds;
			claimed  = 0; rdata = 16'hFFFF;
			n = 0;
			while (n < 3000 && !(card_sel && card_ack)) begin
				@(negedge clk);
				if (card_sel) claimed = 1;
				n = n + 1;
			end
			if (card_sel && card_ack) begin
				claimed = 1;
				rdata   = card_dout;
			end
			if (expect_claim != claimed)
				$display("  (cycle @%h claim=%0d expected=%0d)", addr, claimed, expect_claim);
			_cpuAS = 1; _cpuUDS = 1; _cpuLDS = 1; _cpuRW = 1;
			@(negedge clk);
			@(negedge clk);
		end
	endtask

	// cpu_cycle gives up after 3000 cycles; watchdog/backpressure paths need more.
	task cpu_cycle_slow(input [31:0] addr, input rw, input [15:0] wdata,
	                    input integer maxn, output [15:0] rdata, output claimed);
		integer n;
		begin
			@(negedge clk);
			cpuAddr = addr; _cpuRW = rw; cpuDataIn = wdata;
			_cpuAS = 0; _cpuUDS = 0; _cpuLDS = 0;
			claimed = 0; rdata = 16'hFFFF; n = 0;
			while (n < maxn && !(card_sel && card_ack)) begin
				@(negedge clk); n = n + 1;
			end
			if (card_sel && card_ack) begin claimed = 1; rdata = card_dout; end
			_cpuAS = 1; _cpuUDS = 1; _cpuLDS = 1; _cpuRW = 1;
			@(negedge clk); @(negedge clk);
		end
	endtask

	reg [15:0] rd; reg cl;
	reg [63:0] e;
	reg [31:0] wp0;
	integer nrd0, nrd1;

	initial begin
		// ── reset, no host ───────────────────────────────────────────────
		repeat (10) @(negedge clk);
		rst_core = 0;
		repeat (20) @(negedge clk);
		rst_guest = 0;
		repeat (20) @(negedge clk);

		cpu_cycle(32'hFC000000, 1, 1, 1, 0, 0, rd, cl);
		check(!cl, "no MAGIC: card does not claim $FC000000");

		// ── LC-layout host: MAGIC family gate must reject it ─────────────
		dd.poke64(W_MAGIC, MAGIC_LC);
		repeat (70000) @(negedge clk);      // absent-cadence MAGIC poll
		rst_guest = 1;
		repeat (300) @(negedge clk);
		rst_guest = 0;
		repeat (20) @(negedge clk);
		cpu_cycle(32'hFC000000, 1, 1, 1, 0, 0, rd, cl);
		check(!cl, "LC MAGIC (McLCETH2) is rejected");

		// ── v3 host appears; presence latches during a guest reset ───────
		dd.poke64(W_MAGIC, MAGIC);
		repeat (70000) @(negedge clk);
		rst_guest = 1;
		repeat (300) @(negedge clk);
		rst_guest = 0;
		repeat (20) @(negedge clk);

		check(dd.peek64(W_WPTR) == 0, "presence-establishing reset posts no event");

		// ── SONIC register shadows (NB layout: reg = A[6:1]) ─────────────
		dd.poke64(W_SHAD + 15'd1,  64'h0000_0000_8C41_0000);   // ISR (reg 5)
		dd.poke64(W_SHAD + 15'd0,  64'h00F2_0000_0000_0000);   // TCR (reg 3)
		dd.poke64(W_SHAD + 15'd15, 64'hBEEF_0000_0000_0000);   // DCR2 (reg 63)
		repeat (25000) @(negedge clk);      // let a full poll round pass
		cpu_cycle(32'hFC0C000A, 1, 1, 1, 0, 1, rd, cl);
		check(cl && rd == 16'h8C41, "ISR word read serves shadow (reg 5 @ +$0A)");
		cpu_cycle(32'hFC0C0006, 1, 1, 1, 0, 1, rd, cl);
		check(cl && rd == 16'h00F2, "TCR word read serves shadow (reg 3 @ +$06)");
		cpu_cycle(32'hFC0C007E, 1, 1, 1, 0, 1, rd, cl);
		check(cl && rd == 16'hBEEF, "DCR2 word read serves shadow (reg 63 @ +$7E)");
		cpu_cycle(32'hFC0C000A, 1, 1, 0, 0, 1, rd, cl);
		check(cl && rd[15:8] == 8'h8C, "UDS byte read serves reg[15:8]");
		cpu_cycle(32'hFC0C000A, 1, 0, 1, 0, 1, rd, cl);
		check(cl && rd[7:0] == 8'h41, "LDS byte read serves reg[7:0]");
		cpu_cycle(32'hFC0C0080, 1, 1, 1, 0, 1, rd, cl);
		check(cl && rd == 16'hFFFF, "unmapped $80-$FF half serves $FFFF");

		// ── register doorbell ────────────────────────────────────────────
		wp0 = dd.peek64(W_WPTR);
		cpu_cycle(32'hFC0C000C, 0, 1, 1, 16'hABCD, 1, rd, cl);   // reg 6 (UTDA)
		check(cl, "register word write completes");
		check(dd.peek64(W_WPTR) == wp0 + 1, "word write publishes wptr");
		e = dd.peek64(W_RING + (wp0[7:0] & 8'hFF));
		check(e[0] && e[3:1] == 3'd0 && e[9:4] == 6'd6 && e[31:16] == 16'hABCD,
		      "ring entry carries REG_WR reg 6 data $ABCD");
		wp0 = dd.peek64(W_WPTR);
		cpu_cycle(32'hFC0C000C, 0, 1, 0, 16'h5555, 1, rd, cl);
		check(cl && dd.peek64(W_WPTR) == wp0, "byte write is inert (no doorbell)");
		cpu_cycle(32'hFC0C0080, 0, 1, 1, 16'h5555, 1, rd, cl);
		check(cl && dd.peek64(W_WPTR) == wp0, "write to the unmapped half is inert");

		// ── MAC PROM ({$00, byte} on the low lanes) ──────────────────────
		dd.poke64(W_MACPROM, 64'h7B00_33F0_0F02_01A5);
		repeat (25000) @(negedge clk);
		cpu_cycle(32'hFC400000, 1, 1, 1, 0, 1, rd, cl);
		check(cl && rd == 16'h00A5, "PROM byte 0 word read = {$00, $A5}");
		cpu_cycle(32'hFC40000E, 1, 1, 1, 0, 1, rd, cl);
		check(cl && rd == 16'h007B, "PROM byte 7 (checksum) word read = {$00, $7B}");
		cpu_cycle(32'hFC400002, 1, 0, 1, 0, 1, rd, cl);
		check(cl && rd[7:0] == 8'h01, "PROM LDS byte read serves byte 1");
		cpu_cycle(32'hFC400000, 1, 1, 0, 0, 1, rd, cl);
		check(cl && rd[15:8] == 8'h00, "PROM UDS (even) byte reads $00");
		wp0 = dd.peek64(W_WPTR);
		cpu_cycle(32'hFC400000, 0, 1, 1, 16'hDEAD, 1, rd, cl);
		check(cl && dd.peek64(W_WPTR) == wp0, "PROM write is inert");
		cpu_cycle(32'hFC400010, 1, 1, 1, 0, 0, rd, cl);
		check(!cl, "$400010 (past the PROM) is not claimed");

		// ── card RAM through DDR3 ────────────────────────────────────────
		cpu_cycle(32'hFC000000, 0, 1, 1, 16'hAABB, 1, rd, cl);
		check(cl, "RAM word write @ $000000 completes");
		e = dd.peek64(W_CARD);
		check(e[15:0] == 16'hBBAA, "write lands as window bytes 0=$AA 1=$BB");
		cpu_cycle(32'hFC000006, 0, 1, 1, 16'h1122, 1, rd, cl);
		e = dd.peek64(W_CARD);
		check(e[63:48] == 16'h2211, "lane-6 write lands as window bytes 6=$11 7=$22");
		check(e[47:16] == 32'h0, "byte enables leave the untouched lanes zero");
		cpu_cycle(32'hFC000000, 1, 1, 1, 0, 1, rd, cl);
		check(cl && rd == 16'hAABB, "RAM word read round-trips");
		cpu_cycle(32'hFC000000, 0, 1, 0, 16'hCC00, 1, rd, cl);
		e = dd.peek64(W_CARD);
		check(e[15:0] == 16'hBBCC, "UDS-only write touches only the even byte");
		cpu_cycle(32'hFC000000, 0, 0, 1, 16'h00DD, 1, rd, cl);
		e = dd.peek64(W_CARD);
		check(e[15:0] == 16'hDDCC, "LDS-only write touches only the odd byte");
		dd.poke64(W_CARD + 15'd2, 64'h1817_1615_1413_1211);
		cpu_cycle(32'hFC000010, 1, 1, 1, 0, 1, rd, cl);
		check(cl && rd == 16'h1112, "host-poked bytes read back (lane 0)");
		cpu_cycle(32'hFC000016, 1, 1, 1, 0, 1, rd, cl);
		check(cl && rd == 16'h1718, "host-poked bytes read back (lane 6)");
		cpu_cycle(32'hFCC20010, 0, 1, 1, 16'hC0DE, 1, rd, cl);
		check(cl, "alias window write @ $C20010 completes");
		cpu_cycle(32'hFC000010, 1, 1, 1, 0, 1, rd, cl);
		check(cl && rd == 16'hC0DE, "alias write is visible at $000010");
		cpu_cycle(32'hFCC20016, 1, 1, 1, 0, 1, rd, cl);
		check(cl && rd == 16'h1718, "alias read hits the same storage");
		cpu_cycle(32'hFC01FFFE, 0, 1, 1, 16'hF00D, 1, rd, cl);
		cpu_cycle(32'hFC01FFFE, 1, 1, 1, 0, 1, rd, cl);
		check(cl && rd == 16'hF00D, "top RAM word round-trips");
		cpu_cycle(32'hFC020000, 1, 1, 1, 0, 0, rd, cl);
		check(!cl, "$020000 (past card RAM) is not claimed");

		// ── card-RAM u64 read cache ──────────────────────────────────────
		// A re-read of the same u64 serves with NO DDR3 trip (the copy-loop
		// case); any guest card-RAM write invalidates; a host poke lands
		// within the TTL as documented staleness and reads fresh past it;
		// the $C2 alias shares the line.
		dd.poke64(W_CARD + 15'd4, 64'h4847_4645_4443_4241);   // u64 index 4
		nrd0 = dd.rd_count;
		cpu_cycle(32'hFC000020, 1, 1, 1, 0, 1, rd, cl);
		check(cl && rd == 16'h4142, "cache: miss fills and serves lane 0");
		nrd1 = dd.rd_count;
		check(nrd1 > nrd0, "cache: the fill issued a DDR3 read");
		cpu_cycle(32'hFC000026, 1, 1, 1, 0, 1, rd, cl);
		check(cl && rd == 16'h4748, "cache: same-u64 read serves lane 6");
		check(dd.rd_count == nrd1, "cache: the hit issued NO DDR3 read");
		cpu_cycle(32'hFC000030, 0, 1, 1, 16'h9999, 1, rd, cl);   // any RAM write
		dd.poke64(W_CARD + 15'd4, 64'h5857_5655_5453_5251);
		cpu_cycle(32'hFC000020, 1, 1, 1, 0, 1, rd, cl);
		check(cl && rd == 16'h5152, "cache: a guest write invalidates (fresh fetch)");
		dd.poke64(W_CARD + 15'd4, 64'h6867_6665_6463_6261);
		cpu_cycle(32'hFC000022, 1, 1, 1, 0, 1, rd, cl);
		check(cl && rd == 16'h5354, "cache: in-TTL hit holds the cached u64 (bounded staleness)");
		repeat (300) @(negedge clk);   // > the 255-cycle TTL
		cpu_cycle(32'hFC000022, 1, 1, 1, 0, 1, rd, cl);
		check(cl && rd == 16'h6364, "cache: post-TTL read fetches fresh");
		nrd1 = dd.rd_count;
		cpu_cycle(32'hFCC20024, 1, 1, 1, 0, 1, rd, cl);
		check(cl && rd == 16'h6566, "cache: $C2 alias read of the same u64 hits");
		check(dd.rd_count == nrd1, "cache: the alias hit issued NO DDR3 read");

		// ── declaration ROM (byteLanes $D2: lane-1 x4 expansion) ─────────
		dd.poke64(W_ROM,           64'hC000_0081_0C00_0001);   // raw bytes 0..7
		dd.poke64(W_ROM + 15'h0FFF, 64'hD200_C72B_935A_0101);  // raw $7FF8..$7FFF
		cpu_cycle(32'hFCFE0000, 1, 1, 1, 0, 1, rd, cl);
		check(cl && rd == 16'h0001, "ROM word 0 = {$00, raw[0]}");
		cpu_cycle(32'hFCFE0002, 1, 1, 1, 0, 1, rd, cl);
		check(cl && rd == 16'h0000, "ROM word at 4k+2 is $0000");
		cpu_cycle(32'hFCFE0010, 1, 1, 1, 0, 1, rd, cl);
		check(cl && rd == 16'h0081, "raw[4] appears at guest +$10");
		cpu_cycle(32'hFCFE0000, 1, 0, 1, 0, 1, rd, cl);
		check(cl && rd[7:0] == 8'h01, "ROM LDS byte read serves raw[0] at 4k+1");
		cpu_cycle(32'hFCFFFFFC, 1, 1, 1, 0, 1, rd, cl);
		check(cl && rd == 16'h00D2, "byteLanes byte $D2 reads at $FFFFFC/+1");
		cpu_cycle(32'hFCFFFFF4, 1, 1, 1, 0, 1, rd, cl);
		check(cl && rd == 16'h00C7, "testPattern tail byte reads through the lane map");
		cpu_cycle(32'hFCFDFFFC, 1, 1, 1, 0, 0, rd, cl);
		check(!cl, "below the ROM window is not claimed");

		// ── other unclaimed decodes ──────────────────────────────────────
		cpu_cycle(32'hFC0C0100, 1, 1, 1, 0, 0, rd, cl);
		check(!cl, "$0C0100 (past the register window) is not claimed");
		cpu_cycle(32'hC0000000, 1, 1, 1, 0, 0, rd, cl);
		check(!cl, "super-slot space is not claimed (standard slot only)");
		cpu_cycle(32'hFD000000, 1, 1, 1, 0, 0, rd, cl);
		check(!cl, "slot $D is not claimed");

		// ── INT -> irq, ISR clear-mask + suppression ─────────────────────
		dd.poke64(W_SHAD + 15'd1, 64'h0000_0000_0400_0000);   // ISR = PKTRX
		dd.poke64(W_INT, 64'd1);
		repeat (25000) @(negedge clk);
		check(irq == 1'b1, "INT word raises irq");
		cpu_cycle(32'hFC0C000A, 1, 1, 1, 0, 1, rd, cl);
		check(cl && rd == 16'h0400, "ISR reads the shadow before the ack");
		cpu_cycle(32'hFC0C000A, 0, 1, 1, 16'h0400, 1, rd, cl);
		check(cl, "ISR ack write completes");
		cpu_cycle(32'hFC0C000A, 1, 1, 1, 0, 1, rd, cl);
		check(cl && rd == 16'h0000, "acked ISR bit reads back clear immediately");
		check(irq == 1'b0, "irq drops for the suppression window");
		repeat (62000) @(negedge clk);      // one IRQ_SUPP round trip
		check(irq == 1'b1, "irq returns after the window (INT still set)");
		cpu_cycle(32'hFC0C000A, 1, 1, 1, 0, 1, rd, cl);
		check(cl && rd == 16'h0400, "expired mask serves the raw shadow again");
		dd.poke64(W_INT, 64'd0);
		repeat (25000) @(negedge clk);
		check(irq == 1'b0, "INT word clear drops irq");

		// ── warm guest reset posts TAG_RESET ─────────────────────────────
		wp0 = dd.peek64(W_WPTR);
		rst_guest = 1;
		repeat (300) @(negedge clk);
		rst_guest = 0;
		repeat (300) @(negedge clk);
		check(dd.peek64(W_WPTR) == wp0 + 1, "warm reset posts one doorbell");
		e = dd.peek64(W_RING + (wp0[7:0] & 8'hFF));
		check(e[0] && e[3:1] == 3'd1, "the doorbell is TAG_RESET");

		// ── ring backpressure: saturating wait force-publishes ───────────
		wp0 = dd.peek64(W_WPTR);
		dd.poke64(W_RPTR, wp0 - 32'd250);
		repeat (25000) @(negedge clk);      // rptr_sh refresh
		cpu_cycle_slow(32'hFC0C0000, 0, 16'h0022, 150000, rd, cl);
		check(cl && dd.peek64(W_WPTR) == wp0 + 1,
		      "backpressured write force-publishes after the saturating wait");
		dd.poke64(W_RPTR, dd.peek64(W_WPTR));
		repeat (25000) @(negedge clk);

		// ── watchdog: a dead DDR3 retires the cycle open-bus ─────────────
		dd.stall = 1'b1;
		cpu_cycle_slow(32'hFC000000, 1, 0, 200000, rd, cl);
		check(cl && rd == 16'hFFFF, "stalled RAM read retires open-bus via the watchdog");
		dd.stall = 1'b0;
		repeat (200) @(negedge clk);        // drain the abandoned read
		cpu_cycle(32'hFC000000, 1, 1, 1, 0, 1, rd, cl);
		check(cl && rd == 16'hCCDD, "card recovers after the stall");

		// ── presence latch vs MAGIC / OSD ────────────────────────────────
		dd.poke64(W_MAGIC, 64'd0);
		repeat (75000) @(negedge clk);      // poll notices, magic_ok falls
		cpu_cycle(32'hFC000000, 1, 1, 1, 0, 1, rd, cl);
		check(cl, "host death does not drop a latched presence");
		rst_guest = 1;
		repeat (300) @(negedge clk);
		rst_guest = 0;
		repeat (20) @(negedge clk);
		cpu_cycle(32'hFC000000, 1, 1, 1, 0, 1, rd, cl);
		check(cl, "a reset with MAGIC absent keeps the card (host purge owns un-arming)");
		dd.poke64(W_MAGIC, MAGIC);
		// the interrupted walk drains at the absent cadence before MAGIC is
		// re-sampled: up to 20 x 65536 cycles
		repeat (1500000) @(negedge clk);
		ena_osd = 0;
		rst_guest = 1;
		repeat (300) @(negedge clk);
		rst_guest = 0;
		repeat (20) @(negedge clk);
		cpu_cycle(32'hFC000000, 1, 1, 1, 0, 0, rd, cl);
		check(!cl, "OSD off at reset keeps the card away");
		ena_osd = 1;
		rst_guest = 1;
		repeat (300) @(negedge clk);
		rst_guest = 0;
		repeat (20) @(negedge clk);
		cpu_cycle(32'hFC000000, 1, 1, 1, 0, 1, rd, cl);
		check(cl, "OSD on + MAGIC re-arms on the next reset");

		if (fails == 0) $display("ALL PASS (tb_enetnbtp)");
		else            $display("%0d FAILED", fails);
		$finish;
	end

endmodule
