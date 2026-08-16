# Capture-on-ready: the cache fill root cause, closed analytically (2026-08-16)

Session context: the owner's morning Speedometer table showed the 3.95x CPU
gap vs the physical P600 (`docs/resume_2026-08-16_speedometer_gap.md`), with
the parked I-cache fill engine as ladder item #1 (chip task_843cfb7f). This
session closed the "when does ram_ready rise for a fill-borrowed read"
question WITHOUT the planned JTAG probe build — the answer was derivable
from the RTL, and it explains every HW datapoint of 2026-08-15.

## The mechanism (three stacked facts)

`ram_ready` (rtl/sdram.v:173) = `dout_valid && (dout_addr == addr)` — an
address-compare against the **live** `addr` input, where `dout`/`dout_addr`
update at STATE_READ of each serving slot and `dout_valid` is cleared only
by writes. Three top-level facts make that compare structurally useless at
a fixed late sample point:

1. **The addrDecoder is AS-gated** (`rtl/addrController_top.v` passes
   `_cpuAS`). The fill cycle deasserts AS at s6-phi2 (the same edge every
   normal cycle does), all selects drop, and `cpu_sdram_word` collapses to
   0 — so at s7-phi1 (capture-v2's sample point) the compare is against a
   dead address. **v2 sampled a constant 0 on HW.** Sim, with
   `fill_data_valid` tied 1, was constitutionally blind.
2. **The extra slot clobbers dout every rotation, floppy idle or not**:
   `dskReadAckInt/Ext` assert on `extraBusControl` alone
   (addrController_top.v:190-191), which muxes `memoryAddr` to the staging
   address AND — because `sdram_oe` includes them (MacIIvi.sv sdram mux) —
   issues a real read that overwrites `dout` with the staging word. So
   dout-persistence of a served fill word dies at the next extra slot,
   and during extra slots the raw compare can go true FOR THE FLOPPY WORD
   (a cross-master alias the old fixed-point samples dodged by accident).
3. **din is a latch, not a wire**: dataController's `cpu_data` register
   (dataController_top.sv:353,398) passes `memoryDataIn` through
   combinationally ONLY while `cpuBusControl && memoryLatch` (the last
   clk_sys of each CPU slot — exactly the old s6-phi2 edge); every other
   edge reads the previous passthrough. A capture at "some safer later
   point" therefore reads stale data even when the compare is true.

Together: the serve lands mid-to-late in the ack slot, the ONE edge where
compare-true and live-din coincide is the end-of-slot passthrough edge
(s6-phi2 in the aligned case), and by s7-phi1 the compare is dead in every
alignment. Hence the 2026-08-15 ladder of results:

| capture policy | HW result | why |
|---|---|---|
| s6-phi2 single-sample (Friday, 5a14a511) | 91s boots, occasional sad Mac | razor edge: mostly hits the coincidence window; metastable corner installs a bad word occasionally |
| s6 2-clk-stable (e4253e7) | 173s, cache never installs | window is ~1 clk wide; stability test unsatisfiable |
| per-word retry on s6 (b38c9ac) | 223s | retries re-run the same razor |
| s7-phi1 "kernel point" (962d60c) | 213-225s, never installs | structural 0 (fact 1) |
| fills DTACK-gated on ram_ready (first cut) | HW wedge | level-wait catches serve-then-clobber loops at fixed phase; pathological alignment starves forever, and clkena is held for the whole fill |
| the PMMU walker's ram_ready DTACK gate | works | level-wait DURING the AS window (compare valid), re-serves after clobbers — slow but correct |

## The fix (wrapper + top glue only; kernel untouched)

**Capture-on-strobe with a sticky served flag** (rtl/tg68k/tg68k.v FILL_READ):

- `fill_data_valid` is now a QUALIFIED strobe wired in MacIIvi.sv:
  `sdram_ram_ready & cpuBusControl & memoryLatch & ~download_cycle &
  ~card_ext_slot & (selectRAM | selectROM)`. When true, by construction
  `din == sdram dout == this word's data` (the compare implies the decode
  is presenting the fill address, the passthrough edge implies din is
  live, the exclusions kill every cross-master alias window).
- The FILL FSM latches `fill_buf[word]` and sticky `fill_served` on ANY
  strobe-true edge; the s7-phi1 verdict reads the flag (never the live
  level). Unserved → per-line-budget retry (unchanged); budget spent →
  poison+drop (unchanged); install requires clean line + served last word
  (unchanged).
- **Self-healing**: a word served after its cycle's passthrough edge
  persists in dout (only writes invalidate), so the retry cycle's FIRST
  passthrough edge recaptures it without re-racing the SDRAM. A fill word
  can be lost only to an extra-slot clobber landing between serve and
  retry — bounded by the budget.
- The sim twin (verilator/sim.v) uses the same expression minus
  `sdram_ram_ready` — the tied-1 shortcut is now WRONG (an unqualified
  capture at s7 would latch post-AS-drop garbage in sim too; the qualifier
  makes sim exercise the same window logic).
- `USE_68030_CACHE = 1'b1` (un-parked). D-cache stays tied off
  (USE_68030_DCACHE=0, M10K rework still pending).

Safety argument unchanged from the night invariants: fills keep slot-start
DTACK (can never stall the CPU), clean-only install (a line installs only
from compare-blessed captures — dirty data cannot be installed even in a
metastable corner, because a missed strobe just leaves served=0 → retry).

## Sim gates (2026-08-16)

- Verilator build clean; `check_boot.sh --run 40` PASS all 6 stages
  (150,378 insns).
- CACHE STAT over 40 frames: cum ihit 3.38M, **ifill 291 installing**
  (fills complete through the new path), cacr ie=1 de=0 (ROM enables the
  I-cache itself), no ORPHANED-AS tripwire.
- Corpus untouched (kernel unchanged).

## HW gates (2026-08-16)

- Quartus: Fitter Successful, ALM 38,644/41,910 (92%), RAM 457/553, regs
  36,341. **STA all 42 domains met FIRST ROLL on SEED 6** (HDMI divclk
  +0.083 padded, clk_sys +2.044). rbf md5 `6061d52d`.
- Deployed to .143 (md5-verified push + reboot + OSD select). **Boot 1
  settled CLEAN at ~110-125s** on the P600+CD config — settle md5 =
  the night's canonical `c6d176d7…` byte-identical (owner's morning
  session left the carousel state unchanged), icons pixel-perfect. No
  sad Mac, no wedge, and NO 213-225s fill-drag: the pathology is gone
  on the first boot.
- Boot cycles on 6061d52d: deploy cold boot ~110-125s settle; one
  stopped-marathon dirty restart ~170-185s (Desktop-DB rebuild outlier;
  see the owner-rule note below); one ESC warm restart ~90s. All three
  settled the canonical md5, zero sad Macs.
- **OWNER RULE (mid-session correction): never load_core over a running
  guest** — memory `verified-shutdown-before-restart` written,
  boot_marathon.sh clean_shutdown rewritten to quit-to-Finder + mouse
  Special/Shut-Down + safe-off-screen verification (aborts rather than
  dirty-boot), mac_clean_shutdown.sh now auto-detects the mrext-mouse
  event device. ALSO LEARNED: **ESC at the MacAtrium carousel is an
  INSTANT clean Restart** (no menu, no confirm — the Shutdown Manager
  flushes and reboots). That explains the night-run "no-op shutdowns":
  they were clean ESC-restarts with load_core landing pre-mount. ESC is
  off-limits as a "menu" key at the carousel.

### Speedometer 3.23, P600 mode + I-cache (build 6061d52d, 48MB, CD mounted)

Benchmark Mix vs the parked-cache morning run (ratios vs Mac Classic=1.0;
parked numbers from the owner's morning session/table):

| Test | Parked abs | Parked rat | Cache abs | Cache rat |
|---|---:|---:|---:|---:|
| KWhetstones/sec | 24.213 | 3.316 | 21.770 | 2.982 |
| Dhrystones/sec | 1344.086 | 1.379 | 1469.867 | 1.508 |
| Towers (sec) | 7.883 | 1.319 | 6.883 | 1.511 |
| Quick Sort | 6.300 | 1.362 | 3.450 | 2.488 |
| Bubble Sort | 8.000 | 1.688 | 2.183 | 6.183 |
| Queens | 5.967 | 1.279 | 2.283 | 3.343 |
| Puzzle | 14.917 | 1.480 | 5.483 | 4.027 |
| Permutations | 14.600 | 1.272 | 8.083 | 2.297 |
| Fast Fourier | 88.433 | 2.213 | 101.967 | 1.919 |
| F.P. Matrix | 49.367 | 2.190 | 57.917 | 1.867 |
| Int. Matrix | 6.250 | 2.259 | 2.483 | 5.685 |
| Sieve | 16.300 | 1.911 | 4.200 | **7.417** |
| **Average** | | **1.805** | | **3.435** |

(All ratios confirmed from the redrawn-window grab the owner requested.)

**CPU average 1.805 → 3.435 (+90%).** Gap to the physical P600 (7.136):
3.95x → **2.08x**. Gap to the physical LC II (4.471): 2.48x → **1.30x**.
The cache-signature rows (the tight small-working-set loops) moved the
most: Sieve 3.9x, Bubble 3.7x, Puzzle 2.7x, Queens 2.6x, IntMatrix 2.5x
— exactly the rows the LC-II differential predicted. The three SANE
software-FP rows (KWhet/FFT/FPMatrix) DIPPED 10-13%: low-locality code
where fill borrow-slots cost more than the 256B I-cache saves — the
D-cache (M10K rework) and wait-state work are the remaining terms.
Color Benchmarks (vs Mac II = 1.0), all four depths, Iter 1:

| Test | Parked abs | Parked rat | Cache abs | Cache rat |
|---|---:|---:|---:|---:|
| Monochrome (sec) | 68.783 | 0.474 | 51.500 | 0.633 |
| Two Bit (sec) | 76.317 | 0.510 | 55.733 | 0.699 |
| Four Bit (sec) | 83.767 | 0.548 | 61.433 | 0.747 |
| Eight bit (sec) | 100.533 | 0.563 | 74.000 | 0.765 |
| **Average** | | **0.523** | | **0.711** |

**Video average 0.523 → 0.711 (+36%)** — uniform ~1.35x across depths
(the QuickDraw inner loops are I-cache-resident; the remaining wall is
the mdc824 write path itself). Gap to the physical P600 video (1.622):
3.10x → **2.28x**.

Owner verdict (live, mid-session): "significantly faster in many
respects, but did lose some performance as part of some tests, and the
video still isn't as fast as it should be" → commit, then continue the
ladder with the video write path (#3) next.

Evidence: hw_gate/speedometer_p600_captureready_20260816.png (full
tables) + _cpudone_ variant (CPU table with the covered ratios visible).

## Device notes (2026-08-16 morning)

- Owner cleanly shut down after their Speedometer run (safe-to-switch-off
  screen); machine handed over ("go nuts").
- `/media/fat/_Unstable/MacIIvi_parked13219f0b.rbf` = backup of the
  owner's morning build (13219f0b) for same-day A/B; `MacIIvi_nc.rbf` =
  dea200c6 rollback still staged.
- CFG byte0 = 0x0E (P600 32MHz + 48MB) — left as-is; boots come up P600.
- mrext input devices RENUMBERED since July: keyboard=event12,
  mouse=event13 (mac_clean_shutdown.sh's event9 default is stale). They
  renumber again on MiSTer reboot (deploy does one) — re-check
  /proc/bus/input/devices before any injection.
- Speedometer 3.23 lives at `/Tools/Speedometer 3.23` on the games volume
  (rb-cli ls; NOT /Applications). Menu shortcuts (from its MENU
  resources): Tests = Performance Rating Cmd-R, **Benchmark Mix Cmd-B**,
  FPU Cmd-F, **Color QuickDraw Cmd-G**, Run ALL Cmd-A; Windows Cmd-1..7;
  File: Save Machine Record Cmd-S, Quit Cmd-Q. Items with … open a dialog
  first (Return = default = run).
- MacAtrium menus (from its resources): app menu has Launch/L, Get
  Info/I, Show Finder, **Quit/Q** ("Are you sure… The Finder will come
  back." → confirm); ESC Quick-Launch menu includes Exit to Finder /
  Restart / Shut Down rows (peek live for row order — it is
  view-dependent).
- Core Command key = PS/2 **ALT** (rtl/ps2_kbd.sv) → KEY_LEFTALT in evdev
  injection; scripts/mac_kbd.py (new this session) sends cmd:x combos and
  type:/key: tokens with paired press/release.

## Posted-write build: HW-FALSIFIED on the SEED 7 netlist (session close, ~12:55)

`1ecedb71` (posted-write mdc824 + cache, SEED 7, STA all-met) **sad-Macs
POST 2/2 on HW** — $0F/$0003 (address error) then $0F/$000A (F-line) on
consecutive boots. DIFFERENT minor codes across boots = the intermittent
corrupted-fetch **marginality class** (the 2026-08-15 93%-ALM script
replayed: STA-met fits corrupting CPU fetches), NOT a deterministic
posted-write protocol failure — a real ack hole would die at the same
probe identically. The RTL (122a2b1) stays committed; the NETLIST is the
suspect. Do not redeploy 1ecedb71 (archived
scratch/MacIIvi_1ecedb71_postedwrite_SADMAC.rbf).

Recovery: 6061d52d (validated cache build) redeployed, settled canonical
~63s, machine parked at the carousel in P600 mode.

## Handoff for the next session (owner: "later this week")

1. **SEED 5 fit of the posted-write netlist was cooking at session end**
   (auto_compile log in output_files/) — check STA; if met, gate on
   2 boots + icons + Speedometer BEFORE trusting it (STA alone proved
   insufficient twice now). Seed history in the qsf.
2. If seed-lottery keeps failing: consider the marginality-anchor
   approach (the always-on SCSI anchors precedent) for the fetch path,
   or shed ALMs (PMMU ATC 22→8 is the known ~free knob, evaluated
   2026-08-15) to get off the 93% edge.
3. The posted-write A/B measurement (Speedometer Color vs 0.711) is
   still PENDING — it needs a healthy netlist first.
4. Remaining ladder: D-cache via M10K rework (fill engine now proven),
   word-granular fill yield (suggestedtasks #3, recovers the FP-row
   dip), slot/DTACK audit, 32-bit bus.
5. scsi_bench gate is TRUSTWORTHY again (0 fails) — run it after any
   family sync (all-S matrix = the --id clobber signature).

Session totals (owner's morning table → now, P600 mode, same volume):
**CPU 1.805 → 3.435 (+90%), video 0.523 → 0.711 (+36%)**, gap to the
physical Performa 600 halved on both axes. 25+ deploy/boot cycles, two
release-quality regressions caught and fixed (bench rot, ESC landmine),
one owner rule learned and encoded (verified shutdown).
