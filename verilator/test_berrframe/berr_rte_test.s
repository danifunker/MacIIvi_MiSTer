| Focused Format-$B continue-past RTE unit test for TG68 (MacLCii).
| Reproduces the Mac OS bus-error-protected probe in isolation:
|   install BERR handler -> touch a faulting address -> handler clears DF
|   (SSW bit 8) + DIB, then RTE to "continue past".
| The sim's only BERR source is an FC7 (CPU-space) access (sim.v fc7_berr),
| so the probe faults via MOVES with SFC=7 (same mechanism as the boot ROM's
| RAM-size probe). Observation:
|   * BERRFRAME landed_pc  -> exact resume PC (was the continue-past PC right?)
|   * final spin PC (stale vs applied) -> was the destination register written?
| The post-probe NOP padding makes the d0 check robust to a small PC skip.

        .text
        .org    0
        .long   0x00900000          | [$00] reset: initial supervisor SP
        .long   0x00000008          | [$04] reset PC -> _lowentry ($8, low/overlay)

_lowentry:
        move.l  #_entry, %a0            | absolute (link-time) $A-space address
        jmp     (%a0)                   | jmp to $A-space ROM -> disables overlay

_entry:
        move.l  #0x00900000, %sp        | SSP -> motherboard RAM ($800000-$9FFFFF)
        move.l  #0x00800000, %d0
        movec   %d0, %vbr               | VBR -> vector table in RAM at $800000
        lea     handler, %a0
        move.l  %a0, 0x00800008         | BERR vector (vec 2) = VBR + 8
        moveq   #7, %d1
        movec   %d1, %sfc               | SFC = 7  -> the MOVES read is an FC7 cycle (faults)
        move.l  #0x00022000, %a1
        move.l  #0x55555555, %d0        | sentinel: survives iff DIB writeback skipped
probe:
        moves.l (%a1), %d0             | <-- FC7 read -> BERR (Format-$B). next instr = pad0
pad0:   nop                            | skip-tolerance padding (the correct resume is HERE)
        nop
        nop
        nop
chk:
        cmpi.l  #0x55555555, %d0       | did d0 keep the sentinel?
        bne     d0_applied             | d0 changed -> DIB/EA value written
d0_stale:
        nop                            | d0 == sentinel -> destination register STALE
        bra     d0_stale
d0_applied:
        nop                            | d0 overwritten -> writeback happened
        bra     d0_applied

        .globl  handler
handler:
        andi.w  #0xfeff, 10(%sp)       | clear SSW bit 8 (DF) at frame+$0A  (OS pattern)
        clr.l   44(%sp)                | clear DIB at frame+$2C
        rte                            | continue-past
        .even
