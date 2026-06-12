# pmmu/ — 68030 PMMU bench (contract)

Verilator bench for the Macintosh IIvi core's PMMU wrapper module. The
RTL does not exist yet; this file pins down the contract so the module
and the bench can be built against the already-committed oracle:

- Corpus: `../results/pmmu/mame_baseline_2026-06-12.json` (40 tests,
  JSONL — schema in `../SCHEMA.md`, "PMMU entry")
- Oracle provenance: MAME `maciici` (MC68030 device), captured by
  `../gen/mame_pmmu_capture.lua`, sanity-checked by
  `../gen/mame_pmmu_smoke.lua` (15/15)
- Hardware cross-check: `gen/pmmu_tests.h` feeds the preboot
  supervisor bench on the physical Macintosh LC II

## What the DUT is

A `pmmu_top` wrapper that sits between the integer kernel
(`TG68KdotC_Kernel`) and the bus, owning:

- Registers: TC, TT0, TT1, CRP (limit+aptr), SRP (limit+aptr), PSR —
  reached via PMOVE (F-line cpid 0), NOT via MOVEC
- Instruction decode for PMOVE / PTEST / PLOAD / PFLUSH / PFLUSHA
  (68851-only ops — PBcc/PDBcc/PScc/PTRAPcc/PSAVE/PRESTORE/PVALID —
  must F-line trap)
- Table walker: short (4-byte) and long (8-byte) descriptors, DT=0..3,
  early termination at any level, limit checks, U/M read-modify-write
  updates, TC geometry (IS/PS/TIA-TID), TC.SRE root selection, TT0/TT1
  transparent matching by FC+address
- ATC with PFLUSH-variant invalidation and PMOVE-with-FD=0 flush
- Bus-error generation with the 68030 format $B (92-byte) frame and
  instruction restart; MMU-configuration exception (vector 56,
  format $2) on enabling an invalid TC

## Bench shape (mirror of ../tg68k/)

- `pmmu_tests.v` — instantiate kernel + pmmu_top; expose the same bus
  taps as `tg68k_tests.v` plus MMU register taps (tc, tt0, tt1,
  crp_limit/aptr, srp_limit/aptr, psr) for the comparator.
- `sim_main.cpp` — per test row:
  1. zero the snapshot windows, apply `initial.ram` pairs (this plants
     the translation tables — they are just RAM);
  2. plant `[test bytes][catcher]` at $1000 exactly as the capture did
     (catcher = `PMOVE ($17F8).L,TC ; JMP self`, all vectors → catcher);
  3. inject GP regs via the regfile arrays and MMU regs via the new
     taps; SR=$2700, SSP=$80000, PC=$1000;
  4. run until the catcher's JMP-self fetch (or timeout);
  5. compare D/A regs, MMU regs (note: final TC is always 0 by catcher
     design), PSR, and the `final.ram` diff list — descriptor U/M-bit
     updates and exception frames included.
- Flags: run everything; `mmu_live` rows are the point of the bench.
  `timed_out` rows in the corpus (none today) would be skipped.

## Suggested build-out order

1. PMOVE register file only (no walker) → the 16 PMOVE round-trip rows
   pass.
2. PTEST + walker, no ATC → the 11 PTEST/PLOAD rows pass.
3. Translation datapath (mmu_live rows: identity, remap, M/U bits).
4. ATC (the two ATC-staleness rows distinguish having one from not).
5. Fault frames (the three FAULT rows).

Real-hardware caveats baked into the corpus are listed in
`../test-blockers.md` ("PMMU corpus / bench invariants" and "MAME
oracle quirks") — read both before debugging a divergence here.
