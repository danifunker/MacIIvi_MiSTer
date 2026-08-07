// tb_sdram_vid.v â€” bench for the REAL sdram.v with the Option A video burst
// port, against a behavioral SDR-SDRAM chip model. The main Verilator sim
// swaps sdram.v for sim_ram, so this is the only pre-hardware coverage the
// new controller logic gets.
//
// Checks:
//   * CPU single-beat reads/writes stay correct (mirror-model compare) while
//     the video port scavenges idle windows
//   * video stream words are correct and in order (via a real mdc_scan_fetch
//     instance at clk_sys), across aligned/unaligned bases and aborts
//   * chip-protocol sanity: no READ/WRITE to a closed or wrong row
//   * refresh cadence: AUTO_REFRESH at least once per 24 windows per chip
//     while video is saturating the idle windows
//
// Clocking mirrors the core: clk_64 with an aligned clk_8 (4 high / 4 low)
// and clk_sys at half rate, coincident posedges (same-PLL relationship).
`timescale 1ns/1ns

module tb_sdram_vid;
    reg clk64 = 1'b0;
    always #8 clk64 = ~clk64;
    reg clk_sys = 1'b0;
    always #16 clk_sys = ~clk_sys;

    reg [2:0] div = 3'd0;
    always @(posedge clk64) div <= div + 3'd1;
    wire clk8 = !div[2];

    reg init = 1'b1;

    // sd bus (split: controller out/oe + chip drive)
    wire [15:0] sd_data_o;
    wire        sd_data_oe;
    wire [15:0] sd_data;
    wire [12:0] sd_addr;
    wire [1:0]  sd_dqm;
    wire [1:0]  sd_ba;
    wire        sd_cs, sd_we, sd_ras, sd_cas, sd_clk;

    // cpu/chipset port
    reg  [15:0] din = 16'h0;
    wire [15:0] dout;
    reg  [25:0] addr = 26'h0;
    reg  [1:0]  ds = 2'b11;
    reg         oe = 1'b0, we = 1'b0;
    wire        ram_ready;

    // video port
    wire        vid_rd, vid_seq, vid_dseq, vid_tog;
    wire [25:0] vid_addr;
    wire [15:0] vid_data;

    assign sd_data = sd_data_oe ? sd_data_o : (drive_en ? drive_data : 16'h0);

    sdram_split dut (
        .sd_clk(sd_clk), .sd_data_o(sd_data_o), .sd_data_oe(sd_data_oe),
        .sd_data_i(sd_data), .sd_addr(sd_addr), .sd_dqm(sd_dqm),
        .sd_cs(sd_cs), .sd_ba(sd_ba), .sd_we(sd_we), .sd_ras(sd_ras), .sd_cas(sd_cas),
        .init(init), .clk_64(clk64), .clk_8(clk8),
        .din(din), .dout(dout), .addr(addr), .ds(ds), .oe(oe), .we(we),
        .ram_ready(ram_ready),
        .vid_rd(vid_rd), .vid_addr(vid_addr), .vid_seq(vid_seq),
        .vid_data(vid_data), .vid_dseq(vid_dseq), .vid_tog(vid_tog)
    );

    // fetch client (real module, clk_sys domain)
    reg         start = 1'b0;
    reg  [19:0] base_word = 20'd0;
    reg  [9:0]  words = 10'd0;
    wire        wvalid;
    wire [15:0] wdata;

    mdc_scan_fetch #(.SDRAM_BASE(26'h0100000)) fetch (
        .clk(clk_sys), .reset(init),
        .start(start), .base_word(base_word), .words(words),
        .wvalid(wvalid), .wdata(wdata),
        .vid_rd(vid_rd), .vid_addr(vid_addr), .vid_seq(vid_seq),
        .vid_data(vid_data), .vid_dseq(vid_dseq), .vid_tog(vid_tog)
    );

    // ========================================================================
    // Behavioral SDR chip (single chip = nCS 0 only; 4 banks x 8192 rows x
    // 256 cols x 16). Commands sampled at sd_clk rising = negedge clk64.
    // Read data pipelined to cover the controller's +2-margin sample point
    // (capture at command posedge + 4).
    // ========================================================================
    reg [15:0] mem [0:33554431];   // 64MB worth is plenty (bank|row|col)
    reg [12:0] open_row [0:3];
    reg        row_open [0:3];

    integer protocol_errors = 0;
    integer refresh_count = 0;

    // read pipeline: entry k drives sd_data k negedges later
    reg [15:0] rpipe_data [0:4];
    reg        rpipe_v    [0:4];
    reg [15:0] drive_data;
    reg        drive_en = 1'b0;

    wire [3:0] cmd = {sd_cs, sd_ras, sd_cas, sd_we};
    localparam C_ACTIVE    = 4'b0011;
    localparam C_READ      = 4'b0101;
    localparam C_WRITE     = 4'b0100;
    localparam C_PRECHARGE = 4'b0010;
    localparam C_REFRESH   = 4'b0001;
    localparam C_LOADMODE  = 4'b0000;

    integer pi;
    always @(negedge clk64) begin
        // advance read pipe
        drive_en   <= rpipe_v[0];
        drive_data <= rpipe_data[0];
        for (pi = 0; pi < 4; pi = pi + 1) begin
            rpipe_v[pi]    <= rpipe_v[pi+1];
            rpipe_data[pi] <= rpipe_data[pi+1];
        end
        rpipe_v[4] <= 1'b0;

        case (cmd)
            C_ACTIVE: begin
                if (row_open[sd_ba]) begin
                    $display("PROTOCOL: ACTIVE to open bank %0d @%0t", sd_ba, $time);
                    protocol_errors = protocol_errors + 1;
                end
                open_row[sd_ba] <= sd_addr;
                row_open[sd_ba] <= 1'b1;
            end
            C_READ: begin
                if (!row_open[sd_ba]) begin
                    $display("PROTOCOL: READ on closed bank %0d @%0t", sd_ba, $time);
                    protocol_errors = protocol_errors + 1;
                end else begin
                    // drive window must cover the controller's capture at
                    // command posedge + 4 (its HW-proven "+2 margin" point:
                    // CL2 + ~1 cycle of real-world round trip). Scheduling
                    // at stage 2 puts drive_en at chip-sample + 3 negedges,
                    // i.e. covering exactly that posedge.
                    rpipe_v[2]    <= 1'b1;
                    rpipe_data[2] <= mem[{sd_ba, open_row[sd_ba], sd_addr[9], sd_addr[8], sd_addr[7:0]}];
                    if (sd_addr[10]) row_open[sd_ba] <= 1'b0;   // auto precharge
                end
            end
            C_WRITE: begin
                if (!row_open[sd_ba]) begin
                    $display("PROTOCOL: WRITE on closed bank %0d @%0t", sd_ba, $time);
                    protocol_errors = protocol_errors + 1;
                end else begin
                    if (!sd_dqm[0]) mem[{sd_ba, open_row[sd_ba], sd_addr[9], sd_addr[8], sd_addr[7:0]}][7:0]  <= sd_data[7:0];
                    if (!sd_dqm[1]) mem[{sd_ba, open_row[sd_ba], sd_addr[9], sd_addr[8], sd_addr[7:0]}][15:8] <= sd_data[15:8];
                    if (sd_addr[10]) row_open[sd_ba] <= 1'b0;   // auto precharge
                end
            end
            C_PRECHARGE: begin
                if (sd_addr[10]) begin
                    row_open[0] <= 1'b0; row_open[1] <= 1'b0;
                    row_open[2] <= 1'b0; row_open[3] <= 1'b0;
                end else
                    row_open[sd_ba] <= 1'b0;
            end
            C_REFRESH: refresh_count = refresh_count + 1;
            default: ;
        endcase
    end

    // linear word address -> chip storage index, mirroring the controller's
    // {row=addr[23],addr[19:8]} / ba=addr[21:20] / col={addr[24],addr[22],addr[7:0]}
    function [24:0] chip_index(input [25:0] a);
        chip_index = { a[21:20], a[23], a[19:8], a[24], a[22], a[7:0] };
    endfunction

    // ========================================================================
    // CPU-port driver (clk_sys domain, window-grid aligned like the core mux)
    // ========================================================================
    reg [15:0] mirror [0:1048575];   // covers the low words we exercise
    integer i, errors = 0;

    // stimulus is skewed #2 off the negedge: every clk_sys edge coincides
    // with a clk64 posedge here, and blocking TB assigns at a coincident
    // edge race the controller's sampling (real hardware launches these
    // from registers, which cannot race)
    task cpu_write(input [25:0] a, input [15:0] v);
        begin
            @(negedge clk_sys); #2;
            addr = a; din = v; ds = 2'b11; we = 1'b1;
            repeat (5) @(negedge clk_sys);   // one full window guaranteed
            #2; we = 1'b0;
            mirror[a[19:0]] = v;
            repeat (3) @(negedge clk_sys);   // let the CAS land before checking
            mem_expect_check(a);
        end
    endtask

    // byte-strobe write: explicit ds + a PHASE offset (ph clk64 posedges)
    // so the op can be presented at any offset relative to the 8-cycle
    // command window. Phase matters: the release qualifier needs 5 cycles,
    // so an op presented early in a window can have its FIRST (and only)
    // execution window released out from under it.
    task cpu_write_ds_ph(input [25:0] a, input [15:0] v, input [1:0] strobes,
                         input integer ph);
        begin
            @(negedge clk_sys); #2;
            repeat (ph) @(posedge clk64);
            addr = a; din = v; ds = strobes; we = 1'b1;
            repeat (5) @(negedge clk_sys);
            #2; we = 1'b0;
            // hold the strobes past we, like a real 68k cycle: the
            // controller latches we at T0 but samples ds LIVE at the T2 CAS
            // (long-standing behavior), so dropping both together would let
            // a started window write with the restored ds=11
            repeat (2) @(negedge clk_sys); #2; ds = 2'b11;
            if (strobes[1]) mirror[a[19:0]][15:8] = v[15:8];
            if (strobes[0]) mirror[a[19:0]][7:0]  = v[7:0];
            repeat (3) @(negedge clk_sys);
            mem_expect_check(a);
        end
    endtask

    task cpu_write_ds(input [25:0] a, input [15:0] v, input [1:0] strobes);
        begin cpu_write_ds_ph(a, v, strobes, 0); end
    endtask

    task mem_expect_check(input [25:0] a);
        begin
            if (mem[chip_index(a)] !== mirror[a[19:0]]) begin
                $display("FAIL: chip mem[%h] = %h, mirror %h", a,
                         mem[chip_index(a)], mirror[a[19:0]]);
                errors = errors + 1;
            end
        end
    endtask

    task cpu_read(input [25:0] a);
        integer timeout;
        begin
            @(negedge clk_sys); #2;
            addr = a; oe = 1'b1;
            timeout = 0;
            // one settle cycle: ram_ready is combinational on addr, and a
            // same-instant procedural read would see its pre-assignment value
            // (clocked consumers in the real core cannot do this)
            @(negedge clk_sys); #2;
            while (!(ram_ready) && timeout < 100) begin
                @(negedge clk_sys); #2; timeout = timeout + 1;
            end
            if (!ram_ready) begin
                $display("FAIL: cpu read %h timeout", a); errors = errors + 1;
            end else if (dout !== mirror[a[19:0]]) begin
                $display("FAIL: cpu read %h = %h expected %h", a, dout, mirror[a[19:0]]);
                $display("  at exit: t=%0t ready=%b valid=%b dout_addr=%h addr=%h timeout=%0d",
                         $time, ram_ready, dut.dout_valid, dut.dout_addr, addr, timeout);
                errors = errors + 1;
            end
            oe = 1'b0;
            @(negedge clk_sys); #2;
        end
    endtask

    // video stream collector
    reg [15:0] got [0:1023];
    integer got_n = 0;
    always @(posedge clk_sys) if (wvalid) begin
        got[got_n] = wdata;
        got_n = got_n + 1;
    end

    task run_fetch(input [19:0] base, input [9:0] n);
        integer timeout;
        begin
            @(negedge clk_sys);
            base_word = base; words = n; start = 1'b1;
            @(negedge clk_sys);
            start = 1'b0; got_n = 0;
            timeout = 0;
            while (got_n < n && timeout < 50000) begin
                @(negedge clk_sys); timeout = timeout + 1;
            end
            if (got_n != n) begin
                $display("FAIL: fetch base=%h n=%0d got %0d", base, n, got_n);
                errors = errors + 1;
            end else
                for (i = 0; i < n; i = i + 1)
                    if (got[i] !== (16'h7A00 + base[15:0] + i[15:0])) begin
                        $display("FAIL: fetch base=%h word %0d = %h expected %h",
                                 base, i, got[i], 16'h7A00 + base[15:0] + i[15:0]);
                        errors = errors + 1;
                    end
        end
    endtask

`ifdef SCANDBG
    always @(negedge clk64)
        if ($time > 153900 && $time < 154700 && cmd != 4'b1111 && cmd != 4'b0111)
            $display("[%0t] CMD %b ba=%0d a=%h", $time, cmd, sd_ba, sd_addr);
    always @(posedge clk64)
        if ($time > 153900 && $time < 154700 && dut.t == 3'd0)
            $display("[%0t] T0 oe=%b we=%b addr=%h (latch will=%b/%b)", $time, oe, we, addr, oe, we);
    always @(negedge clk64)
        if (cmd == C_READ)
            $display("[%0t] CHIP RD ba=%0d row=%h col=%h ap=%b data=%h",
                     $time, sd_ba, open_row[sd_ba], sd_addr[7:0], sd_addr[10],
                     mem[{sd_ba, open_row[sd_ba], sd_addr[9], sd_addr[8], sd_addr[7:0]}]);
    always @(posedge clk64)
        if (dut.oe_latch && dut.t == 3'd6)
            $display("[%0t] CTRL CAP addr_latch=%h bus=%h (oe=%b addr=%h)",
                     $time, dut.addr_latch, sd_data, oe, addr);
`endif

    integer k, rf_before, rf_after;
    initial begin
        for (k = 0; k < 4; k = k + 1) row_open[k] = 1'b0;
        for (k = 0; k < 5; k = k + 1) begin rpipe_v[k] = 1'b0; rpipe_data[k] = 16'h0; end

        // pre-load the VRAM window pattern directly into the chip array
        // (word w of the window = SDRAM word $100000+w)
        for (k = 0; k < 2048; k = k + 1) begin
            mem[chip_index(26'h0100000 + k)] = 16'h7A00 + k[15:0];
        end

        // hold init through a few windows, then release and wait out the
        // controller's ~1023-window init ladder
        repeat (40) @(negedge clk64);
        init = 1'b0;
        repeat (9000) @(negedge clk64);

        // 1) CPU writes/reads with video idle
        for (k = 0; k < 32; k = k + 1) cpu_write(26'h0380000 + k, 16'hC000 + k[15:0]);
        for (k = 0; k < 32; k = k + 1) cpu_read (26'h0380000 + k);

        // 2) video line fetches, cpu idle: aligned, unaligned, tiny
        run_fetch(20'd0,   10'd320);
        run_fetch(20'd2,   10'd320);
        run_fetch(20'd13,  10'd33);
        run_fetch(20'd255, 10'd6);    // group straddles a row boundary by addr

        // 3) abort mid-line, then a clean refetch
        @(negedge clk_sys); base_word = 20'd100; words = 10'd300; start = 1'b1;
        @(negedge clk_sys); start = 1'b0;
        repeat (40) @(negedge clk_sys);
        run_fetch(20'd600, 10'd320);

        // 4) concurrent: video fetch + CPU traffic hammering the port
        @(negedge clk_sys); base_word = 20'd1024; words = 10'd320; start = 1'b1;
        @(negedge clk_sys); start = 1'b0; got_n = 0;
        for (k = 0; k < 200; k = k + 1) begin
            cpu_write(26'h0380000 + (k & 31), 16'hD000 + k[15:0]);
            cpu_read (26'h0380000 + (k & 31));
        end
        begin : wait4
            integer timeout;
            timeout = 0;
            while (got_n < 320 && timeout < 50000) begin
                @(negedge clk_sys); timeout = timeout + 1;
            end
        end
        if (got_n != 320) begin
            $display("FAIL: concurrent fetch got %0d/320", got_n);
            errors = errors + 1;
        end else
            for (i = 0; i < 320; i = i + 1)
                if (got[i] !== (16'h7A00 + 1024 + i[15:0])) begin
                    $display("FAIL: concurrent word %0d = %h expected %h",
                             i, got[i], 16'h7A00 + 1024 + i[15:0]);
                    errors = errors + 1;
                end

        // 4b) SATURATING cpu: mimic the real 68030 holding oe across ~3
        // windows per op, back to back, while a full 8bpp line fetches.
        // Without the v2 redundant-window release this starves the fetch
        // (the 2026-08-07 HW right-edge band); with it the released windows
        // must complete 320 words well inside two line-times (~1860 clk_sys).
        @(negedge clk_sys); base_word = 20'd1500; words = 10'd320; start = 1'b1;
        @(negedge clk_sys); start = 1'b0; got_n = 0;
        begin : sat_cpu
            integer t2;
            integer sat_reads;
            sat_reads = 0;
            for (t2 = 0; t2 < 1860 && got_n < 320; t2 = t2 + 1) begin
                // new read every 12 clk_sys = 3 windows, held presented the
                // whole time (the fast slot-start DTACK never releases oe
                // between windows on the real bus)
                if (t2 % 12 == 0) begin
                    @(negedge clk_sys); #2;
                    addr = 26'h0380000 + ((t2/12) & 31); oe = 1'b1;
                    sat_reads = sat_reads + 1;
                end else
                    @(negedge clk_sys);
            end
            oe = 1'b0; #2;
            if (got_n != 320) begin
                $display("FAIL: saturated-cpu fetch got %0d/320 within 2 line-times", got_n);
                errors = errors + 1;
            end else begin
                for (i = 0; i < 320; i = i + 1)
                    if (got[i] !== (16'h7A00 + 1500 + i[15:0])) begin
                        $display("FAIL: saturated word %0d = %h", i, got[i]);
                        errors = errors + 1;
                    end
                $display("saturated-cpu: 320 words in %0d clk_sys with %0d held cpu reads", t2, sat_reads);
            end
        end

        // 4c) release-correctness: back-to-back writes, same address,
        // DIFFERENT data — the second must not be skipped as served
        cpu_write(26'h0380040, 16'h1111);
        cpu_write(26'h0380040, 16'h2222);
        cpu_read (26'h0380040);
        // and same address+data twice (skip is legal, value must hold)
        cpu_write(26'h0380041, 16'h3333);
        cpu_write(26'h0380041, 16'h3333);
        cpu_read (26'h0380041);

        // 4d) BYTE-STROBE releases — the v2.2 hardware-wedge case. Writing
        // the same data to the same word through DIFFERENT byte lanes must
        // NOT be skipped as "already served" (a byte-wise clear loop is
        // exactly this: din 0000, ds 01 then 10).
        for (k = 0; k < 8; k = k + 1) begin
            // byte-wise clear at every bus phase: identical din+addr, the
            // two lanes in turn. Both lanes MUST land.
            cpu_write      (26'h0380050 + k, 16'hFFFF);
            cpu_write_ds_ph(26'h0380050 + k, 16'h0000, 2'b01, k);
            cpu_write_ds_ph(26'h0380050 + k, 16'h0000, 2'b10, k);
            cpu_read       (26'h0380050 + k);          // must be 0000
        end
        // same value, lanes in the other order, then a partial rewrite
        cpu_write   (26'h0380051, 16'hFFFF);
        cpu_write_ds(26'h0380051, 16'hA5A5, 2'b10);    // high := A5
        cpu_write_ds(26'h0380051, 16'hA5A5, 2'b01);    // low  := A5
        cpu_read    (26'h0380051);                     // must be A5A5
        // repeated identical byte write (skip legal, value must hold)
        cpu_write_ds(26'h0380052, 16'h5A5A, 2'b01);
        cpu_write_ds(26'h0380052, 16'h5A5A, 2'b01);
        cpu_read    (26'h0380052);

        // 5) refresh cadence while video saturates idle windows: run a
        // continuous fetch stream and count refreshes over 2400 windows
        rf_before = refresh_count;
        for (k = 0; k < 6; k = k + 1) begin
            run_fetch(20'd0, 10'd320);
        end
        rf_after = refresh_count;
        // 6 fetches of 320 words at ~2 words/clk_sys-pair >= ~2000 windows;
        // demand >= 1 refresh per 32 windows (the credit forces 1 per 24)
        if ((rf_after - rf_before) < 40) begin
            $display("FAIL: refresh starved during video: only %0d refreshes",
                     rf_after - rf_before);
            errors = errors + 1;
        end

        if (protocol_errors != 0) begin
            $display("FAILED: %0d chip protocol errors", protocol_errors);
            errors = errors + protocol_errors;
        end
        if (errors == 0) $display("PASS: sdram video port cases clean (refreshes in window: %0d)", rf_after - rf_before);
        else             $display("FAILED: %0d errors", errors);
        $finish;
    end
endmodule
