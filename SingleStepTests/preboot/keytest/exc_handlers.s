| exc_handlers.s -- catch 68k CPU exceptions during the bench so that
| a faulting trap call doesn't crash the whole bench. Three pieces:
|
| 1. install_exc_vectors -- copy the address of common_exc_handler into
|    vectors 2..9 (bus error, address error, illegal instruction, zero
|    divide, CHK, TRAPV, privilege violation, trace). These are fault
|    vectors that should NEVER fire during a well-behaved _Read/_Write
|    trap; if one does, we want to catch it instead of crashing.
|
|    We deliberately do NOT touch:
|      - vector 0 (RESET SSP) / 1 (RESET PC) -- not exceptions in flight
|      - vectors 10/11 (A-line / F-line) -- Mac OS uses the A-line vector
|        as its trap dispatcher (every _Read/_Write call goes through it),
|        so overwriting it would break the very calls we want to harden
|      - vectors 24..31 (autovectored interrupts) -- VIA timers etc.
|      - vectors 32..47 (TRAP #0..#15) -- Mac OS uses TRAP #15 for the
|        debugger and reserves others
|
| 2. common_exc_handler -- single handler reused for all installed
|    vectors. Reads the vector number from the 68020 exception stack
|    frame's format/vector word, then iotest_longjmp's back to the
|    caller's setjmp point with the vector number as the longjmp value.
|    Does NOT RTE -- we deliberately abandon the partially-completed
|    trap, accepting that the SCSI driver's hardware state may be left
|    dangling.
|
| 3. iotest_setjmp / iotest_longjmp -- minimal C-callable save/restore
|    pair. Caller passes a JmpBuf (12 longs = 48 bytes) for setjmp to
|    populate; longjmp reads it back and "returns from" the original
|    setjmp call with the supplied value. Same idea as POSIX setjmp;
|    we can't use the libc one because we're freestanding.

.ifndef ROW_BYTES
    ROW_BYTES = 80
.endif

    .text

| --------------------------------------------------------------------
| install_exc_vectors() -- C-callable. Overwrites the ROM vector
| table for vectors 2..9 to point at common_exc_handler.
| --------------------------------------------------------------------
    .global install_exc_vectors
install_exc_vectors:
    move.l  #common_exc_handler, 0x0008.l   | vector 2 = bus error
    move.l  #common_exc_handler, 0x000C.l   | vector 3 = address error
    move.l  #common_exc_handler, 0x0010.l   | vector 4 = illegal instr.
    move.l  #common_exc_handler, 0x0014.l   | vector 5 = zero divide
    move.l  #common_exc_handler, 0x0018.l   | vector 6 = CHK
    move.l  #common_exc_handler, 0x001C.l   | vector 7 = TRAPV
    move.l  #common_exc_handler, 0x0020.l   | vector 8 = privilege
    move.l  #common_exc_handler, 0x0024.l   | vector 9 = trace
    rts

| --------------------------------------------------------------------
| common_exc_handler -- CPU enters here from an exception with the
| processor in supervisor mode and the appropriate frame on SSP. For
| all formats the first 8 bytes are:
|   +0  SR (word)
|   +2  PC (long; instruction that faulted, or next instruction
|       depending on the exception class)
|   +6  format/vector word: high 4 bits = frame format, low 12 bits =
|       vector offset (= vector_number * 4)
|
| We extract the vector number, store it in g_last_exc_vector for the
| C side to inspect, and longjmp back to wherever the bench called
| iotest_setjmp from. The exception frame is abandoned along with
| whatever SCSI driver state was in flight -- crude but it lets the
| bench survive a fault that would otherwise have ended in a Sad Mac
| or hard reset.
| --------------------------------------------------------------------
common_exc_handler:
    move.w  6(%sp), %d0                      | format/vector word
    andi.w  #0x0FFF, %d0                     | mask vector-offset bits
    lsr.w   #2, %d0                          | offset/4 -> vector number
    move.w  %d0, g_last_exc_vector
    | iotest_longjmp(&g_exc_jmpbuf, vector_number)
    ext.l   %d0
    move.l  %d0, -(%sp)
    pea     g_exc_jmpbuf
    jsr     iotest_longjmp
    | iotest_longjmp does not return.
.spin_if_longjmp_failed:
    bra.s   .spin_if_longjmp_failed

| --------------------------------------------------------------------
| u32 iotest_setjmp(JmpBuf *buf)
|   Returns 0 the first time it's called for `buf`. Returns the value
|   passed to iotest_longjmp(buf, val) on subsequent "magic" returns.
|   Saves d2-d7, a2-a5, a6 (frame ptr), sp, and the return PC.
| --------------------------------------------------------------------
    .global iotest_setjmp
iotest_setjmp:
    move.l  (%sp), %d0                       | return PC (top of stack)
    move.l  4(%sp), %a0                      | JmpBuf*
    move.l  %d0, 0(%a0)                      | saved return PC
    move.l  %a6, 4(%a0)                      | saved frame pointer
    move.l  %sp, 8(%a0)                      | saved sp (points to ret PC)
    movem.l %d2-%d7/%a2-%a5, 12(%a0)         | callee-save regs (40 bytes)
    moveq   #0, %d0                          | first call: return 0
    rts

| --------------------------------------------------------------------
| void iotest_longjmp(JmpBuf *buf, u32 val) -- does not return.
|   Restores d2-d7, a2-a5, a6, sp, then RTSes to the saved return PC
|   with %d0 = val. Caller "returns from" the matching iotest_setjmp
|   with val instead of 0.
|
| Subtle: when longjmp is called from an exception handler, the CPU's
| exception frame is sitting on the supervisor stack at addresses
| BELOW setjmp's saved sp. We "discard" the frame by overwriting sp
| with the saved value -- but that puts sp at the exact bytes the
| frame's SR/PC fields occupy, NOT at clean memory. The retPC slot
| setjmp saved at *sp was clobbered by the frame's SR + half of its
| saved PC, so a naive rts would pop SR (0x2700) as PC and jump into
| garbage. Instead: restore sp to "setjmp's saved sp + 4" (the post-
| original-rts position), then push the saved retPC from buf[0] and
| rts. That regenerates exactly the stack effect setjmp's own rts had
| -- caller can't tell the difference.
| --------------------------------------------------------------------
    .global iotest_longjmp
iotest_longjmp:
    move.l  4(%sp), %a0                      | JmpBuf*
    move.l  8(%sp), %d0                      | val (-> setjmp's return)
    movem.l 12(%a0), %d2-%d7/%a2-%a5
    move.l  4(%a0), %a6
    move.l  8(%a0), %sp                      | sp = setjmp's saved sp
                                             | (BUT possibly inside a
                                             |  stale exception frame)
    addq.l  #4, %sp                          | sp = post-rts position
    move.l  0(%a0), -(%sp)                   | push saved retPC fresh
    rts                                      | jumps to setjmp's caller

| --------------------------------------------------------------------
| Globals
| --------------------------------------------------------------------
    .data
    .align 4
    .global g_exc_jmpbuf
g_exc_jmpbuf:
    .space  48                                | 12 longs = 48 bytes
    .global g_last_exc_vector
g_last_exc_vector:
    .word   0                                 | 0 = no exception captured
