// tb_vram_ddr.v — standalone check of the Option B chain:
// mdc_scan_fetch -> mdc_vram_ddr -> sim_ddram, plus the ext_* CPU ops.
// Verifies 64-bit lane packing, byte enables, scan word order across beat
// boundaries, unaligned bases, abort tagging, and ext preemption mid-scan.
`timescale 1ns/1ns

module tb_vram_ddr;
    reg clk = 0;
    always #15 clk = ~clk;
    reg reset = 1;

    // DDR channel
    wire        ddr_busy, ddr_rd, ddr_we, ddr_dout_ready;
    wire [7:0]  ddr_burstcnt, ddr_be;
    wire [28:0] ddr_addr;
    wire [63:0] ddr_din, ddr_dout;

    sim_ddram ddr (
        .clk(clk), .reset(reset),
        .addr(ddr_addr), .burstcnt(ddr_burstcnt), .din(ddr_din), .be(ddr_be),
        .rd(ddr_rd), .we(ddr_we), .busy(ddr_busy),
        .dout(ddr_dout), .dout_ready(ddr_dout_ready)
    );

    // scan client chain
    wire        vid_rd, vid_seq, vid_dseq, vid_tog, vid_pair;
    wire [25:0] vid_addr;
    wire [15:0] vid_data, vid_data2;

    reg         start = 0;
    reg  [19:0] base_word = 0;
    reg  [9:0]  words = 0;
    wire        wvalid, wvalid2;
    wire [15:0] wdata, wdata2;

    mdc_scan_fetch #(.SDRAM_BASE(26'h0100000)) fetch (
        .clk(clk), .reset(reset),
        .start(start), .base_word(base_word), .words(words),
        .wvalid(wvalid), .wdata(wdata), .wvalid2(wvalid2), .wdata2(wdata2),
        .vid_rd(vid_rd), .vid_addr(vid_addr), .vid_seq(vid_seq),
        .vid_data(vid_data), .vid_dseq(vid_dseq), .vid_tog(vid_tog),
        .vid_pair(vid_pair), .vid_data2(vid_data2)
    );

    // ext port
    reg         ext_rd = 0, ext_wr = 0;
    reg  [19:0] ext_word = 0;
    reg  [15:0] ext_wdata = 0;
    reg  [1:0]  ext_ds = 2'b11;
    wire [15:0] ext_dout;
    wire        ext_ready;

    mdc_vram_ddr #(.DDR_BASE_QW(29'h06000000)) dut (
        .clk(clk), .reset(reset),
        .ddr_busy(ddr_busy), .ddr_burstcnt(ddr_burstcnt), .ddr_addr(ddr_addr),
        .ddr_dout(ddr_dout), .ddr_dout_ready(ddr_dout_ready),
        .ddr_rd(ddr_rd), .ddr_din(ddr_din), .ddr_be(ddr_be), .ddr_we(ddr_we),
        .vid_rd(vid_rd), .vid_addr(vid_addr), .vid_seq(vid_seq),
        .vid_data(vid_data), .vid_dseq(vid_dseq), .vid_tog(vid_tog),
        .vid_pair(vid_pair), .vid_data2(vid_data2),
        .ext_rd(ext_rd), .ext_wr(ext_wr), .ext_ds(ext_ds), .ext_word(ext_word),
        .ext_wdata(ext_wdata), .ext_dout(ext_dout), .ext_ready(ext_ready)
    );

    reg [15:0] got [0:1023];
    integer got_n = 0;
    always @(posedge clk) if (wvalid) begin
        got[got_n] = wdata;
        got_n = got_n + 1;
        if (wvalid2) begin
            got[got_n] = wdata2;
            got_n = got_n + 1;
        end
    end

    integer i, errors = 0;

    task ext_write(input [19:0] w, input [15:0] v);
        integer timeout;
        begin
            @(negedge clk); ext_word = w; ext_wdata = v; ext_wr = 1;
            timeout = 0;
            while (!ext_ready && timeout < 500) begin @(negedge clk); timeout = timeout + 1; end
            if (!ext_ready) begin $display("FAIL: ext write %h timeout", w); errors = errors + 1; end
            @(negedge clk); ext_wr = 0;
            @(negedge clk);
        end
    endtask

    task ext_write_ds(input [19:0] w, input [15:0] v, input [1:0] ds);
        begin
            ext_ds = ds;
            ext_write(w, v);
            ext_ds = 2'b11;
        end
    endtask

    task ext_read(input [19:0] w, input [15:0] expv);
        integer timeout;
        begin
            @(negedge clk); ext_word = w; ext_rd = 1;
            timeout = 0;
            while (!ext_ready && timeout < 500) begin @(negedge clk); timeout = timeout + 1; end
            if (!ext_ready) begin $display("FAIL: ext read %h timeout", w); errors = errors + 1; end
            else if (ext_dout !== expv) begin
                $display("FAIL: ext read %h = %h expected %h", w, ext_dout, expv);
                errors = errors + 1;
            end
            @(negedge clk); ext_rd = 0;
            @(negedge clk);
        end
    endtask

    integer last_fetch_clks;
    task run_fetch(input [19:0] base, input [9:0] n);
        integer timeout;
        begin
            @(negedge clk); base_word = base; words = n; start = 1;
            @(negedge clk); start = 0; got_n = 0;
            timeout = 0;
            while (got_n < n && timeout < 20000) begin @(negedge clk); timeout = timeout + 1; end
            last_fetch_clks = timeout;
            if (got_n != n) begin
                $display("FAIL: fetch base=%h n=%0d got %0d", base, n, got_n);
                errors = errors + 1;
            end else begin
                for (i = 0; i < n; i = i + 1)
                    if (got[i] !== (16'h5000 + base[15:0] + i[15:0])) begin
                        $display("FAIL: fetch base=%h word %0d = %h expected %h",
                                 base, i, got[i], 16'h5000 + base[15:0] + i[15:0]);
                        errors = errors + 1;
                    end
            end
        end
    endtask

    integer k;
    initial begin
        // pattern-fill the DDR model directly (word w = 0x5000+w packed 4/qw)
        for (k = 0; k < 5000; k = k + 1)
            ddr.mem[k] = { 16'(16'h5000 + k*4 + 3), 16'(16'h5000 + k*4 + 2),
                           16'(16'h5000 + k*4 + 1), 16'(16'h5000 + k*4) };

        repeat (6) @(negedge clk);
        reset = 0;
        repeat (4) @(negedge clk);

        // 1) ext write/read all four 16-bit lanes of a quadword
        ext_write(20'd4000, 16'hBEE0);
        ext_write(20'd4001, 16'hBEE1);
        ext_write(20'd4002, 16'hBEE2);
        ext_write(20'd4003, 16'hBEE3);
        ext_read (20'd4000, 16'hBEE0);
        ext_read (20'd4001, 16'hBEE1);
        ext_read (20'd4002, 16'hBEE2);
        ext_read (20'd4003, 16'hBEE3);
        // neighbors untouched by byte enables
        ext_read (20'd4004, 16'h5000 + 16'd4004);
        ext_read (20'd3999, 16'h5000 + 16'd3999);

        // 1b) byte-strobe writes (packed-aperture ops): each lane lands
        // independently, on every 16-bit lane of the quadword
        ext_write_ds(20'd4000, 16'hAB00, 2'b10);   // high byte only
        ext_read (20'd4000, 16'hABE0);
        ext_write_ds(20'd4000, 16'h00CD, 2'b01);   // low byte only
        ext_read (20'd4000, 16'hABCD);
        ext_write_ds(20'd4001, 16'h0011, 2'b01);
        ext_write_ds(20'd4002, 16'h2200, 2'b10);
        ext_write_ds(20'd4003, 16'h0033, 2'b01);
        ext_read (20'd4001, 16'hBE11);
        ext_read (20'd4002, 16'h22E2);
        ext_read (20'd4003, 16'hBE33);

        // 2) scan fetches: aligned + all misalignments, incl. cross-burst
        run_fetch(20'd0,  10'd320);
        run_fetch(20'd2,  10'd320);
        run_fetch(20'd13, 10'd33);
        run_fetch(20'd15, 10'd1);

        // 3) abort mid-line then clean refetch
        @(negedge clk); base_word = 20'd100; words = 10'd300; start = 1;
        @(negedge clk); start = 0;
        repeat (25) @(negedge clk);
        run_fetch(20'd600, 10'd320);

        // 4) ext op lands mid-scan (must preempt between bursts, both finish)
        @(negedge clk); base_word = 20'd1200; words = 10'd320; start = 1;
        @(negedge clk); start = 0; got_n = 0;
        repeat (10) @(negedge clk);
        ext_write(20'd4400, 16'hCAFE);
        ext_read (20'd4400, 16'hCAFE);
        begin : wait_scan
            integer timeout;
            timeout = 0;
            while (got_n < 320 && timeout < 20000) begin @(negedge clk); timeout = timeout + 1; end
        end
        if (got_n != 320) begin
            $display("FAIL: mid-scan ext: fetch got %0d/320", got_n);
            errors = errors + 1;
        end else begin
            for (i = 0; i < 320; i = i + 1)
                if (got[i] !== (16'h5000 + 1200 + i[15:0])) begin
                    $display("FAIL: mid-scan word %0d = %h", i, got[i]);
                    errors = errors + 1;
                end
        end

        // 5) 24bpp line-rate: 960 words must land inside a line time (~928
        //    card clks) with margin — the pair drain + 32-word bursts exist
        //    for exactly this
        run_fetch(20'd0, 10'd960);
        $display("rate: 960 words in ~%0d clks", last_fetch_clks);
        if (last_fetch_clks > 900) begin
            $display("FAIL: 24bpp line fetch too slow (%0d clks / 960 words)", last_fetch_clks);
            errors = errors + 1;
        end

        if (errors == 0) $display("PASS: all vram-ddr cases clean");
        else             $display("FAILED: %0d errors", errors);
        $finish;
    end
endmodule
