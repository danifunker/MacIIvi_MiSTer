| boot_stub_scsi_m2hires.s — 8 bpp / 640-stride SCSI boot block.
| DEFERRED — see preboot/common/display/old/font_ascii_m2hires.c
| for the reasoning. No card depth-switch happens before paint, so
| this stub paints garbage on hardware until that init is written.
|
| Historical names:
|   - preboot/supervisor_bench/boot_stub_scsi_m2hires.s (build location)
|   - the file's banner says "boot_stub_scsi_toby.s" — copy-paste
|     lineage from the first author. Treat the file as the 8 bpp
|     supervisor_bench SCSI boot block, not Toby-specific.
|
| Same logic as preboot/common/boot/boot_stub_scsi_fixed_offset.s but
| every paint operation assumes:
|   - 1 byte per pixel
|   - 640 bytes per row
|   - $00 = white, $FF = black
| Glyphs are 8 bytes wide on screen (one byte per pixel) and 8 rows tall.

ROW_BYTES = 640
PX_WHITE  = 0x00
PX_BLACK  = 0xFF
FB_BYTES  = 640 * 480

    .text
    .global _start
_start:
    .ascii  "LK"
bbEntry:
    bra.w   startup

bbVersion:    .word 0xD000
bbPageFlags:  .word 0

bbSysName:    .byte 6;  .ascii "System";          .space 9
bbShellName:  .byte 6;  .ascii "Finder";          .space 9
bbDbg1Name:   .byte 7;  .ascii "Macsbug";         .space 8
bbDbg2Name:   .byte 12; .ascii "Disassembler";    .space 3
bbScreenName: .byte 13; .ascii "StartUpScreen";   .space 2
bbHelloName:  .byte 6;  .ascii "Finder";          .space 9
bbScrapName:  .byte 14; .ascii "Clipboard File";  .space 1

bbCntFCBs:        .word 10
bbCntEvts:        .word 20
bbHeapSize128K:   .long 0x00004300
bbHeapSize256K:   .long 0x00008000
bbHeapSize:       .long 0x00020000

PB_OFF_IORESULT     = 16
PB_OFF_IOVREFNUM    = 22
PB_OFF_IOREFNUM     = 24
PB_OFF_IOBUFFER     = 32
PB_OFF_IOREQCOUNT   = 36
PB_OFF_IOPOSMODE    = 44
PB_OFF_IOPOSOFFSET  = 46
PB_SIZE             = 80

PAYLOAD_LOAD_ADDR     = 0x00040000
PAYLOAD_PART_OFFSET   = 0x00051600
PAYLOAD_READ_BYTES    = 262144

HANDOFF_ADDR          = 0x00050000

DRVQHDR_QHEAD         = 0x0000030A
BOOTDRIVE             = 0x00000210
DRVQEL_OFF_QLINK      = 0
DRVQEL_OFF_DQDRIVE    = 6
DRVQEL_OFF_DQREFNUM   = 8

startup:
    move.w  #0x2700, %sr
    move.l  #0x00010000, %sp

    | --- Wipe full framebuffer (307200 bytes) with PX_BLACK.
    | Uses subq.l/bne to avoid dbra's 16-bit overflow at counts > 65535. ---
    move.l  0x0824.l, %a3
    tst.l   %a3
    beq     halt
    cmp.l   #0x00100000, %a3
    blo     halt
    move.l  %a3, %a0
    move.l  #(FB_BYTES/4), %d0
    move.l  #0xFFFFFFFF, %d1
1:  move.l  %d1, (%a0)+
    subq.l  #1, %d0
    bne.s   1b

    | --- Marker 'A' (row 4, char col 4) ---
    move.l  %a3, %a0
    add.l   #(4 * ROW_BYTES + 4 * 8), %a0
    moveq   #10, %d0
    bsr     draw_glyph_d0

    | --- BootDrive number, hex (row 4, char col 6) ---
    move.w  BOOTDRIVE.l, %d4
    move.l  %a3, %a0
    add.l   #(4 * ROW_BYTES + 6 * 8), %a0
    move.w  %d4, %d5
    moveq   #3, %d3
.drv_hex:
    move.l  %d5, %d0
    rol.w   #4, %d0
    move.w  %d0, %d5
    andi.l  #0xF, %d0
    bsr     draw_glyph_d0
    add.l   #8, %a0
    dbra    %d3, .drv_hex

    | --- Walk DrvQHdr to find matching dQDrive, extract dQRefNum ---
    moveal  DRVQHDR_QHEAD.l, %a1
    moveq   #0, %d5
.scan:
    cmp.l   #0, %a1
    beq     fail_noref
    cmp.w   DRVQEL_OFF_DQDRIVE(%a1), %d4
    beq.s   .found
    moveal  DRVQEL_OFF_QLINK(%a1), %a1
    addq.l  #1, %d5
    cmpi.l  #32, %d5
    blt.s   .scan
    bra     fail_noref
.found:
    move.w  DRVQEL_OFF_DQREFNUM(%a1), %d6

    | --- Driver refnum (row 16, char col 5) ---
    move.l  %a3, %a0
    add.l   #(16 * ROW_BYTES + 4 * 8), %a0
    moveq   #13, %d0
    bsr     draw_glyph_d0
    add.l   #8, %a0
    move.w  %d6, %d5
    moveq   #3, %d3
.ref_hex:
    move.l  %d5, %d0
    rol.w   #4, %d0
    move.w  %d0, %d5
    andi.l  #0xF, %d0
    bsr     draw_glyph_d0
    add.l   #8, %a0
    dbra    %d3, .ref_hex

    | --- Zero PB ---
    lea     pb(%pc), %a0
    moveq   #(PB_SIZE/4)-1, %d0
1:  clr.l   (%a0)+
    dbra    %d0, 1b

    | --- Issue _Read via SCSI driver ---
    lea     pb(%pc), %a0
    move.w  %d6, PB_OFF_IOREFNUM(%a0)
    move.w  %d4, PB_OFF_IOVREFNUM(%a0)
    move.l  #PAYLOAD_LOAD_ADDR, PB_OFF_IOBUFFER(%a0)
    move.l  #PAYLOAD_READ_BYTES, PB_OFF_IOREQCOUNT(%a0)
    move.w  #1, PB_OFF_IOPOSMODE(%a0)
    move.l  #PAYLOAD_PART_OFFSET, PB_OFF_IOPOSOFFSET(%a0)
    .word   0xA002
    move.w  PB_OFF_IORESULT(%a0), %d7

    | --- Read result (row 28, char col 4) ---
    move.l  %a3, %a0
    add.l   #(28 * ROW_BYTES + 4 * 8), %a0
    moveq   #14, %d0
    bsr     draw_glyph_d0
    add.l   #8, %a0
    move.w  %d7, %d5
    moveq   #3, %d3
.res_hex:
    move.l  %d5, %d0
    rol.w   #4, %d0
    move.w  %d0, %d5
    andi.l  #0xF, %d0
    bsr     draw_glyph_d0
    add.l   #8, %a0
    dbra    %d3, .res_hex

    tst.w   %d7
    bne     halt

    | --- Handoff refnum + drive to payload ---
    move.w  %d6, HANDOFF_ADDR.l
    move.w  %d4, (HANDOFF_ADDR+2).l

    | --- '3' marker (row 40, char col 4) — about to jump ---
    move.l  %a3, %a0
    add.l   #(40 * ROW_BYTES + 4 * 8), %a0
    moveq   #3, %d0
    bsr     draw_glyph_d0

    jmp     PAYLOAD_LOAD_ADDR.l

fail_noref:
    move.l  %a3, %a0
    add.l   #(16 * ROW_BYTES + 4 * 8), %a0
    moveq   #4, %d3                        | 4 'F' chars
1:  moveq   #15, %d0
    bsr     draw_glyph_d0
    add.l   #8, %a0
    dbra    %d3, 1b

halt:
1:  bra.s   1b

| draw_glyph_d0: paint hex_font glyph idx d0 at FB pointer %a0, at
| 8bpp (one byte per pixel, 8x8 = 64 bytes used). Clobbers d1, d2,
| d3 (NOT a1 — caller relies on a1 surviving outer state).
draw_glyph_d0:
    lea     hex_font(%pc), %a1
    lsl.l   #3, %d0
    adda.l  %d0, %a1
    move.l  %a0, %a2
    moveq   #7, %d1                         | 8 rows
.gloop_row:
    move.b  (%a1)+, %d2                     | bits (MSB = leftmost)
    moveq   #7, %d3                         | 8 cols
.gloop_col:
    add.b   %d2, %d2                        | shift left, CCR=X gets bit
    bcs.s   .gbit_set
    clr.b   (%a2)+
    bra.s   .gbit_next
.gbit_set:
    move.b  #PX_BLACK, (%a2)+
.gbit_next:
    dbra    %d3, .gloop_col
    | next row = move %a2 back to (col 0) + 1 row
    sub.w   #8, %a2
    add.l   #ROW_BYTES, %a2
    dbra    %d1, .gloop_row
    rts

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

    .align 2
pb:
    .space  PB_SIZE
