| boot_stub_calibrate.s — paint a solid 200x200 square with assumed
| stride to detect off-by-N stride errors on an unfamiliar card.
|
| Historical name: preboot/supervisor_bench/boot_stub_m2hires_calibrate.s.
| Build via `make calibrate`. Same generic-vs-named comment as
| boot_stub_probe.s — this is a tool, not card-specific.
|
| If the rendered shape on screen is:
|   - a clean square: assumed stride is correct
|   - a parallelogram: stride is off by N pixels per row
|     -> real stride = assumed stride + N
|     -> per-row skew tells us how to correct
|
| To make N easy to read, paint a "ruler" of 10 distinct stripes
| inside the square at known column offsets. Their visible positions
| reveal the per-row drift.

ASSUMED_STRIDE = 640
SQUARE_TOP_ROW = 80
SQUARE_LEFT    = 80
SQUARE_W       = 200
SQUARE_H       = 200

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

startup:
    move.w  #0x2700, %sr
    move.l  #0x00010000, %sp

    move.l  0x0824.l, %a3
    tst.l   %a3
    beq     halt
    cmp.l   #0x00100000, %a3
    blo     halt

    | --- Paint a 200x200 black square at (row 80, col 80) ---
    move.l  %a3, %a0
    add.l   #(SQUARE_TOP_ROW * ASSUMED_STRIDE + SQUARE_LEFT), %a0
    move.w  #SQUARE_H-1, %d1
.row:
    move.l  %a0, %a1
    move.w  #SQUARE_W-1, %d0
.col:
    move.b  #0xFF, (%a1)+
    dbra    %d0, .col
    add.l   #ASSUMED_STRIDE, %a0
    dbra    %d1, .row

    | --- Paint a column ruler INSIDE the square: vertical white
    | stripes (byte $00 = white) at relative cols 0, 20, 40, ..., 180.
    | Each stripe is 2 pixels wide and spans the full 200 rows of the
    | square. If our stride is right, these are crisp vertical lines.
    | If stride is wrong, they're sloped — slope tells us the error.
    move.l  %a3, %a0
    add.l   #(SQUARE_TOP_ROW * ASSUMED_STRIDE + SQUARE_LEFT), %a0
    moveq   #9, %d2                       | 10 stripes
.ruler_stripe:
    move.l  %a0, %a1
    move.w  #SQUARE_H-1, %d1
.ruler_row:
    move.b  #0x00, (%a1)
    move.b  #0x00, 1(%a1)
    add.l   #ASSUMED_STRIDE, %a1
    dbra    %d1, .ruler_row
    add.l   #20, %a0                      | next stripe = 20 px right
    dbra    %d2, .ruler_stripe

    | --- Above the square, paint 8 horizontal reference lines at
    | rows 5, 10, 15, ..., 40, each 400 pixels wide. If stride is
    | right these are horizontal; if wrong they slope downward.
    moveq   #7, %d2
    move.l  #5, %d3                       | first row
.href:
    move.l  %a3, %a0
    move.l  %d3, %d4
    mulu.w  #ASSUMED_STRIDE, %d4
    add.l   %d4, %a0
    move.w  #399, %d0
.href_col:
    move.b  #0xFF, (%a0)+
    dbra    %d0, .href_col
    addq.l  #5, %d3
    dbra    %d2, .href

halt:
1:  bra.s   1b
