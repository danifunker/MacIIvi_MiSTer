# Supervisor-Mode Bench Results

Per-test results from `SingleStepTests/preboot/supervisor_bench/`,
booting from BlueSCSI. These cover the **privileged** and
**raises_exception** tests that the user-mode bench in
`gen/cpu_test_macii.c` skips — and, once the PMMU runner lands, the
PMMU corpus.

> The capture files that previously lived here came from the Mac II
> (68020) project and were removed in the IIvi port — privileged rows
> (CACR in particular) are CPU-generation-specific. Fresh captures from
> the **Macintosh LC II** (68030) land here; the schema notes and
> architectural quirks below carry over unchanged.

Format per file: `test_<id>_<shortname>.jsonl` — one JSON line per test
result, schema matches the MAME oracle's so `gen/cpu_diff_corpus.py`
can diff them.

JSON schema:
```
{
  "name":  "<test name from cpu_tests.h>",
  "vec":   <exception vector, 0 = clean return>,
  "final": {
    "d":   [D0..D7],
    "a":   [A0..A7],         // A7 is the C stack pointer at dump time
    "ccr": <byte>,
    "pc":  <abs addr of final dump in our prog_buffer>,
    "ram": [scratch_ram[0..63]]
  }
}
```

The schema is a subset of the MAME corpus format (which also has an
"initial" snapshot). The supervisor bench currently only emits the
"final" snapshot since the initial state is fully determined by the
harness preamble (D0..D7=0, A0..A5=0, A6=scratch, CCR=0,
SFC=DFC=5 — see [function codes
doc](../../../docs/680x0_function_codes.md)).

## Notes

| pc / a7 addresses | The `pc` field is the address inside our payload's `prog_buffer` static buffer where the FINAL state dump runs. That's at a known compile-time offset, not at the test instruction itself. To compare against the MAME oracle, we look at the *delta* (final.pc − initial.pc) which should equal `test_len` — not the absolute address. |
| A6 / A1 | The harness sets A6 = `&scratch_ram[0]` before the test, so A6 always matches the scratch base. Most tests then either load A1 = A6 (`LEA 0(A6),A1`) or use A6 directly. |

## Results

All 23 privileged tests captured. 22 returned cleanly; one (test 180,
`ANDI.W #$F8FF,SR`) took an exception that the recovery code caught
and recorded — see the analysis for that test.

| 1-based id | Test | Status |
|---|---|---|
| 171 | `MOVES.L D0,(A1)` | ✓ clean |
| 172 | `MOVES.B D0,(A1)` | ✓ clean |
| 173 | `MOVES.W D0,(A1)` | ✓ clean |
| 174 | `MOVES.L (A1),D0` (load) | ✓ clean |
| 175 | `MOVE.W SR,D0` | ✓ clean |
| 176 | `MOVE.W SR,(A6)` | ✓ clean |
| 177 | `MOVE.W D0,SR  D0.W=$2700` | ✓ clean |
| 178 | `MOVE.W #$2700,SR` | ✓ clean |
| 179 | `ANDI.W #$FFFF,SR` (no-op) | ✓ clean |
| 180 | `ANDI.W #$F8FF,SR` clear T1+M+I | **caught vec=26 (level 2 IRQ autovec)** |
| 181 | `ORI.W #$0700,SR  set IPL=7` | ✓ clean |
| 182 | `ORI.W #$001F,SR  set all CCR bits` | ✓ clean |
| 183 | `EORI.W #$0010,SR  toggle X` | ✓ clean |
| 184 | `RTE simple 8-byte frame to label` | ✓ clean |
| 185 | `MOVEC.L SFC,D0` | ✓ clean |
| 186 | `MOVEC.L DFC,D0` | ✓ clean |
| 187 | `MOVEC.L VBR,D0` | ✓ clean |
| 188 | `MOVEC.L CACR,D0` | ✓ clean |
| 189 | `MOVEC.L D0,SFC; SFC,D1 round-trip` | ✓ clean |
| 190 | `MOVEC.L D0,DFC; DFC,D1 round-trip` | ✓ clean |
| 191 | `MOVEC.L D0,CACR; CACR,D1 write 0` | ✓ clean |
| 192 | `MOVE.L A0,USP A0=$DEADBEEF` | ✓ clean |
| 193 | `MOVE.L USP,A1 read back USP` | ✓ clean |

## Analysis (per test)

### Test 171 — `MOVES.L D0,(A1)`

Preload: `MOVE.L #$CAFEF00D, D0`; `LEA 0(A6), A1`.
Test bytes: `0x0E91 0x0800` = `MOVES.L D0, (A1)`.

Observed:
- D0 = `0xCAFEF00D` ✓ (preload set, MOVES doesn't modify source)
- A1 = `0x6261E` (scratch_ram address) ✓
- A6 = `0x6261E` (same — harness set, preload's LEA preserves) ✓
- A7 = `0xFFEA8` ≈ near 1 MB (the SP we set in payload_entry, after some pushes for the C call into bench_main)
- scratch_ram[0..3] = `[0xCA, 0xFE, 0xF0, 0x0D]` ✓ — MOVES wrote D0 to memory in big-endian order
- scratch_ram[4..63] = all zeros (test only wrote 4 bytes)
- CCR = 4 (Z bit set; needs MAME comparison — MOVES doesn't normally touch CCR, this may be residue from the harness's `MOVE #0,CCR` followed by the preload's MOVE.L not clearing Z when source value is non-zero)
- vec = 0 (clean return, no exception)

The key proof: **the test ran successfully in supervisor mode** and the
memory write landed where expected. This validates:
- The boot block + SCSI driver load path
- The SFC/DFC=5 harness fix
- The state dump → JSONL writer → SCSI write → disk persist → rusty-backup extract pipeline

### Test 172 — `MOVES.B D0,(A1)`

Preload: `MOVE.L #$000000A5, D0`; `LEA 0(A6), A1`.
Test bytes: `0x0E11 0x0800` = `MOVES.B D0, (A1)` (size=00=byte).

Observed:
- D0 = `0xA5` ✓ (preload set)
- A1 = A6 = `0x6261E` (scratch_ram) ✓
- A7 = `0xFFEA8` (same SP context as previous test)
- scratch_ram[0] = `0xA5` ✓ — only the low byte of D0 written
- scratch_ram[1..63] = all zeros ✓ — byte-size MOVES doesn't touch adjacent bytes
- CCR = 4, vec = 0 ✓

Confirms byte-size MOVES with DFC=5 works correctly.

### Test 173 — `MOVES.W D0,(A1)`

Preload: `MOVE.L #$0000BEEF, D0`; `LEA 0(A6), A1`.
Test bytes: `0x0E51 0x0800` = `MOVES.W D0, (A1)` (size=01=word).

Observed: D0=`0xBEEF` ✓, ram[0..1]=`BE EF` ✓ (big-endian word write),
ram[2..63] zeros ✓. CCR=4, vec=0.

### Test 174 — `MOVES.L (A1),D0` (load via SFC)

Preload: `MOVE.L #$11111111, D0` (placeholder); `LEA 0(A6), A1`. The
test's `ram_init` puts `DE AD BE EF 00...` at scratch[0..63], so the
MOVES.L load will pull 0xDEADBEEF from (A1).

Test bytes: `0x0E91 0x0000` = `MOVES.L (A1), D0` (size=10=long,
ext bit 11=0 → load memory into register).

Observed: D0=`0xDEADBEEF` ✓ (loaded from scratch, overwriting the
preload's 0x11111111). ram[0..3]=`DE AD BE EF` ✓ (unchanged).
CCR=4, vec=0.

Confirms the load-direction of MOVES with SFC=5.

### Test 175 — `MOVE.W SR,D0`

Preload: `MOVE.L #$AAAA0000, D0`. Test: `0x40C0` = `MOVE.W SR, D0`.

Observed: D0=`0xAAAA2704` ✓ (high word preserved; low word = SR =
supervisor S=1, IPL=7, Z=1 from harness's CLR.L). Validates we can
read SR and the recovery infrastructure left us at $2700 + Z=1.

### Tests 176–193 (batch run, 18 tests)

Captured in a single batch run (`bench_main.c` looping over indices
175..192, blackout between tests, write all results in one disk
write at end). 17 returned cleanly; test 180 caught an exception via
the recovery code.

#### Test 180 — `ANDI.W #$F8FF,SR clear T1+M+I` — recovery fired

This is the test that broke the bench before we installed VBR
handlers. `ANDI.W #$F8FF, SR` clears the IPL field of SR — the CPU
goes from IPL=7 (all masked) to IPL=0 (all enabled). A pending
level-2 interrupt fires on the very next instruction.

Vector 26 = level 2 autovector interrupt. On Mac II this is typically
the SCC (Serial Communications Controller) — likely a stale interrupt
left over from boot or the SCSI driver's earlier activity.

Our `install_vbr()` + `recovery_stub_v26` caught the exception, longjmp'd
back into `invoke_test_with_recovery` with `vec=26`, the bench
re-masked SR=$2700, and proceeded to test 181. **The bench's exception
recovery infrastructure works as designed.**

This is an important calibration point: when comparing this test's
result to the MAME oracle, MAME has no SCC interrupt pending so its
result will be the clean post-ANDI state. Our hardware result will
show `vec=26` with the state captured at the exception point.

For the comparison logic in `cpu_diff_corpus.py`, this test should
either be flagged as "hw-only outcome" or its final.d/a/ram should be
ignored when `vec != 0`.

### Tests 185–191 — `MOVEC` round-trips and reads

All seven MOVEC tests (SFC, DFC, VBR, CACR reads + 3 write-then-read
round-trips) returned clean. This confirms that:
- VBR can be read back as our installed VBR address (some non-zero RAM addr).
- SFC and DFC read back as 5 (which we set in the harness preamble).
- CACR write of 0 then read back returns 0 (writeable bits cleared).

### Tests 192–193 — USP access

`MOVE.L A0,USP` and `MOVE.L USP,A1` both clean. The USP register is
preserved across our supervisor-mode test loop.

## raises_exception tests

These 19 tests are *designed* to throw a CPU exception. The bench
distinguishes them in the output JSON by emitting `"trap_state"`
(the pre-trap snapshot, captured by build_program's init dump that
ran *before* the test instruction) instead of `"final"`. `vec` holds
the exception vector number.

For the diff tooling: when comparing against MAME, the right
comparison for these tests is `(vec, trap_state)` vs MAME's
post-trap recorded state.

### raises_exception batch (19 tests)

All 19 raises_exception tests captured in one batch run with the
`ONLY_RAISES_EXCEPTION` filter set. JSON shape is `{"name", "vec",
"trap_state": {...}}` (no `"final"`).

| id | Test | Expected vec | Observed vec | Status |
|---|---|---:|---:|---|
| 456 | `CHK2.W (A6),D0  out-of-range`     | 6 | 6 | ✓ |
| 577 | `DIVS.L D1,D0:D0  divide by zero`  | 5 | 5 | ✓ |
| 578 | `DIVU.L D1,D0:D0  divide by zero`  | 5 | 5 | ✓ |
| 630 | `CHK.L D1,D0  D0>D1`               | 6 | 6 | ✓ |
| 632 | `TRAPT`                            | 7 | 7 | ✓ |
| 665 | `TRAPT.W #0`                       | 7 | 7 | ✓ |
| 666 | `TRAPT.L #0`                       | 7 | 7 | ✓ |
| 667 | `TRAPEQ` (Z=1)                     | 7 | 7 | ✓ |
| 707 | `ILLEGAL ($4AFC)`                  | 4 | 4 | ✓ |
| 708 | `DIVU.W #0,D0`                     | 5 | 5 | ✓ |
| 709 | `DIVS.W #0,D0`                     | 5 | 5 | ✓ |
| 710 | `CHK.W D1,D0  D0>D1`               | 6 | 6 | ✓ |
| 711 | `CHK.W D1,D0  D0<0`                | 6 | 6 | ✓ |
| 712 | `MOVE #2,CCR ; TRAPV (V=1)`        | 7 | 7 | ✓ |
| 713 | `TRAP #0`                          | 32 | **2** | ⚠ ROM handler bus-errors |
| 714 | `TRAP #7`                          | 39 | **2** | ⚠ |
| 715 | `TRAP #15`                         | 47 | **2** | ⚠ |
| 716 | `JMP (A0) odd address`             | 3 | 3 | ✓ |
| 717 | `Line A trap ($A000)`              | 10 | **2** | ⚠ Line A intentionally not overridden |

15/19 match the test's intended vector. The other 4 (TRAP #0/7/15 and
Line A) all show `vec=2` — bus error.

### Why TRAP #N and Line A produce vec=2 (not their nominal vectors)

These are NOT bugs in our test infrastructure — they're a consequence
of two deliberate decisions in `recovery.s`:

1. **No stubs for vectors 32–47 (TRAP #0…#15).** When a test does
   `TRAP #N`, the CPU jumps to the vector at `VBR + (32+N)*4`. Our
   `install_vbr` *copies* the ROM's vector table verbatim except for
   the ~20 specific entries we override (CPU exceptions 2–15, IRQ
   autovectors 25–31). The TRAP vectors still point to ROM code.
   ROM's TRAP handlers expect Mac OS structures (Trap Dispatch Table,
   System heap, etc.) that don't exist when we boot pre-OS. The ROM
   handler dereferences a wild pointer → bus error → our vec=2
   handler fires.

2. **Vector 10 (Line A) intentionally preserved.** We use Line A
   traps for `_Read`/`_Write` to the SCSI driver — they're the
   _entire_ I/O path. If we override vector 10, the bench can't talk
   to disk anymore. So we leave it pointing at ROM. The ROM Line A
   dispatcher looks up the trap number ($A000 in this test) in the
   Trap Manager's tables, which again don't exist pre-OS, so it
   eventually faults → bus error → vec=2.

These four divergences are **architectural** rather than failures of
the test code. The TRAP #N tests in particular are well-defined on a
bare 680x0 in isolation but undefined in a "Mac minus OS" environment.
When diffing against MAME, the four tests above need a special case
that records "this is hardware-specific behaviour due to missing OS
context."

If we want to capture the *real* trap vectors for these four tests,
the fix is:
  - For TRAP #0–#15: add recovery_stub_v32 through recovery_stub_v47 in
    `recovery.s`. Each just records the vector and longjmps.
  - For Line A: harder. We'd need a custom Line A dispatcher that
    routes our specific `_Read`/`_Write` trap codes ($A002, $A003,
    $A004) to the SCSI driver but records anything else as an
    exception. About 20 lines of asm.

### Test 456 — `EXC: CHK2.W (A6),D0  out-of-range (D0=0x100)`

Preload sets D0=0x100. `ram_init` puts bounds `00 10 00 30` (16, 48)
at scratch_ram[0..3]. CHK2.W checks D0.W against [scratch[0..1],
scratch[2..3]] — 256 is way out of [16, 48], so it traps to vector 6
(CHK exception).

Observed: `vec=6` ✓, D0=256 ✓, A6=scratch_base, ram[0..3]=[0,16,0,48]
(unchanged from init), CCR=4 (Z=1 from harness CLR.L), pc=402248 (in
our prog_buffer, at the CHK2 instruction). The recovery path picked
up the exception correctly and the trap_state matches what we set up
just before the CHK2.

## Discovered architectural quirks

- **FC=0 bus error on MOVES with default DFC**: see
  [`docs/680x0_function_codes.md`](../../../docs/680x0_function_codes.md).
  At reset, SFC and DFC read as 0, the "Undefined, Reserved" function
  code per the M68000-family UMs. Real Mac II hardware does not
  acknowledge bus cycles with FC=0, so MOVES with default DFC takes a
  bus error (vector 2). Our harness now sets SFC=DFC=5 (supervisor
  data space) before running any test.
