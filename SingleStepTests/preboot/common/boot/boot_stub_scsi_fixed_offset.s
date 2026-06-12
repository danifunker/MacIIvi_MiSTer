| boot_stub_scsi_fixed_offset.s — SCSI-bootable HFS boot block.
|
| Historical name: preboot/supervisor_bench/boot_stub_scsi.s. The
| current canonical SCSI boot block is preboot/common/boot/boot_stub_scsi.s
| (a copy of this file with a PAYLDOFF marker + .long placeholder so the
| /Payload byte offset is patched in at image-build time instead of
| being a compile-time constant). supervisor_bench's older build
| scripts still expect /Payload at the hardcoded 0x51600 offset that
| this file uses; iotest uses the patchable variant. Migrate when
| supervisor_bench's build scripts move to the flat rb-cli verbs.
|
| Same boot block header as the floppy version (bbVersion=$D000 to
| make ROM execute bbEntry directly). At bbEntry time on a SCSI
| boot, the Mac II ROM has:
|   - Read the Driver Descriptor Record (block 0)
|   - Loaded Apple_Driver43 from the driver partition
|   - Registered the driver in the Unit Table with a refnum
|   - Allocated a drive number for our HFS partition
|   - Stored that drive number in BootDrive (low-mem $0210)
|   - Added a DrvQEl to the drive queue (DrvQHdr at $0308)
|   - Read the HFS partition's boot blocks (sectors 0-1) and jumped
|     here because bbVersion=$D000.
|
| We need to load /Payload from the HFS partition. Approach:
|   1. Read BootDrive ($0210) - the drive number for "us".
|   2. Walk DrvQHdr ($030A is qHead) to find the matching DrvQEl.
|   3. Read its dQRefNum field - that's the driver refnum.
|   4. Call _Read ($A002) with PB containing that refnum.
|
| The driver presents the partition as a drive with offset 0 = start
| of HFS partition (i.e. byte 0xC000 of physical disk). So /Payload
| at byte offset 0x51600 within the partition is what we ask for.

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

PB_OFF_IORESULT     = 16
PB_OFF_IOVREFNUM    = 22
PB_OFF_IOREFNUM     = 24
PB_OFF_IOBUFFER     = 32
PB_OFF_IOREQCOUNT   = 36
PB_OFF_IOACTCOUNT   = 40
PB_OFF_IOPOSMODE    = 44
PB_OFF_IOPOSOFFSET  = 46
PB_SIZE             = 80

PAYLOAD_LOAD_ADDR     = 0x00040000
PAYLOAD_PART_OFFSET   = 0x00051600      | /Payload's byte offset within HFS partition
PAYLOAD_READ_BYTES    = 262144          | 256 KB — comfortable headroom for the CPU bench payload

| Slot at $00041000 where the boot block stashes (refnum << 16) | drive
| for the payload to find. Stable above the payload load area.
HANDOFF_ADDR          = 0x00050000

| DrvQHdr / DrvQEl
DRVQHDR_QHEAD         = 0x0000030A
BOOTDRIVE             = 0x00000210
DRVQEL_OFF_QLINK      = 0
DRVQEL_OFF_DQDRIVE    = 6
DRVQEL_OFF_DQREFNUM   = 8

startup:
    move.w  #0x2700, %sr
    move.l  #0x00010000, %sp

    | --- Wipe screen black ---
    move.l  0x0824.l, %a3
    tst.l   %a3
    beq     halt
    cmp.l   #0x00100000, %a3
    blo     halt
    move.l  %a3, %a0
    move.l  #(128*1024/4)-1, %d0
1:  move.l  #0xFFFFFFFF, (%a0)+
    dbra    %d0, 1b

    | Layout: glyphs are 8 pixels tall, space rows 12 scanlines apart.

    | --- Marker 'A' (row 4 col 4) — survived screen wipe ---
    move.l  %a3, %a0
    add.l   #(4 * ROW_BYTES + 4), %a0
    moveq   #10, %d0
    bsr     draw_glyph_d0

    | --- Read BootDrive (signed word) ---
    move.w  BOOTDRIVE.l, %d4              | %d4 = drive number for our partition
    | --- Paint drive number (4 hex digits) at (row 4 col 6) ---
    move.l  %a3, %a0
    add.l   #(4 * ROW_BYTES + 6), %a0
    move.w  %d4, %d5
    moveq   #3, %d3
.drv_hex:
    move.l  %d5, %d0
    rol.w   #4, %d0
    move.w  %d0, %d5
    andi.l  #0xF, %d0
    bsr     draw_glyph_d0
    addq.l  #1, %a0
    dbra    %d3, .drv_hex

    | --- Walk DrvQHdr to find matching dQDrive, extract dQRefNum ---
    moveal  DRVQHDR_QHEAD.l, %a1          | %a1 = qHead
    moveq   #0, %d5                       | %d5 = sanity hop counter
.scan:
    cmp.l   #0, %a1
    beq     fail_noref
    cmp.w   DRVQEL_OFF_DQDRIVE(%a1), %d4
    beq.s   .found
    moveal  DRVQEL_OFF_QLINK(%a1), %a1
    addq.l  #1, %d5
    cmpi.l  #32, %d5                      | guard: max 32 drives
    blt.s   .scan
    bra     fail_noref
.found:
    move.w  DRVQEL_OFF_DQREFNUM(%a1), %d6 | %d6 = driver refnum (negative)

    | --- Paint 'R' (glyph 'r' = use 'D' for now) + refnum hex at (row 12 col 4) ---
    move.l  %a3, %a0
    add.l   #(16 * ROW_BYTES + 4), %a0
    moveq   #13, %d0                      | 'D' = "Driver"
    bsr     draw_glyph_d0
    addq.l  #1, %a0
    move.w  %d6, %d5
    moveq   #3, %d3
.ref_hex:
    move.l  %d5, %d0
    rol.w   #4, %d0
    move.w  %d0, %d5
    andi.l  #0xF, %d0
    bsr     draw_glyph_d0
    addq.l  #1, %a0
    dbra    %d3, .ref_hex

    | --- Zero PB ---
    lea     pb(%pc), %a0
    moveq   #(PB_SIZE/4)-1, %d0
1:  clr.l   (%a0)+
    dbra    %d0, 1b

    | --- Issue _Read via the SCSI driver refnum ---
    lea     pb(%pc), %a0
    move.w  %d6, PB_OFF_IOREFNUM(%a0)     | driver refnum
    move.w  %d4, PB_OFF_IOVREFNUM(%a0)    | drive number
    move.l  #PAYLOAD_LOAD_ADDR, PB_OFF_IOBUFFER(%a0)
    move.l  #PAYLOAD_READ_BYTES, PB_OFF_IOREQCOUNT(%a0)
    move.w  #1, PB_OFF_IOPOSMODE(%a0)     | fsFromStart
    move.l  #PAYLOAD_PART_OFFSET, PB_OFF_IOPOSOFFSET(%a0)
    .word   0xA002                         | _Read
    move.w  PB_OFF_IORESULT(%a0), %d7

    | --- Paint result at (row 16 col 4) ---
    move.l  %a3, %a0
    add.l   #(28 * ROW_BYTES + 4), %a0
    moveq   #14, %d0                      | 'E' = "rEad"
    bsr     draw_glyph_d0
    addq.l  #1, %a0
    move.w  %d7, %d5
    moveq   #3, %d3
.res_hex:
    move.l  %d5, %d0
    rol.w   #4, %d0
    move.w  %d0, %d5
    andi.l  #0xF, %d0
    bsr     draw_glyph_d0
    addq.l  #1, %a0
    dbra    %d3, .res_hex

    | If read failed, just hang here so user sees the error code.
    tst.w   %d7
    bne     halt

    | --- Hand off refnum+drive in low-mem to the payload ---
    move.w  %d6, HANDOFF_ADDR.l           | refnum at $50000
    move.w  %d4, (HANDOFF_ADDR+2).l       | drive   at $50002

    | --- Paint '3' at (row 20 col 4) = about to jump ---
    move.l  %a3, %a0
    add.l   #(40 * ROW_BYTES + 4), %a0
    moveq   #3, %d0
    bsr     draw_glyph_d0

    jmp     PAYLOAD_LOAD_ADDR.l

fail_noref:
    | "FFFF" at row 16 = no matching DrvQEl found for BootDrive.
    | Lives on the same row as the (would-be) refnum readout, but if
    | we landed here the refnum was never read.
    move.l  %a3, %a0
    add.l   #(16 * ROW_BYTES + 4), %a0
    moveq   #15, %d0
    bsr     draw_glyph_d0
    addq.l  #1, %a0
    moveq   #15, %d0
    bsr     draw_glyph_d0
    addq.l  #1, %a0
    moveq   #15, %d0
    bsr     draw_glyph_d0
    addq.l  #1, %a0
    moveq   #15, %d0
    bsr     draw_glyph_d0

halt:
1:  bra.s   1b

| draw_glyph_d0: paint hex_font glyph at %a0. Clobbers d1, d2, a1, a2.
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

    .align 2
pb:
    .space  PB_SIZE
