| recovery.s — setjmp/longjmp-style test recovery via VBR.
|
| install_vbr():
|   1. Read the current VBR (set by ROM at boot).
|   2. Copy all 256 entries to our own vbr_table.
|   3. Overwrite CPU exception vectors (2..15) and TRAP vectors
|      (32..47) with recovery_stub.
|   4. Leave Line A (vector 10) alone — _Write trap goes through it.
|      (Note: vector 10 being ROM-owned means a test that issues a raw
|      $A000 Line A trap can't be caught here — flag those hw_unsafe.)
|   5. Leave autovector interrupts (25..31) to the ROM — they are not
|      crashes, and the disk driver needs its completion IRQ to finish
|      the _Write that persists results.
|   5. MOVEC our table to VBR.
|
| invoke_test_with_recovery(entry):
|   D0 returns 0 on normal RTS, non-zero (= exception vector) if a
|   handler fired and longjmp'd us back. Caller treats non-zero as
|   "test crashed, capture what we have".

    .text
    .global install_vbr
    .global invoke_test_with_recovery

| Module-private data symbols.
    .data
    .align 4
g_resume_sp:    .long 0
g_resume_pc:    .long 0
g_last_vector:  .long 0     | set by recovery_stub before jumping back
g_tc_disable:   .long 0     | PMOVE source that forces TC.E=0 (PMMU builds)
orig_vbr:       .long 0     | the OS's VBR at install_vbr time
g_vbr_ready:    .word 0     | nonzero once vbr_table is populated

    .bss
    .align 4
    .global vbr_table
vbr_table:      .space 1024     | 256 vectors * 4 bytes
orig_vec_32_63: .space 128      | OS originals of vectors 32..63

    .text

| ---- install_vbr ----------------------------------------------------
install_vbr:
    movem.l %d0-%d2/%a0-%a2, -(%sp)

    | Idempotent: the Amiga payload calls this from the gate AND from
    | the shared bench_main. A second run would re-capture orig_vbr as
    | OUR OWN table and copy it onto itself — poisoning the platform
    | I/O bracket's use_os_vbr with a stubbed table.
    tst.w   g_vbr_ready
    bne     install_vbr_done

    | 0x4E7A 8801: movec VBR, A0 (bit 15 of operand word = An, bits 11..0 = $801 for VBR)
    .short  0x4E7A
    .short  0x8801
    move.l  %a0, orig_vbr
    lea     vbr_table, %a1
    move.w  #255, %d0
1:
    move.l  (%a0)+, (%a1)+
    dbra    %d0, 1b

    | Override CPU exception vectors 2..15 with recovery_stub, but
    | keep vector 10 (Line A) pointing to whatever ROM set up.
    lea     vbr_table, %a1
    move.l  #recovery_stub_v2,  8(%a1)      | bus error
    move.l  #recovery_stub_v3,  12(%a1)     | address error
    move.l  #recovery_stub_v4,  16(%a1)     | illegal instruction
    move.l  #recovery_stub_v5,  20(%a1)     | zero divide
    move.l  #recovery_stub_v6,  24(%a1)     | CHK
    move.l  #recovery_stub_v7,  28(%a1)     | TRAPV
    move.l  #recovery_stub_v8,  32(%a1)     | privilege violation
    move.l  #recovery_stub_v9,  36(%a1)     | trace
    | vector 10 (Line A, offset 40) intentionally left as ROM default
    move.l  #recovery_stub_v11, 44(%a1)     | Line F
    move.l  #recovery_stub_v12, 48(%a1)
    move.l  #recovery_stub_v13, 52(%a1)
    move.l  #recovery_stub_v14, 56(%a1)
    move.l  #recovery_stub_v15, 60(%a1)

    | Autovector interrupts (vectors 25..31) are deliberately LEFT to
    | the ROM. They are not "crashes" — if a test lowers IPL and the
    | 60Hz tick (or a driver's completion IRQ) fires, the ROM handler
    | services it and RTEs back to the test, which continues normally.
    | Overriding them here used to hang the bench: the .Sony / SCSI
    | driver's synchronous _Write (used to persist /Results.jsonl) lowers
    | IPL internally to wait for its completion interrupt, and routing
    | that IRQ into recovery_core jumped to a stale resume PC, so the
    | write never returned. (iotest never installed these and writes
    | fine; that was the tell.)

    | Save the OS originals of vectors 32..63 first. On AmigaOS the
    | exec SuperState()/Supervisor() path itself goes through a TRAP
    | vector — stealing 32..47 wholesale hangs the next exec call
    | (found the hard way under FS-UAE; the Mac twin of this lesson is
    | vector 10 / Line A above). The platform I/O bracket restores
    | these originals around every OS call via restore_os_traps /
    | install_recovery_traps below.
    lea     (32*4)(%a1), %a0
    lea     orig_vec_32_63, %a2
    moveq   #31, %d0
2:  move.l  (%a0)+, (%a2)+
    dbra    %d0, 2b

    | TRAP #0..#15 (vectors 32..47). Exception tests issue TRAP #N to
    | verify the trap vector; without these overrides they fall through
    | to the ROM (TRAP #15 = debugger -> Sad Mac). Safe to override: our
    | bench never calls TRAP #N itself — _Write goes through Line A.
    move.l  #recovery_stub_v32, (32*4)(%a1)
    move.l  #recovery_stub_v33, (33*4)(%a1)
    move.l  #recovery_stub_v34, (34*4)(%a1)
    move.l  #recovery_stub_v35, (35*4)(%a1)
    move.l  #recovery_stub_v36, (36*4)(%a1)
    move.l  #recovery_stub_v37, (37*4)(%a1)
    move.l  #recovery_stub_v38, (38*4)(%a1)
    move.l  #recovery_stub_v39, (39*4)(%a1)
    move.l  #recovery_stub_v40, (40*4)(%a1)
    move.l  #recovery_stub_v41, (41*4)(%a1)
    move.l  #recovery_stub_v42, (42*4)(%a1)
    move.l  #recovery_stub_v43, (43*4)(%a1)
    move.l  #recovery_stub_v44, (44*4)(%a1)
    move.l  #recovery_stub_v45, (45*4)(%a1)
    move.l  #recovery_stub_v46, (46*4)(%a1)
    move.l  #recovery_stub_v47, (47*4)(%a1)

    | Coprocessor / FP / MMU vector block 48..63. The ROM never takes
    | these mid-run (no FPU on the IIvi/LC II; the MMU is ours), and
    | the PMMU bench needs vector 56 (MMU configuration exception,
    | raised by PMOVE-to-TC with invalid geometry) to land in recovery
    | instead of the ROM.
    move.l  #recovery_stub_v48, (48*4)(%a1)
    move.l  #recovery_stub_v49, (49*4)(%a1)
    move.l  #recovery_stub_v50, (50*4)(%a1)
    move.l  #recovery_stub_v51, (51*4)(%a1)
    move.l  #recovery_stub_v52, (52*4)(%a1)
    move.l  #recovery_stub_v53, (53*4)(%a1)
    move.l  #recovery_stub_v54, (54*4)(%a1)
    move.l  #recovery_stub_v55, (55*4)(%a1)
    move.l  #recovery_stub_v56, (56*4)(%a1)
    move.l  #recovery_stub_v57, (57*4)(%a1)
    move.l  #recovery_stub_v58, (58*4)(%a1)
    move.l  #recovery_stub_v59, (59*4)(%a1)
    move.l  #recovery_stub_v60, (60*4)(%a1)
    move.l  #recovery_stub_v61, (61*4)(%a1)
    move.l  #recovery_stub_v62, (62*4)(%a1)
    move.l  #recovery_stub_v63, (63*4)(%a1)

    | Now switch VBR to our table.
    move.w  #1, g_vbr_ready
    lea     vbr_table, %a0
    | 0x4E7B 8801: movec A0, VBR
    .short  0x4E7B
    .short  0x8801

install_vbr_done:
    movem.l (%sp)+, %d0-%d2/%a0-%a2
    rts

| ---- use_os_vbr / use_recovery_vbr -----------------------------------
| Swap the WHOLE vector base between the OS's original table and ours.
| Lesson from FS-UAE bring-up: restoring only the TRAP vectors is not
| enough — exec's Supervisor()/SuperState() reach supervisor mode by
| deliberately faulting from user mode (privilege violation, vector 8),
| so ANY stubbed exception vector poisons OS calls with a stale-context
| longjmp. The platform I/O bracket flips the entire VBR instead.
    .global use_os_vbr
use_os_vbr:
    move.l  %a0, -(%sp)
    move.l  orig_vbr, %a0
    .short  0x4E7B
    .short  0x8801
    move.l  (%sp)+, %a0
    rts

    .global use_recovery_vbr
use_recovery_vbr:
    move.l  %a0, -(%sp)
    | Never point VBR at an unpopulated table (1 KB of zero vectors).
    tst.w   g_vbr_ready
    beq     1f
    lea     vbr_table, %a0
    .short  0x4E7B
    .short  0x8801
1:  move.l  (%sp)+, %a0
    rts

| ---- restore_os_traps / install_recovery_traps ----------------------
| Swap vectors 32..63 between the OS originals and the recovery stubs.
| The platform jsonl/diagnostic bracket wraps every OS call with these
| so exec's own TRAP-based plumbing works while the bench still owns
| the vectors during test execution.
    .global restore_os_traps
restore_os_traps:
    movem.l %d0/%a0-%a1, -(%sp)
    lea     orig_vec_32_63, %a0
    lea     vbr_table, %a1
    lea     (32*4)(%a1), %a1
    moveq   #31, %d0
1:  move.l  (%a0)+, (%a1)+
    dbra    %d0, 1b
    movem.l (%sp)+, %d0/%a0-%a1
    rts

    .global install_recovery_traps
install_recovery_traps:
    movem.l %a1, -(%sp)
    lea     vbr_table, %a1
    move.l  #recovery_stub_v32, (32*4)(%a1)
    move.l  #recovery_stub_v33, (33*4)(%a1)
    move.l  #recovery_stub_v34, (34*4)(%a1)
    move.l  #recovery_stub_v35, (35*4)(%a1)
    move.l  #recovery_stub_v36, (36*4)(%a1)
    move.l  #recovery_stub_v37, (37*4)(%a1)
    move.l  #recovery_stub_v38, (38*4)(%a1)
    move.l  #recovery_stub_v39, (39*4)(%a1)
    move.l  #recovery_stub_v40, (40*4)(%a1)
    move.l  #recovery_stub_v41, (41*4)(%a1)
    move.l  #recovery_stub_v42, (42*4)(%a1)
    move.l  #recovery_stub_v43, (43*4)(%a1)
    move.l  #recovery_stub_v44, (44*4)(%a1)
    move.l  #recovery_stub_v45, (45*4)(%a1)
    move.l  #recovery_stub_v46, (46*4)(%a1)
    move.l  #recovery_stub_v47, (47*4)(%a1)
    move.l  #recovery_stub_v48, (48*4)(%a1)
    move.l  #recovery_stub_v49, (49*4)(%a1)
    move.l  #recovery_stub_v50, (50*4)(%a1)
    move.l  #recovery_stub_v51, (51*4)(%a1)
    move.l  #recovery_stub_v52, (52*4)(%a1)
    move.l  #recovery_stub_v53, (53*4)(%a1)
    move.l  #recovery_stub_v54, (54*4)(%a1)
    move.l  #recovery_stub_v55, (55*4)(%a1)
    move.l  #recovery_stub_v56, (56*4)(%a1)
    move.l  #recovery_stub_v57, (57*4)(%a1)
    move.l  #recovery_stub_v58, (58*4)(%a1)
    move.l  #recovery_stub_v59, (59*4)(%a1)
    move.l  #recovery_stub_v60, (60*4)(%a1)
    move.l  #recovery_stub_v61, (61*4)(%a1)
    move.l  #recovery_stub_v62, (62*4)(%a1)
    move.l  #recovery_stub_v63, (63*4)(%a1)
    movem.l (%sp)+, %a1
    rts

| ---- recovery_stub_vN ----------------------------------------------
| One stub per vector so we can record which vector fired. Each
| stub loads its vector number into g_last_vector and jumps to the
| common recovery_core.
    .macro RSTUB n
recovery_stub_v\n:
    move.l  #\n, g_last_vector
    bra     recovery_core
    .endm

    RSTUB 2
    RSTUB 3
    RSTUB 4
    RSTUB 5
    RSTUB 6
    RSTUB 7
    RSTUB 8
    RSTUB 9
    RSTUB 11
    RSTUB 12
    RSTUB 13
    RSTUB 14
    RSTUB 15
    RSTUB 32
    RSTUB 33
    RSTUB 34
    RSTUB 35
    RSTUB 36
    RSTUB 37
    RSTUB 38
    RSTUB 39
    RSTUB 40
    RSTUB 41
    RSTUB 42
    RSTUB 43
    RSTUB 44
    RSTUB 45
    RSTUB 46
    RSTUB 47
    RSTUB 48
    RSTUB 49
    RSTUB 50
    RSTUB 51
    RSTUB 52
    RSTUB 53
    RSTUB 54
    RSTUB 55
    RSTUB 56
    RSTUB 57
    RSTUB 58
    RSTUB 59
    RSTUB 60
    RSTUB 61
    RSTUB 62
    RSTUB 63

| Common recovery: restore SP to where the bench was waiting, mask
| interrupts, set D0 to the vector that fired (non-zero), and jump
| to g_resume_pc. The bench thinks invoke_test_with_recovery() just
| returned with that value.
|
| PMMU builds (assembled with --defsym PMMU_RECOVERY=1) FIRST force
| translation off: a live-translation test that faults arrives here
| with TC.E=1, and everything recovery touches beyond the payload's
| own identity-mapped block (low-mem ScrnBase read, framebuffer DOT
| writes) would bus-error inside the handler — a double fault. The
| stubs, vbr_table, this code, and the test stack are all inside the
| payload's identity mapping, so executing the PMOVE itself is safe.
| PMOVE (g_tc_disable).L,TC = $F039 $4000 <abs32>; g_tc_disable holds 0.
recovery_core:
    .ifdef PMMU_RECOVERY
    .short  0xF039, 0x4000
    .long   g_tc_disable
    .endif
    move.l  g_resume_sp, %sp
    move.w  #0x2700, %sr
    move.l  g_last_vector, %d0
    move.l  g_resume_pc, %a0
    jmp     (%a0)

| ---- invoke_test_with_recovery -------------------------------------
| C call: int invoke_test_with_recovery(u8 *entry);
| Returns 0 on normal RTS, vector# (e.g. 5 for /0) on exception.
| Direct framebuffer markers — write one byte to a known offset of the
| framebuffer so we can see exactly how far we got, independent of C.
| ScrnBase at low-mem $0824, byte offset (row 52 * 80 + col 16) = 4176.
| Writing 0x00 = solid white pixel block, 0xFF = black; we write 0x00.
| Five distinct rows here so each phase paints a distinct dot column.
| DOT macro uses A1 so it doesn't disturb the A0 we're setting up for jsr.
| NO_SCRNBASE_DOT (--defsym): the DOTs read Mac low-mem $0824, which on
| a non-Mac (Amiga) is arbitrary chip RAM -> the write could land
| anywhere. Assemble them away on other platforms.
    .macro DOT col
    .ifndef NO_SCRNBASE_DOT
    move.l  0x0824, %a1
    add.l   #(52 * 80 + 16 + \col), %a1
    move.b  #0x00, (%a1)
    .endif
    .endm

invoke_test_with_recovery:
    DOT 0
    movem.l %d2-%d7/%a2-%a6, -(%sp)
    DOT 1
    lea     .resume(%pc), %a0
    move.l  %a0, g_resume_pc
    move.l  %sp, g_resume_sp
    DOT 2
    move.l  4+(11*4)(%sp), %a0      | entry arg (past saved regs)
    DOT 3
    jsr     (%a0)
    DOT 4
    moveq   #0, %d0                  | normal return
.resume:
    DOT 5
    movem.l (%sp)+, %d2-%d7/%a2-%a6
    rts
