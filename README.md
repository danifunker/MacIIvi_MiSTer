# MacIIvi_MiSTer

A **Macintosh IIvi** core for MiSTer — MC68030 @ 15.6672 MHz with the
on-chip PMMU, VASP system ASIC, built-in video, 3 NuBus slots, and
**no FPU** (the IIvi's 68882 socket is empty in the stock machine).

The core RTL does not exist yet. This repo is currently in its
**testbench-first phase**: the verification infrastructure — MAME-derived
instruction corpora, simulator benches, and real-hardware test images —
is built and verified *before* the core, so every piece of RTL lands
against a known-good oracle. The master plan is
**[68030_PMMU_TESTBENCH.md](68030_PMMU_TESTBENCH.md)**.

Heritage: ported from `lbmactwo_MiSTer` (Mac II / 68020 project), with
all FPU material removed and everything retargeted to the 68030+PMMU.
The physical validation machine is a **Macintosh LC II** — same
15.6672 MHz 68030, so every CPU/PMMU test byte runs unmodified.

## What's here

| Path | What it is |
|---|---|
| `68030_PMMU_TESTBENCH.md` | Master plan: machine facts (MAME-verified), RTL strategy, bench design, LC II campaign, milestones |
| `SingleStepTests/` | The testbench tree — benches, corpora, capture pipelines, hardware test images ([README](SingleStepTests/README.md)) |
| `SingleStepTests/prebuilt/` | **Ready-to-boot test images** (.hda/.dsk per fixture) + [MANIFEST.md](SingleStepTests/prebuilt/MANIFEST.md) with the LC II runbook |
| `SingleStepTests/results/` | Oracle baselines + runs: CPU MAME baseline (721) + real-silicon-corrected `golden` + IIcx hardware run; PMMU (40); Amiga runs |
| `rtl/tg68k/` | TG68KdotC kernel (integer-CPU starting point; 68030-parity gaps tracked in [test-blockers.md](SingleStepTests/test-blockers.md)) |
| `rtl/nubus/` | NuBus video adapters carried from the Mac II core (mdc824 is the active one) |
| `verilator/sim/` | m68k disassembler used by the simulator benches |
| `docs/` | Supporting notes (680x0 function codes) |

## Current status (2026-06-13)

**Done and verified:**
- **First real-silicon CPU run (Macintosh IIcx, 68030):** the full
  consolidated corpus (720/721 rows; the one omission is the `hw_unsafe`
  Line-A trap) booted and ran. **No CPU-semantics divergence from the
  MAME oracle** — every non-match is harness address-residue, a
  PRM-undefined flag, or environmental privileged state. The two
  68030-discriminator rows that carried known-bad MAME goldens are now
  **adjudicated by real silicon**: CACR all-ones reads `$3313` (not
  MAME's `$FF13`) and RTM traps vec 4 (MAME's no-op is a MAME bug) —
  both matching the earlier Amiga/WinUAE oracle. Run +
  analysis: `SingleStepTests/results/cpu_supervisor/maciicx_cpu_2026-06-13.jsonl`.
  Corrected oracle for RTL gating:
  `SingleStepTests/results/cpu/golden_2026-06-13.json`.
- **First real-silicon PMMU run (Macintosh IIcx, 68030):** the full
  PMMU bench ran end-to-end (`identity_probe` OK on the 32-bit-clean
  ROM; all 40 rows incl. live translation + fault frames). **37/40 match
  MAME**; the 3 misses are MAME PMMU-fidelity bugs that real silicon
  adjudicates — PSR write-mask `$EE47` (not `$FFFF`; an IIcx-only
  finding, WinUAE also wrong), root-limit PSR `$4400` (L bit set), and
  PTEST-ignores-TT PSR `$0001`. The MMU-config-exception row confirms
  vec 56 in MAME's favor (clearing a WinUAE divergence). Run:
  `SingleStepTests/results/pmmu/maciicx_pmmu_full_2026-06-13.jsonl`;
  corrected oracle: `…/pmmu/golden_2026-06-13.json` (40/40).
- CPU corpus (721 rows) captured natively on a MAME 68030, including
  68030-discriminator rows (CACR write mask, CALLM/RTM illegal traps).
- PMMU corpus (40 rows: PMOVE/PTEST/PLOAD/PFLUSH, live translation,
  fault frames) captured and sanity-checked against MAME.
- Supervisor-mode **PMMU hardware runner** — verified **40/40** against
  the corpus under a MAME flat-map harness, including live translation
  and deliberate bus faults.
- **12 prebuilt boot images** (CPU / PMMU-safe / PMMU-full ×
  mdc824 / auto-stride video, each as .hda + .dsk), packaged per
  fixture in `SingleStepTests/prebuilt/`.
- CPU image boot-verified end-to-end under MAME (720 result rows
  extracted from the disk image).

**Not started:** the core itself — PMMU RTL wrapper, V8/VASP video
module, IIvi top-level. The benches and corpora that will verify those
are ready and waiting (see `SingleStepTests/pmmu/README.md` and
`SingleStepTests/video/README.md` for the bench contracts).

## What's next — in order

### 1. Hardware campaign on the Macintosh LC II (you + the machine)

The imminent step. Full runbook in
[prebuilt/MANIFEST.md](SingleStepTests/prebuilt/MANIFEST.md); plan
detail in [68030_PMMU_TESTBENCH.md §7](68030_PMMU_TESTBENCH.md).

1. **Dump the LC II ROMs** (4× `341-047x` chips, + Egret `341s0850` if
   reachable) → unlocks MAME `maclc2` as a fourth oracle and the V8
   video reference.
2. Boot **`maciivi-pmmu-safe-autovideo`** first. Two things to watch:
   - the **identity probe** banner — if the machine freezes there, the
     ROM's boot mapping isn't virtual==physical and the PMMU bench
     can't run on it (expected to pass on the LC II; see MANIFEST);
   - the **auto-stride display** — confirms ScrnRow detection on real
     V8 silicon (garbled text = fall back to the mdc824 image and run
     the `strides`/`calibrate` diagnostics).
3. Pull `/Results.jsonl`, diff with `gen/pmmu_diff_corpus.py`. This run
   **adjudicates the three documented MAME-oracle quirks** (depth-limited
   PTEST, the limit-violation L bit, the known-bad RTM golden) — real
   silicon outranks MAME wherever they disagree; update the corpus and
   `test-blockers.md` with the verdicts.
4. Then **`pmmu-full`** (live translation + deliberate faults on real
   silicon), then the **CPU image**, archiving everything under
   `SingleStepTests/results/`.

### 1b. Amiga campaign — the TG68K-030/MMU hardware gate

The custom Minimig build carrying the TG68K-68030+MMU modifications is
the *first hardware home* of the CPU that will drive this core. Three
bootable ADFs (CPU / PMMU-safe / PMMU-full, 68030+MMU only) run the
same corpora there and on a real-030 Amiga — plan settled in
**[AMIGA_TESTBENCH.md](AMIGA_TESTBENCH.md)**. Needs: `pip install
amitools`, `apt install fs-uae`, and Kickstart ROM files copied from
the MiSTer SD card.

### 2. Local tooling gaps (one-time)

- `sudo apt install verilator` — the tg68k bench builds but can't
  compile without it; first run re-censuses the kernel against the
  68030 baseline (`cd SingleStepTests/tg68k && make && ./obj_dir/Vtg68k_tests`).
- Obtain the **IIvi ROM** (`4957eb49.rom`, CRC32 `61be06e5`, + Egret
  `341s0851`) to make MAME `maciivi` the canonical oracle instead of
  `maciici`.

### 3. Core RTL (the main event)

Build order from the plan, each rung gated by corpus rows it turns green:

1. **PMMU wrapper** (`pmmu_top` around the TG68K kernel) — PMOVE
   register file → walker/PTEST → translation datapath → ATC → fault
   frames. Bench contract: `SingleStepTests/pmmu/README.md`.
2. **TG68K 68030-parity fixes** — CALLM/RTM illegal traps, 030 CACR
   bits, format-$B fault frames (`test-blockers.md` has the list).
3. **V8/VASP video module** (one parameterized module covers both) +
   golden-frame bench: `SingleStepTests/video/README.md`.
4. **IIvi top-level**: VASP glue (VIA1/pseudo-VIA, ASC, SWIM1, SCSI,
   Egret), NuBus slots reusing `rtl/nubus/`, ROM boot.

### 4. Testbench follow-ups (opportunistic)

- Control-flow CPU tests (Bcc/JSR/RTS need dual-site dump dispatch).
- Depth-limited PTEST rows once real-silicon goldens exist (MAME
  fatally crashes on them — upstream fix candidate, as is the RTM
  decode bug).
- Verilator PMMU bench runner (`SingleStepTests/pmmu/`) once rung-1
  RTL exists.

## Quick reference

```bash
# Rebuild all prebuilt test images (Retro68 + rb-cli required)
cd SingleStepTests/preboot/supervisor_bench && ./build_prebuilts.sh

# Re-capture the corpora against MAME (maciici today, maciivi once ROMs land)
cd ~/repos/mame
./mame maciici -skip_gameinfo -nothrottle -video none -sound none \
    -seconds_to_run 600 -autoboot_delay 1 \
    -autoboot_script <repo>/SingleStepTests/gen/mame_cpu_capture.lua   # or mame_pmmu_capture.lua

# Diff a hardware/bench run against the oracle
python3 SingleStepTests/gen/pmmu_diff_corpus.py \
    SingleStepTests/results/pmmu/mame_baseline_2026-06-12.json run.jsonl
```

Gotchas that cost time once already (details in `test-blockers.md`):
run MAME headless with `-video none` (offscreen `-window` pauses
without focus); never run two captures concurrently (both write
`/tmp/cpu_corpus.json`); 32-bit-clean Mac ROMs boot with the MMU
**enabled** — any supervisor code touching CRP/TT must save/restore the
ROM's MMU state, as `pmmu_bench_main.c` does.
