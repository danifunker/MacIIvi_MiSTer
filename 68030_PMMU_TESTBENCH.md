# Macintosh IIvi — 68030 + PMMU Testbench Plan

*2026-06-12. This document is the master plan for the SingleStepTests
port and the 68030/PMMU verification campaign for the upcoming
Macintosh IIvi core. Everything stated as "verified" below was checked
against MAME source/binary (`~/repos/mame`, `mame0287-736-gacad9ca235f`)
or produced by an actual MAME run on 2026-06-12.*

---

## 1. Target machine (verified against MAME)

The core implements a **Macintosh IIvi** — a 68030 + on-chip MMU
machine, **no FPU** (the 68882 socket is empty by default; MAME's
`maciivi` input default is "No FPU"). Per `src/mame/apple/maciivx.cpp`:

| Component | Fact | Source |
|---|---|---|
| CPU | MC68030 @ **15.6672 MHz** (`C15M` = 31.3344 MHz ÷ 2; the IIvx variant runs the same board at C32M) | maciivx.cpp:50-51, 430-437 |
| MMU | 68030 on-chip PMMU (PMOVE/PTEST/PLOAD/PFLUSH; TC/TT0/TT1/CRP/SRP/PSR) | m68030 device |
| System ASIC | **VASP** @ C15M — RAM/VRAM controller, VIA1 + pseudo-VIA, ASC audio, built-in video | maciivx.cpp:371, vasp.cpp |
| RAM | 4 MB base, options to 68 MB | maciivx.cpp:316-317 |
| NuBus | 3 slots $C/$D/$E → VASP slot IRQs | maciivx.cpp:384-393 |
| ROM | 1 MB `4957eb49.rom`, CRC32 `61be06e5`, shared with IIvx | maciivx.cpp ROM_START |
| Machine ID | `$5FFFFFFC` reads `$A55A2016` (IIvx: `$A55A2015`) | maciivx.cpp:168-178 |
| I/O | SCSI 53C80 + helper, SCC 85C30 @ C7M, SWIM1, Egret ADB (341s0851), DFAC audio | maciivx.cpp |
| Address map | VASP map installed at `$40000000`: ROM `$40000000`, VIA1 `$50000000` (mirrors incl. `$50F00000`), ASC `$50014000`, DAC `$50024000`, pseudo-VIA `$50026000`, **VRAM `$60000000`** (1 MB) | vasp.cpp map |

**Physical validation machine: Macintosh LC II** (per
`src/mame/apple/maclc.cpp`): same MC68030 @ C15M = 15.6672 MHz — so
every CPU and PMMU test byte runs unmodified — but **V8** system ASIC
(10 MB RAM ceiling, `set_baseram_is_4M`), **LC PDS** slot instead of
NuBus (NuBus protocol, address mask `$80FFFFFF`, only slot-$E IRQ
wired), and 4-chip interleaved ROM (`341-0473..0476`).

## 2. What this port delivered (done)

Copied from `../lbmactwo_MiSTer` and updated, with all FPU and CPU+FPU
material excluded (the IIvi has no FPU; F-line trap coverage lives in
the CPU corpus):

```
SingleStepTests/
├── tg68k/        CPU verilator bench (carried; headers updated for the 030 target)
├── pmmu/         NEW — PMMU bench contract (RTL pending; see §4)
├── video/        NEW — video bench contract (see §5)
├── gen/          capture pipelines:
│   ├── mame_cpu_capture.lua    updated: 68030 oracle (maciici/maciivi), 020 framing removed
│   ├── mame_pmmu_capture.lua   NEW — 40-test PMMU corpus generator (verified, see §3)
│   ├── mame_pmmu_smoke.lua     NEW — 15-assertion oracle sanity check (15/15 green)
│   ├── pmmu_tests.h            NEW — generated header for the LC II supervisor bench
│   ├── cpu_tests.h / cpu_test_macii*.c / diff tools   (carried)
│   └── gen.c                   Musashi generator, now M68K_CPU_TYPE_68030
├── macos_bench/  CpuBench only (FPU APPLs dropped); icons relabeled 68030
├── preboot/      supervisor bench (FPU targets dropped; PMMU runner specced)
└── results/
    ├── cpu/             68030-captured baseline (replaces the Mac II-era 68020 corpus)
    ├── cpu_supervisor/  schema/quirk notes kept; Mac II-era captures removed
    └── pmmu/            mame_baseline_2026-06-12.json  (40 tests)
rtl/
├── tg68k/        TG68KdotC kernel (ghdl-converted) — bench DUT + future core CPU
└── nubus/        NuBus video adapters — mdc824 (the active one), toby, highres
verilator/sim/    m68k disassembler used by the benches
docs/             680x0_function_codes.md (carried, re-scoped to the 030)
```

The corpus also gained three **68030 discriminator rows** (2026-06-12):
a CACR write-all-ones mask probe (030 golden `D1=$0000FF13`; a
68020-behaving core reads back `$03`), and CALLM/RTM rows asserting the
illegal-instruction trap the 030 must take (the RTM golden is known-bad
in MAME — see §6 — and is expected to *fail* against a correct core
until an LC II capture replaces it).

Repo-wide, 68020-specific framing was removed per the 030-only mandate:
docs retitled (`cpu_isa_catalog.md` is now the MC68030 catalog), bench
strings/icons say 68030, `maciihmu` instructions replaced with
`maciivi`/`maciici`, and the CPU corpus was **re-captured on a MAME
68030** so even the baseline's provenance is 030. Necessarily-remaining
mentions are deltas *about* 030 correctness (CALLM/RTM must trap; CACR
gained bits; "From: 68020" ISA-history column in the catalog).

## 3. PMMU oracle — built and verified against MAME (done)

The new corpus pipeline was developed and **run** today against
`maciici` (the MC68030 device is identical across Mac drivers; no test
touches chipset space):

1. **Smoke** (`gen/mame_pmmu_smoke.lua`): 15/15 PASS — PMMU registers
   readable/writable via the Lua state interface (`TC`, `TT0`, `TT1`,
   `CRP_LIMIT/APTR`, `SRP_LIMIT/APTR`, `PSR`), PMOVE round-trips for
   all five register groups execute, PFLUSHA executes, PTESTR walks a
   planted early-termination table (PSR=`$0001`, N=1), and the Lua
   state view equals the PMOVE architectural readback (the equivalence
   the capture method rests on).
2. **Corpus** (`gen/mame_pmmu_capture.lua` →
   `results/pmmu/mame_baseline_2026-06-12.json`, 40 tests, 0 timeouts):
   - 16 PMOVE round-trips (TC geometries, TT enabled/disabled, CRP/SRP
     with DT=1/2/3 and both limit senses, PSR write mask)
   - PFLUSHA, PFLUSH by fc, PFLUSH by fc+ea; PLOADR/PLOADW with
     U-bit descriptor updates verified in the RAM diffs
   - 11 PTEST rows: full-depth walks over early-termination, 3-level,
     write-protected (PSR W=`$0803`), invalid (PSR I=`$0403`),
     limit-violation, long-format (DT=3), SRP-selected (TC.SRE=1 —
     proven via a WP marker only present in the SRP tree),
     TT0-transparent (PSR T=`$0040`), ATC-probe (#0), and An
     descriptor-address writeback (returns `$3204`, the level-C
     descriptor address — correct 030 semantics)
   - 5 live-translation rows (TC.E=1 mid-test): identity store, va→pa
     remap store and load (`$8000` page → `$9000`), M/U-bit
     read-vs-write asymmetry, ATC staleness with and without PFLUSHA
   - 3 fault rows: bus error on invalid and on write-protected pages —
     both captured with textbook **68030 format $B 92-byte frames,
     vector 2** on the supervisor stack — and the MMU-configuration
     exception (vector 56, format $2) on enabling a bad TC geometry
3. **Cross-platform header** (`gen/pmmu_tests.h`): the same 40 tests as
   a `PmmuTestSpec[]` (test bytes + RAM plants + initial MMU register
   values + flags) for the LC II preboot runner.

**MAME oracle quirks found** (recorded in `SingleStepTests/test-blockers.md`):

- Depth-limited PTEST (`#1..#6`) ending on a *table* descriptor hits
  `fatalerror("Table walk did not resolve")` (`m68kmmu.h:591`) — MAME
  exits. Real silicon reports the partial walk in PSR. Corpus v1
  therefore carries only `#0` and `#7` forms; depth-limited goldens
  must come from the real LC II (or a patched MAME — upstreamable fix).
- Root-limit violations report PSR `I|N` where a real 030 also sets
  `L`. Cross-check that row on hardware before trusting it.
- Harness lesson now baked into the generator: live-translation page
  tables must map the supervisor stack (an unmapped stack turns a
  clean bus-error test into a double fault), and every test program
  ends in a catcher that force-disables TC on all exit paths
  (consequence: `final.mmu.tc` is always 0 in the corpus; a test's TC
  effect is observed via its memory readback).

## 4. CPU + PMMU RTL strategy

**Integer core: TG68KdotC_Kernel** (vendored in `rtl/tg68k/`), driven
with `CPU=2'b11` — its most capable mode, covering the 030's user-mode
integer ISA. Verified-on-import bench expectation: the corpus passes
except documented TG68K bugs (re-run `tg68k/` to refresh the count —
requires `apt install verilator` on this machine).

Parity items the core owes beyond the kernel (tracked in
test-blockers.md):

1. CALLM/RTM → illegal-instruction trap (the 030 dropped them).
2. CACR data-cache bits (WA/DBE/CD/CED/FD/ED) accepted on MOVEC.
3. The PMMU (below).
4. Format-$B fault frames + instruction restart for MMU faults.

**PMMU: a new `pmmu_top` wrapper module** between kernel and bus, per
the contract in `SingleStepTests/pmmu/README.md`. Suggested build-out
ladder, each rung gated by corpus rows it makes green:

| Rung | RTL | Corpus rows that prove it |
|---|---|---|
| 1 | PMOVE register file, F-line decode (incl. trapping 68851-only ops) | 16 PMOVE round-trips |
| 2 | Table walker (short+long descriptors, early term, limits, U/M updates) + PTEST/PLOAD | 11 PTEST/PLOAD rows |
| 3 | Translation datapath in the bus path, TT matching | identity/remap/M-U rows |
| 4 | ATC + PFLUSH variants | the two ATC-staleness rows |
| 5 | Bus-error frames + restart, MMU-config exception | the three FAULT rows |

A useful simplification for rungs 2-3: the Mac IIvi ROM and System 7
only ever program 1:1-with-offset style mappings + 32-bit-clean
remaps; but the corpus deliberately exercises general trees, so build
the general walker — it is small compared to debugging a special-cased
one against System 7's enabler later.

**Why no FPU work at all:** the stock IIvi has no FPU; F-line traps are
already exercised by the CPU corpus. If an FPU option is ever wanted,
the Mac II project's benches can be re-imported wholesale.

## 5. Video plan

Three paths, one bench directory (`SingleStepTests/video/README.md`
has the full contract and the verified register/stride facts):

1. **NuBus mdc824 — carried over, reuse as-is.**
   `rtl/nubus/nubus_video_mdc824.sv` (+ `nubus_arbiter.sv`,
   `vram_ram.sv`) is the same adapter the Mac II core instantiated
   (`LBMacTwo.sv:774`); on the IIvi it plugs into any of slots $C/$D/$E.
   MAME cross-check: `maciivi -nbc mdc824`.
2. **V8 built-in video (Macintosh LC/LC II)** — new RTL. VRAM window
   `$540000-$5BFFFF` in the V8 device map (CPU `$F40000` 24-bit /
   `$50F40000` 32-bit), **fixed 1024-byte row stride**, depths
   1/2/4/8 bpp (16 bpp at 512×384), Ariel RAMDAC at +`$524000`,
   depth select via the pseudo-VIA video-config register, monitor
   sense 1/2/6 = 640×870 / 512×384 / 640×480.
3. **VASP built-in video (the IIvi)** — new RTL. VRAM at `$60000000`
   (1 MB), **fixed 2048-byte row stride**, depths 1/2/4/8/16 bpp,
   DAC at `$50024000`, same pseudo-VIA config model and monitor IDs.

V8 and VASP share the programming model — plan is **one parameterized
module** (stride, window base, RAMDAC flavor, max depth) instantiated
twice. Bench: golden-frame comparison against a host-side C model
transliterated from MAME's `screen_update` switches (`v8.cpp` ~:493,
`vasp.cpp` ~:440), plus a register-access capture on `maclc2`/`maciivi`
using the same Lua plant-program technique as the CPU/PMMU captures.

## 6. MAME oracle status

- **RTM decode bug:** MAME's Musashi wires RTM (`$06C0`) into the
  030/040 decode tables as a logging no-op instead of trapping
  (CALLM is correctly 020-only). Corpus row carries the known-bad
  golden, named accordingly. Upstream fix candidate.
- Local MAME was a Mac II-family subset build; **rebuilt 2026-06-12**
  with `SOURCES=...macii.cpp,maciici.cpp,maciivx.cpp,maclc.cpp` — the
  binary now includes `maciivi`, `maciivx`, `maclc`, **`maclc2`**,
  `macclas2`, `maccclas`, `mactv` alongside the II-family drivers.
- ROM status: `maciici` ✅ (current capture oracle), `macii` ✅;
  **`maciivi` missing** `4957eb49.rom` + Egret `341s0851.bin`;
  **`maclc2` missing** the four `341-047x` chips + Egret `341s0850.bin`.
  The LC II set can be **dumped from the physical test machine** —
  that also gives MAME-LC II as a fourth oracle (V8 chipset + video).
- The PMMU/CPU corpora are CPU-device-level and oracle-driver-agnostic;
  when `maciivi` ROMs land, re-run both captures there and diff —
  expected byte-identical.

## 7. Macintosh LC II hardware campaign (the imminent physical test)

Ordered so each step de-risks the next; artifacts named per repo paths.

1. **Dump the LC II ROMs** (gives MAME `maclc2` + provenance for the
   FPGA boot ROM): four 27C010-class chips → `341-0473..0476` images +
   the Egret 341s0850 if accessible. Verify with
   `./mame -verifyroms maclc2`.
2. **User-mode CPU run (no special boot media):** build CpuBench from
   `gen/cpu_test_macii-sys7.c` + `gen/cpu_tests-sys7.h` (THINK C 5+,
   System 6/7), run on the LC II, pull `CPU Results.jsonl`, diff with
   `gen/cpu_diff_corpus.py` against `results/cpu/` baseline. Expected:
   privileged/exception rows skipped, the rest ≈99% match (residue =
   PRM-undefined flags, as on the Mac II campaign).
3. **Supervisor CPU bench:** `preboot/supervisor_bench` `make cpu` +
   `build_cpu_hda.sh`, boot from BlueSCSI, collect `/Results.jsonl` →
   `results/cpu_supervisor/`. This proves the preboot path (boot block,
   recovery, JSONL writer) on V8-chipset hardware **before** any PMMU
   test runs. Display: expect garbage or use serial-blind run first —
   then bring up the V8 1 bpp paint (next step) for on-screen progress.
4. **V8 display bring-up:** run the diagnostics stubs
   (`make minimal` / `probe` / `calibrate` / `strides`) to empirically
   confirm framebuffer base + 1024-byte stride; add the V8 variant to
   `display_1bpp.c` (512×384 ⇒ 64 visible bytes/row).
5. **PMMU runner** (`preboot/supervisor_bench/pmmu_bench_main.c`, to
   write): consumes `gen/pmmu_tests.h`. Phase A runs only
   `hw_unsafe=0` rows (PMOVE round-trips, PTEST/PLOAD/PFLUSH — 32 of
   40 rows): translation stays off; worst case is a trap that the
   existing `recovery.s` longjmp path already absorbs. Emit JSONL,
   diff against the MAME baseline. **This is where the two known MAME
   quirks get adjudicated by real silicon** (depth-limited PTEST rows
   — added to the corpus then — and the limit-violation L bit).
6. **Phase B — promote `mmu_live`/fault rows:** after Phase A proves
   the catcher discipline (TC force-disable on every exit) on real
   hardware, run the live-translation and fault rows; compare fault
   frames (format $B) against both MAME and, later, the FPGA core.
7. **Archive:** all runs land in `results/` with date-stamped names;
   hardware-vs-MAME divergences get rows in test-blockers.md.

## 8. Milestones & acceptance

| # | Milestone | Acceptance |
|---|---|---|
| M0 | Port complete (this commit) | tree builds: `tg68k/` bench compiles and reproduces its pass/fail census on the 68030-captured baseline (needs `apt install verilator` locally) |
| M1 | LC II ROMs dumped | `mame -verifyroms maclc2` good; `maclc2` boots in MAME |
| M2 | LC II user-mode CPU run | diff report committed; no unexplained divergences |
| M3 | LC II supervisor CPU + PMMU Phase A | 32/32 hw-safe PMMU rows captured; MAME-quirk rows adjudicated; corpus updated with real-silicon goldens for depth-limited PTEST |
| M4 | PMMU RTL rungs 1-2 | PMOVE + PTEST/PLOAD corpus rows green in `pmmu/` bench |
| M5 | PMMU RTL rungs 3-5 | all 40 rows green incl. fault frames |
| M6 | Video: V8/VASP module | golden-frame bench green in all depth×monitor combos; mdc824 regression green |
| M7 | LC II PMMU Phase B | live/fault rows match real silicon; `hw_unsafe` flags cleared |

## 8b. Amiga front (added 2026-06-12)

The TG68K-68030+MMU modifications debut in a custom MiSTer Minimig
build before the IIvi core exists. A parallel set of bootable Amiga
test floppies (same corpora, same diff tools, 68030+MMU-only) gates
that work and adds a third real-silicon oracle — see
[AMIGA_TESTBENCH.md](AMIGA_TESTBENCH.md).

## 9. Risks / open questions

- **TG68K 030-parity drift:** the kernel's known bugs (documented
  bench failures) predate this port; fixing them inside ghdl-converted
  Verilog is unpleasant — consider fixing in the VHDL source and
  re-running `rtl/tg68k/convert_to_verilog.sh` instead.
- **MAME PMMU fidelity:** two quirks already found; assume more exist
  in corners (e.g. exact PSR composition on combined violations).
  Mitigation is exactly the LC II campaign — real silicon outranks
  MAME wherever they disagree.
- **IIvi ROM acquisition** gates making `maciivi` (rather than
  `maciici`) the canonical oracle and any ROM-boot bring-up of the
  core itself.
- **V8 vs VASP RAM controller differences** (10 MB vs 68 MB ceilings,
  base-RAM banking) matter for the *core*, not the testbench — but the
  preboot benches' fixed addresses (`payload @ $40000`, scratch at
  low RAM) were chosen on a 4 MB Mac II and remain inside the LC II's
  4 MB envelope. Keep them under 4 MB as tests grow.
- **Verilator availability:** not installed on this machine
  (`sudo apt install verilator`); benches were verified to *configure*
  correctly (all vendored paths resolve) but a local pass/fail census
  needs the install.
