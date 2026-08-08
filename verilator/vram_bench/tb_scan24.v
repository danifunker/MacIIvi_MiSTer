// tb_scan24.v — 24bpp ("Millions") scanout gather check for
// nubus_video_mdc824 in its VRAM_WORDS==0 (line-buffer) configuration.
//
// The bench acts as the scan-fetch backend itself (stor[] + a streamer on
// scan_start), programs the card's registers over real NuBus cycles
// (ramdac mode 0xD, stride 240 = 1920 bytes/row via the direct <<3
// scaling), and checks the emitted vga_r/g/b stream against the packed
// 3-byte framebuffer. The check is run-detection — find a >=639-long
// consecutive ascending run of tagged pixels per tagged row — so it is
// robust to the pipeline's documented h==0 stale-column phase quirk.
// An 8bpp (mode 0xC) pass afterwards regression-checks the even/odd
// line-buffer split against the legacy byte path.
`timescale 1ns/1ns

module tb_scan24;
    reg clk = 0;
    always #15 clk = ~clk;
    reg reset = 1;

    // CPU / NuBus side
    reg  [31:0] addr = 0;
    reg  [15:0] data_in = 16'h0000;
    reg  [1:0]  uds_lds = 2'b00;
    reg         rw_n = 1;
    reg         cpu_as_n = 1;
    reg         select = 0;
    wire [15:0] data_out;
    wire        ack_n, nmrq_n;

    // scanline fetch port
    wire        scan_start;
    wire [19:0] scan_base;
    wire [9:0]  scan_words;
    reg         scan_wr = 0, scan_wr2 = 0;
    reg  [15:0] scan_wdata = 0, scan_wdata2 = 0;
    wire [15:0] underruns;

    wire [7:0] vga_r, vga_g, vga_b;

    nubus_video_mdc824 #(.SLOT_ID(4'hE), .VRAM_WORDS(0),
                         .TOTAL_WORDS(524288)) card (
        .clk(clk), .reset(reset),
        .addr(addr), .data_in(data_in), .uds_lds(uds_lds),
        .cpu_longword(1'b0), .rw_n(rw_n), .cpu_as_n(cpu_as_n),
        .select(select), .data_out(data_out), .ack_n(ack_n), .nmrq_n(nmrq_n),
        .vga_r(vga_r), .vga_g(vga_g), .vga_b(vga_b),
        .vga_hs(), .vga_vs(), .vga_blank(), .vga_clk(),
        .vram_addr(), .vram_dout(), .vram_din(16'h0000),
        .vram_rd(), .vram_wr(), .vram_ds(), .vram_ready(1'b1),
        .ext_rd(), .ext_wr(), .ext_ds(), .ext_din(16'h0000), .ext_ready(1'b1),
        .vram_scan_addr(), .vram_scan_rd(), .vram_scan_data(16'h0000),
        .scan_start(scan_start), .scan_base(scan_base), .scan_words(scan_words),
        .scan_wr(scan_wr), .scan_wdata(scan_wdata),
        .scan_wr2(scan_wr2), .scan_wdata2(scan_wdata2),
        .dbg_scan_underrun(underruns),
        .ioctl_wr(1'b0), .ioctl_addr(25'd0), .ioctl_data(16'd0),
        .ioctl_download(1'b0), .ioctl_index(8'd0),
        .overlay_en(1'b0), .monochrome(1'b0), .monitor_512(1'b0),
        .ce_pixel(),
        .dbg_video_en(), .dbg_vram_wr_cnt(), .dbg_vram_fetch_cnt(),
        .dbg_irq_cnt(), .dbg_ack_cnt(), .dbg_vblank_enable()
    );

    // ---- fetch backend: word storage + streamer -----------------------------
    reg [15:0] stor [0:524287];

    reg [19:0] f_base; reg [9:0] f_words, f_i; reg [4:0] f_delay;
    reg        f_busy = 0;
    always @(posedge clk) begin
        scan_wr <= 1'b0; scan_wr2 <= 1'b0;
        if (scan_start) begin
            f_base <= scan_base; f_words <= scan_words;
            f_i <= 0; f_delay <= 5'd20; f_busy <= 1;
        end else if (f_busy) begin
            if (f_delay != 0) f_delay <= f_delay - 5'd1;
            else begin
                scan_wr    <= 1'b1;
                scan_wdata <= stor[f_base + {10'd0, f_i}];
                if (f_i + 10'd1 != f_words) begin
                    // serve pairs like the DDR backend does
                    scan_wr2    <= 1'b1;
                    scan_wdata2 <= stor[f_base + {10'd0, f_i} + 20'd1];
                    f_i <= f_i + 10'd2;
                    if (f_i + 10'd2 == f_words) f_busy <= 0;
                end else begin
                    f_i <= f_i + 10'd1;
                    f_busy <= 0;
                end
            end
        end
    end

    // ---- NuBus register write (cribbed from mdc_bench) ----------------------
    integer timeout;
    task bus_write_q(input [31:0] a, input [15:0] v, input [1:0] strobes);
        begin
            @(negedge clk);
            addr = a; data_in = v; rw_n = 0; select = 1; cpu_as_n = 0;
            uds_lds = strobes;
            timeout = 0;
            @(negedge clk);
            while (ack_n !== 1'b0 && timeout < 200) begin
                @(negedge clk); timeout = timeout + 1;
            end
            @(negedge clk);
            cpu_as_n = 1; select = 0; uds_lds = 2'b00; rw_n = 1;
            repeat (2) @(negedge clk);
        end
    endtask

    // ---- byte-level storage fill helpers ------------------------------------
    task put_byte(input [20:0] ba, input [7:0] v);
        begin
            if (ba[0]) stor[ba[20:1]][7:0]  = v;
            else       stor[ba[20:1]][15:8] = v;
        end
    endtask

    // ---- sample collection ---------------------------------------------------
    // record every pixel tick's output; runs are detected offline
    reg [7:0] smp_r [0:600000];
    reg [7:0] smp_g [0:600000];
    reg [7:0] smp_b [0:600000];
    integer smp_n = 0;
    reg collecting = 0;
    always @(posedge clk)
        if (collecting && card.clk_video_en && smp_n < 600000) begin
            smp_r[smp_n] = vga_r; smp_g[smp_n] = vga_g; smp_b[smp_n] = vga_b;
            smp_n = smp_n + 1;
        end

    integer errors = 0;

    // longest consecutive ascending tagged run for one 24bpp row tag
    task check24_row(input [7:0] btag);
        integer i, run, best; reg [9:0] px;
        begin
            best = 0; run = 0; px = 0;
            for (i = 0; i < smp_n; i = i + 1) begin
                if (smp_b[i] === btag &&
                    (run == 0 ||
                     (smp_r[i] === ((px + 1) & 8'hFF) &&
                      smp_g[i] === (8'h40 | ((({22'd0, px} + 1) >> 8) & 3))))) begin
                    if (run == 0) begin
                        // anchor only on an exact x decode
                        px = {smp_g[i][1:0], smp_r[i]};
                        if ((8'h40 | {6'd0, px[9:8]}) === smp_g[i]) run = 1;
                    end else begin
                        px = px + 10'd1; run = run + 1;
                    end
                    if (run > best) best = run;
                end else if (smp_b[i] === btag) begin
                    px = {smp_g[i][1:0], smp_r[i]}; run = 1;
                end else
                    run = 0;
            end
            if (best < 639) begin
                $display("FAIL: 24bpp row tag %02x longest run %0d (< 639)", btag, best);
                errors = errors + 1;
            end
        end
    endtask

    integer x, y, k;
    reg [20:0] rowb;
    initial begin
        repeat (8) @(negedge clk);
        reset = 0;
        repeat (8) @(negedge clk);

        // ---- 24bpp frame: rows 0..3 tagged, packed 3 bytes/pixel ----------
        for (k = 0; k < 524288; k = k + 1) stor[k] = 16'h0000;
        for (y = 0; y < 4; y = y + 1) begin
            rowb = y * 1920;
            for (x = 0; x < 640; x = x + 1) begin
                put_byte(rowb + x*3 + 0, x[7:0]);
                put_byte(rowb + x*3 + 1, 8'h40 | {6'd0, x[9:8]});
                put_byte(rowb + x*3 + 2, 8'hA0 + y[7:0]);
            end
        end

        // program: ctrl $0006 (RGB+strap), stride 240 (<<3 = 1920), ramdac 0xD
        bus_write_q(32'hFE200000, 16'h0000, 2'b11);
        bus_write_q(32'hFE200002, 16'h0006, 2'b11);
        bus_write_q(32'hFE20000C, 16'h0000, 2'b11);
        bus_write_q(32'hFE20000E, 16'h00F0, 2'b11);
        bus_write_q(32'hFE20020A, 16'h001A, 2'b01);   // ramdac_ctrl <- $1A (mode D)

        // let one full frame settle (fill+scan rotations re-sync at line 0),
        // then collect a bit more than one frame of samples
        repeat (600000) @(negedge clk);
        smp_n = 0; collecting = 1;
        repeat (560000) @(negedge clk);
        collecting = 0;

        check24_row(8'hA0);
        check24_row(8'hA1);
        check24_row(8'hA2);
        check24_row(8'hA3);
        if (underruns !== 16'd0) begin
            $display("FAIL: 24bpp underruns = %0d", underruns);
            errors = errors + 1;
        end

        // ---- 8bpp regression through the split line buffer ----------------
        // row 5 = ascending indexes; default CLUT is the identity grayscale
        for (k = 0; k < 524288; k = k + 1) stor[k] = 16'h0000;
        for (x = 0; x < 640; x = x + 1)
            put_byte(21'd5*640 + x, x[7:0]);
        bus_write_q(32'hFE20000C, 16'h0000, 2'b11);
        bus_write_q(32'hFE20000E, 16'h00A0, 2'b11);   // stride 160 (<<2 = 640)
        bus_write_q(32'hFE20020A, 16'h0018, 2'b01);   // ramdac_ctrl <- $18 (mode C)

        repeat (600000) @(negedge clk);
        smp_n = 0; collecting = 1;
        repeat (560000) @(negedge clk);
        collecting = 0;

        begin : chk8
            integer i, run, best; reg [7:0] prev;
            best = 0; run = 0; prev = 0;
            for (i = 0; i < smp_n; i = i + 1) begin
                if (smp_r[i] === smp_g[i] && smp_g[i] === smp_b[i] &&
                    run != 0 && smp_r[i] === ((prev + 8'd1) & 8'hFF)) begin
                    run = run + 1;
                    if (run > best) best = run;
                end else if (smp_r[i] === smp_g[i] && smp_g[i] === smp_b[i] &&
                             smp_r[i] !== 8'h00) begin
                    run = 1;
                end else
                    run = 0;
                prev = smp_r[i];
            end
            if (best < 600) begin
                $display("FAIL: 8bpp regression longest run %0d (< 600)", best);
                errors = errors + 1;
            end
        end

        if (errors == 0) $display("PASS: 24bpp gather + 8bpp regression clean");
        else             $display("FAILED: %0d errors", errors);
        $finish;
    end
endmodule
