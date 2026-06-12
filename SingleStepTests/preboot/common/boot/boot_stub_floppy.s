| boot_stub_floppy.s — HFS boot block for floppy media (≤1024 bytes,
| lands at floppy offset 0).
|
| Historical name: preboot/supervisor_bench/boot_stub.s. Renamed to
| boot_stub_floppy.s during the preboot/ reorg so the SCSI vs floppy
| variants are unambiguous at a glance.
|
|
| Layout matches real Mac OS boot blocks. bbVersion=$D000 makes the
| ROM execute our bbEntry directly (bit 7 + bit 6 set in high byte =
| "new format, run boot code, skip System file load").
|
|   +0x00  bbID            'LK'                 (2 bytes)
|   +0x02  bbEntry         BRA.W                (4 bytes)
|   +0x06  bbVersion       word ($D000)
|   +0x08  bbPageFlags     word
|   +0x0A  bbSysName       pstr16  "System"
|   +0x1A  bbShellName     pstr16  "Finder"
|   +0x2A  bbDbg1Name      pstr16  "Macsbug"
|   +0x3A  bbDbg2Name      pstr16  "Disassembler"
|   +0x4A  bbScreenName    pstr16  "StartUpScreen"
|   +0x5A  bbHelloName     pstr16  "Finder"
|   +0x6A  bbScrapName     pstr16  "Clipboard File"
|   +0x7A  bbCntFCBs       word
|   +0x7C  bbCntEvts       word
|   +0x7E  bbHeapSize128K  long
|   +0x82  bbHeapSize256K  long
|   +0x86  bbHeapSize      long
|   +0x8A  startup

.ifndef ROW_BYTES
    ROW_BYTES = 80
.endif

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

| ----------------------------------------------------------------------
| .Sony driver _Read at bbEntry time. The File Manager isn't
| initialised yet, so File Manager _Open hangs. Instead we call the
| .Sony driver directly via the standard _Read trap ($A002) with
| ioRefNum = -5 (the .Sony unit) — when the trap dispatcher sees a
| negative refnum it routes to the driver Prime entry, bypassing
| File Manager.
|
| /Payload's disk offset is baked into the boot block at build time
| (PAYLOAD_DISK_OFFSET); current value found by hexdumping the
| assembled .dsk for the payload's magic header.
| ----------------------------------------------------------------------

PB_OFF_IORESULT     = 16
PB_OFF_IONAMEPTR    = 18
PB_OFF_IOVREFNUM    = 22
PB_OFF_IOREFNUM     = 24
PB_OFF_IOPERMSSN    = 27
PB_OFF_IOBUFFER     = 32
PB_OFF_IOREQCOUNT   = 36
PB_OFF_IOACTCOUNT   = 40
PB_OFF_IOPOSMODE    = 44
PB_OFF_IOPOSOFFSET  = 46
PB_SIZE             = 80

PAYLOAD_LOAD_ADDR   = 0x00040000
PAYLOAD_DISK_OFFSET = 0x00001800       | offset 6144 in .dsk (= sector 12)
PAYLOAD_READ_BYTES  = 4096             | round up payload size to next 512-byte boundary
SONY_DRIVER_REFNUM  = -5

startup:
    move.w  #0x2700, %sr

    | Set up our own supervisor stack at $00010000 (well below any
    | code/payload, above low-mem globals and the boot-block load
    | area). The ROM-provided SP may not be safe to push onto at
    | bbEntry time on some ROMs/Snow combos.
    move.l  #0x00010000, %sp

    | --- Wipe screen black so error indicators are visible. ---
    move.l  0x0824.l, %a3              | %a3 = ScrnBase, kept for paint helpers
    tst.l   %a3
    beq     halt
    cmp.l   #0x00100000, %a3
    blo     halt
    move.l  %a3, %a0
    move.l  #(128*1024/4)-1, %d0
1:  move.l  #0xFFFFFFFF, (%a0)+
    dbra    %d0, 1b

    | --- diag: paint 'A' (glyph 10) at row 8 col 4 — past screen wipe ---
    move.l  %a3, %a0
    add.l   #(8 * ROW_BYTES + 4), %a0
    moveq   #10, %d0
    bsr     draw_glyph_d0

    | --- Zero ParamBlockRec ---
    lea     pb(%pc), %a0
    moveq   #(PB_SIZE/4)-1, %d0
1:  clr.l   (%a0)+
    dbra    %d0, 1b

    | --- diag: paint 'B' (glyph 11) at row 8 col 5 — past PB zero ---
    move.l  %a3, %a0
    add.l   #(8 * ROW_BYTES + 5), %a0
    moveq   #11, %d0
    bsr     draw_glyph_d0

    | --- Driver _Read via .Sony ---
    lea     pb(%pc), %a0
    move.w  #SONY_DRIVER_REFNUM, PB_OFF_IOREFNUM(%a0)
    move.w  #1, PB_OFF_IOVREFNUM(%a0)      | drive 1 (internal floppy)
    move.l  #PAYLOAD_LOAD_ADDR, PB_OFF_IOBUFFER(%a0)
    move.l  #PAYLOAD_READ_BYTES, PB_OFF_IOREQCOUNT(%a0)
    move.w  #1, PB_OFF_IOPOSMODE(%a0)      | fsFromStart
    move.l  #PAYLOAD_DISK_OFFSET, PB_OFF_IOPOSOFFSET(%a0)
    .word   0xA002                         | _Read (dispatched to .Sony Prime)
    move.w  PB_OFF_IORESULT(%a0), %d7
    beq.s   .read_ok
    moveq   #2, %d6                        | error tag: 2=read
    bra     fail
.read_ok:

    | --- Diagnostic: paint "3" at row 8 col 4 so we know we reached
    | the jump (will be overwritten by the payload once it runs). ---
    move.l  %a3, %a0
    add.l   #(8 * ROW_BYTES + 4), %a0
    moveq   #3, %d0
    bsr.s   draw_glyph_d0

    | --- jump to payload ---
    jmp     PAYLOAD_LOAD_ADDR.l

| ----------------------------------------------------------------------
| fail: paint   <tag>  ioResult-hex   on screen, then hang.
| %d6 = tag (1=open, 2=read).  %d7 = ioResult (signed 16-bit).
| %a3 = ScrnBase.
| ----------------------------------------------------------------------
fail:
    | Paint tag digit at (row 16, col-byte 4).
    move.l  %a3, %a0
    add.l   #(16 * ROW_BYTES + 4), %a0
    move.l  %d6, %d0
    bsr.s   draw_glyph_d0

    | Paint 4 hex digits of d7 at (row 16, col-bytes 6..9).
    move.l  %a3, %a0
    add.l   #(16 * ROW_BYTES + 6), %a0
    move.w  %d7, %d5
    moveq   #3, %d4                    | 4 nibbles
.hexloop:
    move.l  %d5, %d0
    rol.w   #4, %d0
    move.w  %d0, %d5
    andi.l  #0xF, %d0
    | %d0 = nibble. Glyph index = nibble (0-15).
    bsr.s   draw_glyph_d0
    addq.l  #1, %a0
    dbra    %d4, .hexloop
halt:
1:  bra.s   1b

| draw_glyph_d0: paint the 8x8 glyph indexed by %d0 (0–15) at FB pointer %a0.
| Clobbers: %d1, %d2, %a1, %a2.
draw_glyph_d0:
    lea     hex_font(%pc), %a1
    lsl.l   #3, %d0                    | glyph index * 8
    adda.l  %d0, %a1
    move.l  %a0, %a2
    moveq   #7, %d1
1:  move.b  (%a1)+, %d2
    not.b   %d2
    move.b  %d2, (%a2)
    lea     ROW_BYTES(%a2), %a2
    dbra    %d1, 1b
    rts

| 16-glyph hex font (1=letter pixel, NOT'd at render). Indices 0-15.
hex_font:
    | '0'
    .byte 0x3C,0x42,0x46,0x4A,0x52,0x62,0x3C,0x00
    | '1'
    .byte 0x18,0x28,0x08,0x08,0x08,0x08,0x3E,0x00
    | '2'
    .byte 0x3C,0x42,0x02,0x0C,0x30,0x40,0x7E,0x00
    | '3'
    .byte 0x3C,0x42,0x02,0x1C,0x02,0x42,0x3C,0x00
    | '4'
    .byte 0x04,0x0C,0x14,0x24,0x7E,0x04,0x04,0x00
    | '5'
    .byte 0x7E,0x40,0x7C,0x02,0x02,0x42,0x3C,0x00
    | '6'
    .byte 0x1C,0x20,0x40,0x7C,0x42,0x42,0x3C,0x00
    | '7'
    .byte 0x7E,0x02,0x04,0x08,0x10,0x20,0x20,0x00
    | '8'
    .byte 0x3C,0x42,0x42,0x3C,0x42,0x42,0x3C,0x00
    | '9'
    .byte 0x3C,0x42,0x42,0x3E,0x02,0x04,0x38,0x00
    | 'A'
    .byte 0x3C,0x42,0x42,0x7E,0x42,0x42,0x42,0x00
    | 'B'
    .byte 0x7C,0x42,0x42,0x7C,0x42,0x42,0x7C,0x00
    | 'C'
    .byte 0x3C,0x42,0x40,0x40,0x40,0x42,0x3C,0x00
    | 'D'
    .byte 0x78,0x44,0x42,0x42,0x42,0x44,0x78,0x00
    | 'E'
    .byte 0x7E,0x40,0x40,0x7C,0x40,0x40,0x7E,0x00
    | 'F'
    .byte 0x7E,0x40,0x40,0x7C,0x40,0x40,0x40,0x00

    .align 2
pb:
    .space  PB_SIZE
