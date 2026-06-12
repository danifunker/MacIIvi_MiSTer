#!/usr/bin/env python3
"""Generate 32x32 color icons (icl4 + ICN# + mask) for all three benches:
  - CPU bench:     green chip outline, "CPU 68030 BENCH"

Outputs Rez-formatted hex blocks to stdout for pasting into .r files.

Color palette: Apple's standard 16-entry "Apple color" CLUT (clut 4).
Indices used:
   2 = red       ($DD)
   8 = green     ($08)
  15 = black
   0 = white
"""

# 4x6 pixel digit/letter glyphs. Width 3, height 5; 4th col is the gap.
# Pixels are MSB-aligned in a 4-bit nibble per row.
GLYPHS = {
    '0': [0x6, 0x9, 0x9, 0x9, 0x6],
    '1': [0x2, 0x6, 0x2, 0x2, 0x7],
    '2': [0x6, 0x1, 0x2, 0x4, 0xF],
    '6': [0x6, 0x8, 0xE, 0x9, 0x6],
    '8': [0x6, 0x9, 0x6, 0x9, 0x6],
    '/': [0x1, 0x2, 0x2, 0x4, 0x8],
    'A': [0x6, 0x9, 0xF, 0x9, 0x9],
    'B': [0xE, 0x9, 0xE, 0x9, 0xE],
    'C': [0x6, 0x8, 0x8, 0x8, 0x6],
    'E': [0xF, 0x8, 0xE, 0x8, 0xF],
    'F': [0xF, 0x8, 0xE, 0x8, 0x8],
    'H': [0x9, 0x9, 0xF, 0x9, 0x9],
    'I': [0x7, 0x2, 0x2, 0x2, 0x7],
    'M': [0x9, 0xF, 0xF, 0x9, 0x9],
    'N': [0x9, 0xD, 0xB, 0x9, 0x9],
    'P': [0xE, 0x9, 0xE, 0x8, 0x8],
    'U': [0x9, 0x9, 0x9, 0x9, 0x6],
    ' ': [0x0, 0x0, 0x0, 0x0, 0x0],
}

COLOR_RED   = 0x2   # icl4 palette index for red
COLOR_GREEN = 0x8   # icl4 palette index for green
COLOR_BLACK = 0xF
COLOR_WHITE = 0x0


def render_text(text, x_offset):
    """Yield (row, col) pixel coords for each set bit of TEXT placed
    with leftmost char column at x_offset. 4 px per char (3 glyph + 1 gap)."""
    for i, ch in enumerate(text):
        g = GLYPHS.get(ch, GLYPHS[' '])
        for row, row_bits in enumerate(g):
            for col in range(4):
                if row_bits & (0x8 >> col):
                    yield (row, x_offset + i*4 + col)


def chip_outline_pixels():
    """Return set of (r, c) pixels that form the chip outline + pin
    rectangles. Shared between all icons."""
    pix = set()
    # Body outline: rows 2..29, cols 2..29.
    for r in range(2, 30):
        pix.add((r, 2))
        pix.add((r, 29))
    for c in range(2, 30):
        pix.add((2, c))
        pix.add((29, c))
    # Knock corners off, add inner-corner tile
    for (r, c) in [(2,2),(2,29),(29,2),(29,29)]:
        pix.discard((r, c))
    for (r, c) in [(3,3),(3,28),(28,3),(28,28)]:
        pix.add((r, c))
    # Pins on top/bottom edges
    for col_base in [5, 9, 13, 17, 21, 25]:
        for c in (col_base, col_base+1):
            for r in (0, 1, 30, 31):
                pix.add((r, c))
    # Pins on left/right edges
    for row_base in [5, 9, 13, 17, 21, 25]:
        for r in (row_base, row_base+1):
            for c in (0, 1, 30, 31):
                pix.add((r, c))
    return pix


def chip_body_pixels():
    """Solid-fill mask for the chip body + pin areas."""
    pix = set()
    for r in range(2, 30):
        for c in range(2, 30):
            pix.add((r, c))
    for (r, c) in [(2,2),(2,29),(29,2),(29,29)]:
        pix.discard((r, c))
    # Pin rectangles
    for col_base in [5, 9, 13, 17, 21, 25]:
        for c in (col_base, col_base+1):
            for r in (0, 1, 30, 31):
                pix.add((r, c))
    for row_base in [5, 9, 13, 17, 21, 25]:
        for r in (row_base, row_base+1):
            for c in (0, 1, 30, 31):
                pix.add((r, c))
    return pix


def build_icon(text_lines, outline_color_left, outline_color_right):
    """
    text_lines: list of (top_row, x_offset, string) — the inner text.
    outline_color_left/right: color index for the outline. If both
       equal → single-color outline; if different → left half uses
       left, right half uses right (vertical split at col 16).
    Returns:
      grid:  32x32 list of int color indices (icl4 palette)
      mono:  32x32 list of 0/1 for the ICN# 1-bit version
    """
    grid = [[COLOR_WHITE]*32 for _ in range(32)]
    mono = [[0]*32 for _ in range(32)]

    # Outline
    for (r, c) in chip_outline_pixels():
        color = outline_color_left if c < 16 else outline_color_right
        grid[r][c] = color
        mono[r][c] = 1

    # Text in black on top of white
    for (top, x_off, text) in text_lines:
        for (rdy, cdy) in render_text(text, x_off):
            r = top + rdy
            c = cdy
            grid[r][c] = COLOR_BLACK
            mono[r][c] = 1

    return grid, mono


def pack_1bit(grid):
    """Pack a 32x32 0/1 grid into 128 bytes (MSB = leftmost)."""
    out = bytearray()
    for r in range(32):
        for byte_col in range(4):
            b = 0
            for bit in range(8):
                if grid[r][byte_col*8 + bit]:
                    b |= 0x80 >> bit
            out.append(b)
    return out


def pack_4bit(grid):
    """Pack a 32x32 4-bit color grid into 512 bytes.
    Two nibbles per byte; upper nibble = left pixel."""
    out = bytearray()
    for r in range(32):
        for c in range(0, 32, 2):
            out.append((grid[r][c] << 4) | grid[r][c+1])
    return out


def hex_block(b, indent="        "):
    """Format as Rez-style $\"XX XX..\" lines, 16 bytes per line."""
    lines = []
    for i in range(0, len(b), 16):
        chunk = b[i:i+16]
        hex_pairs = " ".join(f"{x:02X}" for x in chunk)
        lines.append(f'{indent}$"{hex_pairs}"')
    return "\n".join(lines)


def mask_pixels():
    """Mask = solid chip body silhouette."""
    grid = [[0]*32 for _ in range(32)]
    for (r, c) in chip_body_pixels():
        grid[r][c] = 1
    return grid


def emit_icon_set(name, text_lines, color_left, color_right):
    grid, mono = build_icon(text_lines, color_left, color_right)
    icon_1bit  = pack_1bit(mono)
    mask_1bit  = pack_1bit(mask_pixels())
    icon_4bit  = pack_4bit(grid)

    print(f"/* ===== {name} ===== */\n")
    print(f"/* ICN# (32x32 1-bit icon + mask, 256 bytes) */")
    print("/* icon: */")
    print(hex_block(icon_1bit))
    print("/* mask: */")
    print(hex_block(mask_1bit))
    print(f"\n/* icl4 (32x32 4-bit colour, 512 bytes) */")
    print(hex_block(icon_4bit))
    print()


def main():
    # CPU bench: green chip, "CPU / 68030 / BENCH"
    emit_icon_set("CPU bench",
        [
            (6,  10, "CPU"),
            (13,  6, "68030"),
            (20,  6, "BENCH"),
        ],
        color_left=COLOR_GREEN, color_right=COLOR_GREEN)


if __name__ == "__main__":
    main()
