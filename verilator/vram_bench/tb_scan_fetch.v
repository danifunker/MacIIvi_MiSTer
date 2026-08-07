// tb_scan_fetch.v — standalone check of mdc_scan_fetch + sim_ram's video
// port twin: word order, unaligned bases, mid-line abort (seq tagging), and
// CPU-port contention stalls. Fast evidence for Option A's plumbing without
// a full boot.
`timescale 1ns/1ns

module tb_scan_fetch;
    reg clk = 0;
    always #15 clk = ~clk;

    reg reset = 1;

    // sim_ram cpu port (used only to model contention)
    reg  [25:0] addr = 0;
    reg  [15:0] din = 0;
    reg  [1:0]  ds = 2'b00;
    reg         oe = 0, we = 0;
    wire [15:0] dout;

    // video port
    wire        vid_rd;
    wire [25:0] vid_addr;
    wire        vid_seq;
    wire [15:0] vid_data;
    wire        vid_dseq, vid_tog;

    sim_ram ram (
        .clk(clk), .reset(reset),
        .din(din), .dout(dout), .addr(addr), .ds(ds), .oe(oe), .we(we),
        .module_sz(2'd3), .frame_count(32'd0),
        .vid_rd(vid_rd), .vid_addr(vid_addr), .vid_seq(vid_seq),
        .vid_data(vid_data), .vid_dseq(vid_dseq), .vid_tog(vid_tog)
    );

    // fetch client under test
    reg         start = 0;
    reg  [19:0] base_word = 0;
    reg  [9:0]  words = 0;
    wire        wvalid;
    wire [15:0] wdata;

    mdc_scan_fetch #(.SDRAM_BASE(26'h0100000)) dut (
        .clk(clk), .reset(reset),
        .start(start), .base_word(base_word), .words(words),
        .wvalid(wvalid), .wdata(wdata),
        .vid_rd(vid_rd), .vid_addr(vid_addr), .vid_seq(vid_seq),
        .vid_data(vid_data), .vid_dseq(vid_dseq), .vid_tog(vid_tog)
    );

    // collect stream
    reg [15:0] got [0:1023];
    integer got_n = 0;
    always @(posedge clk) if (wvalid) begin
        got[got_n] = wdata;
        got_n = got_n + 1;
    end

    integer i, errors = 0;

    task run_fetch(input [19:0] base, input [9:0] n);
        integer timeout;
        begin
            @(negedge clk);
            base_word = base; words = n; start = 1;
            @(negedge clk);
            // start latched at the posedge just passed: the DUT suppresses any
            // same-edge stale delivery, so clearing the collector HERE is
            // race-free (clearing before start latches collects the old
            // stream's final in-flight words as bogus word 0)
            start = 0; got_n = 0;
            timeout = 0;
            while (got_n < n && timeout < 20000) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (got_n != n) begin
                $display("FAIL: base=%h n=%0d got only %0d words", base, n, got_n);
                errors = errors + 1;
            end else begin
                for (i = 0; i < n; i = i + 1)
                    if (got[i] !== (16'hA000 + base[15:0] + i[15:0])) begin
                        $display("FAIL: base=%h word %0d = %h expected %h",
                                 base, i, got[i], 16'hA000 + base[15:0] + i[15:0]);
                        errors = errors + 1;
                    end
            end
        end
    endtask

    integer k;
    initial begin
        // fill the VRAM window with an address-derived pattern
        for (k = 0; k < 20000; k = k + 1)
            ram.mem[26'h0100000 + k] = 16'hA000 + k[15:0];

        repeat (6) @(negedge clk);
        reset = 0;
        repeat (4) @(negedge clk);

        // 1) aligned line (320 words, the 8bpp/640 case)
        run_fetch(20'd0, 10'd320);
        // 2) unaligned bases (stride 2-word cases)
        run_fetch(20'd2, 10'd320);
        run_fetch(20'd1, 10'd7);
        run_fetch(20'd3, 10'd5);
        // 3) abort mid-line: start a long fetch, restart quickly, verify the
        //    new line arrives clean (stale-tag words must be dropped)
        got_n = 0;
        @(negedge clk);
        base_word = 20'd100; words = 10'd300; start = 1;
        @(negedge clk); start = 0;
        repeat (37) @(negedge clk);   // let ~15-20 words flow
        run_fetch(20'd500, 10'd320);  // restart onto a new line

        // 4) contention: fetch while the cpu port hammers oe
        @(negedge clk);
        base_word = 20'd900; words = 10'd256; start = 1;
        @(negedge clk); start = 0; got_n = 0;
        for (k = 0; k < 3000 && got_n < 256; k = k + 1) begin
            oe = (k[2:0] < 5);   // cpu busy 5 of 8 cycles
            @(negedge clk);
        end
        oe = 0;
        if (got_n != 256) begin
            $display("FAIL: contention fetch got %0d/256", got_n);
            errors = errors + 1;
        end else begin
            for (i = 0; i < 256; i = i + 1)
                if (got[i] !== (16'hA000 + 900 + i[15:0])) begin
                    $display("FAIL: contention word %0d = %h", i, got[i]);
                    errors = errors + 1;
                end
        end

        if (errors == 0) $display("PASS: all scan-fetch cases clean");
        else             $display("FAILED: %0d errors", errors);
        $finish;
    end
endmodule
