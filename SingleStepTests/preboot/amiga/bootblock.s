| bootblock.s — Amiga boot block for the 68030+PMMU test floppies.
|
| Raw-layout disk (NOT a filesystem; see AMIGA_TESTBENCH.md):
|   bytes 0x00000-0x003FF : this boot block ('DOS\0' + checksum)
|   bytes 0x00400-...     : payload flat binary (PAYLLEN! marker)
|   bytes 0x78000-0xDFFFF : raw results region (Results.jsonl stream)
|
| The Kickstart strap validates the checksum and enters at offset 12
| with A1 = trackdisk.device IOStdReq (df0:, already open) and
| A6 = ExecBase. We never return: AllocAbs the payload region at
| $80000 chip RAM, CMD_READ the payload there, flush caches, and jump
| to it with A1/A6 still live (the payload entry stores them — the
| IOStdReq is reused later to write results).
|
| Everything is PC-relative: the strap loads this block at an
| arbitrary address.
|
| Build: assembled to a flat 1024-byte image; build_amiga_adfs.sh
| patches the PAYLLEN!/ALLOCLN! marker slots and the checksum.

| exec LVOs
LVO_AllocAbs    = -204
LVO_DoIO        = -456
LVO_CacheClearU = -636

LOAD_ADDR    = 0x80000
PAYLOAD_DOFF = 0x400          | byte offset of payload on disk

| IOStdReq field offsets
IO_COMMAND = 28
IO_ERROR   = 31
IO_LENGTH  = 36
IO_DATA    = 40
IO_OFFSET  = 44
CMD_READ   = 2

    .text
    .org 0

    .ascii  "DOS"
    .byte   0                 | flags (FS type — unused, we never mount)
    .long   0                 | checksum (patched by build script)
    .long   880               | rootblock (conventional; unused)

| --- entry (offset 12) ----------------------------------------------
entry:
    bra.w   start

| --- patch slots (found by marker scan) ------------------------------
    .ascii  "PAYLLEN!"
paylen:
    .long   0                 | payload bytes to read (512-multiple)
    .ascii  "ALLOCLN!"
alloclen:
    .long   0                 | AllocAbs size (covers payload + bss)

start:
    movem.l %a1/%a6, -(%sp)       | keep ioreq + execbase

    | Claim the payload region. At bootblock time almost nothing is
    | allocated; if $80000 is taken we cannot run — flash and hang.
    move.l  alloclen(%pc), %d0
    lea     LOAD_ADDR, %a1
    jsr     LVO_AllocAbs(%a6)
    tst.l   %d0
    beq     fail

    | Read the payload: CMD_READ paylen bytes from disk offset $400.
    movem.l (%sp), %a1/%a6        | peek (leave saved)
    move.w  #CMD_READ, IO_COMMAND(%a1)
    move.l  #LOAD_ADDR, IO_DATA(%a1)
    move.l  paylen(%pc), IO_LENGTH(%a1)
    move.l  #PAYLOAD_DOFF, IO_OFFSET(%a1)
    jsr     LVO_DoIO(%a6)
    tst.b   IO_ERROR(%a1)
    bne     fail

    | Breadcrumb: prove we got this far (and that ADF writes land) by
    | writing 512 bytes to the diagnostic slot at the tail of the
    | results region. Source: this bootblock's own image (PC-relative
    | base), recognizable by its DOS header.
    movem.l (%sp), %a1/%a6
    move.w  #3, IO_COMMAND(%a1)        | CMD_WRITE
    lea     entry(%pc), %a0
    lea     -12(%a0), %a0              | back to bootblock byte 0
    move.l  %a0, IO_DATA(%a1)
    move.l  #512, IO_LENGTH(%a1)
    move.l  #0xD8000, IO_OFFSET(%a1)
    jsr     LVO_DoIO(%a6)
    move.w  #4, IO_COMMAND(%a1)        | CMD_UPDATE
    move.l  #0, IO_LENGTH(%a1)
    jsr     LVO_DoIO(%a6)

    | We just wrote code: clear caches (KS 2.0+, fine on our 3.x floor).
    jsr     LVO_CacheClearU(%a6)

    | Hand off. A1 = ioreq, A6 = ExecBase, jump to the payload.
    movem.l (%sp)+, %a1/%a6
    jmp     LOAD_ADDR

| --- failure: flash the background color forever ---------------------
fail:
    lea     0xDFF000, %a5
    moveq   #0, %d1
1:  move.w  %d1, 0x180(%a5)       | COLOR00
    addq.w  #1, %d1
    move.l  #2000, %d2
2:  subq.l  #1, %d2
    bne.s   2b
    bra.s   1b
