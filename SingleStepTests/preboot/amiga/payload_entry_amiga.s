| payload_entry_amiga.s — entry shim for the Amiga 68030+PMMU bench
| payloads. Entered by bootblock.s at $80000 with A1 = trackdisk
| IOStdReq and A6 = ExecBase.
|
| Responsibilities (Amiga analog of payload_entry_cpu.s on the Mac):
|   1. Stash ioreq/ExecBase for the trackdisk jsonl backend.
|   2. SuperState() -> supervisor on our own task; SR = $2700.
|   3. Save INTENA, then take the custom chips: interrupts off,
|      DMA off, our copper list + one hires bitplane (640 wide,
|      80-byte stride -- the stride the shared display kernel paints),
|      COLOR00 white / COLOR01 black so the inverted-font paint looks
|      like the Mac bench (white text on black).
|   4. 68030+MMU gate (amiga_gate.c) -- halts with a painted message
|      on anything else.
|   5. bench_main() (shared CPU or PMMU runner).
|
| Multitasking is left intact (no Forbid): the jsonl backend drops to
| user mode and re-enables interrupts around each trackdisk DoIO, which
| needs the scheduler for its task + reply signals.

LVO_SuperState = -150

CUSTOM   = 0xDFF000
INTENAR  = 0x01C
COP1LCH  = 0x080
COPJMP1  = 0x088
DIWSTRT  = 0x08E
DIWSTOP  = 0x090
DDFSTRT  = 0x092
DDFSTOP  = 0x094
DMACON   = 0x096
INTENA   = 0x09A
INTREQ   = 0x09C
BPLCON0  = 0x100
BPLCON1  = 0x102
BPLCON2  = 0x104
BPL1MOD  = 0x108
COLOR00  = 0x180
COLOR01  = 0x182

FB_ROWS  = 480                  | display_wipe(480) touches this much
FB_BYTES = FB_ROWS * 80

    .text
    .global _payload_start
_payload_start:
    | --- 1. handoff ---------------------------------------------------
    move.l  %a1, g_amiga_ioreq
    move.l  %a6, g_amiga_execbase

    | Breadcrumb 2: payload entry reached (OS still fully alive).
    move.w  #3, 28(%a1)                | CMD_WRITE
    move.l  #_payload_start, 40(%a1)   | io_Data
    move.l  #512, 36(%a1)              | io_Length
    move.l  #0xD8200, 44(%a1)          | io_Offset
    jsr     -456(%a6)                  | DoIO
    move.w  #4, 28(%a1)                | CMD_UPDATE
    move.l  #0, 36(%a1)
    jsr     -456(%a6)
    move.l  g_amiga_ioreq, %a1

    | --- 2. supervisor ------------------------------------------------
    jsr     LVO_SuperState(%a6)
    move.l  %d0, g_super_ssp
    move.w  #0x2700, %sr

    | --- 3. take the machine -------------------------------------------
    lea     CUSTOM, %a5
    move.w  INTENAR(%a5), %d0
    move.w  %d0, g_saved_intena
    move.w  #0x7FFF, INTENA(%a5)
    move.w  #0x7FFF, INTREQ(%a5)
    move.w  #0x7FFF, DMACON(%a5)

    | display: hires, 1 bitplane, PAL/NTSC-safe window
    move.w  #0x9200, BPLCON0(%a5)
    move.w  #0x0000, BPLCON1(%a5)
    move.w  #0x0000, BPLCON2(%a5)
    move.w  #0x0000, BPL1MOD(%a5)
    move.w  #0x003C, DDFSTRT(%a5)
    move.w  #0x00D4, DDFSTOP(%a5)
    move.w  #0x2C81, DIWSTRT(%a5)
    move.w  #0x2CC1, DIWSTOP(%a5)
    move.w  #0x0FFF, COLOR00(%a5)      | pixel=0 -> white (glyph ink)
    move.w  #0x0000, COLOR01(%a5)      | pixel=1 -> black (background)

    | copper list: point BPL1PT at the framebuffer each frame
    lea     copper_list, %a0
    lea     framebuffer, %a1
    move.l  %a1, %d0
    move.w  #0x00E0, (%a0)+            | BPL1PTH
    swap    %d0
    move.w  %d0, (%a0)+
    move.w  #0x00E2, (%a0)+            | BPL1PTL
    swap    %d0
    move.w  %d0, (%a0)+
    move.l  #0xFFFFFFFE, (%a0)+        | end of list
    lea     copper_list, %a0
    move.l  %a0, COP1LCH(%a5)
    move.w  %d0, COPJMP1(%a5)          | strobe (data ignored)
    move.w  #0x8380, DMACON(%a5)       | SET | MASTER | COPPER | RASTER

    | shared display kernel paints through this pointer
    lea     framebuffer, %a0
    move.l  %a0, g_display_fb

    | --- 4. gate, 5. bench ---------------------------------------------
    jsr     amiga_gate
    tst.l   %d0
    bne     .hang
    jsr     bench_main
.hang:
1:  bra.s   1b

| --------------------------------------------------------------------
| Globals shared with C
| --------------------------------------------------------------------
    .data
    .align 4
    .global g_amiga_ioreq
    .global g_amiga_execbase
    .global g_super_ssp
    .global g_saved_intena
    .global g_handoff_refnum
    .global g_handoff_drive
    .global g_results_offset
    .global g_results_max_bytes
g_amiga_ioreq:      .long 0
g_amiga_execbase:   .long 0
g_super_ssp:        .long 0
g_saved_intena:     .word 0
| Mac-compat handoff fields referenced by the shared runners (unused
| by the trackdisk backend).
g_handoff_refnum:   .word 0
g_handoff_drive:    .word 0
| Raw-layout results region (see bootblock.s / build_amiga_adfs.sh).
g_results_offset:     .long 0x78000
g_results_max_bytes:  .long 409600

    .bss
    .align 4
copper_list:        .space 16
    .global framebuffer
framebuffer:        .space FB_BYTES
