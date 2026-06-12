// Apple Macintosh Display Card 8*24 (the non-GC card)
// Declaration ROM: 341-0868 (32 KB)
// Behavioral reference: Snow emulator core/src/mac/nubus/mdc12.rs
//   (NOT MAME nubus_48gc.cpp, which is the accelerated GC variant)
//
// Key differences from the Apple High Resolution Video Card (m2hires):
//   * NO inversion anywhere (VRAM, registers and ROM are all raw).
//   * Declaration ROM is on byte lane 3 (addr%4==3), not inverted.
//   * Flat register map at slot-local 0x20_xxxx (control / base / stride /
//     CRTC / RAMDAC), not the TFB quadrant decode.
//   * Resolution is chosen by the ROM reading MONITOR SENSE lines; we
//     advertise the Macintosh 14" hi-res monitor (640x480), sense [6,2,4,6].
//   * bpp comes from the RAMDAC control register mode field.
//
// The data-plane backend (dual-port VRAM-in-BRAM, port-B scanout, pixel
// extraction, NuBus halfword/ACK handling) is carried over from
// nubus_video_highres.sv.
//
// Same-bpp milestone: boot is 1 bpp; 8/24 bpp need a larger VRAM than the
// current 128 KB on-chip BRAM, so they are deferred.

module nubus_video_mdc824 #(
    parameter SLOT_ID = 4'hE,
    parameter DEFAULT_MONOCHROME = 1'b0
) (
    input clk,
    input reset,

    // CPU Interface (NuBus Slot)
    input [31:0] addr,
    input [15:0] data_in,
    output reg [15:0] data_out,
    input [1:0] uds_lds,
    input cpu_longword,
    input rw_n,
    input cpu_as_n,
    input select,
    output reg ack_n,
    output reg nmrq_n,

    // Video Output
    output [7:0] vga_r,
    output [7:0] vga_g,
    output [7:0] vga_b,
    output vga_hs,
    output vga_vs,
    output vga_blank,
    output vga_clk,

    // VRAM Port A — CPU read/write (via FSM)
    output reg [24:0] vram_addr,
    output reg [15:0] vram_dout,
    input [15:0] vram_din,
    output reg vram_rd,
    output reg vram_wr,
    input vram_ready,

    // VRAM Port B — dedicated scanout read (no cache, never misses)
    output     [24:0] vram_scan_addr,
    output            vram_scan_rd,
    input      [15:0] vram_scan_data,

    // IOCTL Interface for ROM Download
    input        ioctl_wr,
    input [24:0] ioctl_addr,
    input [15:0] ioctl_data,
    input        ioctl_download,
    input [7:0]  ioctl_index,

    // Overlay control (MiSTer OSD)
    input        overlay_en,
    input        monochrome,

    // Pixel clock enable output
    output       ce_pixel,

    // JTAG debug exposures
    output       dbg_video_en,
    output [15:0] dbg_vram_wr_cnt,
    output [15:0] dbg_vram_fetch_cnt,
    output [15:0] dbg_irq_cnt,        // # of VBL IRQ assertions (nmrq_n falling)
    output [15:0] dbg_ack_cnt,        // # of bus cycles this card ACKed
    output        dbg_vblank_enable   // is the card's VBL IRQ currently enabled?
);

    // ========================================================================
    // NuBus Slot Configuration — Slot E (same window as the hi-res card).
    //   Standard slot: addr[31:28]==F && addr[27:24]==E  ($FE00_0000..$FEFF_FFFF)
    //   Super slot:    addr[31:28]==E                     ($E000_0000..$EEFF_FFFF)
    // The 8*24 driver (per Snow) uses the standard "normal" slot space, where
    // the slot-local address is addr[23:0].
    // ========================================================================
    wire in_our_slot = (addr[31:28] == SLOT_ID) ||
                       (addr[31:28] == 4'hF && addr[27:24] == SLOT_ID);

    wire [23:0] local_addr = addr[23:0];

    // VRAM lives in dedicated on-chip BRAM (vram_ram).  VRAM_BASE high bits are
    // ignored by the BRAM (only the low word-index bits index it); kept for
    // parity with the hi-res card.
    localparam VRAM_BASE = 25'h300000;
    localparam VRAM_SIZE = 65536;   // 2^16 words = 128 KB (1 bpp boot fits)

    // ========================================================================
    // Slot-local address decode (Snow mdc12 map):
    //   0x00_0000 - 0x1F_FFFF  VRAM (2 MB)
    //   0x20_0000 - 0x20_FFFF  registers / CRTC / RAMDAC
    //   0xFE_0000 - 0xFF_FFFF  declaration ROM (byte lane 3)
    // ========================================================================
    wire addr_is_vram = (local_addr[23:21] == 3'b000);          // 0x000000-0x1FFFFF
    wire addr_is_regs = (local_addr[23:16] == 8'h20);           // 0x200000-0x20FFFF
    wire addr_is_rom  = (local_addr[23:17] == 7'h7F);           // 0xFE0000-0xFFFFFF

    // ========================================================================
    // CLUT — 256 entries x 24-bit, stored as {B,G,R} (matches Snow palette
    // layout: low byte = R, mid = G, high = B).
    // ========================================================================
    reg [23:0] clut [0:255];
    integer ci;
    initial begin
        for (ci = 0; ci < 256; ci = ci + 1)
            clut[ci] = {ci[7:0], ci[7:0], ci[7:0]};  // default grayscale ramp
    end

    // ========================================================================
    // Declaration ROM — 32 KB, byte lane 3, NOT inverted.
    //   ROM byte index = local_addr[16:2]  (one byte per NuBus longword)
    //   responds only when local_addr[1:0]==2'b11 (lane 3)
    // boot2.hex = releases/341-0868.BIN as 16384 big-endian 16-bit word tokens
    //   (xxd -p -c 2 releases/341-0868.BIN > boot2.hex)
    //
    // Stored 16-bit-wide (NOT byte-wide) so the block has a SINGLE write port and
    // infers cleanly as M10K.  A byte-wide array with the 2-byte-per-ioctl-word
    // download needs two write ports, which forces the whole 32 KB ROM (+ its
    // 32768:1 read mux) into logic cells and overflows the device.
    //
    // ROM byte index = local_addr[16:2] (one byte per NuBus longword, lane 3):
    //   word index = local_addr[16:3]; byte within word = local_addr[2]
    //   big-endian file -> even byte index (addr[2]==0) = high byte [15:8].
    // ========================================================================
    (* ramstyle = "M10K" *) reg [15:0] rom [0:16383];
    initial $readmemh("boot2.hex", rom);

    reg [15:0] rom_word;
    always @(posedge clk)
        rom_word <= rom[local_addr[16:3]];
    wire [7:0] rom_rdata = local_addr[2] ? rom_word[7:0] : rom_word[15:8];

    wire rom_lane_valid = (local_addr[1:0] == 2'b11);

    // Declaration ROM is baked into the bitstream via $readmemh("boot2.hex")
    // above; no runtime download path is provided. (Previously this listened
    // for ioctl_index==8'd1 as a "sim convenience", but the F1 floppy mount
    // now also arrives at ioctl_index=1 per MiSTer hps_io's F<N> convention.
    // Routing the 800K floppy stream into the 32K decl ROM wrapped 25× and
    // corrupted the slot-manager declaration, hanging Mac OS on the "Welcome
    // to Macintosh" splash. Sim should bake the ROM the same way real
    // hardware does.)

    // ========================================================================
    // Registers
    // ========================================================================
    reg [15:0] ctrl;          // control register (sense / pixelclock / reset)
    reg [31:0] base_reg;      // screen base (units of 32 bytes)
    reg [31:0] stride_reg;    // scanline stride (units of 4 bytes, <<3 for 24bpp)
    reg [7:0]  ramdac_ctrl;   // RAMDAC control (bpp mode in bits [4:1])
    reg [31:0] palette_addr;  // RAMDAC palette write index
    reg [31:0] pal_wr;        // palette write accumulator (R,G,B byte sequence)
    reg [1:0]  pal_cnt;       // 0->R, 1->G, 2->B
    reg        vblank_enable;
    reg        beam_toggle;   // CRTC beam-position read toggles 0<->4

    // ---- Monitor sense: advertise Macintosh 14" hi-res (640x480) = [6,2,4,6]
    localparam [2:0] MSENSE0 = 3'd6;
    localparam [2:0] MSENSE1 = 3'd2;
    localparam [2:0] MSENSE2 = 3'd4;
    localparam [2:0] MSENSE3 = 3'd6;
    // ctrl sense_in0=bit11, sense_in1=bit10, sense_in2=bit9 gate the AND.
    wire [2:0] sense_val =
        MSENSE0 & (ctrl[11] ? MSENSE1 : 3'b111)
                & (ctrl[10] ? MSENSE2 : 3'b111)
                & (ctrl[9]  ? MSENSE3 : 3'b111);
    // Control read-back: sense_out occupies bits [11:9].
    wire [7:0] ctrl_high_sense = {ctrl[15:12], sense_val, ctrl[8]};

    // bpp / pixel mode from RAMDAC control field (bits [4:1])
    wire [3:0] rmode = ramdac_ctrl[4:1];
    // Map to the 2-bit pipeline mode (0=1bpp,1=2bpp,2=4bpp,3=8bpp).
    wire [1:0] mode = (rmode == 4'h0) ? 2'd0 :
                      (rmode == 4'h4) ? 2'd1 :
                      (rmode == 4'h8) ? 2'd2 : 2'd3;  // 0xC/0xD -> 8bpp (24bpp later)

    // ========================================================================
    // Pixel clock: 30.24 MHz from clk_sys = 31.3344 MHz (same divider as hi-res)
    // ========================================================================
    reg [15:0] clk_video_acc;
    reg clk_video_en;
    always @(posedge clk) begin
        if (reset) begin
            clk_video_acc <= 16'd0;
            clk_video_en <= 1'b0;
        end else begin
            if (clk_video_acc + 16'd30240 >= 16'd31334) begin
                clk_video_acc <= clk_video_acc + 16'd30240 - 16'd31334;
                clk_video_en <= 1'b1;
            end else begin
                clk_video_acc <= clk_video_acc + 16'd30240;
                clk_video_en <= 1'b0;
            end
        end
    end
    assign vga_clk = clk;
    assign ce_pixel = clk_video_en;

    // ========================================================================
    // Video timing — 640x480 (Macintosh 14" hi-res), 896x525 total @ 30.24 MHz
    // ========================================================================
    localparam H_TOTAL = 896;
    localparam H_RES   = 640;
    localparam V_TOTAL = 525;
    localparam V_RES   = 480;
    localparam H_SYNC_START = 640 + 32;
    localparam H_SYNC_END   = 640 + 32 + 64;
    localparam V_SYNC_START = 480 + 3;
    localparam V_SYNC_END   = 480 + 3 + 3;

    reg [10:0] h_cnt;
    reg [10:0] v_cnt;
    reg vga_hs_reg, vga_vs_reg;
    reg blanking;

    always @(posedge clk) begin
        if (reset) begin
            h_cnt <= 11'd0;
            v_cnt <= 11'd0;
            vga_hs_reg <= 1'b1;
            vga_vs_reg <= 1'b1;
            blanking <= 1'b1;
        end else if (clk_video_en) begin
            if (h_cnt == H_TOTAL - 1) begin
                h_cnt <= 11'd0;
                if (v_cnt == V_TOTAL - 1)
                    v_cnt <= 11'd0;
                else
                    v_cnt <= v_cnt + 11'd1;
            end else begin
                h_cnt <= h_cnt + 11'd1;
            end
            vga_hs_reg <= ~(h_cnt >= H_SYNC_START && h_cnt < H_SYNC_END);
            vga_vs_reg <= ~(v_cnt >= V_SYNC_START && v_cnt < V_SYNC_END);
            blanking <= (h_cnt >= H_RES) || (v_cnt >= V_RES);
        end
    end

    assign vga_hs = vga_hs_reg;
    assign vga_vs = vga_vs_reg;
    assign vga_blank = ~blanking;  // active-high DE

    // ========================================================================
    // VBL interrupt — Snow fires a 60 Hz vblank IRQ when enabled.
    // We use the real beam: pulse one scanline before vblank.
    // ========================================================================
    reg irq_active;
    reg irq_clear;
    wire vbl_pulse = clk_video_en && (h_cnt == 0) && (v_cnt == V_RES - 1);
    always @(posedge clk) begin
        if (reset) begin
            irq_active <= 1'b0;
            nmrq_n <= 1'b1;
        end else begin
            if (vbl_pulse && vblank_enable)
                irq_active <= 1'b1;
            if (irq_clear)
                irq_active <= 1'b0;
            nmrq_n <= ~irq_active;
        end
    end

    // ========================================================================
    // Scanout VRAM address calculation
    //   fb_byte = base_reg*32 + v*stride_bytes + h_byte
    //   stride_bytes = stride_reg << 2  (<<3 for 24bpp, deferred)
    // ========================================================================
    wire [24:0] base_bytes   = {base_reg[19:0], 5'b00000};   // * 32
    wire [13:0] stride_bytes = {stride_reg[11:0], 2'b00};    // * 4

    wire [9:0] h_byte =
        (mode == 2'd0) ? {3'd0, h_cnt[9:3]} :     // 1bpp: h/8
        (mode == 2'd1) ? {2'd0, h_cnt[9:2]} :     // 2bpp: h/4
        (mode == 2'd2) ? {1'd0, h_cnt[9:1]} :     // 4bpp: h/2
                         h_cnt[9:0];              // 8bpp: h

    wire [24:0] v_byte_offset  = v_cnt[9:0] * stride_bytes;
    wire [24:0] fetch_byte_addr = base_bytes + v_byte_offset + {15'd0, h_byte};
    wire [23:0] fetch_word_addr = fetch_byte_addr[24:1];
    wire fetch_byte_sel = fetch_byte_addr[0];

    assign vram_scan_addr = VRAM_BASE + {1'b0, fetch_word_addr};
    assign vram_scan_rd   = clk_video_en;

    // ========================================================================
    // SDRAM/BRAM state machine — CPU access only (scanout uses port B)
    // ========================================================================
    localparam S_IDLE              = 4'd0;
    localparam S_CPU_WRITE         = 4'd3;
    localparam S_CPU_WRITE_WAIT    = 4'd4;
    localparam S_CPU_READ          = 4'd5;
    localparam S_CPU_READ_WAIT     = 4'd6;
    localparam S_CPU_RMW_READ      = 4'd7;
    localparam S_CPU_RMW_READ_WAIT = 4'd8;
    localparam S_CPU_RMW_WRITE     = 4'd9;

    reg [3:0] state;
    reg [15:0] cpu_write_data;
    reg [15:0] cpu_write_merged;
    reg [1:0]  cpu_write_strobes;

    wire [19:0] cpu_vram_word = local_addr[20:1];  // byte addr -> word addr (2MB)

    // NuBus ack timing
    reg [2:0] ack_delay;
    reg rom_read_pending;
    reg [31:0] ack_addr;
    reg [15:0] ack_data_in;
    reg [1:0]  ack_uds_lds;
    reg ack_rw_n;
    wire bus_key_changed = (addr != ack_addr) ||
                           (!rw_n && data_in != ack_data_in) ||
                           (uds_lds != ack_uds_lds) ||
                           (rw_n != ack_rw_n);

    // ---- Register read (combinational byte reader) -------------------------
    function automatic [7:0] rd_reg_byte(input [15:0] ba);
        begin
            if      (ba == 16'h0002) rd_reg_byte = ctrl_high_sense;
            else if (ba == 16'h0003) rd_reg_byte = ctrl[7:0];
            else if (ba == 16'h0008) rd_reg_byte = base_reg[31:24];
            else if (ba == 16'h0009) rd_reg_byte = base_reg[23:16];
            else if (ba == 16'h000A) rd_reg_byte = base_reg[15:8];
            else if (ba == 16'h000B) rd_reg_byte = base_reg[7:0];
            else if (ba == 16'h000C) rd_reg_byte = stride_reg[31:24];
            else if (ba == 16'h000D) rd_reg_byte = stride_reg[23:16];
            else if (ba == 16'h000E) rd_reg_byte = stride_reg[15:8];
            else if (ba == 16'h000F) rd_reg_byte = stride_reg[7:0];
            else if (ba == 16'h0200) rd_reg_byte = palette_addr[31:24];
            else if (ba == 16'h0201) rd_reg_byte = palette_addr[23:16];
            else if (ba == 16'h0202) rd_reg_byte = palette_addr[15:8];
            else if (ba == 16'h0203) rd_reg_byte = palette_addr[7:0];
            else if (ba == 16'h020B) rd_reg_byte = ramdac_ctrl;
            else if (ba >= 16'h01C0 && ba <= 16'h01C3) rd_reg_byte = beam_toggle ? 8'd0 : 8'd4;
            else rd_reg_byte = 8'h00;  // includes 0x01C4-0x01CF (must read 0)
        end
    endfunction

    wire [15:0] reg_word_addr_even = {addr[15:1], 1'b0};
    wire [15:0] reg_read_data = {rd_reg_byte(reg_word_addr_even),
                                 rd_reg_byte({addr[15:1], 1'b1})};

    // ---- Register write (one byte lane) ------------------------------------
    task automatic wr_reg_byte(input [15:0] ba, input [7:0] v);
        begin
            case (ba)
                16'h0002: begin ctrl[15:8] <= v; ctrl[15] <= 1'b0; end
                16'h0003: begin ctrl[7:0]  <= v; ctrl[15] <= 1'b0; end
                16'h0008: base_reg[31:24]   <= v;
                16'h0009: base_reg[23:16]   <= v;
                16'h000A: base_reg[15:8]    <= v;
                16'h000B: base_reg[7:0]     <= v;
                16'h000C: stride_reg[31:24] <= v;
                16'h000D: stride_reg[23:16] <= v;
                16'h000E: stride_reg[15:8]  <= v;
                16'h000F: stride_reg[7:0]   <= v;
                16'h013C: vblank_enable <= ~v[1];        // CRTC: enable when bit1==0
                16'h0148: irq_clear <= 1'b1;             // IRQ clear
                16'h0200: palette_addr[31:24] <= v;
                16'h0201: palette_addr[23:16] <= v;
                16'h0202: palette_addr[15:8]  <= v;
                16'h0203: palette_addr[7:0]   <= v;
                16'h0207: begin
                    // palette byte sequence: R, G, B -> commit on 3rd
                    if (pal_cnt == 2'd2) begin
                        clut[palette_addr[7:0]] <= {v, pal_wr[31:16]}; // {B,G,R}
                        pal_wr <= 32'd0;
                        palette_addr <= palette_addr + 32'd1;
                        pal_cnt <= 2'd0;
                    end else begin
                        pal_wr <= {v, pal_wr[31:8]};
                        pal_cnt <= pal_cnt + 2'd1;
                    end
                end
                16'h020B: ramdac_ctrl <= v;
                default: ;
            endcase
        end
    endtask

    // ========================================================================
    // Main state machine
    // ========================================================================
    always @(posedge clk) begin
        irq_clear <= 1'b0;

        if (reset) begin
            state <= S_IDLE;
            vram_rd <= 1'b0;
            vram_wr <= 1'b0;
            vram_addr <= 25'd0;
            vram_dout <= 16'd0;
            cpu_write_data <= 16'd0;
            cpu_write_merged <= 16'd0;
            cpu_write_strobes <= 2'b00;
            ack_n <= 1'b1;
            ack_delay <= 3'd0;
            rom_read_pending <= 1'b0;
            ack_addr <= 32'd0;
            ack_data_in <= 16'd0;
            ack_uds_lds <= 2'b00;
            ack_rw_n <= 1'b1;
            data_out <= 16'd0;
            ctrl <= 16'd0;
            base_reg <= 32'd0;
            stride_reg <= 32'd0;
            ramdac_ctrl <= 8'd0;
            palette_addr <= 32'd0;
            pal_wr <= 32'd0;
            pal_cnt <= 2'd0;
            vblank_enable <= 1'b0;
            beam_toggle <= 1'b0;
        end else begin
            if (ack_delay > 3'd0)
                ack_delay <= ack_delay - 3'd1;
            if (ack_delay == 3'd1)
                ack_n <= 1'b0;

            case (state)
                S_IDLE: begin
                    vram_rd <= 1'b0;
                    vram_wr <= 1'b0;

                    if (cpu_as_n && !ack_n) begin
                        ack_n <= 1'b1;
                        ack_delay <= 3'd0;
                    end else if (select && in_our_slot && !ack_n && ack_delay == 3'd0 && bus_key_changed) begin
                        ack_n <= 1'b1;
                    end

                    if (!cpu_as_n && select && in_our_slot && ack_n && ack_delay == 3'd0) begin
                        ack_addr <= addr;
                        ack_data_in <= data_in;
                        ack_uds_lds <= uds_lds;
                        ack_rw_n <= rw_n;

                        // ---- VRAM write (raw, no inversion) ----
                        if (!rw_n && addr_is_vram) begin
                            if (cpu_vram_word < VRAM_SIZE) begin
                                vram_addr <= VRAM_BASE + {5'd0, cpu_vram_word};
                                cpu_write_data <= data_in;
                                cpu_write_strobes <= uds_lds;
                                if (uds_lds == 2'b11) begin
                                    cpu_write_merged <= data_in;
                                    vram_dout <= data_in;
                                    state <= S_CPU_WRITE;
                                end else if (uds_lds != 2'b00) begin
                                    state <= S_CPU_RMW_READ;
                                end else begin
                                    ack_delay <= 3'd2;
                                end
                            end else begin
                                ack_delay <= 3'd2;
                            end
                        end
                        // ---- VRAM read (raw) ----
                        else if (rw_n && addr_is_vram) begin
                            if (cpu_vram_word < VRAM_SIZE) begin
                                vram_addr <= VRAM_BASE + {5'd0, cpu_vram_word};
                                state <= S_CPU_READ;
                            end else begin
                                data_out <= 16'hFFFF;
                                ack_delay <= 3'd2;
                            end
                        end
                        // ---- Register write ----
                        else if (!rw_n && addr_is_regs) begin
                            if (uds_lds[1]) wr_reg_byte({addr[15:1], 1'b0}, data_in[15:8]);
                            if (uds_lds[0]) wr_reg_byte({addr[15:1], 1'b1}, data_in[7:0]);
                            ack_delay <= 3'd2;
                        end
                        // ---- Register read ----
                        else if (rw_n && addr_is_regs) begin
                            data_out <= reg_read_data;
                            // CRTC beam-position read toggles on access to 0x1C3
                            // (word at 0x01C2 / byte 0x01C3 share addr[15:1]==0xE1)
                            if (addr[15:1] == 15'h00E1)
                                beam_toggle <= ~beam_toggle;
                            ack_delay <= 3'd2;
                        end
                        // ---- ROM read (lane 3, not inverted) ----
                        else if (rw_n && addr_is_rom) begin
                            ack_delay <= 3'd3;
                            rom_read_pending <= 1'b1;
                        end
                        // ---- everything else: ack, return open bus ----
                        else if (rw_n) begin
                            data_out <= 16'hFFFF;
                            ack_delay <= 3'd2;
                        end
                        else begin
                            ack_delay <= 3'd2;
                        end

                    end else if ((!select || cpu_as_n) && !ack_n) begin
                        ack_n <= 1'b1;
                        ack_delay <= 3'd0;
                    end
                end

                S_CPU_WRITE: begin
                    vram_wr <= 1'b1;
                    state <= S_CPU_WRITE_WAIT;
                end

                S_CPU_WRITE_WAIT: begin
                    if (vram_ready) begin
                        vram_wr <= 1'b0;
                        ack_delay <= 3'd2;
                        state <= S_IDLE;
                    end
                end

                S_CPU_READ: begin
                    vram_rd <= 1'b1;
                    state <= S_CPU_READ_WAIT;
                end

                S_CPU_READ_WAIT: begin
                    if (vram_ready) begin
                        data_out <= vram_din;   // raw, no inversion
                        vram_rd <= 1'b0;
                        ack_delay <= 3'd2;
                        state <= S_IDLE;
                    end
                end

                S_CPU_RMW_READ: begin
                    vram_rd <= 1'b1;
                    state <= S_CPU_RMW_READ_WAIT;
                end

                S_CPU_RMW_READ_WAIT: begin
                    if (vram_ready) begin
                        vram_rd <= 1'b0;
                        cpu_write_merged <= {
                            cpu_write_strobes[1] ? cpu_write_data[15:8] : vram_din[15:8],
                            cpu_write_strobes[0] ? cpu_write_data[7:0]  : vram_din[7:0]
                        };
                        state <= S_CPU_RMW_WRITE;
                    end
                end

                S_CPU_RMW_WRITE: begin
                    vram_dout <= cpu_write_merged;
                    vram_wr <= 1'b1;
                    state <= S_CPU_WRITE_WAIT;
                end

                default: state <= S_IDLE;
            endcase

            // Latch ROM read data one cycle before ack.  Lane 3 -> D7..D0.
            if (ack_delay == 3'd2 && rom_read_pending) begin
                data_out <= rom_lane_valid ? {8'hFF, rom_rdata} : 16'hFFFF;
                rom_read_pending <= 1'b0;
            end
        end
    end

    // ========================================================================
    // Pixel output pipeline (raw VRAM -> index -> palette / mono)
    // ========================================================================
    reg [2:0] h_cnt_d;
    reg byte_sel_d;
    reg blanking_d;

    always @(posedge clk) begin
        if (clk_video_en) begin
            h_cnt_d <= h_cnt[2:0];
            byte_sel_d <= fetch_byte_sel;
            blanking_d <= blanking;
        end
    end

    // Big-endian: byte_sel=0 -> [15:8], byte_sel=1 -> [7:0]
    wire [7:0] vram_byte = byte_sel_d ? vram_scan_data[7:0] : vram_scan_data[15:8];

    reg [7:0] pixel_idx;
    always @(*) begin
        pixel_idx = 8'd0;
        case (mode)
            2'd0: begin  // 1bpp
                case (h_cnt_d)
                    3'd0: pixel_idx = {7'd0, vram_byte[7]};
                    3'd1: pixel_idx = {7'd0, vram_byte[6]};
                    3'd2: pixel_idx = {7'd0, vram_byte[5]};
                    3'd3: pixel_idx = {7'd0, vram_byte[4]};
                    3'd4: pixel_idx = {7'd0, vram_byte[3]};
                    3'd5: pixel_idx = {7'd0, vram_byte[2]};
                    3'd6: pixel_idx = {7'd0, vram_byte[1]};
                    3'd7: pixel_idx = {7'd0, vram_byte[0]};
                endcase
            end
            2'd1: begin  // 2bpp
                case (h_cnt_d[1:0])
                    2'd0: pixel_idx = {6'd0, vram_byte[7:6]};
                    2'd1: pixel_idx = {6'd0, vram_byte[5:4]};
                    2'd2: pixel_idx = {6'd0, vram_byte[3:2]};
                    2'd3: pixel_idx = {6'd0, vram_byte[1:0]};
                endcase
            end
            2'd2: begin  // 4bpp
                pixel_idx = h_cnt_d[0] ? {4'd0, vram_byte[3:0]}
                                       : {4'd0, vram_byte[7:4]};
            end
            2'd3: begin  // 8bpp
                pixel_idx = vram_byte;
            end
        endcase
    end

    wire pixel_valid = !blanking_d;
    wire mono_mode = DEFAULT_MONOCHROME || monochrome || (mode == 2'd0);
    // 1bpp (and forced mono): bit clear -> light (0xEE), set -> dark (0x22).
    wire [7:0] mono_pixel = pixel_idx[0] ? 8'h22 : 8'hEE;
    assign vga_r = pixel_valid ? (mono_mode ? mono_pixel : clut[pixel_idx][7:0])   : 8'd0;
    assign vga_g = pixel_valid ? (mono_mode ? mono_pixel : clut[pixel_idx][15:8])  : 8'd0;
    assign vga_b = pixel_valid ? (mono_mode ? mono_pixel : clut[pixel_idx][23:16]) : 8'd0;

    // ========================================================================
    // JTAG debug exposures
    // ========================================================================
    assign dbg_video_en = (stride_reg != 32'd0);  // ROM has configured the card

    reg [15:0] vram_wr_cnt_r;
    reg [15:0] vram_fetch_cnt_r;
    reg        vram_wr_d;
    assign dbg_vram_wr_cnt    = vram_wr_cnt_r;
    assign dbg_vram_fetch_cnt = vram_fetch_cnt_r;
    always @(posedge clk) begin
        if (reset) begin
            vram_wr_cnt_r    <= 16'd0;
            vram_fetch_cnt_r <= 16'd0;
            vram_wr_d        <= 1'b0;
        end else begin
            vram_wr_d <= vram_wr;
            if (vram_wr && !vram_wr_d)
                vram_wr_cnt_r <= vram_wr_cnt_r + 16'd1;
            if (clk_video_en && !blanking)
                vram_fetch_cnt_r <= vram_fetch_cnt_r + 16'd1;
        end
    end

    // VBL IRQ assertion counter + ack counter (audio-regression diagnosis):
    //   dbg_irq_cnt   : how many times the card raised its VBL slot IRQ.  If this
    //                   is climbing during the boot/chime window, the card is
    //                   interrupting the CPU (candidate ASC-FIFO starvation).
    //   dbg_ack_cnt   : how many bus cycles the card ACKed (is it on the bus?).
    //   dbg_vblank_enable : whether the 8*24 driver has enabled VBL yet.
    reg [15:0] irq_cnt_r;
    reg [15:0] ack_cnt_r;
    reg        nmrq_d;
    reg        ack_n_d;
    assign dbg_irq_cnt = irq_cnt_r;
    assign dbg_ack_cnt = ack_cnt_r;
    assign dbg_vblank_enable = vblank_enable;
    always @(posedge clk) begin
        if (reset) begin
            irq_cnt_r <= 16'd0;
            ack_cnt_r <= 16'd0;
            nmrq_d    <= 1'b1;
            ack_n_d   <= 1'b1;
        end else begin
            nmrq_d  <= nmrq_n;
            ack_n_d <= ack_n;
            if (nmrq_d && !nmrq_n)        // falling edge: VBL IRQ asserted
                irq_cnt_r <= irq_cnt_r + 16'd1;
            if (ack_n_d && !ack_n)        // falling edge: card ACKed a cycle
                ack_cnt_r <= ack_cnt_r + 16'd1;
        end
    end

endmodule
