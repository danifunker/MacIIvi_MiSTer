// Apple Macintosh II High Resolution Video Card
// TFB 2.2 ASIC (344S0077) + Bt453 RAMDAC
// MAME reference: src/devices/bus/nubus/nubus_m2hires.cpp
// ROM: 341-0660.bin (8KB)
// 640x480, 1/2/4/8 bpp, 30.24 MHz pixel clock

module nubus_video_highres #(
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

    // JTAG debug exposures (diagnose the hardware black-screen):
    //   dbg_video_en      : has the Mac enabled video (REG_SOFTRESET[0])?
    //   dbg_vram_wr_cnt   : count of CPU VRAM writes (Mac drawing)
    //   dbg_vram_fetch_cnt: count of completed video VRAM fetches (reads)
    output       dbg_video_en,
    output [15:0] dbg_vram_wr_cnt,
    output [15:0] dbg_vram_fetch_cnt
);

    // ========================================================================
    // NuBus Slot Configuration — Slot E
    //   Standard slot: $E000_0000 - $EEFF_FFFF (addr[31:28] == E)
    //   Super slot:    $FE00_0000 - $FEFF_FFFF (addr[31:28] == F, [27:24] == E)
    // Mac II ROM probes standard slot space for declaration ROMs.
    // ========================================================================
    wire in_our_slot = (addr[31:28] == SLOT_ID) ||
                       (addr[31:28] == 4'hF && addr[27:24] == SLOT_ID);

    // ========================================================================
    // VRAM in SDRAM — 512KB at offset $30_0000
    // ========================================================================
    localparam VRAM_BASE = 25'h300000;
    // VRAM now lives in dedicated on-chip BRAM (vram_ram, 2^17 words = 256 KB),
    // which fits comfortably in M10K (256/472 free blocks).  Cap the size to the
    // BRAM depth so addresses can't alias past it.  256 KB covers 1/2/4 bpp at
    // 640x480 (boot is 1 bpp); full 512 KB (8 bpp) would need 512 blocks (>free).
    localparam VRAM_SIZE = 65536;   // 2^16 words = 128 KB (dual-port BRAM; 1/2 bpp)


    // ========================================================================
    // CLUT — 256 entries x 24-bit RGB, on-chip
    // ========================================================================
    reg [23:0] clut [0:255];
    integer i;
    initial begin
        for (i = 0; i < 256; i = i + 1)
            clut[i] = {i[7:0], i[7:0], i[7:0]};  // Default grayscale ramp
    end

    // ========================================================================
    // Declaration ROM — 8KB (4096 x 16-bit words), on-chip
    //
    // NuBus byte-lane mapping: 341-0660 ROM file is an inverted single-lane
    // ROM originally on NuBus lane 0 (D31-D24).  Format byte $1E de-inverts
    // to $E1, which advertises lane 0.  MAME's install_declaration_rom()
    // keeps that lane; on our 16-bit CPU bus, lane 0 is represented by the
    // upper byte of the even 16-bit word.
    // Each ROM byte occupies one lane-0 position per 4-byte NuBus word,
    // so 8KB ROM → 32KB address space at top of slot: $FF8000-$FFFFFF.
    //
    // MAME mirrors the ROM across all 16MB of slot space (mirror_all_mb=true).
    // We achieve this by making ROM the fallback for any unmatched read.
    //
    // Reference: MAME nubus.cpp install_declaration_rom(),
    //            Snow mdc12.rs line 316 "ROM (byte lane 3)"
    // ========================================================================
    (* ramstyle = "M10K" *) reg [15:0] rom [0:4095];

    // Bake the 341-0660 declaration ROM into the bitstream.  On real MiSTer
    // hardware the HPS only auto-loads ONE ROM (boot0.rom @ index 0); there is
    // no mechanism to send boot1.rom @ index 1, so the card never received its
    // declaration ROM and the Slot Manager could not initialize it (no video).
    // Initializing rom[] here makes the card self-contained, like real hardware
    // where the declaration ROM lives on the card.  The ioctl path below still
    // overwrites it when a host (e.g. the Verilator sim) does provide the ROM.
    // boot1.hex = releases/boot1.rom as 4096 big-endian 16-bit words
    // (xxd -p -c 2 releases/boot1.rom > boot1.hex), stored inverted exactly as
    // the file is; the read path de-inverts (rom_byte ^ 0xFF).
    initial $readmemh("boot1.hex", rom);

    // ROM read — byte-lane 3 addressing
    // Each ROM byte at every 4th NuBus address (addr[1:0]==3).
    // ROM byte index = addr[14:2], ROM word index = addr[14:3].
    // addr[2] selects even byte (rom_word[15:8]) or odd byte (rom_word[7:0]).
    reg [15:0] rom_rdata;
    always @(posedge clk)
        rom_rdata <= rom[addr[14:3]];

    // ROM byte-lane mapping for the 16-bit CPU bus
    //
    // The 341-0660 ROM file is stored INVERTED (format byte $1E at pos -1,
    // inversion marker $FF at pos -2).  MAME's install_declaration_rom
    // detects this and XORs all bytes with $FF to de-invert, then exposes the
    // de-inverted format byte $E1 on NuBus lane 0.
    wire [7:0] rom_byte_raw = addr[2] ? rom_rdata[7:0] : rom_rdata[15:8];
    wire [7:0] rom_byte_deinv = rom_byte_raw ^ 8'hFF;  // De-invert
    wire [7:0] rom_byte_out = rom_byte_deinv;
    // Only lane 0 responds. On the 16-bit CPU bus this is D15-D8 at even
    // byte addresses (addr[1:0] == 0).
    wire rom_lane_valid = (addr[1:0] == 2'b00);

    // Declaration ROM is baked into the bitstream via $readmemh("boot1.hex")
    // above; no runtime ioctl path. Previously listened for ioctl_index==8'd1
    // as a sim convenience, but the F1 floppy mount now arrives at index 1
    // per the MiSTer hps_io F<N> convention, and an 800K stream into 8K of
    // ROM wrapped 100× and corrupted the decl table -> Mac OS hung on the
    // "Welcome" splash. Sim should bake the ROM the same way.
    // synthesis translate_off
    integer rom_load_count = 0;
    integer vbl_debug_count = 0;
    integer vram_debug_count = 0;
    // synthesis translate_on

    // ========================================================================
    // TFB 2.2 Registers (MAME register indices)
    // ========================================================================
    localparam REG_BASE        = 0;   // VRAM draw offset, 32-bit words (17 bits)
    localparam REG_LENGTH      = 1;   // Scanline stride, 32-bit words (10 bits)
    localparam REG_MISC        = 2;   // Bits [10:8] = mode
    localparam REG_SYNCINTERVAL = 3;
    localparam REG_VFRONTPORCH = 4;
    localparam REG_VBACKPORCH  = 5;
    localparam REG_VLINES      = 6;
    localparam REG_HFRONTPORCH = 7;
    localparam REG_HSYNCPULSE  = 8;
    localparam REG_HBACKPORCH  = 9;
    localparam REG_HFIRST      = 10;
    localparam REG_HLAST       = 11;
    localparam REG_SOFTRESET   = 12;  // Bit 0 = enable video

    reg [31:0] registers [0:15];

    // Bt453 RAMDAC state
    reg [7:0] ramdac_addr;
    reg [1:0] ramdac_rgb;   // 0=R, 1=G, 2=B
    reg [31:0] ramdac_last_addr;
    reg [15:0] ramdac_last_data;
    reg ramdac_dup_phase;

    // VBL interrupt
    reg irq_active;
    reg irq_clear;
    reg vbl_disable;

    // NuBus ack timing
    reg [2:0] ack_delay;
    reg rom_read_pending;  // Set when ROM read in progress (ack_delay=3 path)
    reg [31:0] ack_addr;
    reg [15:0] ack_data_in;
    reg [1:0] ack_uds_lds;
    reg ack_rw_n;
    wire bus_key_changed = (addr != ack_addr) ||
                           (!rw_n && data_in != ack_data_in) ||
                           (uds_lds != ack_uds_lds) ||
                           (rw_n != ack_rw_n);

    // ========================================================================
    // Decoded register values
    // ========================================================================
    // MAME: mode = (registers[MISC] >> 8) & 7; Bt453: m_mode = mode - 4
    wire [2:0] mode_raw = registers[REG_MISC][10:8];
    wire [1:0] mode = (mode_raw >= 3'd4) ? mode_raw[1:0] : 2'd0;
    wire video_en = registers[REG_SOFTRESET][0];
    wire [16:0] vram_base_offset = registers[REG_BASE][16:0];   // 32-bit words
    wire [9:0]  vram_stride      = registers[REG_LENGTH][9:0];  // 32-bit words

    // ========================================================================
    // Pixel clock: 30.24 MHz from clk_sys = 31.3344 MHz
    // Accumulator method: enable when acc + 30240 >= 31334 (≈ clk_sys in kHz)
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
    // Video timing — defaults match MAME m2hires (896x525 @ 30.24 MHz)
    // ========================================================================
    localparam H_TOTAL_DEFAULT = 896;
    localparam H_RES_DEFAULT   = 640;
    localparam V_TOTAL_DEFAULT = 525;
    localparam V_RES_DEFAULT   = 480;

    // Use fixed 640x480 timing for now; TFB register-based timing can be
    // added later once basic video works.
    localparam H_TOTAL = H_TOTAL_DEFAULT;
    localparam H_RES   = H_RES_DEFAULT;
    localparam V_TOTAL = V_TOTAL_DEFAULT;
    localparam V_RES   = V_RES_DEFAULT;

    // Sync pulse positions (standard 640x480 with 896 total)
    // H: 640 vis + 32 fp + 64 sync + 160 bp = 896
    localparam H_SYNC_START = 640 + 32;
    localparam H_SYNC_END   = 640 + 32 + 64;
    // V: 480 vis + 3 fp + 3 sync + 39 bp = 525
    localparam V_SYNC_START = 480 + 3;
    localparam V_SYNC_END   = 480 + 3 + 3;

    // ========================================================================
    // Video counters and sync generation
    // ========================================================================
    reg [10:0] h_cnt;
    reg [10:0] v_cnt;
    reg vga_hs_reg, vga_vs_reg;
    reg blanking;  // 1 during blanking interval

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
            // DE must stay active in the visible region regardless of video_en,
            // otherwise the MiSTer scaler measures no active pixels and reports
            // 0x0 / no-signal (the "0x0x0hz" symptom) until the Mac enables
            // video. Keep DE tied only to the visible window so the card always
            // presents a measurable 640x480 frame.
            blanking <= (h_cnt >= H_RES) || (v_cnt >= V_RES);
        end
    end

    assign vga_hs = vga_hs_reg;
    assign vga_vs = vga_vs_reg;
    assign vga_blank = ~blanking;  // MiSTer: active-high DE (1 = active display)

    // ========================================================================
    // VBL interrupt generation
    // ========================================================================
    // MAME schedules the m2hires slot IRQ at screen position (m_vres - 1, 0),
    // one scanline before screen().vblank() becomes true.
    wire vbl_pulse = clk_video_en && (h_cnt == 0) && (v_cnt == V_RES - 1);

    always @(posedge clk) begin
        if (reset) begin
            irq_active <= 1'b0;
            nmrq_n <= 1'b1;
        end else begin
            if (vbl_pulse && !vbl_disable)
                irq_active <= 1'b1;
            if (irq_clear)
                irq_active <= 1'b0;
            nmrq_n <= ~irq_active;
        end
    end

    // ========================================================================
    // VRAM fetch address calculation
    //
    // MAME: vram8 = base + (BASE & 0x1ffff) * 4 + y * stride_bytes + x_byte
    //   stride_bytes = (LENGTH & 0x3ff) * 4
    //   x_byte depends on mode: 1bpp=x/8, 2bpp=x/4, 4bpp=x/2, 8bpp=x
    //
    // Our SDRAM is 16-bit word addressed.
    // fetch_byte_addr = base_byte + v_cnt * stride_bytes + h_byte
    // sdram_word_addr = fetch_byte_addr >> 1
    // ========================================================================

    wire [18:0] base_byte = {vram_base_offset[16:0], 2'b00};  // * 4
    wire [11:0] stride_bytes = {vram_stride[9:0], 2'b00};     // * 4

    // Horizontal byte offset within current scanline
    wire [9:0] h_byte;
    assign h_byte = (mode == 2'd0) ? {3'd0, h_cnt[9:3]} :     // 1bpp: h/8
                    (mode == 2'd1) ? {2'd0, h_cnt[9:2]} :     // 2bpp: h/4
                    (mode == 2'd2) ? {1'd0, h_cnt[9:1]} :     // 4bpp: h/2
                                     h_cnt[9:0];              // 8bpp: h

    // Full byte address in VRAM
    wire [20:0] v_byte_offset = v_cnt[9:0] * stride_bytes;
    wire [20:0] fetch_byte_addr = base_byte + v_byte_offset + {11'd0, h_byte};

    // Convert to 16-bit word address for SDRAM
    wire [18:0] fetch_word_addr = fetch_byte_addr[19:1];

    // Dedicated scanout read port (port B of the VRAM BRAM): present the current
    // pixel's word address every displayed pixel.  The BRAM returns it
    // (registered) on the next clk_video_en, aligned with byte_sel_d/h_cnt_d in
    // the pixel pipeline below -- so the scanout always has the correct word and
    // never depends on the CPU port or a cache.
    assign vram_scan_addr = VRAM_BASE + {6'd0, fetch_word_addr};
    assign vram_scan_rd   = clk_video_en;

    // Which byte within the 16-bit word (0=high byte, 1=low byte, big-endian)
    wire fetch_byte_sel = fetch_byte_addr[0];

    wire [10:0] pixels_per_word =
        (mode == 2'd0) ? 11'd16 :
        (mode == 2'd1) ? 11'd8 :
        (mode == 2'd2) ? 11'd4 : 11'd2;

    wire [10:0] prefetch_x = h_cnt + pixels_per_word;
    wire prefetch_visible = video_en && (v_cnt < V_RES) && (prefetch_x < H_RES);
    wire [9:0] prefetch_h_byte =
        (mode == 2'd0) ? {3'd0, prefetch_x[9:3]} :
        (mode == 2'd1) ? {2'd0, prefetch_x[9:2]} :
        (mode == 2'd2) ? {1'd0, prefetch_x[9:1]} :
                         prefetch_x[9:0];
    wire [20:0] prefetch_byte_addr = base_byte + v_byte_offset + {11'd0, prefetch_h_byte};
    wire [18:0] prefetch_word_addr = prefetch_byte_addr[19:1];

    reg [15:0] vram_cache0;
    reg [15:0] vram_cache1;
    reg [18:0] vram_cache0_word;
    reg [18:0] vram_cache1_word;
    reg vram_cache0_valid;
    reg vram_cache1_valid;
    reg vram_cache_replace;
    reg [18:0] video_fetch_word;

    wire display_word_cached0 = vram_cache0_valid && (vram_cache0_word == fetch_word_addr);
    wire display_word_cached1 = vram_cache1_valid && (vram_cache1_word == fetch_word_addr);
    wire prefetch_word_cached0 = vram_cache0_valid && (vram_cache0_word == prefetch_word_addr);
    wire prefetch_word_cached1 = vram_cache1_valid && (vram_cache1_word == prefetch_word_addr);
    wire video_fetch_cached = display_word_cached0 || display_word_cached1;
    wire prefetch_cached = prefetch_word_cached0 || prefetch_word_cached1;
    wire [18:0] video_fetch_target = video_fetch_cached ? prefetch_word_addr : fetch_word_addr;
    wire video_fetch_valid = video_en && !blanking &&
                             ((!video_fetch_cached && (fetch_word_addr < VRAM_SIZE)) ||
                              (prefetch_visible && !prefetch_cached && (prefetch_word_addr < VRAM_SIZE)));

    // ========================================================================
    // SDRAM state machine — video fetch + CPU access
    // ========================================================================
    localparam S_IDLE               = 4'd0;
    localparam S_VIDEO_FETCH        = 4'd1;
    localparam S_VIDEO_WAIT         = 4'd2;
    localparam S_CPU_WRITE          = 4'd3;
    localparam S_CPU_WRITE_WAIT     = 4'd4;
    localparam S_CPU_READ           = 4'd5;
    localparam S_CPU_READ_WAIT      = 4'd6;
    localparam S_CPU_RMW_READ       = 4'd7;
    localparam S_CPU_RMW_READ_WAIT  = 4'd8;
    localparam S_CPU_RMW_WRITE      = 4'd9;

    reg [3:0] state;
    reg [18:0] cpu_write_word;
    reg [15:0] cpu_write_data;
    reg [15:0] cpu_write_merged;
    reg [1:0] cpu_write_strobes;

    wire [18:0] cpu_vram_word = addr[19:1];  // CPU byte addr → word addr

    // ========================================================================
    // Address decode for card-local space
    //
    // MAME card_map (all mirrored at $F00000 intervals — bits 23:20 ignored):
    //   $x0_0000 - $x7_FFFF  VRAM         (addr[19]=0)
    //   $x8_0000 - $x8_FFFF  TFB regs     (addr[19:16]=8)
    //   $x9_0000 - $x9_FFFF  RAMDAC+VBL   (addr[19:16]=9)
    //   $xA_0000 - $xA_FFFF  VBL control  (addr[19:16]=A)
    //
    // Declaration ROM (mirrored across entire 16MB slot space, like MAME):
    //   Any unmatched read returns ROM data (addr[14:0] selects within 32KB window)
    // ========================================================================
    // ROM is now mirrored across entire slot space (fallback for any unmatched read)
    wire addr_is_vram   = !addr[19];                         // $x0_0000 - $x7_FFFF
    wire addr_is_regs   = (addr[19:16] == 4'h8);            // $x8_xxxx
    wire addr_is_ramdac = (addr[19:16] == 4'h9);            // $x9_xxxx
    wire addr_is_vblctl = (addr[19:16] == 4'hA);            // $xA_xxxx

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
            vram_cache0 <= 16'd0;
            vram_cache1 <= 16'd0;
            vram_cache0_word <= 19'h7FFFF;
            vram_cache1_word <= 19'h7FFFF;
            vram_cache0_valid <= 1'b0;
            vram_cache1_valid <= 1'b0;
            vram_cache_replace <= 1'b0;
            video_fetch_word <= 19'd0;
            cpu_write_word <= 19'd0;
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
            ramdac_addr <= 8'd0;
            ramdac_rgb <= 2'd0;
            ramdac_last_addr <= 32'd0;
            ramdac_last_data <= 16'd0;
            ramdac_dup_phase <= 1'b0;
            vbl_disable <= 1'b1;
            for (i = 0; i < 16; i = i + 1)
                registers[i] <= 32'd0;
        end else begin
            // Ack delay countdown
            if (ack_delay > 3'd0)
                ack_delay <= ack_delay - 3'd1;
            if (ack_delay == 3'd1)
                ack_n <= 1'b0;

            case (state)
                S_VIDEO_FETCH: begin
                    state <= S_VIDEO_WAIT;
                end

                S_VIDEO_WAIT: begin
                    if (vram_ready) begin
                        if (vram_cache_replace) begin
                            vram_cache1 <= vram_din;  // Raw data — NOT inverted for display
                            vram_cache1_word <= video_fetch_word;
                            vram_cache1_valid <= 1'b1;
                        end else begin
                            vram_cache0 <= vram_din;  // Raw data — NOT inverted for display
                            vram_cache0_word <= video_fetch_word;
                            vram_cache0_valid <= 1'b1;
                        end
                        vram_cache_replace <= ~vram_cache_replace;
                        vram_rd <= 1'b0;
                        state <= S_IDLE;
                    end
                end

                S_IDLE: begin
                    vram_rd <= 1'b0;
                    vram_wr <= 1'b0;

                    if (cpu_as_n && !ack_n) begin
                        ack_n <= 1'b1;
                        ack_delay <= 3'd0;
                    end else if (select && in_our_slot && !ack_n && ack_delay == 3'd0 && bus_key_changed) begin
                        ack_n <= 1'b1;
                    end

                    // Priority: CPU access > opportunistic video fetch.  This
                    // still is not a full local-VRAM scanout model, but it keeps
                    // boot timing stable while the NuBus write path is tested.
                    // VRAM/regs/RAMDAC/VBL checked first; ROM is fallback
                    // (MAME: mirror_all_mb=true mirrors ROM across entire 16MB slot space)
                    if (!cpu_as_n && select && in_our_slot && ack_n && ack_delay == 3'd0) begin
                        ack_addr <= addr;
                        ack_data_in <= data_in;
                        ack_uds_lds <= uds_lds;
                        ack_rw_n <= rw_n;
                        // synthesis translate_off
`ifdef SIMULATION
                        if ($test$plusargs("nubus_debug")) begin
                            if (addr_is_regs && !rw_n)
                                $display("NUBUS: WR REG[%0d] addr=%h data_in=%h addr[1]=%b",
                                    addr[5:2], addr, data_in, addr[1]);
                            else if (addr_is_ramdac && !rw_n)
                                $display("NUBUS: WR RAMDAC addr=%h addr[2]=%b data=%h rgb=%0d clut_addr=%0d",
                                    addr, addr[2], data_in, ramdac_rgb, ramdac_addr);
                            else if (addr_is_vblctl)
                                $display("NUBUS: WR VBL_CTL addr=%h addr[4]=%b", addr, addr[4]);
                            else if (addr_is_vram && !rw_n)
                                ; // too noisy - uncomment if needed
                            else if (addr_is_ramdac && rw_n)
                                $display("NUBUS: RD RAMDAC/VBL addr=%h", addr);
                            else if (rw_n)
                                $display("NUBUS: RD ROM addr=%h rom_word[%0d]=%h raw=%h out=%h lane=%0d data_out=%h",
                                    addr, addr[14:3], rom[addr[14:3]], rom_byte_raw, rom_byte_out,
                                    addr[1:0], rom_lane_valid ? {rom_byte_out, 8'hFF} : 16'hFFFF);
                        end
`endif
                        // synthesis translate_on
                        // ---------------------------------------------------
                        // VRAM write ($x0_0000 - $x7_FFFF)
                        // ---------------------------------------------------
                        if (!rw_n && addr_is_vram) begin
                            if (cpu_vram_word < VRAM_SIZE) begin
                                vram_addr <= VRAM_BASE + {6'd0, cpu_vram_word};
                                cpu_write_word <= cpu_vram_word;
                                cpu_write_data <= ~data_in;  // Invert on write (MAME: data ^= 0xFFFFFFFF)
                                cpu_write_strobes <= uds_lds;
                                if (uds_lds == 2'b11) begin
                                    cpu_write_merged <= ~data_in;
                                    vram_dout <= ~data_in;
                                    // Apple NuBus longword transfers through a 16-bit local
                                    // interface are presented as two halfword operations
                                    // (+0 then +2). Store only the addressed halfword here;
                                    // the following bus cycle supplies the other half.
                                    // synthesis translate_off
`ifdef SIMULATION
                                    if ($test$plusargs("nubus_vram_debug") && vram_debug_count < 240) begin
                                        $display("NUBUS_VRAM_WR addr=%h word=%h data=%h stored=%h strobes=%b long=%b",
                                            addr, cpu_vram_word, data_in, ~data_in, uds_lds, cpu_longword);
                                        vram_debug_count = vram_debug_count + 1;
                                    end
`endif
                                    // synthesis translate_on
                                    state <= S_CPU_WRITE;
                                end else if (uds_lds != 2'b00) begin
                                    // synthesis translate_off
`ifdef SIMULATION
                                    if ($test$plusargs("nubus_vram_debug") && vram_debug_count < 240) begin
                                        $display("NUBUS_VRAM_RMW addr=%h word=%h data=%h strobes=%b long=%b",
                                            addr, cpu_vram_word, data_in, uds_lds, cpu_longword);
                                        vram_debug_count = vram_debug_count + 1;
                                    end
`endif
                                    // synthesis translate_on
                                    state <= S_CPU_RMW_READ;
                                end else begin
                                    ack_delay <= 3'd2;
                                end
                            end else begin
                                ack_delay <= 3'd2;
                            end
                        end
                        // ---------------------------------------------------
                        // VRAM read
                        // ---------------------------------------------------
                        else if (rw_n && addr_is_vram) begin
                            if (cpu_vram_word < VRAM_SIZE) begin
                                vram_addr <= VRAM_BASE + {6'd0, cpu_vram_word};
                                state <= S_CPU_READ;
                            end else begin
                                data_out <= 16'hFFFF;
                                ack_delay <= 3'd2;
                            end
                        end
                        // ---------------------------------------------------
                        // TFB register write ($x8_xxxx)
                        //
                        // MAME: data ^= 0xFFFFFFFF; data = swapendian_int32(data);
                        // On 16-bit bus: invert + byte-swap each 16-bit half,
                        // then swap which half goes where:
                        //   addr[1]==0 (high word from CPU) → reg[15:0]
                        //   addr[1]==1 (low word from CPU)  → reg[31:16]
                        // ---------------------------------------------------
                        else if (!rw_n && addr_is_regs) begin
                            if (addr[15:6] == 10'd0) begin  // Registers 0-15
                                // Invert + byte-swap the 16-bit value
                                // {~lo_byte, ~hi_byte}
                                if (addr[1] == 1'b0)
                                    registers[addr[5:2]][15:0] <= {~data_in[7:0], ~data_in[15:8]};
                                else
                                    registers[addr[5:2]][31:16] <= {~data_in[7:0], ~data_in[15:8]};
                            end
                            ack_delay <= 3'd2;
                        end
                        // ---------------------------------------------------
                        // TFB register read (rarely used)
                        // ---------------------------------------------------
                        else if (rw_n && addr_is_regs) begin
                            data_out <= 16'h0000;
                            ack_delay <= 3'd2;
                        end
                        // ---------------------------------------------------
                        // RAMDAC write ($x9_xxxx)
                        //
                        // MAME: data ^= 0xFFFFFFFF; offset & 1 selects function
                        // 32-bit word offset → addr[2] on 16-bit bus
                        //   addr[2]==0: address_w — set palette index
                        //   addr[2]==1: palette_w — write R,G,B sequentially
                        //
                        // Data byte: upper byte lane (data_in[15:8]) for
                        // byte-wide NuBus peripherals at even addresses.
                        // ---------------------------------------------------
                        else if (!rw_n && addr_is_ramdac) begin
                            if (ramdac_dup_phase && ramdac_last_addr == addr && ramdac_last_data == data_in) begin
                                ramdac_dup_phase <= 1'b0;
                            end else begin
                                ramdac_last_addr <= addr;
                                ramdac_last_data <= data_in;
                                ramdac_dup_phase <= 1'b1;

                                if (addr[2] == 1'b0) begin
                                    // Set RAMDAC address, reset RGB counter
                                    ramdac_addr <= ~data_in[15:8];
                                    ramdac_rgb <= 2'd0;
                                end else begin
                                    // Write palette R/G/B sequentially
                                    case (ramdac_rgb)
                                        2'd0: clut[ramdac_addr][23:16] <= ~data_in[15:8]; // R
                                        2'd1: clut[ramdac_addr][15:8]  <= ~data_in[15:8]; // G
                                        2'd2: begin
                                            clut[ramdac_addr][7:0] <= ~data_in[15:8];     // B
                                            ramdac_addr <= ramdac_addr + 8'd1;            // Auto-increment
                                        end
                                        default: ;
                                    endcase
                                    ramdac_rgb <= (ramdac_rgb == 2'd2) ? 2'd0 : ramdac_rgb + 2'd1;
                                end
                            end
                            ack_delay <= 3'd2;
                        end
                        // ---------------------------------------------------
                        // VBL status + RAMDAC read ($x9_xxxx)
                        //
                        // MAME vblank_r: offset 0x10/4 returns
                        //   (vblank << 16) | (1 << 17)
                        // On 16-bit bus:
                        //   High word (addr[1]==0): {14'd0, 1'b1, vblank}
                        //   Low word (addr[1]==1):  16'd0
                        // All other offsets return 0.
                        // ---------------------------------------------------
                        else if (rw_n && addr_is_ramdac) begin
                            if (addr[15:2] == 14'h0004) begin  // Byte offset $10
                                if (addr[1] == 1'b0)
                                    data_out <= {14'd0, 1'b1, (v_cnt >= V_RES) ? 1'b1 : 1'b0};
                                else
                                    data_out <= 16'd0;
                            end else begin
                                data_out <= 16'd0;
                            end
                            // synthesis translate_off
`ifdef SIMULATION
                            if ($test$plusargs("vbl_debug") && vbl_debug_count < 240) begin
                                $display("NUBUS_VBL_R addr=%h data=%h h=%0d v=%0d vblank=%b irq=%b dis=%b",
                                    addr,
                                    (addr[15:2] == 14'h0004) ? (addr[1] ? 16'h0000 : {14'd0, 1'b1, (v_cnt >= V_RES) ? 1'b1 : 1'b0}) : 16'h0000,
                                    h_cnt, v_cnt, (v_cnt >= V_RES), irq_active, vbl_disable);
                                vbl_debug_count = vbl_debug_count + 1;
                            end
`endif
                            // synthesis translate_on
                            ack_delay <= 3'd2;
                        end
                        // ---------------------------------------------------
                        // VBL interrupt control write ($xA_xxxx)
                        //
                        // MAME: offset & 4 (32-bit word offset) → addr[4]
                        //   addr[4]==0: enable VBL, clear pending IRQ
                        //   addr[4]==1: disable VBL
                        // ---------------------------------------------------
                        else if (!rw_n && addr_is_vblctl) begin
                            if (addr[4]) begin
                                vbl_disable <= 1'b1;
                            end else begin
                                vbl_disable <= 1'b0;
                                irq_clear <= 1'b1;
                            end
                            // synthesis translate_off
`ifdef SIMULATION
                            if ($test$plusargs("vbl_debug") && vbl_debug_count < 240) begin
                                $display("NUBUS_VBL_W addr=%h data=%h h=%0d v=%0d irq=%b dis=%b clear=%b",
                                    addr, data_in, h_cnt, v_cnt, irq_active, vbl_disable, !addr[4]);
                                vbl_debug_count = vbl_debug_count + 1;
                            end
`endif
                            // synthesis translate_on
                            ack_delay <= 3'd2;
                        end
                        // ---------------------------------------------------
                        // Default: ROM read (mirrored across entire slot space)
                        // Any unmatched read returns declaration ROM data.
                        // Writes to unknown addresses are silently acked.
                        // ---------------------------------------------------
                        else if (rw_n) begin
                            // ROM read — rom_rdata available next cycle (synchronous)
                            ack_delay <= 3'd3;
                            rom_read_pending <= 1'b1;
                        end
                        else begin
                            ack_delay <= 3'd2;
                        end

                    // synthesis translate_off
                    // Uncomment for NuBus slot debug:
                    // end else if (select && !in_our_slot && ack_n && ack_delay == 3'd0) begin
                    //     $display("NUBUS: SELECT but NOT our slot! addr=%h [31:28]=%h [27:24]=%h",
                    //         addr, addr[31:28], addr[27:24]);
                    // synthesis translate_on
                    end else if ((!select || cpu_as_n) && !ack_n) begin
                        // CPU deasserted select — end transaction
                        ack_n <= 1'b1;
                        ack_delay <= 3'd0;

                    end
                    // Scanout no longer fetches through this (CPU) port -- it
                    // reads directly from the dedicated VRAM port B.  So port A
                    // (this FSM) is CPU-only now; the old S_VIDEO_FETCH path is
                    // retired (the 2-word cache + opportunistic fetch caused the
                    // stale-word garbling).
                end

                S_CPU_WRITE: begin
                    vram_wr <= 1'b1;
                    state <= S_CPU_WRITE_WAIT;
                end

                S_CPU_WRITE_WAIT: begin
                    if (vram_ready) begin
                        if (vram_cache0_valid && vram_cache0_word == cpu_write_word)
                            vram_cache0 <= cpu_write_merged;
                        if (vram_cache1_valid && vram_cache1_word == cpu_write_word)
                            vram_cache1 <= cpu_write_merged;
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
                        data_out <= ~vram_din;  // CPU reads inverted (MAME: vram ^ 0xFFFFFFFF)
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

            // Latch ROM read data one cycle before ack
            // Byte lane 0: ROM data on D15-D8, $FF on D7-D0.
            // Non-lane-0 addresses return $FFFF (empty lanes).
            if (ack_delay == 3'd2 && rom_read_pending) begin
                data_out <= rom_lane_valid ? {rom_byte_out, 8'hFF} : 16'hFFFF;
                rom_read_pending <= 1'b0;
            end
        end
    end

    // ========================================================================
    // Pixel output pipeline
    //
    // MAME screen_update reads raw VRAM bytes (which store inverted CPU data)
    // and uses them as CLUT indices. The RAMDAC palette compensates for the
    // inversion — the ROM driver programs pen[0]=white, pen[1]=black for 1bpp.
    //
    // We read raw SDRAM data into an address-tagged cache (no inversion) and
    // extract pixel indices based on mode, then look up in CLUT.
    // ========================================================================

    // Delay h_cnt bits and byte select for pipeline alignment
    reg [2:0] h_cnt_d;
    reg byte_sel_d;
    reg blanking_d;
    reg display_word_cached_d;
    reg vram_cache_any_valid_d;
    reg [15:0] display_cache_word_d;

    wire [15:0] display_cache_word =
        display_word_cached0 ? vram_cache0 :
        display_word_cached1 ? vram_cache1 :
        vram_cache1_valid ? vram_cache1 : vram_cache0;

    always @(posedge clk) begin
        if (clk_video_en) begin
            h_cnt_d <= h_cnt[2:0];
            display_word_cached_d <= video_fetch_cached;
            vram_cache_any_valid_d <= vram_cache0_valid || vram_cache1_valid;
            display_cache_word_d <= display_cache_word;
            // Big-endian: high byte first. byte_sel=0 -> [15:8], byte_sel=1 -> [7:0]
            byte_sel_d <= fetch_byte_sel;
            blanking_d <= blanking;
        end
    end

    // Scanout reads straight from the dedicated VRAM port B (vram_scan_data,
    // registered in the BRAM on clk_video_en) -- always the correct word,
    // aligned with byte_sel_d/h_cnt_d.  No cache, so no stale-word garbling.
    wire [7:0] vram_byte = byte_sel_d ? vram_scan_data[7:0] : vram_scan_data[15:8];

    // Extract pixel index from byte based on mode
    reg [7:0] pixel_idx;
    always @(*) begin
        pixel_idx = 8'd0;
        case (mode)
            2'd0: begin  // 1bpp: 8 pixels per byte, index 0-1
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
            2'd1: begin  // 2bpp: 4 pixels per byte, index 0-3
                case (h_cnt_d[1:0])
                    2'd0: pixel_idx = {6'd0, vram_byte[7:6]};
                    2'd1: pixel_idx = {6'd0, vram_byte[5:4]};
                    2'd2: pixel_idx = {6'd0, vram_byte[3:2]};
                    2'd3: pixel_idx = {6'd0, vram_byte[1:0]};
                endcase
            end
            2'd2: begin  // 4bpp: 2 pixels per byte, index 0-15
                pixel_idx = h_cnt_d[0] ? {4'd0, vram_byte[3:0]}
                                       : {4'd0, vram_byte[7:4]};
            end
            2'd3: begin  // 8bpp: 1 pixel per byte, index 0-255
                pixel_idx = vram_byte;
            end
        endcase
    end

    // CLUT lookup and output.  Scanout data is always available from VRAM port
    // B, so validity is just enable + active region (no cache-hit dependency).
    wire pixel_valid = video_en && !blanking_d;
    wire mono_mode = DEFAULT_MONOCHROME || monochrome;
    wire [7:0] mono_pixel = pixel_idx[0] ? 8'h22 : 8'hee;
    assign vga_r = pixel_valid ? (mono_mode ? mono_pixel : clut[pixel_idx][23:16]) : 8'd0;
    assign vga_g = pixel_valid ? (mono_mode ? mono_pixel : clut[pixel_idx][15:8])  : 8'd0;
    assign vga_b = pixel_valid ? (mono_mode ? mono_pixel : clut[pixel_idx][7:0])   : 8'd0;

    // ========================================================================
    // Debug: video pipeline state (synthesis translate_off)
    // ========================================================================
    // synthesis translate_off
`ifdef SIMULATION
    reg debug_printed_regs;
    reg [10:0] debug_prev_v_cnt;
    initial begin
        debug_printed_regs = 0;
        debug_prev_v_cnt = 0;
    end

    always @(posedge clk) begin
        // Print register state once when video_en first goes high
        if ($test$plusargs("video_debug") && video_en && !debug_printed_regs) begin
            debug_printed_regs <= 1;
            $display("VIDEO_EN: video enabled! mode_raw=%0d mode=%0d base=%0d stride=%0d",
                mode_raw, mode, vram_base_offset, vram_stride);
            $display("VIDEO_EN: CLUT[0]=%h CLUT[1]=%h CLUT[255]=%h",
                clut[0], clut[1], clut[255]);
        end

        // Print first few pixels of each new frame (v_cnt==0, h_cnt < 16)
        if ($test$plusargs("video_debug") && clk_video_en && video_en && v_cnt == 0 && h_cnt < 16 && debug_prev_v_cnt != 0) begin
            $display("VIDEO_PIX: h=%0d v=%0d word=%h cached=%b byte_sel=%b vram_byte=%h pixel_idx=%0d rgb=%h%h%h",
                h_cnt, v_cnt, fetch_word_addr,
                display_word_cached_d, byte_sel_d,
                vram_byte, pixel_idx, vga_r, vga_g, vga_b);
        end

        if (clk_video_en)
            debug_prev_v_cnt <= v_cnt;
    end
`endif
    // synthesis translate_on

    // ========================================================================
    // JTAG debug exposures (hardware black-screen diagnosis)
    // ========================================================================
    assign dbg_video_en = video_en;

    reg [15:0] vram_wr_cnt_r;      // CPU VRAM writes (Mac drawing the framebuffer)
    reg [15:0] vram_fetch_cnt_r;   // completed video VRAM fetches (scanout reads)
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
            if (vram_wr && !vram_wr_d)               // rising edge: a VRAM write
                vram_wr_cnt_r <= vram_wr_cnt_r + 16'd1;
            if (state == S_VIDEO_WAIT && vram_ready)  // a video fetch completed
                vram_fetch_cnt_r <= vram_fetch_cnt_r + 16'd1;
        end
    end

endmodule
