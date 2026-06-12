#!/usr/bin/env python3
"""Generate a 32x32 1-bit ICN# icon for the CpuBench APPL.
Drawn as a chip outline with "68020" + "CPU" + "BENCH" text inside.

Outputs the icon + mask as space-separated hex bytes suitable for
pasting into a Rez .r file."""

# 4x6 pixel digits/letters, MSB = leftmost column of character.
# Width 3 (the 4th column is the gap), height 5.
GLYPHS = {
    '0': [0x6, 0x9, 0x9, 0x9, 0x6],
    '1': [0x2, 0x6, 0x2, 0x2, 0x7],
    '2': [0x6, 0x1, 0x2, 0x4, 0xF],
    '6': [0x6, 0x8, 0xE, 0x9, 0x6],
    '8': [0x6, 0x9, 0x6, 0x9, 0x6],
    'C': [0x6, 0x8, 0x8, 0x8, 0x6],
    'P': [0x6, 0x9, 0x6, 0x8, 0x8],
    'U': [0x9, 0x9, 0x9, 0x9, 0x6],
    'B': [0xE, 0x9, 0xE, 0x9, 0xE],
    'E': [0xF, 0x8, 0xE, 0x8, 0xF],
    'N': [0x9, 0xD, 0xB, 0x9, 0x9],
    'H': [0x9, 0x9, 0xF, 0x9, 0x9],
    ' ': [0x0, 0x0, 0x0, 0x0, 0x0],
}

def render_text(text, x_offset):
    """Return a list of (row, col, bit) tuples for each pixel of TEXT
    placed with leftmost char column at x_offset. Each glyph is 3 px
    wide + 1 px gap, 5 px tall."""
    pixels = []
    for i, ch in enumerate(text):
        g = GLYPHS.get(ch, GLYPHS[' '])
        for row, row_bits in enumerate(g):
            for col in range(4):
                if row_bits & (0x8 >> col):
                    pixels.append((row, x_offset + i*4 + col))
    return pixels


def draw_icon():
    # 32x32 grid, 1 = pixel set (black), 0 = clear.
    grid = [[0]*32 for _ in range(32)]

    # Chip outline: rounded square at rows 2..29, cols 2..29.
    for r in range(2, 30):
        grid[r][2] = 1
        grid[r][29] = 1
    for c in range(2, 30):
        grid[2][c] = 1
        grid[29][c] = 1

    # Knock corners off so it looks like a DIP chip.
    grid[2][2] = grid[2][29] = grid[29][2] = grid[29][29] = 0
    grid[3][3] = grid[3][28] = grid[28][3] = grid[28][28] = 1

    # Pins on top edge (rows 0..1) and bottom edge (rows 30..31).
    for col_base in [5, 9, 13, 17, 21, 25]:
        for c in (col_base, col_base+1):
            grid[0][c] = 1
            grid[1][c] = 1
            grid[30][c] = 1
            grid[31][c] = 1

    # Pins on left + right edges (cols 0..1 and 30..31), rows 5..26.
    for row_base in [5, 9, 13, 17, 21, 25]:
        for r in (row_base, row_base+1):
            grid[r][0] = 1
            grid[r][1] = 1
            grid[r][30] = 1
            grid[r][31] = 1

    # Place text inside chip body (rows 6..27, cols 4..27 = 24 px wide):
    #   row 6-10:  "CPU"   (3 chars × 4px = 12 px, centered at col 10)
    #   row 13-17: "68020" (5 chars × 4px = 20 px, centered at col 6)
    #   row 20-24: "BENCH" (5 chars × 4px = 20 px, centered at col 6)
    line1 = "CPU"
    line2 = "68020"
    line3 = "BENCH"
    for row, col in render_text(line1, x_offset=10):
        grid[6 + row][col] = 1
    for row, col in render_text(line2, x_offset=6):
        grid[13 + row][col] = 1
    for row, col in render_text(line3, x_offset=6):
        grid[20 + row][col] = 1

    return grid


def grid_to_hex(grid):
    """Pack a 32x32 grid (MSB = leftmost) into 128 bytes."""
    bytes_out = bytearray()
    for r in range(32):
        for byte_col in range(4):
            b = 0
            for bit in range(8):
                if grid[r][byte_col*8 + bit]:
                    b |= 0x80 >> bit
            bytes_out.append(b)
    return bytes_out


def hex_block(b, indent="    "):
    """Format as Rez-style $\"XX XX XX XX\" lines, 16 bytes per line."""
    lines = []
    for i in range(0, len(b), 16):
        chunk = b[i:i+16]
        hex_pairs = " ".join(f"{x:02X}" for x in chunk)
        lines.append(f"{indent}$\"{hex_pairs}\"")
    return "\n".join(lines)


def main():
    grid = draw_icon()
    icon = grid_to_hex(grid)

    # Mask: every pixel within the chip's bounding region is opaque.
    # Simplest mask = solid filled chip silhouette, same shape as the icon.
    mask_grid = [[0]*32 for _ in range(32)]
    # Body: rows 2..29, cols 2..29 (the whole chip)
    for r in range(2, 30):
        for c in range(2, 30):
            mask_grid[r][c] = 1
    # Mask the corners off (same as icon shape)
    mask_grid[2][2] = mask_grid[2][29] = mask_grid[29][2] = mask_grid[29][29] = 0
    # Include the pin areas in the mask
    for col_base in [5, 9, 13, 17, 21, 25]:
        for c in (col_base, col_base+1):
            for r in (0, 1, 30, 31):
                mask_grid[r][c] = 1
    for row_base in [5, 9, 13, 17, 21, 25]:
        for r in (row_base, row_base+1):
            for c in (0, 1, 30, 31):
                mask_grid[r][c] = 1
    mask = grid_to_hex(mask_grid)

    print("/* ICN# = 32x32 1-bit icon + 32x32 1-bit mask, 256 bytes total */")
    print("/* === icon === */")
    print(hex_block(icon))
    print("/* === mask === */")
    print(hex_block(mask))


if __name__ == "__main__":
    main()
