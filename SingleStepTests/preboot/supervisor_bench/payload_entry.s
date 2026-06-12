| payload_entry.s — runs at $00040000 after boot block loads us.
| For now: paints "PAYLOAD OK" then writes one JSONL-style line to
| /Results.jsonl via .Sony _Write at the file's known disk offset.

.ifndef ROW_BYTES
    ROW_BYTES = 80
.endif

PB_OFF_IORESULT     = 16
PB_OFF_IOVREFNUM    = 22
PB_OFF_IOREFNUM     = 24
PB_OFF_CSCODE       = 26       | for _Control / _Status calls (CntrlParam)
PB_OFF_IOBUFFER     = 32
PB_OFF_IOREQCOUNT   = 36
PB_OFF_IOACTCOUNT   = 40
PB_OFF_IOPOSMODE    = 44
PB_OFF_IOPOSOFFSET  = 46
PB_SIZE             = 80

| .Sony driver Control csCodes (Inside Macintosh: Devices)
SONY_CSCODE_EJECT   = 7

| Refnum / drive supplied by the boot block at $00041000 (set by
| boot_stub_scsi.s before jumping here). For the legacy floppy path,
| if no handoff is present, fall back to .Sony (-5, drive 1).
HANDOFF_ADDR          = 0x00050000
SONY_DRIVER_REFNUM    = -5
RESULTS_DISK_OFFSET   = 0x1E00       | byte offset of /Results.jsonl (FLOPPY layout)
RESULTS_WRITE_BYTES   = 512          | one sector — sector-aligned IO

    .text
    .global _payload_start
_payload_start:
    | --- Clear screen (boot block already did this, but be safe). ---
    move.l  0x0824.l, %a4
    move.l  %a4, %d0
    beq     .hang
    cmp.l   #0x00100000, %d0
    blo     .hang
    move.l  %a4, %a0
    move.l  #(128*1024/4)-1, %d0
1:  move.l  #0xFFFFFFFF, (%a0)+
    dbra    %d0, 1b

    | --- Paint "PAYLOAD OK" at row 16. ---
    move.l  %a4, %a0
    add.l   #(16 * ROW_BYTES + 4), %a0
    lea     font_payload_ok(%pc), %a1
    moveq   #9, %d0
    bsr     draw_string_n_d0

    | --- Zero our PB. ---
    lea     pb(%pc), %a0
    moveq   #(PB_SIZE/4)-1, %d0
1:  clr.l   (%a0)+
    dbra    %d0, 1b

    | --- .Sony _Write: write marker to /Results.jsonl region. ---
    lea     pb(%pc), %a0
    move.w  #SONY_DRIVER_REFNUM, PB_OFF_IOREFNUM(%a0)
    move.w  #1, PB_OFF_IOVREFNUM(%a0)
    lea     write_buf(%pc), %a1
    move.l  %a1, PB_OFF_IOBUFFER(%a0)
    move.l  #RESULTS_WRITE_BYTES, PB_OFF_IOREQCOUNT(%a0)
    move.w  #1, PB_OFF_IOPOSMODE(%a0)
    move.l  #RESULTS_DISK_OFFSET, PB_OFF_IOPOSOFFSET(%a0)
    .word   0xA003                        | _Write (driver-routed)
    move.w  PB_OFF_IORESULT(%a0), %d7

    | --- Paint "W" + 4 hex digits of d7 at row 24. ---
    move.l  %a4, %a0
    add.l   #(24 * ROW_BYTES + 4), %a0
    | 'W' = no hex glyph; use a vertical-stroke-ish marker (char '8' would do)
    | We'll just paint two hex digits each side: 'W' label = 'F' 'F' (so the
    | user sees FF if write returned noErr, FE etc. otherwise visible).
    moveq   #15, %d0                      | glyph 'F'
    bsr     draw_glyph_d0
    addq.l  #1, %a0
    move.w  %d7, %d5
    moveq   #3, %d4
.hexloop:
    move.l  %d5, %d0
    rol.w   #4, %d0
    move.w  %d0, %d5
    andi.l  #0xF, %d0
    bsr     draw_glyph_d0
    addq.l  #1, %a0
    dbra    %d4, .hexloop

    | --- Marker 'E' = post-write, pre-eject ---
    move.l  %a4, %a0
    add.l   #(28 * ROW_BYTES + 4), %a0
    moveq   #14, %d0
    bsr     draw_glyph_d0

    | --- Eject the floppy: .Sony Control with csCode=7. ---
    lea     pb(%pc), %a0
    moveq   #(PB_SIZE/4)-1, %d0
1:  clr.l   (%a0)+
    dbra    %d0, 1b
    lea     pb(%pc), %a0
    move.w  #SONY_DRIVER_REFNUM, PB_OFF_IOREFNUM(%a0)
    move.w  #1, PB_OFF_IOVREFNUM(%a0)
    move.w  #SONY_CSCODE_EJECT, PB_OFF_CSCODE(%a0)
    .word   0xA004                        | _Control
    move.w  PB_OFF_IORESULT(%a0), %d6

    | --- Paint 'X' (use glyph 'C' = C-control) + hex result at row 32. ---
    move.l  %a4, %a0
    add.l   #(32 * ROW_BYTES + 4), %a0
    moveq   #12, %d0                      | glyph 'C'
    bsr     draw_glyph_d0
    addq.l  #1, %a0
    move.w  %d6, %d5
    moveq   #3, %d4
.cthexloop:
    move.l  %d5, %d0
    rol.w   #4, %d0
    move.w  %d0, %d5
    andi.l  #0xF, %d0
    bsr     draw_glyph_d0
    addq.l  #1, %a0
    dbra    %d4, .cthexloop

.hang:
1:  bra.s   1b

| ----- draw_string_n_d0: paint d0+1 glyphs from font at %a1 to FB ptr %a0.
|       Font format: 8 bytes per glyph (1=letter). Clobbers d1, d2, a2, a3.
draw_string_n_d0:
    move.l  %a0, %a3                      | save column origin
.dsn_char:
    move.l  %a3, %a2
    moveq   #7, %d1
.dsn_row:
    move.b  (%a1)+, %d2
    not.b   %d2
    move.b  %d2, (%a2)
    lea     ROW_BYTES(%a2), %a2
    dbra    %d1, .dsn_row
    addq.l  #1, %a3                       | next char column
    dbra    %d0, .dsn_char
    rts

| draw_glyph_d0: paint hex_font glyph index d0 at %a0. Clobbers d1, d2, a1, a2.
draw_glyph_d0:
    lea     hex_font(%pc), %a1
    lsl.l   #3, %d0
    adda.l  %d0, %a1
    move.l  %a0, %a2
    moveq   #7, %d1
1:  move.b  (%a1)+, %d2
    not.b   %d2
    move.b  %d2, (%a2)
    lea     ROW_BYTES(%a2), %a2
    dbra    %d1, 1b
    rts

| 8x8 font for "PAYLOAD OK"
font_payload_ok:
    | 'P'
    .byte 0x7C, 0x42, 0x42, 0x7C, 0x40, 0x40, 0x40, 0x00
    | 'A'
    .byte 0x3C, 0x42, 0x42, 0x7E, 0x42, 0x42, 0x42, 0x00
    | 'Y'
    .byte 0x42, 0x42, 0x42, 0x3C, 0x18, 0x18, 0x18, 0x00
    | 'L'
    .byte 0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x7E, 0x00
    | 'O'
    .byte 0x3C, 0x42, 0x42, 0x42, 0x42, 0x42, 0x3C, 0x00
    | 'A'
    .byte 0x3C, 0x42, 0x42, 0x7E, 0x42, 0x42, 0x42, 0x00
    | 'D'
    .byte 0x78, 0x44, 0x42, 0x42, 0x42, 0x44, 0x78, 0x00
    | ' '
    .byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    | 'O'
    .byte 0x3C, 0x42, 0x42, 0x42, 0x42, 0x42, 0x3C, 0x00
    | 'K'
    .byte 0x42, 0x44, 0x48, 0x70, 0x48, 0x44, 0x42, 0x00

| 16-glyph hex font, indices 0–15 = '0'..'F'.
hex_font:
    .byte 0x3C,0x42,0x46,0x4A,0x52,0x62,0x3C,0x00   | 0
    .byte 0x18,0x28,0x08,0x08,0x08,0x08,0x3E,0x00   | 1
    .byte 0x3C,0x42,0x02,0x0C,0x30,0x40,0x7E,0x00   | 2
    .byte 0x3C,0x42,0x02,0x1C,0x02,0x42,0x3C,0x00   | 3
    .byte 0x04,0x0C,0x14,0x24,0x7E,0x04,0x04,0x00   | 4
    .byte 0x7E,0x40,0x7C,0x02,0x02,0x42,0x3C,0x00   | 5
    .byte 0x1C,0x20,0x40,0x7C,0x42,0x42,0x3C,0x00   | 6
    .byte 0x7E,0x02,0x04,0x08,0x10,0x20,0x20,0x00   | 7
    .byte 0x3C,0x42,0x42,0x3C,0x42,0x42,0x3C,0x00   | 8
    .byte 0x3C,0x42,0x42,0x3E,0x02,0x04,0x38,0x00   | 9
    .byte 0x3C,0x42,0x42,0x7E,0x42,0x42,0x42,0x00   | A
    .byte 0x7C,0x42,0x42,0x7C,0x42,0x42,0x7C,0x00   | B
    .byte 0x3C,0x42,0x40,0x40,0x40,0x42,0x3C,0x00   | C
    .byte 0x78,0x44,0x42,0x42,0x42,0x44,0x78,0x00   | D
    .byte 0x7E,0x40,0x40,0x7C,0x40,0x40,0x7E,0x00   | E
    .byte 0x7E,0x40,0x40,0x7C,0x40,0x40,0x40,0x00   | F

| 512-byte buffer holding the marker line we write to disk.
| Starts with a JSON-shaped line + newline; rest is zero padding.
| The visible string here is what should appear in extracted Results.jsonl.
write_buf:
    .ascii  "{\"hello\":\"world\",\"step\":\"F-write\",\"v\":1}\n"
    .space  512 - (. - write_buf)

    .align 4
read_buf:
    .space  512

    .data
    .align 4
pb:
    .space  PB_SIZE

    .bss
    .align 4
    .global vbr_table
vbr_table:
    .space  1024
