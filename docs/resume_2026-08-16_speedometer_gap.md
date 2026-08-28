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

**AUTHORITATIVE comparison: `docs/Speedometer_3-23_Benchmarks.md`** (the
owner's measured table — physical Mac LC, LC II, Mac II, Performa 600,
and This Core, all Speedometer 3.23). Exact deltas:

| | Physical P600 | This Core | Gap |
|---|---:|---:|---:|
| CPU average | 7.136 | 1.805 | **3.95x** |
| Video average | 1.622 | 0.523 | **3.10x** |

Per-test gap ranking (P600/core): Sieve 6.7x, Puzzle 6.05x, Queens 4.91x,
Bubble 4.90x, QuickSort 4.20x, Permutations 4.04x, IntMatrix 4.03x,
Dhrystones 2.96x, FPMatrix 2.93x, KWhet 2.80x, Towers 2.73x, FFT 2.70x.

And the owner's opening observation confirmed: the 68020 **Mac LC beats
this core 2x** (3.702 vs 1.805); the LC II 2.5x (4.471).

## Why — the differential, ranked by contribution

**The Mac LC II row is the master key.** The real LC II = 16MHz 68030 on
the SAME 16-bit bus and same V8-family chipset this core inherited, no L2
— and it scores 4.471 vs our 1.805 (2.48x). So the 16-bit bus does NOT
explain the bulk of the gap: the real LC II pays the same bus toll and
wins 2.5x with HALF our (turbo) clock. What it has that we lack: the
030's on-chip I+D caches ENABLED, and a bus that doesn't burn slot-grid
wait states. The per-test gap ranking says the same — our worst rows
(Sieve 6.7x, Puzzle 6.1x, Queens/Bubble 4.9x) are tight small-working-set
loops that fit entirely inside the real 030's 256B+256B caches; our
least-bad rows (FFT/Whet/FP ~2.7-2.9x) are SANE software-FP compute where
turbo's internal beats help. Contributors, re-ranked by this evidence:

1. **Both 030 on-chip caches missing** (I-cache parked
   `USE_68030_CACHE=0`; D-cache never fitted `USE_68030_DCACHE=0`) — the
   dominant term per the LC II evidence: together with wait-states this
   is the ~2.5x real-LCII delta, concentrated in exactly our worst rows.
   The fill-engine probe hunt (docs/suggestedtasks.md #1, chip
   task_843cfb7f) is THE unlock (Friday proved fills can pay: 91s vs
   154s boots); D-cache needs the M10K array rework after it. This is
   worth MORE than everything else combined — target the Sieve/Puzzle/
   Queens rows as the measurement.
2. **Slot-grid DTACK wait states**: the CPU waits for its slot in the
   rotation with slot-start ack — cycles the real LC II's chipset doesn't
   burn the same way. Micro-audit slot rotation/dead phases (the H1 note
   in MacIIvi.sv dtack glue documents a historical +50% ack-rate win).
   Cheap, measurable, kernel-free.
3. **16-bit data bus**: real per-longword cost, but bounded by the
   P600-vs-LCII residual (7.136/4.471 = 1.6x = what the real 32-bit bus
   + 32MHz + L2 buy TOGETHER). The true 32-bit VASP bus remains the big
   architectural project — worth it only after 1+2 land.
4. PMMU ATC-8 (was 22): minor; walk rate is low in flat System 7 mapping.

Video 0.523x Mac II (owner's table anchors: real LC/LCII onboard ≈1.25,
real Mac II ≈1.27, real P600 ≈1.622 — every physical machine is 2.4-3.1x
our card) — all in the mdc824 write path:
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

1. ~~**Cache probe hunt**~~ **DONE 2026-08-16** — closed analytically
   (capture-on-strobe, `docs/resume_2026-08-16_capture_on_ready.md`):
   Speedometer CPU 1.805 → 3.435, video 0.523 → 0.711 on HW. Gap to the
   physical P600 now 2.08x CPU / 2.28x video. The SANE FP rows dip 10-13%
   (fill stall on low-locality code — suggestedtasks #3, word-granular
   fill yield).
2. **Slot/DTACK micro-audit** (cheap, kernel-free, measurable) — the
   other half of the real-LCII 2.5x delta.
3. **mdc824 write-path RMW/posted-write audit** — self-contained video
   project, the 3.1x video gap lives here, no kernel risk.
4. D-cache via M10K rework (after 1 — same fill engine).
5. 32-bit bus (the big one, own branch, plan first in
   docs/VASP_RETARGET.md style; bounded win ~1.6x-class per the
   P600-vs-LCII residual).

Target: real-LC II parity (4.47) is the honest near-term goal —
caches + wait-states get us there without touching bus width. P600
parity (7.14) needs the full ladder.

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
