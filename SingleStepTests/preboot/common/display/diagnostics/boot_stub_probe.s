| boot_stub_probe.s — 8 bpp framebuffer polarity probe.
|
| Historical name: preboot/supervisor_bench/boot_stub_m2hires_probe.s.
| Renamed during the preboot/ reorg to drop the m2hires-specific tag
| since the probe is generic: it draws 4 stripes at known byte values
| ($00, $55, $AA, $FF) and the operator reports whether they render
| dark-to-light or light-to-dark. Works on any 8 bpp 640-stride card.
| Build via `make probe`. Banner inside still says "Toby" — copy-paste
| lineage from the first author, not a target indication.
|
| Boots as a self-running boot block (bbVersion=$D000, like our other
| stubs). Paints four 64-pixel-wide vertical stripes near the top of
| the screen using bytes $00, $55, $AA, $FF so we can identify the
| 8bpp pixel polarity on a real card.
|
| Each stripe sits at row 32, columns 0..63 / 64..127 / 128..191 /
| 192..255. Above and below the stripes is the unmodified ROM
| boot-init pattern (whatever the ROM left there).
|
| Assumes Toby framebuffer:
|   - 8 bits per pixel
|   - 640 bytes per row
|   - ScrnBase low-mem $0824 points at it
|   - 640 x 480 visible area
|
| Hangs forever after painting so the operator can read the screen.

ROW_BYTES = 640

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

    | %a3 = ScrnBase
    move.l  0x0824.l, %a3
    tst.l   %a3
    beq     halt
    cmp.l   #0x00100000, %a3
    blo     halt

    | ---- Paint 4 stripes at row 32, 64 px each. ----
    | Stripe 0: cols 0..63   -> fill 64 bytes with $00
    move.l  %a3, %a0
    add.l   #(32 * ROW_BYTES + 0), %a0
    moveq   #63, %d0
1:  move.b  #0x00, (%a0)+
    dbra    %d0, 1b

    | Stripe 1: cols 64..127 -> $55
    move.l  %a3, %a0
    add.l   #(32 * ROW_BYTES + 64), %a0
    moveq   #63, %d0
1:  move.b  #0x55, (%a0)+
    dbra    %d0, 1b

    | Stripe 2: cols 128..191 -> $AA
    move.l  %a3, %a0
    add.l   #(32 * ROW_BYTES + 128), %a0
    moveq   #63, %d0
1:  move.b  #0xAA, (%a0)+
    dbra    %d0, 1b

    | Stripe 3: cols 192..255 -> $FF
    move.l  %a3, %a0
    add.l   #(32 * ROW_BYTES + 192), %a0
    moveq   #63, %d0
1:  move.b  #0xFF, (%a0)+
    dbra    %d0, 1b

    | Make each stripe 32 rows tall so it's easy to see (paint 31 more
    | copies of the line by simply copying the row 31 times).
    move.l  %a3, %a0
    add.l   #(32 * ROW_BYTES), %a0       | row 32 base
    moveq   #30, %d1                      | 31 more copies
.row_loop:
    move.l  %a0, %a1                      | source row
    move.l  %a0, %a2
    add.l   #ROW_BYTES, %a2               | target row
    move.l  #(256/4)-1, %d0               | 64 longs covers 256 bytes
.byte_loop:
    move.l  (%a1)+, (%a2)+
    dbra    %d0, .byte_loop
    add.l   #ROW_BYTES, %a0               | advance to the row we just painted
    dbra    %d1, .row_loop

halt:
1:  bra.s   1b
