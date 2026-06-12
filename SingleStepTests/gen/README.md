# Oracle + hardware-bench pipeline (Macintosh IIvi: 68030 + PMMU)

Two MAME-driven capture pipelines live here:

1. **CPU** — integer-ISA corpus (instruction list carried over from
   the Mac II project; baseline captured on a MAME 68030).
2. **PMMU** — 68030 on-chip MMU corpus (new for this core).

The FPU pipeline from the Mac II project was not ported: the Macintosh
IIvi has an empty FPU socket by default, so F-line traps (covered by the
CPU corpus) are the only FPU-adjacent behavior the core needs.

Both pipelines share the same architecture: a Lua script drives a MAME
Macintosh driver, plants a small program + data into low RAM, sets
machine state, runs the instruction(s) under test, snapshots state, and
emits (a) a JSONL corpus and (b) a C header with the test bytes for the
real-hardware benches.

## Which MAME machine to drive

Any MAME 68030 Macintosh works — the MC68030 device (and its PMMU) is
identical across drivers, and no test touches chipset space:

- `maciivi` — the target machine. Needs the `maciivx` ROM set
  (`4957eb49.rom`, CRC32 `61be06e5`) plus Egret `341s0851.bin` — not on
  hand yet.
- `maciici` — works with the ROMs present today. The committed PMMU
  baseline was captured on it (2026-06-12).
- `maclc2` — the physical test machine's twin; driver present in the
  local MAME build (rebuilt 2026-06-12 with `maclc.cpp`), ROMs still
  needed (4× `341-047x` + Egret `341s0850.bin` — dumpable from the
  physical LC II).

# PMMU oracle (mame_pmmu_capture.lua)

- `mame_pmmu_smoke.lua` — run this FIRST on any new MAME build/driver.
  15 assertions: PMMU registers visible via the Lua state interface,
  PMOVE round-trips execute, PFLUSHA executes, PTESTR walks a planted
  table, and the Lua state view agrees with the PMOVE architectural
  readback (the invariant the capture rests on). All green on `maciici`,
  MAME `acad9ca235f`.
- `mame_pmmu_capture.lua` — the corpus generator. 40 tests across PMOVE
  round-trips, PFLUSH/PLOAD, PTEST walks (early-termination, 3-level,
  WP/invalid/limit, long-format, SRP-path, transparent-translation,
  An-writeback), live-translation tests (identity, remap, M/U bits, ATC
  staleness ± PFLUSHA), and faults (bus error format-$B frames, MMU
  configuration exception). Writes:
  - `/tmp/pmmu_corpus.json` — JSONL, schema in `../SCHEMA.md`
  - `/tmp/pmmu_tests.h` — `PmmuTestSpec[]` header for the preboot
    supervisor bench (committed copy: `pmmu_tests.h`)

```
cd ~/repos/mame
./mame maciici -skip_gameinfo -nothrottle -video none -sound none -seconds_to_run 120 -autoboot_delay 1 \
    -autoboot_script <repo>/SingleStepTests/gen/mame_pmmu_capture.lua
cp /tmp/pmmu_corpus.json <repo>/SingleStepTests/results/pmmu/mame_baseline_$(date +%F).json
cp /tmp/pmmu_tests.h     <repo>/SingleStepTests/gen/pmmu_tests.h
```

Unlike the CPU pipeline, the PMMU capture snapshots state via the Lua
state interface (not dump-epilogue stores): PMMU state isn't readable
by unprivileged stores, and PMOVE-based epilogues would perturb the ATC
under test. The smoke script is what makes this substitution sound. The
real-hardware runner uses PMOVE epilogues instead and the two are
diffed offline.

Capture-side invariants (violations cost an afternoon each — see
test-blockers.md "PMMU corpus / bench invariants"):
- every test program ends in the TC-disabling catcher, and all 256
  vectors point at it;
- live-translation page tables must map the supervisor stack;
- no depth-limited PTEST (#1..#6) rows — they fatalerror this MAME
  build when the search ends on a table descriptor.

# CPU oracle + hardware bench

Same architecture (MAME-driven oracle plants instructions and dumps
state; Mac-side bench runs the same byte stream and produces a matching
JSONL).

## Files

### Test generator + oracle

- `mame_cpu_capture.lua` — drives a MAME Macintosh driver via Lua.
  Builds a corpus across the common integer instruction families
  (MOVE/MOVEQ/ADD/SUB/CMP/AND/OR/EOR + immediates, MULU/MULS/DIVU/DIVS,
  NEG/NOT/CLR/SWAP/EXT, LEA, BTST/BSET/BCLR/BCHG, all 8 shift+rotate
  ops, MOVEM, MOVES, MOVE-to/from-CCR, plus 020+ ops: 32-bit MUL/DIV,
  bitfields, PACK/UNPK, scaled-index EAs), runs each test on the live
  CPU, and writes:
  - `/tmp/cpu_corpus.json` — JSON Lines, one test per line, initial +
    final state for every test
  - `/tmp/cpu_tests.h` — C header with the same test specs as a
    static `CpuTestSpec[]` array (consumed by the Mac program)

  **v1 scope**: non-control-flow instructions only. Bcc/JMP/JSR/RTS/BSR
  need dual-site dump dispatch (the dump epilogue is only reached by
  fall-through; branch targets need their own landing sites) and are
  deferred to a later phase.

  **Baseline provenance:** captured on `maciici` (MC68030) 2026-06-12.
  When control-flow tests land, add CALLM/RTM rows asserting the
  illegal-instruction trap (those opcodes are 68020-only and absent
  from the 030).

- `gen.c` — Musashi-linked random-test generator (18 opcode families,
  360 tests, SCHEMA.md format). Useful for quick local corpora without
  MAME. `make MUSASHI_DIR=<path-to-musashi-checkout>`.

### Mac OS application

- `cpu_test_macii.c` / `cpu_test_macii-sys7.c` — full CPU bench.
  `#include`s `cpu_tests.h` and iterates `g_cpu_tests[]`. Output:
  `CPU Results.jsonl` in the app's directory, in JSONL form matching
  the MAME oracle's schema. Runs unmodified on the Macintosh LC II
  (the "macii" in the filename is heritage, not a requirement).

  Tests flagged `privileged` are skipped — a Mac OS APPL runs in user
  mode, so they would trap. The bench writes zeroed init/final
  snapshots for those tests; the diff tool labels them `skipped`.

### Diff / analysis tool

- `cpu_diff_corpus.py` — compares two CPU JSONL corpora.
  - default: human-readable terminal report
  - `--json`: machine-parseable structured dump
  - `--markdown`: drop-in markdown for `SingleStepTests/results/cpu/`

  Categories: `match`, `skipped`, `ccr_only`, `flag_only`, `dreg_diff`,
  `areg_diff`, `ram_diff`, `sign_extension`, `unknown`.

## Cross-platform invariant

Test instruction bytes must be **byte-identical between MAME and the
Mac OS bench**, so any test that touches memory uses `(A6)` / `d16(A6)`
addressing with A6 pre-loaded by the harness to a *platform-specific*
scratch base. That way the same bytes run on both sides regardless of
where scratch RAM actually lives:

- MAME side: `A6 = $00001800` (an arbitrary low-RAM page we own).
- Mac side: `A6 = &scratch_ram[0]` (a 64-byte C global).

Tests must NOT preload A6 (it's reserved); the lua helper
`preload_an_scratch({[an] = offset})` emits `LEA off(A6),An` so other
A regs can be loaded with platform-correct addresses derived from A6.

### Dump-epilogue invariant

The state-dump epilogue (run before AND after each test instruction)
**must not clobber any general-purpose register**. Earlier versions
used `MOVE CCR,D0` and `MOVE.L (A0)+,(A1)+` for the scratch copy, which
clobbered D0/A0/A1 between the init dump and the test. Current sequence
uses only memory-to-memory MOVEs:
- `MOVE CCR,(abs.L)` ($42F9) — 16-bit word write; CCR byte lands at
  snap+0x41 (snap+0x40 is the zero-extended high byte).
- `MOVE.L (abs.L),(abs.L)` ($23F9) — for the 16-longword scratch copy.

If you add new dump fields, keep this constraint: any temp-register
trick will break the test it's supposed to be observing.

## Typical workflows

### Regenerate the CPU oracle + header

```
cd ~/repos/mame
./mame maciici -skip_gameinfo -nothrottle -video none -sound none -seconds_to_run 180 -autoboot_delay 1 \
    -autoboot_script <repo>/SingleStepTests/gen/mame_cpu_capture.lua
```

Produces `/tmp/cpu_corpus.json` and `/tmp/cpu_tests.h`. (Swap `maciici`
for `maciivi` once its ROM set is present.)

### Compare candidate corpus to oracle

```
python3 SingleStepTests/gen/cpu_diff_corpus.py \
    /tmp/cpu_corpus.json /path/to/candidate.jsonl
```

Add `--markdown > SingleStepTests/results/cpu/<run>.md` to save a snapshot.

### Build the Mac OS CPU bench (for the LC II)

1. Regenerate the CR-line-ending header from the latest oracle run:
   ```
   tr '\n' '\r' < /tmp/cpu_tests.h > SingleStepTests/gen/cpu_tests-sys7.h
   ```
   (The committed `cpu_tests-sys7.h` already mirrors the committed
   baseline, so this is only needed after a fresh MAME run.)
2. Transfer `cpu_test_macii-sys7.c` and `cpu_tests-sys7.h` to the Mac.
3. THINK C: New Project → Application → add the `.c`, `ANSI.π`,
   `MacTraps`. Place the `.h` in the same folder (not the picker).
4. Build Application → save as e.g. "CPU Test".
5. Run. Output: `CPU Results.jsonl` in the app's folder.

If you hit **"code overflow"** in THINK C, the `g_cpu_tests[]` array
ended up in a CODE resource (32KB per-segment ceiling). The generator
emits the array as plain `static` (not `static const`) precisely so it
lives in the data segment instead. The data segment itself can exceed
32KB via Project Type → Memory → **32-bit globals**.

## Results layout

- `SingleStepTests/results/cpu/` — CPU corpora and comparisons.
  - `mame_baseline_2026-06-12.json` — MAME 68030 oracle reference
    baseline (`maciici`). Mac II-era baselines and hardware runs were
    removed in the IIvi port; LC II runs will land here.
- `SingleStepTests/results/cpu_supervisor/` — privileged-test hardware
  captures from the preboot bench.
- `SingleStepTests/results/pmmu/` — PMMU corpora.
  - `mame_baseline_2026-06-12.json` — 40 tests, MAME `maciici` oracle.
