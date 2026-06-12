| boot_stub_strides.s — paint 4 small 50x50 black squares, each
| drawn assuming a different row stride. The one that appears as
| a clean, non-skewed square reveals the actual stride.
|
| Historical name: preboot/supervisor_bench/boot_stub_m2hires_v3.s
| (the "v3" suffix tracks the iteration history that landed on this
| 4-stride bracket approach). Build via `make strides`.
|
| Strides tested (left to right): 640, 832, 1024, 1280.
| Above each square: a single horizontal reference line that's
| 50 px wide, using the SAME assumed stride. If stride is right,
| line is straight; if wrong, line wraps.
|
| Also: paint a UNIQUE marker pixel pattern in each square so they
| can't be confused. Square 0 = single white dot top-left.
| Square 1 = horizontal white line near top. Square 2 = vertical
| white line near left. Square 3 = X mark.

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

    | Square 0 — assumed stride 640
    move.l  #640, %d6
    move.l  #20, %d7        | top byte offset within base
    bsr     paint_square

    | Square 1 — assumed stride 832
    move.l  #832, %d6
    move.l  #(60), %d7
    bsr     paint_square

    | Square 2 — assumed stride 1024
    move.l  #1024, %d6
    move.l  #(100), %d7
    bsr     paint_square

    | Square 3 — assumed stride 1280
    move.l  #1280, %d6
    move.l  #(140), %d7
    bsr     paint_square

halt:
1:  bra.s   1b

| paint_square: paint a 50x50 black ($FF) square at row 100,
| col %d7 using assumed stride %d6. Inside, paint a unique white
| ($00) "label" marking so we can ID the square.
| Clobbers: %d0, %d1, %d2, %d3, %d4, %a0, %a1.
paint_square:
    move.l  %a3, %a0
    | offset = 100 * stride + col
    move.l  %d6, %d4
    mulu.l  #100, %d4               | %d4 = 100 * stride
    add.l   %d4, %a0
    add.l   %d7, %a0                | %a0 = top-left of square

    | --- Draw 50x50 black square ---
    move.w  #49, %d1                | rows
.s_row:
    move.l  %a0, %a1
    move.w  #49, %d0                | cols
.s_col:
    move.b  #0xFF, (%a1)+
    dbra    %d0, .s_col
    add.l   %d6, %a0                | next row = +stride
    dbra    %d1, .s_row
    rts
