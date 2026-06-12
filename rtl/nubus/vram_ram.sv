//
// vram_ram.sv
//
// Dedicated on-chip VRAM for the NuBus Hi-Res video card, dual-port.
//
// Replaces the shared-SDRAM framebuffer path so the scanout never competes with
// the Mac for SDRAM (the cyan/green/red noise).  Matches how a real Mac II works
// (VRAM on the card).
//
// Dual-port:
//   * Port A (read/write, write-through) — CPU VRAM access via the card's FSM.
//   * Port B (read-only)                 — the video SCANOUT, on its own port so
//     it NEVER misses (every pixel's word comes straight from BRAM, independent
//     of CPU writes).  This retires the old 2-word cache that fell back to a
//     stale word on a miss -> garbled text/edges.
//
// Sizing: 128 KB (2^16 16-bit words).  A 256 KB dual-port instance was getting
// duplicated by the M10K mapper (2 reads + 1 write -> two arrays) and overflowed
// the 553 M10K blocks.  128 KB fits even if duplicated (~256 blocks) and covers
// 1/2 bpp at 640x480 -- the Mac's boot screens (gray desktop, dialogs, happy
// Mac, Welcome) are 1 bpp.  Revisit for deeper colour once a non-duplicating
// 256 KB mapping is confirmed.
//
module vram_ram #(
    parameter integer AW = 16                 // 2^16 words = 128 KB
) (
    input             clk,

    // Port A — CPU read/write (card FSM)
    input      [24:0] addr,
    input      [15:0] din,
    output reg [15:0] dout,
    input             rd,
    input             wr,
    output reg        ready,

    // Port B — video scanout (read-only)
    input      [24:0] addr_b,
    input             rd_b,
    output reg [15:0] dout_b
);
    localparam integer WORDS = (1 << AW);

    (* ramstyle = "M10K" *) reg [15:0] mem [0:WORDS-1];

    // VRAM_BASE (0x300000) is aligned to the VRAM region, so the low AW address
    // bits are the word offset within VRAM (same for both ports).
    wire [AW-1:0] idx_a = addr[AW-1:0];
    wire [AW-1:0] idx_b = addr_b[AW-1:0];

    // Port A: CPU read/write, canonical write-through true-dual-port style.
    always @(posedge clk) begin
        if (wr) begin
            mem[idx_a] <= din;
            dout       <= din;          // write-through (new data)
        end else begin
            dout       <= mem[idx_a];
        end
        ready <= rd | wr;
    end

    // Port B: scanout read (enabled per displayed pixel-word, so it advances in
    // lockstep with the pixel pipeline's clk_video_en-gated registers).
    always @(posedge clk) begin
        if (rd_b)
            dout_b <= mem[idx_b];
    end
endmodule
