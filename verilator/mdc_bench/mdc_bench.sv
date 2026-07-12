// mdc_bench.sv — standalone probe bench for nubus_video_mdc824.
//
// Reproduces the Slot Manager's declaration-ROM format-block probe (the
// MAME oracle: first read of the $FEFFFFxx block returns $78 on lane 3)
// against OUR card model + vram_ram, byte by byte, and prints what the
// CPU would see. Run: verilator/mdc_bench/run.sh (seconds). Written for
// the 2026-07-11 finding: the in-system probe saw the card ACK with
// data=$FFFF, so the Slot Manager treats slot $E as empty.
`timescale 1ns/1ns

module mdc_bench;
    reg clk = 0;
    always #15 clk = ~clk;   // ~32.5MHz-ish; exact rate irrelevant here

    reg reset = 1;

    // CPU-side signals
    reg  [31:0] addr = 0;
    reg  [15:0] data_in = 16'h0000;
    reg  [1:0]  uds_lds = 2'b00;   // {UDS,LDS} active high
    reg         rw_n = 1;
    reg         cpu_as_n = 1;
    reg         select = 0;
    wire [15:0] data_out;
    wire        ack_n, nmrq_n;

    // VRAM hookup
    wire [24:0] vram_addr, vram_scan_addr;
    wire [15:0] vram_dout, vram_din, vram_scan_data;
    wire        vram_rd, vram_wr, vram_ready, vram_scan_rd;

    // The FPGA hybrid shape (2026-07-11): 384KB hot framebuffer in BRAM +
    // cold tail to 1MB on the ext_* port (SDRAM window in-system; a latency
    // model here). PrimaryInit's sizing probe (write $AAAAAAAA @ byte
    // $F4B00 = word $7A580, read back) lands in the TAIL — the IIvi ROM
    // sad-Macs if it misses. See the PrimaryInit section below.
    wire        ext_rd, ext_wr;
    wire [15:0] ext_din;
    wire        ext_ready;

    nubus_video_mdc824 #(.SLOT_ID(4'hE), .VRAM_WORDS(196608),
                         .TOTAL_WORDS(524288)) card (
        .clk(clk), .reset(reset),
        .addr(addr), .data_in(data_in), .uds_lds(uds_lds),
        .cpu_longword(1'b0), .rw_n(rw_n), .cpu_as_n(cpu_as_n),
        .select(select), .data_out(data_out), .ack_n(ack_n), .nmrq_n(nmrq_n),
        .vga_r(), .vga_g(), .vga_b(), .vga_hs(), .vga_vs(), .vga_blank(),
        .vga_clk(),
        .vram_addr(vram_addr), .vram_dout(vram_dout), .vram_din(vram_din),
        .vram_rd(vram_rd), .vram_wr(vram_wr), .vram_ready(vram_ready),
        .ext_rd(ext_rd), .ext_wr(ext_wr), .ext_din(ext_din),
        .ext_ready(ext_ready),
        .vram_scan_addr(vram_scan_addr), .vram_scan_rd(vram_scan_rd),
        .vram_scan_data(vram_scan_data),
        .ioctl_wr(1'b0), .ioctl_addr(25'd0), .ioctl_data(16'd0),
        .ioctl_download(1'b0), .ioctl_index(8'd0),
        .overlay_en(1'b0), .monochrome(1'b0), .monitor_512(1'b0),
        .ce_pixel(),
        .dbg_video_en(), .dbg_vram_wr_cnt(), .dbg_vram_fetch_cnt(),
        .dbg_irq_cnt(), .dbg_ack_cnt(), .dbg_vblank_enable(dbg_vbl_en)
    );
    wire dbg_vbl_en;

    // Cold-tail model: SDRAM-ish latency (several cycles to ready), word
    // index = vram_addr[19:0] per the module's ext contract. In-system this
    // is the cpu-slot SDRAM port at word $100000 + index.
    reg [15:0] ext_mem [0:524287];
    reg [2:0]  ext_lat = 0;
    reg        ext_ready_r = 0;
    always @(posedge clk) begin
        ext_ready_r <= 1'b0;
        if ((ext_rd | ext_wr) && !ext_ready_r) begin
            if (ext_lat == 3'd6) begin
                if (ext_wr) ext_mem[vram_addr[19:0]] <= vram_dout;
                ext_ready_r <= 1'b1;
                ext_lat <= 3'd0;
            end else
                ext_lat <= ext_lat + 3'd1;
        end else
            ext_lat <= 3'd0;
    end
    assign ext_din   = ext_mem[vram_addr[19:0]];
    assign ext_ready = ext_ready_r;

    vram_ram #(.WORDS(196608)) vram (
        .clk(clk),
        .addr(vram_addr), .din(vram_dout), .dout(vram_din),
        .rd(vram_rd), .wr(vram_wr), .ready(vram_ready),
        .addr_b(vram_scan_addr), .rd_b(vram_scan_rd), .dout_b(vram_scan_data)
    );

    integer timeout;
    integer errors = 0;

    // Golden copy of the declaration ROM for the sweep
    reg [15:0] gold [0:16383];
    initial $readmemh("../rtl/nubus/mdc824_rom.hex", gold);

    // Quiet read returning the data (for the sweep)
    reg [15:0] rd_val;
    task bus_read_q(input [31:0] a, input [1:0] strobes);
        begin
            @(negedge clk);
            addr = a; rw_n = 1; select = 1; cpu_as_n = 0; uds_lds = strobes;
            timeout = 0;
            @(negedge clk);
            while (ack_n !== 1'b0 && timeout < 40) begin
                @(negedge clk); timeout = timeout + 1;
            end
            rd_val = (ack_n === 1'b0) ? data_out : 16'hDEAD;
            @(negedge clk);
            cpu_as_n = 1; select = 0; uds_lds = 2'b00;
            repeat (2) @(negedge clk);
        end
    endtask

    // Quiet write (PrimaryInit smoke: registers + VRAM sizing probe)
    task bus_write_q(input [31:0] a, input [15:0] v, input [1:0] strobes);
        begin
            @(negedge clk);
            addr = a; data_in = v; rw_n = 0; select = 1; cpu_as_n = 0;
            uds_lds = strobes;
            timeout = 0;
            @(negedge clk);
            while (ack_n !== 1'b0 && timeout < 60) begin
                @(negedge clk); timeout = timeout + 1;
            end
            @(negedge clk);
            cpu_as_n = 1; select = 0; uds_lds = 2'b00; rw_n = 1;
            repeat (2) @(negedge clk);
        end
    endtask

    task expect16(input [31:0] a, input [15:0] want, input [175:0] tag);
        begin
            if (rd_val !== want) begin
                $display("PINIT FAIL %0s: addr=%08x got=%04x want=%04x",
                         tag, a, rd_val, want);
                errors = errors + 1;
            end
        end
    endtask

    // One 16-bit bus cycle (byte or word) like the TG68 wrapper drives it.
    task bus_read(input [31:0] a, input [1:0] strobes);
        begin
            @(negedge clk);
            addr = a; rw_n = 1; select = 1; cpu_as_n = 0; uds_lds = strobes;
            timeout = 0;
            @(negedge clk);
            while (ack_n !== 1'b0 && timeout < 40) begin
                @(negedge clk); timeout = timeout + 1;
            end
            if (ack_n === 1'b0)
                $display("READ  %08x strobes=%b -> data=%04x (ack after %0d clks)",
                         a, strobes, data_out, timeout);
            else
                $display("READ  %08x strobes=%b -> NO ACK (timeout)", a, strobes);
            @(negedge clk);
            cpu_as_n = 1; select = 0; uds_lds = 2'b00;
            repeat (4) @(negedge clk);
        end
    endtask

    initial begin
        repeat (8) @(negedge clk);
        reset = 0;
        repeat (8) @(negedge clk);

        // Reference: dump the tail of the loaded declaration ROM image
        $display("rom[16383]=%04x rom[16382]=%04x rom[16381]=%04x rom[16380]=%04x",
                 card.rom[16383], card.rom[16382], card.rom[16381], card.rom[16380]);

        // The Slot Manager format-block walk: lane-3 bytes from the top.
        // The card sees TRUE byte addresses (the tops feed tg68_a[0] as
        // addr[0]); an odd byte -> LDS ({0,1}), even -> UDS ({1,0}).
        bus_read(32'hFEFFFFFF, 2'b01); // byte $FEFFFFFF (lane 3) = ByteLanes
        bus_read(32'hFEFFFFFE, 2'b10); // byte $FEFFFFFE (lane 2) = expect open
        bus_read(32'hFEFFFFFD, 2'b01); // byte $FEFFFFFD (lane 1) = expect open
        bus_read(32'hFEFFFFFC, 2'b10); // byte $FEFFFFFC (lane 0) = expect open
        bus_read(32'hFEFFFFFB, 2'b01); // byte $FEFFFFFB (lane 3, next longword)
        bus_read(32'hFEFFFFF7, 2'b01); // byte $FEFFFFF7 (lane 3)
        bus_read(32'hFEFFFFF3, 2'b01); // byte $FEFFFFF3 (lane 3)
        bus_read(32'hFEFFFFEF, 2'b01); // byte $FEFFFFEF (lane 3)
        // Super-slot flavor of the same top byte
        bus_read(32'hEEFFFFFF, 2'b01);
        // And a word read covering both lanes of the top longword's upper half
        // (Slot Manager driver copies use word/long accesses: must be $FF78)
        bus_read(32'hFEFFFFFE, 2'b11);

        // ---- Full-image lane-3 sweep: every declaration ROM byte, via both
        // WORD reads (the driver-copy shape) and odd-BYTE reads. ----
        begin : sweep
            integer w;
            reg [7:0] expect_hi, expect_lo;
            for (w = 0; w < 16384; w = w + 1) begin
                expect_hi = gold[w][15:8];  // lane-3 byte of longword 2w
                expect_lo = gold[w][7:0];   // lane-3 byte of longword 2w+1
                // word read at A1==1 of each longword
                bus_read_q(32'hFE000000 + 24'hFE0000 + w*8 + 2, 2'b11);
                if (rd_val !== {8'hFF, expect_hi}) begin
                    if (errors < 10) $display("SWEEP FAIL w=%0d wordA got=%04x want=FF%02x", w, rd_val, expect_hi);
                    errors = errors + 1;
                end
                bus_read_q(32'hFE000000 + 24'hFE0000 + w*8 + 6, 2'b11);
                if (rd_val !== {8'hFF, expect_lo}) begin
                    if (errors < 10) $display("SWEEP FAIL w=%0d wordB got=%04x want=FF%02x", w, rd_val, expect_lo);
                    errors = errors + 1;
                end
                // spot-check byte reads on a stride
                if ((w & 255) == 0) begin
                    bus_read_q(32'hFE000000 + 24'hFE0000 + w*8 + 3, 2'b01);
                    if (rd_val[7:0] !== expect_hi) begin
                        $display("SWEEP FAIL w=%0d byteA got=%02x want=%02x", w, rd_val[7:0], expect_hi);
                        errors = errors + 1;
                    end
                end
            end
            if (errors == 0) $display("SWEEP PASS: all 32768 lane-3 bytes correct (word+byte access)");
            else $display("SWEEP: %0d ERRORS", errors);
        end

        // ---- PrimaryInit smoke — the exact hardware conversation the card's
        // declaration-ROM init code has with the card, captured from MAME
        // (tap.lua rw over $FE000000-$FE3FFFFF, 2026-07-11; the smRecNotFnd
        // sad-Mac root cause #3). 32-bit CPU ops arrive as two 16-bit word
        // cycles, high half (A1==0) first. ----
        begin : pinit
            integer pinit_errors_at_start;
            pinit_errors_at_start = errors;

            // (1) ctrl long read — MUST be $00000C02 exactly (the MAME
            //     golden's first PrimaryInit read): sense code 6 (13"
            //     640x480) in bits [11:9] AND the reset straps in the low
            //     byte (bit1 SET, bit0 clear = the VRAM config straps
            //     PrimaryInit branches on — root cause #5).
            bus_read_q(32'hFE200000, 2'b11);
            expect16(32'hFE200000, 16'h0000, "ctrl-hi");
            bus_read_q(32'hFE200002, 2'b11);
            expect16(32'hFE200002, 16'h0C02, "ctrl-sense-straps");

            // (2) register $300: PrimaryInit writes $55 and expects to read 0
            //     back (MAME: WR $55 -> RD $00000000).
            bus_write_q(32'hFE200300, 16'h0000, 2'b11);
            bus_write_q(32'hFE200302, 16'h0055, 2'b11);
            bus_read_q(32'hFE200300, 2'b11);
            expect16(32'hFE200300, 16'h0000, "reg300-hi");
            bus_read_q(32'hFE200302, 2'b11);
            expect16(32'hFE200302, 16'h0000, "reg300-lo");

            // (3) THE VRAM SIZING PROBE: write $AAAAAAAA at byte offset
            //     $F4B00 (~979KB) and read it back — PrimaryInit's 1MB
            //     presence test. We model the card's default 1MB config, so
            //     this must succeed. With the old 384KB VRAM_WORDS the
            //     readback returned $FFFF, PrimaryInit failed, the Slot
            //     Manager dropped the video sResources and the ROM
            //     sad-Macced $0F/$33 (smRecNotFnd) hunting a boot display.
            bus_write_q(32'hFE0F4B00, 16'hAAAA, 2'b11);
            bus_write_q(32'hFE0F4B02, 16'hAAAA, 2'b11);
            bus_read_q(32'hFE0F4B00, 2'b11);
            expect16(32'hFE0F4B00, 16'hAAAA, "vram-size-probe-hi");
            bus_read_q(32'hFE0F4B02, 2'b11);
            expect16(32'hFE0F4B02, 16'hAAAA, "vram-size-probe-lo");

            // (4) VRAM low-address readback (framebuffer clear region)
            bus_write_q(32'hFE000000, 16'h5678, 2'b11);
            bus_write_q(32'hFE000002, 16'h9ABC, 2'b11);
            bus_read_q(32'hFE000000, 2'b11);
            expect16(32'hFE000000, 16'h5678, "vram-low-hi");
            bus_read_q(32'hFE000002, 2'b11);
            expect16(32'hFE000002, 16'h9ABC, "vram-low-lo");

            // (4b) BRAM/tail boundary straddle: word 196607 (byte $5FFFE) is
            //      the last BRAM word, word 196608 (byte $60000) the first
            //      tail word — both must hold values independently.
            bus_write_q(32'hFE05FFFE, 16'h1122, 2'b11);
            bus_write_q(32'hFE060000, 16'h3344, 2'b11);
            bus_read_q(32'hFE05FFFE, 2'b11);
            expect16(32'hFE05FFFE, 16'h1122, "boundary-bram");
            bus_read_q(32'hFE060000, 2'b11);
            expect16(32'hFE060000, 16'h3344, "boundary-ext");

            // (4c) RMW byte write INTO the tail (odd byte -> LDS strobe):
            //      merges over the ext port's read-modify-write path.
            bus_write_q(32'hFE060001, 16'h0055, 2'b01);
            bus_read_q(32'hFE060000, 2'b11);
            expect16(32'hFE060000, 16'h3355, "ext-rmw-byte");

            // (5) beyond-VRAM reads stay open-bus ($FFFF): the sizing probe
            //     must FAIL cleanly past the installed size (here: at 2MB-1,
            //     beyond the 1MB card).
            bus_read_q(32'hFE1FFFFC, 2'b11);
            expect16(32'hFE1FFFFC, 16'hFFFF, "vram-beyond");

            // (5b) PrimaryInit's VBL-DISABLE write: the CRTC long at $13C
            //      carries its data in byte $13F (two word cycles:
            //      $0000 @ $13C, $0006 @ $13E). Bit1 SET = disable. The
            //      old byte-$13C decode saw the long's $00 byte 0 and
            //      ENABLED the VBL instead — stuck slot-$E IRQ, POST
            //      reg2 fingerprint fail, sad Mac $0F/$33 (root cause #8).
            bus_write_q(32'hFE20013C, 16'h0000, 2'b11);
            bus_write_q(32'hFE20013E, 16'h0006, 2'b11);
            if (dbg_vbl_en !== 1'b0) begin
                $display("PINIT FAIL vbl-disable: enable=%b after $13C<-$06 long", dbg_vbl_en);
                errors = errors + 1;
            end
            // ...and an ENABLE write (bit1 clear) must turn it on.
            bus_write_q(32'hFE20013C, 16'h0000, 2'b11);
            bus_write_q(32'hFE20013E, 16'h0004, 2'b11);
            if (dbg_vbl_en !== 1'b1) begin
                $display("PINIT FAIL vbl-enable: enable=%b after $13C<-$04 long", dbg_vbl_en);
                errors = errors + 1;
            end
            // restore disabled (boot state)
            bus_write_q(32'hFE20013C, 16'h0000, 2'b11);
            bus_write_q(32'hFE20013E, 16'h0006, 2'b11);

            // (6) CRTC beam-position: two reads of $2001C2 must differ
            //     (toggles 4 <-> 0 so the driver sees a moving beam).
            begin
                reg [15:0] beam_first;
                bus_read_q(32'hFE2001C2, 2'b11);
                beam_first = rd_val;
                bus_read_q(32'hFE2001C2, 2'b11);
                if (rd_val === beam_first) begin
                    $display("PINIT FAIL beam-toggle: stuck at %04x", rd_val);
                    errors = errors + 1;
                end
            end

            if (errors == pinit_errors_at_start)
                $display("PINIT PASS: sense, reg $300, 1MB sizing probe (tail), BRAM/tail boundary, ext RMW, beam toggle");
            else
                $display("PINIT: %0d ERRORS", errors - pinit_errors_at_start);
        end

        $display("DONE");
        $finish;
    end
endmodule
