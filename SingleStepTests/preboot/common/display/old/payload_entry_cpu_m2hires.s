| payload_entry_cpu_m2hires.s — 8 bpp / 640-stride payload entry.
| DEFERRED — see preboot/common/display/old/font_ascii_m2hires.c
| for status. Kept around as the seed for future 8 bpp work.
|
| Historical names:
|   - preboot/supervisor_bench/payload_entry_cpu_m2hires.s (build location)
|   - the file's banner says "payload_entry_cpu_toby.s" — copy-paste
|     lineage from the first author, not a target indication.
|
| Identical logic to preboot/supervisor_bench/payload_entry_cpu.s but
| with pixel-aware paint (1 byte per pixel, 640 bytes per row).

ROW_BYTES = 640
PX_WHITE  = 0x00
PX_BLACK  = 0xFF
FB_BYTES  = 640 * 480

    .text
    .global _payload_start
_payload_start:
    move.w  #0x2700, %sr
    move.l  #0x00100000, %sp

    | --- Earliest possible "alive" marker: solid-white horizontal bar
    | at row 0 (just 16 bytes wide). If we never see this on the
    | physical machine, the boot block isn't actually loading us. ---
    move.l  0x0824.l, %a4
    move.l  %a4, %d0
    beq     .hang
    cmp.l   #0x00100000, %d0
    blo     .hang
    move.l  %a4, %a0
    move.w  #15, %d0
1:  move.b  #0x00, (%a0)+
    dbra    %d0, 1b

    | --- Load handoff slot (refnum word, drive word) ---
    move.w  0x00050000.l, %d0
    move.w  %d0, g_handoff_refnum
    move.w  0x00050002.l, %d0
    move.w  %d0, g_handoff_drive

    | --- "got handoff" marker: solid black bar at row 0 col 16..31 ---
    move.l  %a4, %a0
    add.l   #16, %a0
    move.w  #15, %d0
1:  move.b  #0xFF, (%a0)+
    dbra    %d0, 1b

    | --- Wipe screen (640*480 = 307200 bytes). 32-bit counter to
    | avoid dbra's 16-bit limit. ---
    move.l  %a4, %a0
    move.l  #(FB_BYTES/4), %d0
    move.l  #0xFFFFFFFF, %d1                | PX_BLACK x 4
1:  move.l  %d1, (%a0)+
    subq.l  #1, %d0
    bne.s   1b

    | --- "wipe complete" marker: 16 white bytes at row 0 col 0 ---
    move.l  %a4, %a0
    move.w  #15, %d0
1:  move.b  #0x00, (%a0)+
    dbra    %d0, 1b

    | --- Paint "CPU BENCH" at row 4 (char col 4) ---
    move.l  %a4, %a0
    add.l   #(4 * ROW_BYTES + 4 * 8), %a0
    lea     banner(%pc), %a1
    moveq   #8, %d0                         | 9 chars: C P U _ B E N C H
    bsr     draw_string_n_d0

    jsr     bench_main

    | --- Paint "DONE" at row 56 (char col 4) ---
    move.l  0x0824.l, %a4
    move.l  %a4, %a0
    add.l   #(56 * ROW_BYTES + 4 * 8), %a0
    lea     done_str(%pc), %a1
    moveq   #3, %d0                         | D O N E
    bsr     draw_string_n_d0

.hang:
1:  bra.s   1b

    .data
    .align 4
    .global g_handoff_refnum
    .global g_handoff_drive
g_handoff_refnum:   .word 0
g_handoff_drive:    .word 0

    .text

    .global paint_progress
paint_progress:
    | paint_progress(u32 idx, u32 total)
    | At 8bpp, row 56 char col 32 = byte (56 * 640 + 32 * 8) = 35840 + 256 = 36096
    move.l  0x0824.l, %a0
    add.l   #(56 * ROW_BYTES + 32 * 8), %a0
    move.l  4(%sp), %d3                     | idx
    moveq   #3, %d4
.pp_loop:
    move.l  %d3, %d0
    rol.w   #4, %d0
    move.w  %d0, %d3
    andi.l  #0xF, %d0
    bsr     draw_glyph_d0
    add.l   #8, %a0
    dbra    %d4, .pp_loop
    rts

draw_string_n_d0:
    | %a1 = font pointer (8 bytes per glyph), %a0 = top-left FB byte,
    | %d0 = (count - 1).
    move.l  %a0, %a3
.dsn_char:
    move.l  %a3, %a2
    moveq   #7, %d1
.dsn_row:
    move.b  (%a1)+, %d2
    moveq   #7, %d3
.dsn_col:
    add.b   %d2, %d2
    bcs.s   .dsn_set
    clr.b   (%a2)+
    bra.s   .dsn_next
.dsn_set:
    move.b  #PX_BLACK, (%a2)+
.dsn_next:
    dbra    %d3, .dsn_col
    sub.w   #8, %a2
    add.l   #ROW_BYTES, %a2
    dbra    %d1, .dsn_row
    add.l   #8, %a3                         | next char = 8 px right
    dbra    %d0, .dsn_char
    rts

draw_glyph_d0:
    lea     hex_font(%pc), %a1
    lsl.l   #3, %d0
    adda.l  %d0, %a1
    move.l  %a0, %a2
    moveq   #7, %d1
.glr:
    move.b  (%a1)+, %d2
    moveq   #7, %d3
.glc:
    add.b   %d2, %d2
    bcs.s   .gset
    clr.b   (%a2)+
    bra.s   .gn
.gset:
    move.b  #PX_BLACK, (%a2)+
.gn:
    dbra    %d3, .glc
    sub.w   #8, %a2
    add.l   #ROW_BYTES, %a2
    dbra    %d1, .glr
    rts

banner:
    .byte 0x3C,0x42,0x40,0x40,0x40,0x42,0x3C,0x00   | C
    .byte 0x7C,0x42,0x42,0x7C,0x40,0x40,0x40,0x00   | P
    .byte 0x42,0x42,0x42,0x42,0x42,0x42,0x3C,0x00   | U
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00   | space
    .byte 0x7C,0x42,0x42,0x7C,0x42,0x42,0x7C,0x00   | B
    .byte 0x7E,0x40,0x40,0x7C,0x40,0x40,0x7E,0x00   | E
    .byte 0x42,0x62,0x52,0x4A,0x46,0x42,0x42,0x00   | N
    .byte 0x3C,0x42,0x40,0x40,0x40,0x42,0x3C,0x00   | C
    .byte 0x42,0x42,0x42,0x7E,0x42,0x42,0x42,0x00   | H

done_str:
    .byte 0x78,0x44,0x42,0x42,0x42,0x44,0x78,0x00   | D
    .byte 0x3C,0x42,0x42,0x42,0x42,0x42,0x3C,0x00   | O
    .byte 0x42,0x62,0x52,0x4A,0x46,0x42,0x42,0x00   | N
    .byte 0x7E,0x40,0x40,0x7C,0x40,0x40,0x7E,0x00   | E

hex_font:
    .byte 0x3C,0x42,0x46,0x4A,0x52,0x62,0x3C,0x00
    .byte 0x18,0x28,0x08,0x08,0x08,0x08,0x3E,0x00
    .byte 0x3C,0x42,0x02,0x0C,0x30,0x40,0x7E,0x00
    .byte 0x3C,0x42,0x02,0x1C,0x02,0x42,0x3C,0x00
    .byte 0x04,0x0C,0x14,0x24,0x7E,0x04,0x04,0x00
    .byte 0x7E,0x40,0x7C,0x02,0x02,0x42,0x3C,0x00
    .byte 0x1C,0x20,0x40,0x7C,0x42,0x42,0x3C,0x00
    .byte 0x7E,0x02,0x04,0x08,0x10,0x20,0x20,0x00
    .byte 0x3C,0x42,0x42,0x3C,0x42,0x42,0x3C,0x00
    .byte 0x3C,0x42,0x42,0x3E,0x02,0x04,0x38,0x00
    .byte 0x3C,0x42,0x42,0x7E,0x42,0x42,0x42,0x00
    .byte 0x7C,0x42,0x42,0x7C,0x42,0x42,0x7C,0x00
    .byte 0x3C,0x42,0x40,0x40,0x40,0x42,0x3C,0x00
    .byte 0x78,0x44,0x42,0x42,0x42,0x44,0x78,0x00
    .byte 0x7E,0x40,0x40,0x7C,0x40,0x40,0x7E,0x00
    .byte 0x7E,0x40,0x40,0x7C,0x40,0x40,0x40,0x00
