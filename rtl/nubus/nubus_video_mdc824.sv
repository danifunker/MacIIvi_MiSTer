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
//   * Resolution is chosen by the ROM reading MONITOR SENSE lines; the
//     monitor_512 input (OSD "Monitor" option) selects which monitor we
//     advertise: 0 = Macintosh 14" hi-res 640x480, sense [6,2,4,6];
//     1 = Macintosh 12" RGB 512x384, sense [2,2,0,2] (Snow MacMonitor codes).
//     A change takes effect on the next Mac reboot (Slot Manager re-probe).
//   * bpp comes from the RAMDAC control register mode field.
//
// The data-plane backend (dual-port VRAM-in-BRAM, port-B scanout, pixel
// extraction, NuBus halfword/ACK handling) is carried over from
// nubus_video_highres.sv.
//
// 1/2/4/8 bpp are supported (VRAM_WORDS BRAM words; 8 bpp @ 640x480 needs
// 300 KB).  24 bpp (RAMDAC mode 0xD, "Millions") is supported on the
// VRAM_WORDS==0 (SDRAM/DDR-backed) configuration: the real card stores
// direct colour PACKED, 3 bytes per pixel — 640x480 = 900 KB, which is why
// the 341-0868 ROM offers Millions on the 1 MB card. Control bit 2 switches
// the CPU aperture to the packed view (4-byte XRGB bus pixels <-> 3 stored
// bytes; MAME nubus_48gc.cpp jmfb rgb_pack/rgb_unpack — that file is the
// UNACCELERATED 4*8/8*24 JMFB despite its name, and matches this card's
// register map and $0C02 ctrl golden; Snow's mdc12 24bpp is a 4-byte
// simplification that needs >1 MB and disagrees with the ROM's own capacity
// math). Legacy BRAM configs keep the old 0xD->8bpp fallback.

module nubus_video_mdc824 #(
    parameter SLOT_ID = 4'hE,
    parameter DEFAULT_MONOCHROME = 1'b0,
    parameter integer VRAM_WORDS = 196608,  // 16-bit words of card VRAM in BRAM (384 KB)
    // Total card size PRESENTED to the machine. The IIvi ROM's Slot Manager
    // (unlike the Mac II's) hard-fails the card when PrimaryInit's VRAM
    // sizing probe (write $AAAAAAAA @ byte $F4B00, read back) misses — the
    // 2026-07-11 sad Mac $0F/$33 (smRecNotFnd). Words [VRAM_WORDS,
    // TOTAL_WORDS) are the COLD TAIL: CPU-accessible via the ext_* port
    // (SDRAM window at word $100000), never scanned out. The visible
    // framebuffer (8bpp @ 640x480 = 300KB) always fits the BRAM portion.
    parameter integer TOTAL_WORDS = 524288  // 1MB — the real card's default config
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

    // VRAM Port A — CPU read/write (via FSM), BRAM portion (word < VRAM_WORDS)
    output reg [24:0] vram_addr,
    output reg [15:0] vram_dout,
    input [15:0] vram_din,
    output vram_rd,
    output vram_wr,
    output [1:0] vram_ds,     // write byte strobes ([1]=high/even, [0]=low/odd)
    input vram_ready,

    // Cold-tail port — CPU read/write of words [VRAM_WORDS, TOTAL_WORDS).
    // Same handshake as the BRAM port; the top maps ext_word into the SDRAM
    // window at word $100000 and answers with ext_din/ext_ready. Shares
    // vram_dout for write data. ext_word = vram_addr[19:0] (card word).
    output ext_rd,
    output ext_wr,
    output [1:0] ext_ds,      // write byte strobes (same lanes as vram_ds)
    input [15:0] ext_din,
    input ext_ready,

    // VRAM Port B — dedicated scanout read (no cache, never misses).
    // Only used when VRAM_WORDS != 0 (BRAM-backed scanout).
    output     [24:0] vram_scan_addr,
    output            vram_scan_rd,
    input      [15:0] vram_scan_data,

    // Scanline prefetch port — only used when VRAM_WORDS == 0 (VRAM fully
    // SDRAM-backed, docs/VRAM_1MB_OPTIONS.md Option A). At the start of each
    // line the card requests the NEXT visible line's words; mdc_scan_fetch
    // streams them back on scan_wr/scan_wdata into the internal 2-line
    // ping-pong buffer that scanout reads instead of port B.
    output            scan_start,   // 1-clk pulse: fetch a line
    output     [19:0] scan_base,    // card word address of the line start
    output     [9:0]  scan_words,   // words to fetch
    input             scan_wr,      // 1-clk: scan_wdata = next word of the line
    input      [15:0] scan_wdata,
    input             scan_wr2,     // pair lane: scan_wdata2 = the word after
    input      [15:0] scan_wdata2,  //   (even/odd sub-banks absorb 2 words/clk)
    output     [15:0] dbg_scan_underrun,  // lines scanned out before their fetch completed

    // IOCTL Interface for ROM Download
    input        ioctl_wr,
    input [24:0] ioctl_addr,
    input [15:0] ioctl_data,
    input        ioctl_download,
    input [7:0]  ioctl_index,

    // Overlay control (MiSTer OSD)
    input        overlay_en,
    input        monochrome,
    input        monitor_512,   // OSD monitor select: 0=640x480 13", 1=512x384 12"

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
    // parity with the hi-res card.  Size comes from the VRAM_WORDS parameter
    // (set in LBMacTwo.sv, same value as the vram_ram instance) — accesses
    // beyond it are acked-and-dropped / read $FFFF so the declaration ROM's
    // VRAM probe sees the real size.
    localparam VRAM_BASE = 25'h300000;

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
    // MacIIvi repo path: the 341-0868 declaration ROM lives at
    // rtl/nubus/mdc824_rom.hex (byte-verified against ../mdc824.rom).
    // The sim runs with CWD = a direct child of the repo root (verilator/
    // or a sim*run/ dir); Quartus resolves relative to the project root.
`ifdef SIMULATION
    initial $readmemh("../rtl/nubus/mdc824_rom.hex", rom);
`else
    initial $readmemh("rtl/nubus/mdc824_rom.hex", rom);
`endif

    reg [15:0] rom_word;
    always @(posedge clk)
        rom_word <= rom[local_addr[16:3]];
    wire [7:0] rom_rdata = local_addr[2] ? rom_word[7:0] : rom_word[15:8];

    // Lane-3 byte visibility on the 16-bit bus: the byte at longword offset
    // 3 (A1:A0 == 11) is the LOW (LDS) byte of the A1==1 half-word. It must
    // be served for BYTE reads at the odd address AND for WORD reads at
    // A1==1 (A0==0, LDS strobed) — the Slot Manager's sResource/driver
    // copies use word/long accesses, and the old A0-inclusive compare
    // (local_addr[1:0]==2'b11) returned $FF for every such read, corrupting
    // the copied driver code -> sad Mac $0F/$33 after PrimaryInit
    // (2026-07-11; mdc_bench word-read case). D[15:8] (byte 2, lane 2) is
    // always open ($FF) on this lane-3 card.
    wire rom_lane_valid = local_addr[1] && uds_lds[0];

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

    // ---- Monitor sense (Snow MacMonitor::sense codes):
    //   Macintosh 14" hi-res (640x480) = [6,2,4,6]
    //   Macintosh 12" RGB   (512x384) = [2,2,0,2]
    wire [2:0] msense0 = monitor_512 ? 3'd2 : 3'd6;
    wire [2:0] msense1 = monitor_512 ? 3'd2 : 3'd2;
    wire [2:0] msense2 = monitor_512 ? 3'd0 : 3'd4;
    wire [2:0] msense3 = monitor_512 ? 3'd2 : 3'd6;
    // ctrl sense_in0=bit11, sense_in1=bit10, sense_in2=bit9 gate the AND.
    wire [2:0] sense_val =
        msense0 & (ctrl[11] ? msense1 : 3'b111)
                & (ctrl[10] ? msense2 : 3'b111)
                & (ctrl[9]  ? msense3 : 3'b111);
    // Control read-back: sense_out occupies bits [11:9].
    wire [7:0] ctrl_high_sense = {ctrl[15:12], sense_val, ctrl[8]};

    // bpp / pixel mode from RAMDAC control field (bits [4:1])
    wire [3:0] rmode = ramdac_ctrl[4:1];
    // Map to the pipeline mode (0=1bpp,1=2bpp,2=4bpp,3=8bpp,4=24bpp).
    // 24bpp renders only on the VRAM_WORDS==0 scanout (the line-buffer path
    // can gather 3 bytes/pixel); BRAM port-B configs keep the 0xD->8bpp
    // fallback they always had.
    /* verilator lint_off UNSIGNED */
    /* verilator lint_off CMPCONST */
    wire [2:0] mode = (rmode == 4'h0) ? 3'd0 :
                      (rmode == 4'h4) ? 3'd1 :
                      (rmode == 4'h8) ? 3'd2 :
                      ((rmode == 4'hD) && (VRAM_WORDS == 0)) ? 3'd4 :
                      3'd3;  // 0xC (and 0xD on BRAM configs) -> 8bpp
    /* verilator lint_on CMPCONST */
    /* verilator lint_on UNSIGNED */
    wire mode24 = (mode == 3'd4);

    // ========================================================================
    // Pixel clock (fractional accumulator). clk here is THIS core's clk_sys =
    // 32.5 MHz; the modulus is that clock in kHz, so the increment is the
    // pixel rate in kHz exactly:
    //   640x480 13": 31.360 MHz on the 896x525 raster below = 66.666 Hz, the
    //                Apple 13" refresh (a real 8*24 does 30.24 MHz on 864x525
    //                = 66.667 Hz; we keep the wider heritage raster and match
    //                REFRESH, not dot clock)
    //   512x384 12": 15.667 MHz on 640x407 = 60.147 Hz (the Apple 12" RGB
    //                rate)
    // History (2026-07-15 clock audit): the modulus was 31334 — carried from
    // lbmactwo, whose clk_sys IS 31.3344 MHz. On our 32.5 MHz that scanned
    // +3.72% fast: 512x384 refreshed at 62.4 Hz instead of 60.15 (640x480
    // happened to land on 66.68 Hz because the wide 896-dot raster nearly
    // cancelled the error).
    // ========================================================================
    wire [15:0] clk_video_inc = monitor_512 ? 16'd15667 : 16'd31360;
    reg [15:0] clk_video_acc;
    reg clk_video_en;
    always @(posedge clk) begin
        if (reset) begin
            clk_video_acc <= 16'd0;
            clk_video_en <= 1'b0;
        end else begin
            if (clk_video_acc + clk_video_inc >= 16'd32500) begin
                clk_video_acc <= clk_video_acc + clk_video_inc - 16'd32500;
                clk_video_en <= 1'b1;
            end else begin
                clk_video_acc <= clk_video_acc + clk_video_inc;
                clk_video_en <= 1'b0;
            end
        end
    end
    assign vga_clk = clk;
    assign ce_pixel = clk_video_en;

    // ========================================================================
    // Video timing, selected by monitor_512:
    //   640x480 (Macintosh 14" hi-res): 896x525 total @ 30.24 MHz
    //   512x384 (Macintosh 12" RGB):    640x407 total @ 15.6672 MHz
    //     (24.48 kHz / 60.15 Hz — the Apple 12" RGB scan rates)
    // ========================================================================
    wire [10:0] h_total      = monitor_512 ? 11'd640 : 11'd896;
    wire [10:0] h_res        = monitor_512 ? 11'd512 : 11'd640;
    wire [10:0] v_total      = monitor_512 ? 11'd407 : 11'd525;
    wire [10:0] v_res        = monitor_512 ? 11'd384 : 11'd480;
    wire [10:0] h_sync_start = monitor_512 ? 11'd528 : 11'd672;   // res + front porch
    wire [10:0] h_sync_end   = monitor_512 ? 11'd560 : 11'd736;   // + sync width
    wire [10:0] v_sync_start = monitor_512 ? 11'd385 : 11'd483;
    wire [10:0] v_sync_end   = monitor_512 ? 11'd388 : 11'd486;

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
            if (h_cnt >= h_total - 11'd1) begin
                h_cnt <= 11'd0;
                if (v_cnt >= v_total - 11'd1)
                    v_cnt <= 11'd0;
                else
                    v_cnt <= v_cnt + 11'd1;
            end else begin
                h_cnt <= h_cnt + 11'd1;
            end
            vga_hs_reg <= ~(h_cnt >= h_sync_start && h_cnt < h_sync_end);
            vga_vs_reg <= ~(v_cnt >= v_sync_start && v_cnt < v_sync_end);
            blanking <= (h_cnt >= h_res) || (v_cnt >= v_res);
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
    wire vbl_pulse = clk_video_en && (h_cnt == 0) && (v_cnt == v_res - 11'd1);
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
    //
    // Two scanout backends, selected by VRAM_WORDS (compile-time):
    //   != 0 : legacy BRAM port B — word fetched per pixel clock (unchanged).
    //   == 0 : SDRAM-backed (Option A) — a prefetch engine fetches the NEXT
    //          visible line into a 2x512-word ping-pong line buffer while the
    //          current line scans out of the other bank. base/stride are
    //          32-byte/4-byte units, so a line always starts byte-even and
    //          the in-line byte select reduces to h_byte[0].
    // ========================================================================
    // Direct (24bpp) units per MAME jmfb update_screen: base is 64-byte
    // increments (<<6) and stride 8-byte increments (<<3); indexed modes
    // keep the historical 32-byte / 4-byte units.
    wire [24:0] base_bytes   = mode24 ? {base_reg[18:0], 6'b000000}
                                      : {base_reg[19:0], 5'b00000};
    wire [13:0] stride_bytes = mode24 ? {stride_reg[10:0], 3'b000}
                                      : {stride_reg[11:0], 2'b00};

    wire [9:0] h_byte =
        (mode == 3'd0) ? {3'd0, h_cnt[9:3]} :     // 1bpp: h/8
        (mode == 3'd1) ? {2'd0, h_cnt[9:2]} :     // 2bpp: h/4
        (mode == 3'd2) ? {1'd0, h_cnt[9:1]} :     // 4bpp: h/2
                         h_cnt[9:0];              // 8bpp: h (24bpp has its own math)

    wire        fetch_byte_sel;
    wire [15:0] scan_word_q;      // scanout word (registered, 1 clk_video_en late)
    wire [7:0]  scan24_r, scan24_g, scan24_b;  // 24bpp gathered pixel (same latency)

    generate if (VRAM_WORDS != 0) begin : scan_bram

        wire [24:0] v_byte_offset  = v_cnt[9:0] * stride_bytes;
        wire [24:0] fetch_byte_addr = base_bytes + v_byte_offset + {15'd0, h_byte};
        wire [23:0] fetch_word_addr = fetch_byte_addr[24:1];
        assign fetch_byte_sel = fetch_byte_addr[0];

        assign vram_scan_addr = VRAM_BASE + {1'b0, fetch_word_addr};
        assign vram_scan_rd   = clk_video_en;
        assign scan_word_q    = vram_scan_data;

        assign scan_start = 1'b0;
        assign scan_base  = 20'd0;
        assign scan_words = 10'd0;
        assign dbg_scan_underrun = 16'd0;
        assign scan24_r = 8'd0;   // 24bpp never renders on the BRAM path
        assign scan24_g = 8'd0;
        assign scan24_b = 8'd0;

    end else begin : scan_sdram

        assign vram_scan_addr = 25'd0;
        assign vram_scan_rd   = 1'b0;
        assign fetch_byte_sel = h_byte[0];   // line starts are always byte-even

        // words per visible line for the current depth (24bpp: 3 bytes per
        // pixel packed -> h_res*3/2 words; 640 -> 960, 512 -> 768)
        wire [9:0] half_res = h_res[10:1];   // h_res is even
        wire [9:0] line_words = (mode == 3'd0) ? {4'b0, h_res[9:4]} :
                                (mode == 3'd1) ? {3'b0, h_res[9:3]} :
                                (mode == 3'd2) ? {2'b0, h_res[9:2]} :
                                mode24         ? (half_res + half_res + half_res) :
                                                 {1'b0, h_res[9:1]};

        // the line to prefetch: TWO lines ahead of the one starting now
        // (v2, 2026-08-07 HW finding — one line time was not enough budget
        // under a saturating CPU; two line-times + the released-window
        // supply in sdram.v covers 8bpp with margin), wrapping so lines
        // 0 and 1 are fetched while raster lines v_total-2 / v_total-1 scan
        wire [9:0]  next2_line = (v_cnt == v_total - 11'd2) ? 10'd0 :
                                 (v_cnt == v_total - 11'd1) ? 10'd1 :
                                 (v_cnt[9:0] + 10'd2);
        wire        next2_visible = ({1'b0, next2_line} < v_res) &&
                                    (v_cnt < v_res - 11'd2 || v_cnt >= v_total - 11'd2);
        wire [24:0] next_line_bytes = base_bytes + next2_line * stride_bytes;
        // guard: only fetch lines that lie entirely inside the card's 1MB
        // (a garbage base_reg during setup must not matter — reads would be
        // harmless, but keep the address math honest)
        wire        fetch_ok = ({1'b0, next_line_bytes[24:1]} + {15'd0, line_words})
                               <= TOTAL_WORDS;

        // 3-line rotating buffer (fills run up to two lines ahead of scan).
        // Banks rotate 0->1->2 on the fill side per SCHEDULED fetch and on
        // the scan side per visible line, both forced to bank 0 at line 0 /
        // the line-0 schedule, so the two rotations re-sync every frame and
        // stay aligned for any v_total (525 and 407 are not both mod-3
        // friendly — arithmetic on line numbers is not). Banks are 1024
        // words so a 24bpp line (960 words) fits, stored as EVEN/ODD word
        // sub-arrays: the 24bpp gather needs two adjacent words per pixel
        // tick (3 bytes always span exactly one even and one odd word), and
        // at 96% pixel-clock duty there is no headroom to serialize two
        // reads. Each sub-array is one M10K read port; legacy modes read
        // both and mux by the delayed word parity — bit-identical to the
        // old single-array read. 2x 2048x16 = 8 M10K (was 4).
        (* ramstyle = "M10K" *) reg [15:0] lb_ev [0:2047];  // even card words
        (* ramstyle = "M10K" *) reg [15:0] lb_od [0:2047];  // odd  card words
        reg [15:0] lb_q_ev, lb_q_od;
        reg [9:0]  fill_ptr;
        reg [1:0]  fill_bank;
        reg [1:0]  scan_bank;
        reg [9:0]  fill_words;
        reg        fill_busy;
        reg [15:0] underrun_cnt;
        reg        r_start;
        reg [19:0] r_base;
        reg [9:0]  r_words;

        assign scan_start = r_start;
        assign scan_base  = r_base;
        assign scan_words = r_words;
        assign dbg_scan_underrun = underrun_cnt;

        wire [1:0] fill_bank_nxt = (next2_line == 10'd0) ? 2'd0 :
                                   (fill_bank == 2'd2)   ? 2'd0 : fill_bank + 2'd1;

        always @(posedge clk) begin
            r_start <= 1'b0;
            if (reset) begin
                fill_ptr <= 10'd0; fill_bank <= 2'd0; fill_words <= 10'd0;
                fill_busy <= 1'b0; underrun_cnt <= 16'd0;
                r_base <= 20'd0; r_words <= 10'd0;
                scan_bank <= 2'd0;
            end else begin
                if (scan_wr && fill_busy) begin
                    // one word or an adjacent pair per clk: the pair's two
                    // words always land in opposite sub-banks (one write
                    // port each), whatever the current alignment
                    if (fill_ptr[0]) begin
                        lb_od[{fill_bank, fill_ptr[9:1]}] <= scan_wdata;
                        if (scan_wr2)
                            lb_ev[{fill_bank, fill_ptr[9:1] + 9'd1}] <= scan_wdata2;
                    end else begin
                        lb_ev[{fill_bank, fill_ptr[9:1]}] <= scan_wdata;
                        if (scan_wr2)
                            lb_od[{fill_bank, fill_ptr[9:1]}] <= scan_wdata2;
                    end
                    fill_ptr <= fill_ptr + (scan_wr2 ? 10'd2 : 10'd1);
                    if (fill_ptr + (scan_wr2 ? 10'd2 : 10'd1) >= fill_words)
                        fill_busy <= 1'b0;
                end
                if (clk_video_en && h_cnt == 11'd0) begin
                    // scan-side bank rotation for the line starting NOW
                    if (v_cnt == 11'd0)
                        scan_bank <= 2'd0;
                    else if (v_cnt < v_res)
                        scan_bank <= (scan_bank == 2'd2) ? 2'd0 : scan_bank + 2'd1;
                    // schedule the fetch of the line TWO ahead
                    if (next2_visible && stride_reg != 32'd0) begin
                        if (fill_busy) underrun_cnt <= underrun_cnt + 16'd1;
                        if (fetch_ok && line_words != 10'd0) begin
                            r_start    <= 1'b1;
                            r_base     <= next_line_bytes[20:1];
                            r_words    <= line_words;
                            fill_bank  <= fill_bank_nxt;
                            fill_ptr   <= 10'd0;
                            fill_words <= line_words;
                            fill_busy  <= 1'b1;
                        end
                    end
                end
            end
        end

        // scanout read — same registered-1-enable-late timing as port B had.
        // scan_bank updates on the h==0 tick of each line; the h==0 pixel's
        // read (stale by design, see the line-buffer note) may use the old
        // bank for one access — the pixel was never derived from live data.
        //
        // Legacy modes: the target word is rd_w0 = h_byte>>1; both sub-arrays
        // are read at the pair index and the delayed parity muxes — the same
        // word the old single array returned. 24bpp: pixel x needs bytes
        // 3x..3x+2, which span words w0=(3x)>>1 and w0+1 — always one even
        // and one odd word, read in parallel:
        //   w0 even: ev[w0/2]={R,G}, od[w0/2]={B,-}
        //   w0 odd:  od[w0/2]={-,R}, ev[w0/2+1]={G,B}
        wire [10:0] px3   = {1'b0, h_cnt[9:0]} + {h_cnt[9:0], 1'b0};  // 3*h
        wire [9:0]  rd_w0 = mode24 ? px3[10:1] : {1'b0, h_byte[9:1]};
        wire [8:0]  od_idx = rd_w0[9:1];
        wire [8:0]  ev_idx = (mode24 && rd_w0[0]) ? (rd_w0[9:1] + 9'd1)
                                                  : rd_w0[9:1];
        reg         rd_w0par;
        reg  [1:0]  rd_ph;    // px3[1:0]: R byte's lane AND word parity — they
                              // are independent (byte 4k+2 is the HIGH lane of
                              // an ODD word), so the byte pick needs both bits
        always @(posedge clk)
            if (clk_video_en) begin
                lb_q_ev  <= lb_ev[{scan_bank, ev_idx}];
                lb_q_od  <= lb_od[{scan_bank, od_idx}];
                rd_w0par <= rd_w0[0];
                rd_ph    <= px3[1:0];
            end
        assign scan_word_q = rd_w0par ? lb_q_od : lb_q_ev;
        // R/G/B by the R byte's address phase (bytes 4k+ph, +1, +2):
        //   ph 0: R=ev.hi G=ev.lo B=od.hi        ph 1: R=ev.lo G=od.hi B=od.lo
        //   ph 2: R=od.hi G=od.lo B=ev.hi (ev = the NEXT even word)
        //   ph 3: R=od.lo G=ev.hi B=ev.lo
        assign scan24_r = (rd_ph == 2'd0) ? lb_q_ev[15:8] :
                          (rd_ph == 2'd1) ? lb_q_ev[7:0]  :
                          (rd_ph == 2'd2) ? lb_q_od[15:8] :
                                            lb_q_od[7:0];
        assign scan24_g = (rd_ph == 2'd0) ? lb_q_ev[7:0]  :
                          (rd_ph == 2'd1) ? lb_q_od[15:8] :
                          (rd_ph == 2'd2) ? lb_q_od[7:0]  :
                                            lb_q_ev[15:8];
        assign scan24_b = (rd_ph == 2'd0) ? lb_q_od[15:8] :
                          (rd_ph == 2'd1) ? lb_q_od[7:0]  :
                          (rd_ph == 2'd2) ? lb_q_ev[15:8] :
                                            lb_q_ev[7:0];

`ifdef SIMULATION
        reg [15:0] underrun_last = 16'd0;
        always @(posedge clk)
            if (vbl_pulse && underrun_cnt != underrun_last) begin
                $display("[MDC] scanline fetch underruns: %0d (+%0d)",
                         underrun_cnt, underrun_cnt - underrun_last);
                underrun_last <= underrun_cnt;
            end
`endif

    end endgenerate

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
    localparam S_PK_ISSUE          = 4'd10;  // packed aperture: raise strobe
    localparam S_PK_WAIT           = 4'd11;  // packed aperture: wait ready

    reg [3:0] state;
    reg [15:0] cpu_write_data;
    reg [15:0] cpu_write_merged;
    reg [1:0]  cpu_write_strobes;

    wire [19:0] cpu_vram_word = local_addr[20:1];  // byte addr -> word addr (2MB)

    // BRAM/cold-tail steer: one FSM, two targets. ext_sel_r is latched at
    // cycle accept; the FSM's generic rd/wr/ready plumbing fans out to
    // whichever port owns the word. RMW partial writes work identically
    // over both (read-merge-write through the same mux). With VRAM_WORDS=0
    // (SDRAM-backed VRAM) every word steers ext.
    /* verilator lint_off UNSIGNED */
    /* verilator lint_off CMPCONST */
    wire cpu_word_in_bram = (VRAM_WORDS != 0) && (cpu_vram_word < VRAM_WORDS);
    /* verilator lint_on CMPCONST */
    /* verilator lint_on UNSIGNED */
    reg  ext_sel_r;
    reg  port_rd_r, port_wr_r;
    reg [1:0] port_ds_r;    // write byte strobes; 2'b11 for all linear writes
    assign vram_rd = port_rd_r & ~ext_sel_r;
    assign vram_wr = port_wr_r & ~ext_sel_r;
    assign ext_rd  = port_rd_r &  ext_sel_r;
    assign ext_wr  = port_wr_r &  ext_sel_r;
    assign vram_ds = port_ds_r;
    assign ext_ds  = port_ds_r;
    wire        port_ready = ext_sel_r ? ext_ready : vram_ready;
    wire [15:0] port_din   = ext_sel_r ? ext_din   : vram_din;

    // ---- packed-RGB aperture (ctrl bit 2; MAME jmfb rgb_pack/rgb_unpack) ---
    // Aperture longword p (local_addr[20:2]) is one pixel, stored as bytes
    // 3p+0/1/2 = R/G/B. On our 16-bit bus each half maps to 0-2 storage
    // byte ops: half 0 = {X,R} (X dropped on write, reads back $00), half 1
    // = {G,B}. A same-word G/B pair collapses to one full-word op; the rest
    // are single-byte ops via the byte strobes (no RMW). Bytes past the 1MB
    // card are dropped on write and read $FF — which also reproduces the
    // partial last pixel MAME exposes at the packed tail (1MB%3 = 1 byte).
    wire pack_mode = ctrl[2];
    wire [18:0] pk_pixel = local_addr[20:2];
    wire [20:0] pk_sb = {2'd0, pk_pixel} + {1'd0, pk_pixel, 1'b0};  // 3*pixel
    wire [20:0] pk_b0 = pk_sb;                 // R
    wire [20:0] pk_b1 = pk_sb + 21'd1;         // G
    wire [20:0] pk_b2 = pk_sb + 21'd2;         // B
    // Presented-size gate: storage bytes at or past the card's VRAM end are
    // dropped on write / read $FF — the aperture scales with TOTAL_WORDS
    // exactly as the real card's packed view scales with fitted VRAM (MAME
    // installs it as vramsize/3*4 bytes). Was a hardcoded 1MB bit test.
    localparam [20:0] PK_BYTES = TOTAL_WORDS * 2;
    wire pk_b0_ok = (pk_b0 < PK_BYTES);
    wire pk_b1_ok = (pk_b1 < PK_BYTES);
    wire pk_b2_ok = (pk_b2 < PK_BYTES);
    reg        pk_we;        // current packed op is a write
    reg        pk_second;    // a second op is queued
    reg        pk_full;      // read op returns the whole word (same-word G,B)
    reg        pk_take_hi;   // read op: target byte is port_din's high lane
    reg        pk_put_hi;    // read op: place byte into data_out[15:8]
    reg [19:0] pk_word2;     // second op: storage word
    reg [1:0]  pk_ds2;       //            write strobes
    reg [15:0] pk_data2;     //            write data
    reg        pk_take_hi2, pk_put_hi2;

    /* verilator lint_off UNSIGNED */
    /* verilator lint_off CMPCONST */
    function automatic pk_word_in_bram(input [19:0] w);
        pk_word_in_bram = (VRAM_WORDS != 0) && ({12'd0, w} < VRAM_WORDS);
    endfunction
    /* verilator lint_on CMPCONST */
    /* verilator lint_on UNSIGNED */

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
                // CRTC VBL control: the REGISTER is the 32-bit long at $13C,
                // but its meaningful low byte arrives on byte lane 3 = byte
                // address $13F (MAME crtc_w: `data &= 0xffff`, bit1 = VBL
                // disable). Decoding byte $13C caught the long's byte 0
                // (always $00) instead: PrimaryInit's DISABLE write ($06,
                // bit1=1) decoded as v=$00 -> ~v[1] ENABLED the VBL, the
                // card interrupted every frame with no handler installed,
                // pseudoVIA reg2 stuck at $5F (slot $E pending), and the
                // POST identity check's reg2 fingerprint sad-Macced $0F/$33
                // (root cause #8, 2026-07-12 — the REAL "unserviceable slot
                // interrupt" the minor code $33 = SysError 51 named all
                // along).
                16'h013F: vblank_enable <= ~v[1];        // enable when bit1==0
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
            port_rd_r <= 1'b0;
            port_wr_r <= 1'b0;
            ext_sel_r <= 1'b0;
            vram_addr <= 25'd0;
            vram_dout <= 16'd0;
            cpu_write_data <= 16'd0;
            cpu_write_merged <= 16'd0;
            cpu_write_strobes <= 2'b00;
            port_ds_r <= 2'b11;
            pk_we <= 1'b0; pk_second <= 1'b0; pk_full <= 1'b0;
            pk_take_hi <= 1'b0; pk_put_hi <= 1'b0;
            pk_word2 <= 20'd0; pk_ds2 <= 2'b00; pk_data2 <= 16'd0;
            pk_take_hi2 <= 1'b0; pk_put_hi2 <= 1'b0;
            ack_n <= 1'b1;
            ack_delay <= 3'd0;
            rom_read_pending <= 1'b0;
            ack_addr <= 32'd0;
            ack_data_in <= 16'd0;
            ack_uds_lds <= 2'b00;
            ack_rw_n <= 1'b1;
            data_out <= 16'd0;
            // ctrl RESET VALUE $0002 — NOT zero. The low ctrl bits are the
            // card's VRAM configuration STRAPS (bit0 = RAM chip density
            // 128k/256k, bit1 = undocumented strap, SET on the real card:
            // MAME jmfb device_reset m_control=0x0002). PrimaryInit's first
            // action is a ctrl read (MAME golden: $0C02) and it BRANCHES on
            // these straps to pick the VRAM layout and prune the video mode
            // sResources; answering $0C00 sent it down the wrong path and
            // the Slot Manager's later mode-record hunt died smRecNotFnd =
            // sad Mac $0F/$33 (root cause #5, 2026-07-12 — survived the A0,
            // lane, VRAM-size and PRAM fixes because the strap, not the
            // probed size, selects the config).
            ctrl <= 16'h0002;
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
                    port_rd_r <= 1'b0;
                    port_wr_r <= 1'b0;

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

                        // ---- packed-RGB VRAM write (ctrl bit 2 set) ----
                        if (!rw_n && addr_is_vram && pack_mode) begin
                            pk_we <= 1'b1;
                            pk_full <= 1'b0;
                            pk_second <= 1'b0;
                            if (!local_addr[1]) begin
                                // {X,R}: X dropped; R -> storage byte 3p
                                if (uds_lds[0] && pk_b0_ok) begin
                                    vram_addr <= VRAM_BASE + {5'd0, pk_b0[20:1]};
                                    vram_dout <= {data_in[7:0], data_in[7:0]};
                                    port_ds_r <= pk_b0[0] ? 2'b01 : 2'b10;
                                    ext_sel_r <= !pk_word_in_bram(pk_b0[20:1]);
                                    state     <= S_PK_ISSUE;
                                end else
                                    ack_delay <= 3'd2;  // X-only or out of range
                            end else begin
                                // {G,B} -> storage bytes 3p+1, 3p+2
                                if (uds_lds[1] && uds_lds[0]
                                    && !pk_b1[0] && pk_b1_ok) begin
                                    // G even: both bytes live in one word
                                    vram_addr <= VRAM_BASE + {5'd0, pk_b1[20:1]};
                                    vram_dout <= data_in;
                                    port_ds_r <= 2'b11;
                                    ext_sel_r <= !pk_word_in_bram(pk_b1[20:1]);
                                    state     <= S_PK_ISSUE;
                                end else if (uds_lds[1] && pk_b1_ok) begin
                                    // G now; B (if strobed and in range) queued
                                    vram_addr <= VRAM_BASE + {5'd0, pk_b1[20:1]};
                                    vram_dout <= {data_in[15:8], data_in[15:8]};
                                    port_ds_r <= pk_b1[0] ? 2'b01 : 2'b10;
                                    ext_sel_r <= !pk_word_in_bram(pk_b1[20:1]);
                                    pk_second <= uds_lds[0] && pk_b2_ok;
                                    pk_word2  <= pk_b2[20:1];
                                    pk_ds2    <= pk_b2[0] ? 2'b01 : 2'b10;
                                    pk_data2  <= {data_in[7:0], data_in[7:0]};
                                    state     <= S_PK_ISSUE;
                                end else if (uds_lds[0] && pk_b2_ok) begin
                                    // B only
                                    vram_addr <= VRAM_BASE + {5'd0, pk_b2[20:1]};
                                    vram_dout <= {data_in[7:0], data_in[7:0]};
                                    port_ds_r <= pk_b2[0] ? 2'b01 : 2'b10;
                                    ext_sel_r <= !pk_word_in_bram(pk_b2[20:1]);
                                    state     <= S_PK_ISSUE;
                                end else
                                    ack_delay <= 3'd2;
                            end
                        end
                        // ---- packed-RGB VRAM read ----
                        else if (rw_n && addr_is_vram && pack_mode) begin
                            pk_we <= 1'b0;
                            pk_full <= 1'b0;
                            pk_second <= 1'b0;
                            if (!local_addr[1]) begin
                                // {X,R}: X reads $00; R from storage byte 3p
                                data_out <= 16'h00FF;
                                if (pk_b0_ok) begin
                                    vram_addr  <= VRAM_BASE + {5'd0, pk_b0[20:1]};
                                    pk_take_hi <= !pk_b0[0];
                                    pk_put_hi  <= 1'b0;
                                    ext_sel_r  <= !pk_word_in_bram(pk_b0[20:1]);
                                    state      <= S_PK_ISSUE;
                                end else
                                    ack_delay <= 3'd2;
                            end else begin
                                // {G,B}; bytes past the card read $FF
                                data_out <= 16'hFFFF;
                                if (!pk_b1[0] && pk_b1_ok) begin
                                    // same word: {G,B} verbatim
                                    vram_addr <= VRAM_BASE + {5'd0, pk_b1[20:1]};
                                    pk_full   <= 1'b1;
                                    ext_sel_r <= !pk_word_in_bram(pk_b1[20:1]);
                                    state     <= S_PK_ISSUE;
                                end else if (pk_b1[0] && pk_b1_ok) begin
                                    // straddle: G = low lane of its word, B =
                                    // high lane of the next (queued if in range)
                                    vram_addr  <= VRAM_BASE + {5'd0, pk_b1[20:1]};
                                    pk_take_hi <= 1'b0;
                                    pk_put_hi  <= 1'b1;
                                    ext_sel_r  <= !pk_word_in_bram(pk_b1[20:1]);
                                    pk_second  <= pk_b2_ok;
                                    pk_word2   <= pk_b2[20:1];
                                    pk_take_hi2<= 1'b1;
                                    pk_put_hi2 <= 1'b0;
                                    state      <= S_PK_ISSUE;
                                end else
                                    ack_delay <= 3'd2;  // both out of range
                            end
                        end
                        // ---- VRAM write (raw, no inversion) ----
                        // word < VRAM_WORDS -> BRAM; < TOTAL_WORDS -> cold
                        // tail (ext port); beyond -> ack-and-drop as before.
                        else if (!rw_n && addr_is_vram) begin
                            if (cpu_vram_word < TOTAL_WORDS) begin
                                ext_sel_r <= !cpu_word_in_bram;
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
                            if (cpu_vram_word < TOTAL_WORDS) begin
                                ext_sel_r <= !cpu_word_in_bram;
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
                    port_ds_r <= 2'b11;
                    port_wr_r <= 1'b1;
                    state <= S_CPU_WRITE_WAIT;
                end

                S_CPU_WRITE_WAIT: begin
                    if (port_ready) begin
                        port_wr_r <= 1'b0;
                        ack_delay <= 3'd2;
                        state <= S_IDLE;
                    end
                end

                S_CPU_READ: begin
                    port_rd_r <= 1'b1;
                    state <= S_CPU_READ_WAIT;
                end

                S_CPU_READ_WAIT: begin
                    if (port_ready) begin
                        data_out <= port_din;   // raw, no inversion
                        port_rd_r <= 1'b0;
                        ack_delay <= 3'd2;
                        state <= S_IDLE;
                    end
                end

                S_CPU_RMW_READ: begin
                    port_rd_r <= 1'b1;
                    state <= S_CPU_RMW_READ_WAIT;
                end

                S_CPU_RMW_READ_WAIT: begin
                    if (port_ready) begin
                        port_rd_r <= 1'b0;
                        cpu_write_merged <= {
                            cpu_write_strobes[1] ? cpu_write_data[15:8] : port_din[15:8],
                            cpu_write_strobes[0] ? cpu_write_data[7:0]  : port_din[7:0]
                        };
                        state <= S_CPU_RMW_WRITE;
                    end
                end

                S_CPU_RMW_WRITE: begin
                    vram_dout <= cpu_write_merged;
                    port_ds_r <= 2'b11;
                    port_wr_r <= 1'b1;
                    state <= S_CPU_WRITE_WAIT;
                end

                S_PK_ISSUE: begin
                    if (pk_we) port_wr_r <= 1'b1;
                    else       port_rd_r <= 1'b1;
                    state <= S_PK_WAIT;
                end

                S_PK_WAIT: begin
                    if (port_ready) begin
                        port_wr_r <= 1'b0;
                        port_rd_r <= 1'b0;
                        if (!pk_we) begin
                            if (pk_full)
                                data_out <= port_din;
                            else if (pk_put_hi)
                                data_out[15:8] <= pk_take_hi ? port_din[15:8]
                                                             : port_din[7:0];
                            else
                                data_out[7:0]  <= pk_take_hi ? port_din[15:8]
                                                             : port_din[7:0];
                        end
                        if (pk_second) begin
                            // strobes are low for exactly one cycle here, so
                            // the ext backend's level-ready clears before the
                            // second op's rising edge (contract in
                            // mdc_vram_ddr.sv)
                            pk_second  <= 1'b0;
                            vram_addr  <= VRAM_BASE + {5'd0, pk_word2};
                            vram_dout  <= pk_data2;
                            port_ds_r  <= pk_ds2;
                            ext_sel_r  <= !pk_word_in_bram(pk_word2);
                            pk_take_hi <= pk_take_hi2;
                            pk_put_hi  <= pk_put_hi2;
                            state      <= S_PK_ISSUE;
                        end else begin
                            ack_delay <= 3'd2;
                            state <= S_IDLE;
                        end
                    end
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
    wire [7:0] vram_byte = byte_sel_d ? scan_word_q[7:0] : scan_word_q[15:8];

    reg [7:0] pixel_idx;
    always @(*) begin
        pixel_idx = 8'd0;
        case (mode)
            3'd0: begin  // 1bpp
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
            3'd1: begin  // 2bpp
                case (h_cnt_d[1:0])
                    2'd0: pixel_idx = {6'd0, vram_byte[7:6]};
                    2'd1: pixel_idx = {6'd0, vram_byte[5:4]};
                    2'd2: pixel_idx = {6'd0, vram_byte[3:2]};
                    2'd3: pixel_idx = {6'd0, vram_byte[1:0]};
                endcase
            end
            3'd2: begin  // 4bpp
                pixel_idx = h_cnt_d[0] ? {4'd0, vram_byte[3:0]}
                                       : {4'd0, vram_byte[7:4]};
            end
            default: begin  // 8bpp (24bpp bypasses pixel_idx entirely)
                pixel_idx = vram_byte;
            end
        endcase
    end

    wire pixel_valid = !blanking_d;
    wire mono_mode = DEFAULT_MONOCHROME || monochrome || (mode == 3'd0);
    // 1bpp (and forced mono): bit clear -> light (0xEE), set -> dark (0x22).
    wire [7:0] mono_pixel = pixel_idx[0] ? 8'h22 : 8'hEE;
    // 24bpp is direct colour — no CLUT (MAME jmfb renders the raw bytes; a
    // mono monitor takes the blue channel, matching update_screen<0xd>).
    wire [7:0] px24_r = mono_mode ? scan24_b : scan24_r;
    wire [7:0] px24_g = mono_mode ? scan24_b : scan24_g;
    wire [7:0] px24_b = scan24_b;
    assign vga_r = !pixel_valid ? 8'd0 :
                   mode24       ? px24_r :
                   mono_mode    ? mono_pixel : clut[pixel_idx][7:0];
    assign vga_g = !pixel_valid ? 8'd0 :
                   mode24       ? px24_g :
                   mono_mode    ? mono_pixel : clut[pixel_idx][15:8];
    assign vga_b = !pixel_valid ? 8'd0 :
                   mode24       ? px24_b :
                   mono_mode    ? mono_pixel : clut[pixel_idx][23:16];

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
