| payload_entry_scsi.s — minimal SCSI-boot test payload.
| Boot block places refnum at $00041000 (word) and drive number at
| $00041002 (word). We paint both to screen as a sanity check.

.ifndef ROW_BYTES
    ROW_BYTES = 80
.endif

HANDOFF_ADDR        = 0x00050000

PB_OFF_IORESULT     = 16
PB_OFF_IOVREFNUM    = 22
PB_OFF_IOREFNUM     = 24
PB_OFF_IOBUFFER     = 32
PB_OFF_IOREQCOUNT   = 36
PB_OFF_IOPOSMODE    = 44
PB_OFF_IOPOSOFFSET  = 46
PB_SIZE             = 80

RESULTS_PART_OFFSET = 0x00051C00       | /Results.jsonl byte offset in HFS partition (block 641 × 512 + drAlBlSt × 512)
RESULTS_WRITE_BYTES = 512              | sector-aligned

    .text
    .global _payload_start
_payload_start:
    | --- Re-wipe screen ---
    move.l  0x0824.l, %a4
    move.l  %a4, %d0
    beq     .hang
    cmp.l   #0x00100000, %d0
    blo     .hang
    move.l  %a4, %a0
    move.l  #(128*1024/4)-1, %d0
1:  move.l  #0xFFFFFFFF, (%a0)+
    dbra    %d0, 1b

    | Each text row uses an 8-pixel-tall glyph; pace rows 12 scanlines
    | apart so there's a 4-pixel gap.

    | --- Paint "PAYLOAD OK" at row 16 ---
    move.l  %a4, %a0
    add.l   #(16 * ROW_BYTES + 4), %a0
    lea     font_payload_ok(%pc), %a1
    moveq   #9, %d0
    bsr     draw_string_n_d0

    | --- Paint refnum at row 28 (12 below "PAYLOAD OK") ---
    move.l  %a4, %a0
    add.l   #(28 * ROW_BYTES + 4), %a0
    moveq   #13, %d0                      | 'D' marker
    bsr     draw_glyph_d0
    addq.l  #1, %a0
    move.w  HANDOFF_ADDR.l, %d5           | refnum (signed)
    moveq   #3, %d4
.refloop:
    move.l  %d5, %d0
    rol.w   #4, %d0
    move.w  %d0, %d5
    andi.l  #0xF, %d0
    bsr     draw_glyph_d0
    addq.l  #1, %a0
    dbra    %d4, .refloop

    | --- Paint drive number at row 40 ---
    move.l  %a4, %a0
    add.l   #(40 * ROW_BYTES + 4), %a0
    moveq   #11, %d0                      | 'B' marker
    bsr     draw_glyph_d0
    addq.l  #1, %a0
    move.w  (HANDOFF_ADDR+2).l, %d5       | drive number
    moveq   #3, %d4
.drvloop:
    move.l  %d5, %d0
    rol.w   #4, %d0
    move.w  %d0, %d5
    andi.l  #0xF, %d0
    bsr     draw_glyph_d0
    addq.l  #1, %a0
    dbra    %d4, .drvloop

    | --- Write a marker line to /Results.jsonl via SCSI driver. ---
    lea     pb(%pc), %a0
    moveq   #(PB_SIZE/4)-1, %d0
1:  clr.l   (%a0)+
    dbra    %d0, 1b
    lea     pb(%pc), %a0
    move.w  HANDOFF_ADDR.l, PB_OFF_IOREFNUM(%a0)
    move.w  (HANDOFF_ADDR+2).l, PB_OFF_IOVREFNUM(%a0)
    lea     write_buf(%pc), %a1
    move.l  %a1, PB_OFF_IOBUFFER(%a0)
    move.l  #RESULTS_WRITE_BYTES, PB_OFF_IOREQCOUNT(%a0)
    move.w  #1, PB_OFF_IOPOSMODE(%a0)       | fsFromStart
    move.l  #RESULTS_PART_OFFSET, PB_OFF_IOPOSOFFSET(%a0)
    .word   0xA003                          | _Write
    move.w  PB_OFF_IORESULT(%a0), %d6

    | --- Paint 'W' (use 'F' glyph) + 4 hex digits at row 52. ---
    move.l  %a4, %a0
    add.l   #(52 * ROW_BYTES + 4), %a0
    moveq   #15, %d0
    bsr     draw_glyph_d0
    addq.l  #1, %a0
    move.w  %d6, %d5
    moveq   #3, %d4
.wrloop:
    move.l  %d5, %d0
    rol.w   #4, %d0
    move.w  %d0, %d5
    andi.l  #0xF, %d0
    bsr     draw_glyph_d0
    addq.l  #1, %a0
    dbra    %d4, .wrloop

.hang:
1:  bra.s   1b

draw_string_n_d0:
    move.l  %a0, %a3
.dsn_char:
    move.l  %a3, %a2
    moveq   #7, %d1
.dsn_row:
    move.b  (%a1)+, %d2
    not.b   %d2
    move.b  %d2, (%a2)
    lea     ROW_BYTES(%a2), %a2
    dbra    %d1, .dsn_row
    addq.l  #1, %a3
    dbra    %d0, .dsn_char
    rts

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

font_payload_ok:
    .byte 0x7C, 0x42, 0x42, 0x7C, 0x40, 0x40, 0x40, 0x00   | P
    .byte 0x3C, 0x42, 0x42, 0x7E, 0x42, 0x42, 0x42, 0x00   | A
    .byte 0x42, 0x42, 0x42, 0x3C, 0x18, 0x18, 0x18, 0x00   | Y
    .byte 0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x7E, 0x00   | L
    .byte 0x3C, 0x42, 0x42, 0x42, 0x42, 0x42, 0x3C, 0x00   | O
    .byte 0x3C, 0x42, 0x42, 0x7E, 0x42, 0x42, 0x42, 0x00   | A
    .byte 0x78, 0x44, 0x42, 0x42, 0x42, 0x44, 0x78, 0x00   | D
    .byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00   | space
    .byte 0x3C, 0x42, 0x42, 0x42, 0x42, 0x42, 0x3C, 0x00   | O
    .byte 0x42, 0x44, 0x48, 0x70, 0x48, 0x44, 0x42, 0x00   | K

| 512-byte payload to write into /Results.jsonl.
write_buf:
    .ascii  "{\"hello\":\"world\",\"step\":\"F-write-scsi\",\"v\":1}\n"
    .space  512 - (. - write_buf)

    .align 4
pb:
    .space  PB_SIZE

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
