| boot_stub_minimal.s — diagnostic boot block, no A-traps.
|
| Historical location: preboot/supervisor_bench/boot_stub_minimal.s.
| Moved into the shared diagnostics tree during the reorg since it's
| a generic "is the boot path even alive" probe — no bench logic in
| it. Build via `make minimal` from any bench's Makefile.
|
| Identical header to boot_stub.s; bbEntry writes a known pattern
| to known low-RAM addresses, then infinite-loops.
|
| If this disk also "happy Mac → ejects", the boot block format
| itself is the problem (most likely bbVersion/bbPageFlags flagging
| the ROM to try and load a System file).
|
| If this disk shows happy Mac and HANGS (no eject), bbEntry was
| reached successfully and the issue with the real bench is the
| _Open/_Read/_Close path or the payload jump.

    .text
    .global _start
_start:
    .ascii  "LK"
bbEntry:
    bra.w   startup                | bbEntry is exactly 4 bytes
bbVersion:
    | New-format magic: bit 7 set (new format) + bit 6 set (execute
    | the boot code in bbEntry instead of loading the System file).
    | Per Inside Macintosh: Files, "Boot Blocks". Without this the
    | ROM ignores our code and tries to load System.
    .word   0xD000
bbPageFlags:  .word 0

| Each name is a Pascal string padded to 16 bytes (1 length + up to
| 15 chars). Hand-encoded so each block is exactly 16 bytes; lengths
| and padding match Disk605.dsk's boot block byte-for-byte.
bbSysName:    .byte 6;  .ascii "System";          .space 9
bbShellName:  .byte 6;  .ascii "Finder";          .space 9
bbDbg1Name:   .byte 7;  .ascii "Macsbug";         .space 8
bbDbg2Name:   .byte 12; .ascii "Disassembler";    .space 3
bbScreenName: .byte 13; .ascii "StartUpScreen";   .space 2
bbHelloName:  .byte 6;  .ascii "Finder";          .space 9
bbScrapName:  .byte 14; .ascii "Clipboard File";  .space 1

bbCntFCBs:        .word 10
bbCntEvts:        .word 20
bbHeapSize128K:   .long 0x00004300       | matches Disk605.dsk
bbHeapSize256K:   .long 0x00008000
bbHeapSize:       .long 0x00020000

| Bytes per row of the framebuffer. 80 = 640px @ 1bpp. If the actual
| display is wider/narrower, the text will render mis-stretched and
| we can adjust here without redesigning.
.ifndef ROW_BYTES
    ROW_BYTES = 80
.endif

startup:
    move.w  #0x2700, %sr

    | Read ScrnBase low-mem global ($0824) — set by ROM during early
    | boot, points at framebuffer base.
    move.l  0x0824.l, %a0
    move.l  %a0, %d0
    beq     .hang
    cmp.l   #0x00100000, %d0
    blo     .hang

    | --- Fill 128 KB with $FF (solid black at 1bpp). ---
    move.l  #(128*1024/4)-1, %d0
1:  move.l  #0xFFFFFFFF, (%a0)+
    dbra    %d0, 1b

    | --- Render "BENCH OK" at row 16, starting at byte column 4. ---
    move.l  0x0824.l, %a0          | reload ScrnBase
    add.l   #(16 * ROW_BYTES + 4), %a0   | top-left of text rectangle
    lea     font_data(%pc), %a1
    moveq   #7, %d0                | 8 chars total (loop counter is N-1)
.char_loop:
    move.l  %a0, %a2               | column origin for this char
    moveq   #7, %d1                | 8 rows per glyph
.row_loop:
    move.b  (%a1)+, %d2            | font byte (1-bit = lit pixel)
    not.b   %d2                    | invert so lit pixels become white (0)
    move.b  %d2, (%a2)
    lea     ROW_BYTES(%a2), %a2
    dbra    %d1, .row_loop
    addq.l  #1, %a0                | next char = 1 byte to the right (8 px)
    dbra    %d0, .char_loop

.hang:
1:  bra.s   1b

| 8x8 font, one bit per pixel, MSB = leftmost column.
| 1 = letter pixel (will be inverted to 0=white at render time).
font_data:
    | 'B'
    .byte 0x7C, 0x42, 0x42, 0x7C, 0x42, 0x42, 0x7C, 0x00
    | 'E'
    .byte 0x7E, 0x40, 0x40, 0x7C, 0x40, 0x40, 0x7E, 0x00
    | 'N'
    .byte 0x42, 0x62, 0x52, 0x4A, 0x46, 0x42, 0x42, 0x00
    | 'C'
    .byte 0x3C, 0x42, 0x40, 0x40, 0x40, 0x42, 0x3C, 0x00
    | 'H'
    .byte 0x42, 0x42, 0x42, 0x7E, 0x42, 0x42, 0x42, 0x00
    | ' ' (space)
    .byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    | 'O'
    .byte 0x3C, 0x42, 0x42, 0x42, 0x42, 0x42, 0x3C, 0x00
    | 'K'
    .byte 0x42, 0x44, 0x48, 0x70, 0x48, 0x44, 0x42, 0x00
