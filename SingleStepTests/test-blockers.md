# SingleStepTests — Status & Blockers (Macintosh IIvi / 68030 + PMMU)

Ported 2026-06-12 from `lbmactwo_MiSTer` (Mac II / 68020 project). All
FPU and CPU+FPU sections were dropped with the benches themselves — the
IIvi ships without an FPU. CPU-side history below is preserved verbatim
where still accurate; new 68030/PMMU material is at the top.

## 68030 gap list (what the upcoming core must add over the TG68K kernel)

The CPU bench drives `TG68KdotC_Kernel` with `CPU=2'b11` (its most
capable mode). Known deltas a 68030-correct core must close, ordered by
how much the Mac IIvi ROM / System 7 cares:

1. **On-chip PMMU.** PMOVE / PTEST / PLOAD / PFLUSH (coprocessor ID 0),
   TC / TT0 / TT1 / CRP / SRP / PSR registers, 3-level table walks with
   early termination, ATC, U/M descriptor updates, format-$B bus-fault
   frames with instruction restart. This is new RTL (a wrapper around
   the integer kernel), benched by `pmmu/` against
   `results/pmmu/mame_baseline_2026-06-12.json` (40 tests, verified
   against MAME 2026-06-12).
2. **CALLM / RTM must trap as illegal.** The 68030 dropped that
   68020-only pair. Corpus rows exist (2026-06-12): the CALLM golden
   shows the correct vec-4 frame; the **RTM golden is known-bad**
   (MAME quirk #3 below) — a core that correctly traps RTM will fail
   that row, and that failure is the desired behavior until a
   real-silicon golden replaces it.
   **ADJUDICATED on real 68030 silicon (Macintosh IIcx, 2026-06-13):
   RTM `D0` takes the vec-4 illegal trap** (matching the Amiga/WinUAE
   oracle). MAME's no-op golden is confirmed wrong; the corrected golden
   for `EXC: RTM D0` is `vec=4`. CALLM already matched (vec 4 on both).
   Run: `results/cpu_supervisor/maciicx_cpu_2026-06-13.jsonl`.
3. **CACR data-cache bits.** 030 adds IBE + WA/DBE/CD/CED/FD/ED to
   the 020's EI/FI/CEI/CI. The corpus's discriminator row
   `MOVEC.L D0,CACR; CACR,D1 write all-ones` has golden
   **D1 = $0000FF13** (MAME's 030 mask `$FF1F` minus the self-clearing
   CI/CEI). A 68020-behaving core fails it with `D1: got 0x00000003`;
   a core ignoring CACR fails with `got 0x00000000`.
   **ADJUDICATED on real 68030 silicon (Macintosh IIcx, 2026-06-13):
   the readback is `D1 = $00003313`, not MAME's `$FF13`** (bits 14-15
   don't exist; CD/CED self-clear, exactly as predicted, and matching the
   Amiga/WinUAE oracle). MAME's `$FF13` is confirmed wrong; the corrected
   golden is `$00003313`. The IIcx is a different machine than the
   project's nominal LC II, but the same MC68030 core, so this verdict is
   authoritative for the integer ISA.
4. **Bus fault frame format $B** (92 bytes) replaces the 020's $A/$B
   sizes in MMU-fault paths; the PMMU corpus's FAULT rows carry real
   frames to compare against.
5. **MMU configuration exception** (vector 56, format $2) on enabling
   an invalid TC. Captured in the corpus.

## MAME oracle quirks (mame0287-736-gacad9ca235f)

Found while building the PMMU corpus — treat these rows with care and
cross-check on the physical LC II:

1. **Depth-limited PTEST is a MAME landmine.** PTEST with level #1..#6
   whose search ends on a *table* descriptor (not a page descriptor)
   hits `fatalerror("Table walk did not resolve")` in
   `src/devices/cpu/m68000/m68kmmu.h:591` — MAME exits. MAME counts the
   root-pointer fetch as a level, so even `PTESTR #5,(A0),#1` against an
   early-termination tree dies. Real silicon reports the partial walk in
   PSR. Consequence: corpus v1 has only `#0` (pure ATC probe) and `#7`
   (full walk) forms. Depth-limited goldens must come from the real
   LC II (or a patched MAME — patch is a candidate upstream fix).
2. **Root-limit violations report PSR=I|N, not L.** Real 030 sets the
   L (limit) bit; MAME folds it into INVALID. The corpus row
   `PTESTR ... root limit violation (L)` records MAME's `0x0401`.
   **ADJUDICATED on real silicon (Macintosh IIcx, 2026-06-13): PSR =
   `$4400`** (L | I, N=0). Corrected golden is `$4400`. All three oracles
   disagreed here — MAME `$0401`, WinUAE A3000 `$0001`, real 030 `$4400`
   — which is exactly why silicon was needed.
3. **RTM is a silent no-op on MAME's 030/040.** Musashi wires opcode
   `$06C0` into the 030 decode table (handler `x06c0_rtm_l_234fc`) as a
   `logerror` no-op — no trap, no module pop. Real 68030 silicon takes
   the vec-4 illegal trap (CALLM, by contrast, is correctly 020-only in
   the decode table and traps). The corpus row is named
   "MAME golden known-bad"; expect correct cores to fail it. Upstream
   fix candidate. **CONFIRMED on real silicon (Macintosh IIcx,
   2026-06-13): RTM `D0` traps vec 4** — second real-silicon oracle to
   contradict MAME (after the FS-UAE/WinUAE A3000 run). See gap-list
   item 2 above.
4. **PMOVE-to-PSR is accepted** (`m68851_pmove` case 3 writes m_mmu_sr)
   — fine — but MAME treats PSR as **fully writable**: the corpus row
   `PMOVE PSR w/r (write $FFFF)` reads back `$FFFF`. **ADJUDICATED on real
   silicon (Macintosh IIcx, 2026-06-13): the implemented-bit mask is
   `$EE47`** — writing all-ones reads back `$EE47`. The WinUAE A3000 also
   read `$FFFF`, so this is an **IIcx-only finding**: neither emulator
   models the PSR write mask. Corrected golden is `$EE47`.
5. **PTEST ignores transparent translation (MAME sets the T bit).** The
   030's `PTEST` always does a table search and does *not* consult TT0/TT1
   (the T bit reports a transparent hit only via the bus, not via PTEST).
   MAME sets PSR `T` (`$0040`) for `PTESTR ... through TT0`; **real
   silicon (IIcx, 2026-06-13) walks the table and reports PSR = `$0001`
   (N=1, no T)**. Corrected golden is `$0001`. (WinUAE returned `$0000`.)
6. **MMU-configuration exception is vector 56 — confirmed.** The fault
   row `PMOVE TC enable with bad geometry` takes **vec 56** on both MAME
   and real silicon (IIcx, 2026-06-13). The FS-UAE/WinUAE A3000 took
   vec 11 (F-line) here — a WinUAE bug, now cleared; MAME and hardware
   agree, no corpus change.
7. **maciici vs maciivi as capture host:** the MC68030 device is
   identical; no PMMU test in the corpus touches chipset space. When the
   `maciivx` ROM set lands, re-run both captures and diff — expect
   byte-identical corpora.

Real-silicon PMMU run: `results/pmmu/maciicx_pmmu_full_2026-06-13.jsonl`
(37/40 vs MAME baseline; 40/40 vs `results/pmmu/golden_2026-06-13.json`).
The depth-limited PTEST landmine (#1) is still unadjudicated — the corpus
carries no depth-limited rows to exercise it, so it awaits a patched MAME
or hand-built hardware goldens.

## PMMU corpus / bench invariants (learned building it)

- **32-bit-clean ROMs boot with the MMU ENABLED.** Touching CRP/TT
  while the ROM's translation is live rips the mapping out from under
  the executing code. The hardware runner therefore saves the ROM's
  full MMU state at startup, force-disables translation as the FIRST
  instruction of every generated program, and restores the ROM state
  after every test. Writing a root pointer whose DT=0 raises the
  MMU-config exception — never "restore" a never-initialized CRP/SRP.
- **The boot mapping is NOT identity on vampiric-video machines.**
  MAME `maciici` (RBV): main RAM is physically in Bank B; disabling
  translation mid-run sends the PC into unmapped space. The runner's
  identity probe announces itself on screen + in the results file
  before attempting the transition. Dedicated-VRAM machines (LC II V8,
  IIvi VASP) are expected identity — confirm on the LC II first boot.
- **Relocation must NOT touch walk inputs.** A-register initial values
  are virtual addresses whose BITS select table indices; relocating
  them shifts the walk into the wrong descriptors. Only plants,
  descriptor address fields, embedded absolute addresses, CRP/SRP
  aptrs, and the test stack pointer relocate.
- **U/M bits encode placement.** The capture environment's own
  fetches/stores (program at $1000, vectors at $0, stack at $7FFxx,
  table edits) set U/M in the tables. `gen/pmmu_diff_corpus.py` masks
  those on live/fault rows; the remap-page descriptors keep strict
  U/M comparison.

- **The catcher must disable translation on every exit path.** Program
  layout is `[test][PMOVE (TC_OFF).L,TC][JMP self]` with all vectors
  pointed at the catcher. Without this, a fault mid-test leaves the MMU
  enabled for the next test (MAME's `m_pmmu_enabled` is only recomputed
  by PMOVE-to-TC, not by Lua state writes — and real hardware behaves
  the same way: nothing but PMOVE/reset clears TC.E).
- **Map the supervisor stack in live tests.** First capture attempt
  left va `$7xxxx` unmapped in the 3-level tree; the bus-error frame
  push itself then faulted (double fault), and MAME wandered off with
  SSP=$FF70. `three_level()` now identity-maps `$070000-$07FFFF` via an
  early-termination level-B descriptor. The same discipline applies to
  the FPGA bench and the real-hardware runner.
- **PTEST's An writeback is the descriptor address, not the translated
  address.** Corpus row `PTESTR #5,(A0),#7,A1` returns `$3204` (the
  level-C descriptor for va `$1800`), matching the 68030 PRM. Don't
  "fix" this in the bench.
- **PSR only changes on PTEST / PMOVE-to-PSR.** Faults do not write it.

## What works end-to-end

### CPU bench (`tg68k/`)
- Verilator builds clean. (Note: this machine needs
  `apt install verilator`; the project previously built on macOS.)
- Runs JSON tests against the raw `TG68KdotC_Kernel` (CPU=2'b11).
- Per-test flow: plant SSP/PC at reset vectors → reset → inject D0–D7/A0–A7
  into the kernel's regfile arrays → run until the dump-epilogue write
  lands → compare regfile + CCR + PC/SR/USP + RAM diffs.
- 711/718 on the Mac II project's corpus; the failures are TG68K bugs
  in extended-ISA ops (bitfields et al.). Re-census against
  `results/cpu/mame_baseline_2026-06-12.json` (the 68030-captured
  baseline) once verilator is installed here.

### CPU corpus generator (`gen/`)
- `gen/gen.c` (Musashi-linked): 18 opcode families × 20 random tests,
  360/360 pass with full PC + SR + USP verification. Families:
  arithmetic/logic Dn,Dn (ADD/SUB/AND/OR/EOR/CMP .L), unary Dn
  (NEG/NOT/CLR/TST .L), shifts/rotates #imm,Dn (ASL/ASR/LSL/LSR/ROL/ROR/
  ROXL/ROXR .L).
- `gen/mame_cpu_capture.lua` (MAME oracle): 721-test corpus, currently
  the committed baseline. See gen/README.md.
- `gen/mame_pmmu_capture.lua` (MAME oracle): 40-test PMMU corpus +
  `gen/pmmu_tests.h` for the preboot bench. `gen/mame_pmmu_smoke.lua`
  sanity-checks a MAME build first (15 assertions, all green on
  `maciici` 2026-06-12).

### B-3: SR/PC architectural state not verified in CPU bench  ✅ RESOLVED

`tg68k_tests.v` exposes `pc_out`, `sr_out` (FlagsSR<<8 | Flags), and
`usp_out` as wrapper-level outputs via hierarchical refs (`cpu.tg68_pc`,
`cpu.flagssr`, `cpu.flags`, `cpu.usp`). VBR via the kernel's `VBR_out`
port. `sim_main.cpp` diffs PC + SR + USP when the corpus carries those
fields. The signal names survive ghdl-synth (verified in
`rtl/tg68k/TG68KdotC_Kernel.v`); if `convert_to_verilog.sh` is rerun
with a different ghdl version that renames them, update the hierarchical
refs in `tg68k_tests.v`.

PC tap reads the prefetch-ahead PC; bench compares deltas (corpus
`final.pc - initial.pc`) rather than absolute addresses. SR comparison
masks IPL bits 8-10 (setup convention, not divergence).

### MAME corpus replay as a *Verilator* oracle  ⚠ context

Two historical findings that still shape the bench:

1. **CCR-read bug in `mame_cpu_capture.lua` (fixed 2026-05-16).** The
   dump epilogue writes CCR at snapshot offset +0x43, not +0x40; the
   pre-fix corpus had all-zero `ccr` fields. Anything regenerated after
   2026-05-16 is fine.
2. **Dump-epilogue flag sensitivity.** Byte-for-byte snapshot replay
   between MAME and TG68K is noisy because the epilogue's own MOVEs
   perturb flags differently on divergent cores; the bench therefore
   compares architectural state (regs/CCR/PC/SR/USP/RAM), not raw
   snapshots. MAME-vs-real-hardware comparison via the *same* epilogue
   cancels the noise — that's the hardware bench's signal.

## What to do next, in order

1. **PMMU RTL wrapper** around the integer kernel (TC/TT/CRP/SRP regs,
   walker FSM, ATC, fault frames) — see 68030_PMMU_TESTBENCH.md.
2. **`pmmu/` Verilator bench** consuming the committed PMMU corpus.
3. ~~`preboot/supervisor_bench/pmmu_bench_main.c`~~ DONE 2026-06-12 —
   verified 40/40 against the corpus via the MAME harness build;
   prebuilt images in `SingleStepTests/prebuilt/`.
4. **V8 1 bpp display path** for the LC II preboot bench
   (512×384, 1024-byte stride — `display_1bpp.c` currently assumes
   80-byte rows).
5. **CALLM/RTM illegal-trap rows** in the CPU corpus.

## File map

```
SingleStepTests/
├── README.md            — entry-point doc
├── SCHEMA.md            — JSON test schemas (CPU + PMMU)
├── test-blockers.md     — this file
├── cpu_isa_catalog.md   — per-instruction coverage catalog
├── json.hpp             — shared JSON parser
│
├── gen/                 — corpus generators + hardware-bench sources
│   ├── gen.c                    Musashi CPU generator
│   ├── mame_cpu_capture.lua     MAME CPU oracle capture
│   ├── mame_pmmu_capture.lua    MAME PMMU oracle capture
│   ├── mame_pmmu_smoke.lua      PMMU oracle sanity check
│   ├── cpu_tests.h / pmmu_tests.h   generated test-byte headers
│   ├── cpu_test_macii*.c        Mac OS user-mode bench sources
│   └── cpu_diff_corpus.py / diff_corpus.py
│
├── tg68k/               — CPU bench (works; needs verilator installed)
├── pmmu/                — PMMU bench (contract written; awaits RTL)
├── video/               — video bench (contract written; awaits RTL)
├── macos_bench/         — CpuBench Mac OS APPL build
├── preboot/             — supervisor benches (boot-block + payload)
└── results/
    ├── cpu/             — committed CPU baselines + hardware runs
    ├── cpu_supervisor/  — privileged-test hardware captures
    └── pmmu/            — mame_baseline_2026-06-12.json (40 tests)
```
