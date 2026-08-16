# Speedometer gap vs real Performa 600 — differential analysis + speed ladder

Owner-reported 2026-08-16 morning: the core is "A LOT slower on all
accounts" than their PHYSICAL Performa 600 (same config class, 16MB RAM).
Evidence: hw_gate/speedometer_p600mode_cacheparked_20260816.png —
Speedometer 3.x run on build `13219f0b` (P600 32MHz mode, **I-cache
PARKED**, 48MB). System Info confirms the IIvx identity works (reads
"Mac IIvx", MC68030, No FPU, MC68030 MMU, ROM $067C 1024K).

## Measured (this core, P600 mode, cache parked)

Benchmark Mix (ratios vs Mac Classic = 1.0), average **1.805**:

| Test | Abs | Ratio |
|---|---|---|
| KWhetstones/sec | 24.213 | 3.316 |
| Dhrystones/sec | 1344.086 | 1.379 |
| Towers (sec) | 7.883 | 1.319 |
| Quick Sort | 6.300 | 1.362 |
| Bubble Sort | 8.000 | 1.688 |
| Queens | 5.967 | 1.279 |
| Puzzle | 14.917 | 1.480 |
| Permutations | 14.600 | 1.272 |
| Fast Fourier | 88.433 | 2.213 |
| F.P. Matrix | 49.367 | 2.190 |
| Int. Matrix | 6.250 | 2.259 |
| Sieve | 16.300 | 1.911 |

Color Benchmarks (vs Mac II = 1.0), average **0.523**:
Mono 68.783s / 0.474, TwoBit 76.317 / 0.510, FourBit 83.767 / 0.548,
EightBit 100.533 / 0.563.

Reference class for a REAL P600 (32MHz 030 + caches + 32-bit bus): CPU
average ≈ 3.6-4.0; video multiples of ours. **We are ~0.5x the CPU and
~0.2-0.25x the video of the real machine.** FIRST ACTION next session:
get the owner's saved physical-P600 Speedometer numbers (they have them;
desktop folder "MiSTer Performa 600 260816" holds OUR saved run) and
replace this estimate with exact per-test deltas.

## Why — the differential, ranked by contribution

The per-test SHAPE is the diagnosis: compute-bound tests (Whet 3.32,
FFT/Matrix ~2.2) sit ~2.4x above memory-bound ones (Dhrystone 1.38,
Permutations 1.27, Queens 1.28). The 32MHz turbo (internal beats) works;
everything memory dies on the bus. Contributors:

1. **No working I-cache** (parked 2026-08-16, `USE_68030_CACHE=0`): a real
   030 loses ~30-40% without its I-cache; ours is parked because the fill
   engine measured a 2x NET LOSS as integrated (docs/
   resume_2026-08-16_night_run.md §1). The probe hunt
   (docs/suggestedtasks.md #1, chip task_843cfb7f) is THE unlock — Friday
   proved the engine can pay (91s vs 154s boots). Expected Speedometer
   effect: large, across every CPU row.
2. **16-bit data bus** (LCII heritage): every longword = 2 bus cycles.
   The real P600's bus is 32-bit. A true 32-bit VASP bus is the big
   architectural project (addrController/dataController/sdram/peripheral
   muxes/both tops). Expected effect: up to ~2x on memory-bound rows.
3. **No D-cache** (`USE_68030_DCACHE=0`, arrays are fabric regs — didn't
   fit; M10K rework = the path, and unlocks after #1's fill fix since
   D-fills use the same engine).
4. **Slot-grid DTACK**: CPU waits for its bus slot (3-of-4 slots CPU,
   slot-start ack). Effective wait states on every access. Micro-lever:
   audit slot rotation / dead phases; historical +50% ack-rate win exists
   (H1 note in MacIIvi.sv dtack glue).
5. PMMU ATC-8 (was 22): minor; walk rate is low in flat System 7 mapping.

Video 0.523x Mac II — all in the mdc824 write path:
- Every QuickDraw write crosses the NuBus card FSM ~4-6 clk_sys per
  16-bit half + **RMW read for byte masking** + DDR3 VRAM domain crossing
  (MDC_VRAM_DDR). The real machine writes 32-bit words straight into
  local VRAM.
- Levers, cheapest first: (a) kill the RMW on full-halfword/full-word
  writes (byte-enables straight through — audit nubus_video_mdc824.sv
  write path); (b) posted-write FIFO so the CPU never waits on the card
  FSM (bounded depth, drain in card domain); (c) 32-bit lane pairing on
  writes (the scanout already has a pair-lane fetch chain — mirror the
  idea for stores); (d) longer term the 32-bit bus (#2) doubles the feed.

## Attack ladder (next session order)

1. Exact deltas: owner's physical-P600 numbers into this doc.
2. **Cache probe hunt** (suggestedtasks #1) → fix fills → re-enable
   I-cache → re-run Speedometer. Single biggest CPU lever, already
   scoped, evidence-rich.
3. **mdc824 write-path RMW/posted-write audit** — self-contained video
   project, likely the biggest video lever, no kernel risk.
4. Slot/DTACK micro-audit (cheap, measurable by Speedometer re-run).
5. D-cache via M10K rework (after 2), 32-bit bus (the big one, own
   branch, plan first in docs/VASP_RETARGET.md style).

Measurement discipline: Speedometer on the games volume is now the
canonical A/B (owner's saved-run folder on the desktop names the
convention: "MiSTer Performa 600 <yymmdd>"). Re-run + save after EVERY
lever; boot-settle times are NOT a proxy (UI-state dependence, see
night-run doc §2).

## Machine state at doc time

.143 = `13219f0b` parked settled in P600 mode, CD mounted; Speedometer
run was the owner's morning session. Branch `update-CPU` @ the night-run
tip + this doc. Chips pending: task_843cfb7f (cache probe),
task_5f610038 (scsi_bench rot — fix before trusting any SCSI-path lever).
