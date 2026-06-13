# SingleStepTests benches — Macintosh IIvi (68030 + PMMU)

Per-instruction verification benches for the upcoming **Macintosh IIvi**
core, modeled on the
[iigs_simulation/SingleStepTests](https://github.com/SingleStepTests/65816)
pattern and ported from `lbmactwo_MiSTer` (the Mac II / 68020 project).

The IIvi target machine, verified against MAME (`maciivx.cpp`,
`mame0287-736-gacad9ca235f`):

| | |
|---|---|
| CPU | MC68030 @ 15.6672 MHz (C15M = 31.3344 MHz / 2) with on-chip PMMU |
| FPU | **none by default** — the 68882 socket is empty (MAME default "No FPU") |
| System ASIC | VASP (RAM/VRAM controller, VIA1 + pseudo-VIA, ASC audio, built-in video) |
| RAM | 4 MB base, up to 68 MB |
| Expansion | 3 NuBus slots ($C/$D/$E) |
| ROM | 1 MB, `4957eb49.rom` (shared with IIvx), CRC32 `61be06e5` |
| Machine ID | reads `$A55A2016` at `$5FFFFFFC` (IIvx = `$A55A2015`) |

Because the stock IIvi has no FPU, the FPU and CPU+FPU benches from the
Mac II project are **not carried over** (F-line ops must trap, which the
CPU corpus already covers). What is new here is the **PMMU**: the 68030's
on-chip MMU is mandatory and gets its own corpus, capture pipeline, and
bench.

The companion hardware platform for real-machine validation is a
**Macintosh LC II** — same 15.6672 MHz 68030 (so the same CPU/PMMU test
bytes run unmodified), but with the V8 system ASIC and an LC PDS slot
instead of VASP + NuBus.

## Layout

| Dir | What it tests | Status |
|---|---|---|
| `tg68k/` | Raw `TG68KdotC_Kernel` (CPU=2'b11, its most capable mode; 68030-parity gaps documented in the wrapper header) via per-cycle bus driver | 711/718 on the Mac II project's corpus; re-census pending on the 68030 baseline |
| `pmmu/` | 68030 PMMU wrapper module (RTL not yet written) via JSONL corpus | corpus + oracle done; bench awaits RTL |
| `video/` | NuBus mdc824 adapter (carried over) + V8 + VASP built-in video (to be written) | scaffold |
| `gen/` | Corpus generators: MAME capture scripts (CPU + PMMU) + Musashi generator + Mac OS hardware bench sources + diff tool | 721-test CPU corpus, 40-test PMMU corpus |
| `macos_bench/` | User-mode Mac OS APPL (CpuBench) for real-hardware runs | carried over |
| `preboot/` | Pre-OS supervisor benches (boot-block + freestanding payload) | CPU bench carried over; PMMU runner planned |
| `results/` | Committed JSONL corpora / result snapshots | `cpu/`, `cpu_supervisor/`, `pmmu/` |

The verilator benches need `rtl/tg68k/` and `verilator/sim/` (the m68k
disassembler), both vendored at the repo root.

## Quick start: CPU bench

```
cd SingleStepTests/tg68k
make
./obj_dir/Vtg68k_tests ../results/cpu/mame_baseline_2026-06-12.json
```

The committed baseline was captured on a MAME **68030** (`maciici`,
2026-06-12). On the Mac II project's corpus the kernel scored 711/718
with the failures being documented TG68K bugs (see
[test-blockers.md](test-blockers.md)); re-run the bench to census it
against the 68030 baseline (expect the same integer rows plus possible
movement on the privileged CACR rows — the 030 has more writable CACR
bits than the kernel implements).

For **gating a 68030-correct core**, diff against
`results/cpu/golden_2026-06-13.json` instead — it is the MAME baseline
with two rows corrected from real silicon (CACR all-ones `$3313`, RTM
traps vec 4). See [`results/cpu/README.md`](results/cpu/README.md). The
first real-hardware run lives at
`results/cpu_supervisor/maciicx_cpu_2026-06-13.jsonl` (Macintosh IIcx).

## PMMU corpus

The PMMU baseline lives at `results/pmmu/mame_baseline_2026-06-12.json`
(40 tests, JSONL — schema in [SCHEMA.md](SCHEMA.md)). Categories:

- **PMOVE round-trips** — TC / TT0 / TT1 / CRP / SRP / PSR through
  memory, multiple descriptor types and geometries (translation off;
  safe on real hardware)
- **PFLUSH / PLOAD** — ATC flush variants; PLOAD walks that set U-bits
  in planted descriptors
- **PTEST** — full-depth walks over early-termination, 3-level,
  write-protected (PSR W), invalid (PSR I), limit-violation, long-format
  (DT=3) and SRP-selected (TC.SRE=1) trees, transparent-translation hits
  (PSR T), and descriptor-address writeback to An
- **Live translation** (`mmu_live`, currently `hw_unsafe`) — enable
  TC.E=1 mid-test: identity store, va→pa remap store/load, M/U-bit
  updates, ATC staleness with and without PFLUSHA
- **Faults** (`raises_exception`) — bus error on invalid / write-protected
  pages (format $B 92-byte frame, vector 2) and the MMU-configuration
  exception (vector 56, format $2) on enabling a bad TC geometry

Regenerate / extend with:

```
cd ~/repos/mame
./mame maciici -skip_gameinfo -nothrottle -video none -sound none -seconds_to_run 120 -autoboot_delay 1 \
    -autoboot_script <repo>/SingleStepTests/gen/mame_pmmu_capture.lua
# -> /tmp/pmmu_corpus.json + /tmp/pmmu_tests.h, then copy into the repo
```

`gen/mame_pmmu_smoke.lua` is the quick sanity check (15 assertions) that
the MAME build exposes the PMMU to Lua and that PMOVE/PTEST execute —
run it first on any new MAME build or driver.

## Video

Three video paths, all oracled by MAME:

1. **NuBus mdc824** (`rtl/nubus/nubus_video_mdc824.sv`) — the same
   adapter card the Mac II core used; works in any of the IIvi's three
   NuBus slots. MAME reference: `src/devices/bus/nubus/nubus_48gc.cpp`.
2. **V8 built-in video** (Macintosh LC/LC II — the physical test
   machine). MAME reference: `src/mame/apple/v8.cpp`. VRAM window
   `$540000-$5BFFFF` inside the V8 map (CPU sees it at `$F40000` /
   `$50F40000`), fixed 1024-byte row stride, 1/2/4/8 bpp (16 bpp at
   512×384), Ariel RAMDAC at V8 +`$524000`, depth set via the
   pseudo-VIA video-config register. Monitor IDs: 1=640×870 portrait,
   2=512×384, 6=640×480.
3. **VASP built-in video** (the IIvi itself). MAME reference:
   `src/mame/apple/vasp.cpp`. The VASP device map sits at `$40000000`:
   ROM `$40000000`, VIA1 `$50000000` (mirror `$50F00000`), DAC
   `$50024000`, pseudo-VIA `$50026000`, **VRAM `$60000000`** (1 MB),
   fixed 2048-byte row stride, 1/2/4/8/16 bpp, same three monitor IDs.

V8 and VASP share the pseudo-VIA + video-config + RAMDAC programming
model, so one parameterized RTL module should cover both (stride 1024
vs 2048, base addresses, RAMDAC flavor). See `video/README.md` for the
bench contract and `68030_PMMU_TESTBENCH.md` (repo root) for the plan.

## MAME oracle setup

The MAME checkout at `~/repos/mame` is a subset build. It was rebuilt
(2026-06-12) to include the LC family:

```
make -j4 SOURCES=src/mame/apple/macii.cpp,src/mame/apple/maciici.cpp,\
src/mame/apple/maciivx.cpp,src/mame/apple/maclc.cpp REGENIE=1
```

ROM status (in `~/repos/mame/roms/`):

| Driver | Machine | ROMs | Use |
|---|---|---|---|
| `maciici` | IIci (68030 @ 25 MHz, RBV) | **present** | current CPU/PMMU capture oracle |
| `macii` | Mac II family | present | not used by this project |
| `maciivi` | **IIvi — the target** | missing: `4957eb49.rom` + Egret `341s0851.bin` | becomes the canonical oracle once present |
| `maclc2` | **LC II — the physical test machine** | missing: 4× `341-047x` chips + Egret `341s0850.bin` | V8 video + LC II cross-check |

The LC II ROMs can be dumped from the physical test machine. The CPU and
PMMU corpora do not depend on which 68030 driver captures them — the
MC68030 device is identical; only chipset-touching tests (none today)
would differ.

## Test categories and what they cover

Each test carries flags that control which environments run it:

| Flag | Verilator bench | MAME (supervisor) | Mac OS bench (user) | Preboot bench (supervisor) |
|---|---|---|---|---|
| (none) | runs | runs | runs | runs |
| `privileged` | runs | runs | **skips** (traps in user mode) | runs |
| `raises_exception` | runs | runs | **skips** | runs (vectors hooked) |
| `mmu_live` | runs (PMMU bench) | runs | **skips** | gated: only after identity-map bring-up |
| `hw_unsafe` | **skips** | runs | **skips** | **skips** |

All 40 PMMU tests are `privileged`. The `mmu_live` and fault tests are
born `hw_unsafe` and get promoted once the LC II supervisor bench proves
the catcher protocol (PMOVE-disable on every exit path) holds on real
silicon.

## Running on a real Macintosh LC II

**User-mode CPU tests** (no PMMU): build `gen/cpu_test_macii-sys7.c` +
`gen/cpu_tests-sys7.h` with THINK C 5+ under System 6/7, run, pull back
`"CPU Results.jsonl"`, and diff:

```
python3 SingleStepTests/gen/cpu_diff_corpus.py \
    SingleStepTests/results/cpu/mame_baseline_2026-06-12.json \
    /path/to/CPU\ Results.jsonl --markdown
```

The LC II runs the same user-mode ISA the corpus captures — the bench
needs no changes. (The "macii" in the filename is heritage, not a
requirement.)

**Privileged + PMMU tests** need supervisor mode: the preboot bench
(`preboot/supervisor_bench/`) boots from floppy/SCSI before Mac OS and
runs with SR=$2700. The PMMU runner (`pmmu_bench_main.c`, consuming
`gen/pmmu_tests.h`) is the next build-out — see the plan. Display output
on the LC II uses the V8 built-in framebuffer (1 bpp, 512×384, row
stride 1024 — a new stride for `display_1bpp.c`, which currently
hardcodes 80-byte rows for 640-wide NuBus cards).

## What's documented elsewhere

- **[SCHEMA.md](SCHEMA.md)** — CPU and PMMU corpus JSON schemas
- **[test-blockers.md](test-blockers.md)** — known TG68K bugs, MAME
  oracle quirks, 68030/PMMU gap list
- **[gen/README.md](gen/README.md)** — capture pipelines and the Mac OS
  bench in detail
- **[../68030_PMMU_TESTBENCH.md](../68030_PMMU_TESTBENCH.md)** — the
  master plan: CPU-core strategy, PMMU RTL + bench design, video bench
  design, LC II hardware campaign
