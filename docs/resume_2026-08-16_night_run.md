# Night run 2026-08-16 (owner asleep): cache verdict, ring, P600 park

Continuation of `docs/resume_2026-08-16_speed_session_results.md`. Branch
`update-CPU`, commits `e4253e7..8a4e542`. The owner asked (before sleep):
keep driving to a good stopping point; try 32KB SCSI ring; deploy P600 for
them; keep the CD mounted.

## Where the machine is (the morning state)

- **.143 runs `13219f0b`** = the cache-PARKED turbo-only build: capture-v2
  kept inert behind `USE_68030_CACHE=0`, 32KB boot-disk ring, IIvx
  `$A55A2015` box-ID, OSD `Performa 600 (32MHz)` label, SEED 6 (all
  domains met, HDMI +0.106 padded). **Parked settled in P600 32MHz mode**,
  games carousel (PoP selected), CD auto-mount intact.
- Boot pace: **~100-113s to settled** at both 16MHz and P600 (11
  consecutive clean boots on the final build family tonight; 25 total
  clean boots across all builds, ZERO sad Macs all night).
- Rollbacks staged: `/media/fat/_Unstable/MacIIvi_nc.rbf` = dea200c6
  (no-cache validated); scratch/ holds 6c412b45 (hardened, marathon-passed).

## The night's findings, in order of importance

1. **The I-cache fill engine is a measured 2x NET LOSS on HW as
   integrated** — the clean A/B (same night/volume/UI-state/CD): no-cache
   ~100s vs 213-225s for ALL THREE capture policies (poison e4253e7,
   per-word retry b38c9ac, kernel-point v2 962d60c — within seconds of
   each other, so capture policy is NOT the variable). Friday's same-day
   91s-vs-154s win proves the engine CAN pay. Open question: when does
   `ram_ready` (sdram.v:173 addr-compare level) actually rise for a
   fill-BORROWED read on HW? Sim is constitutionally blind
   (`fill_data_valid` tied 1 in sim.v). **Chip task_843cfb7f** = the JTAG
   counter-probe hunt. Cache re-enable = flip `USE_68030_CACHE` +
   answer that question. Stability was never the issue: capture-v2's
   clean-only install held across every boot.
2. **Settle times are persisted-UI-state dependent** (MacAtrium carousel
   art loading differs per category/selection): Friday's 154s-no-cache vs
   tonight's 100s-no-cache same rbf = state+CD delta. NEVER compare
   settle numbers across persisted states. The settle reference md5 for
   the current state (Recommended/PoP carousel):
   `c6d176d73e048dfb1eff739dc2ad5326` — held byte-identical across 11
   boots, both machine modes, with and without CD.
3. **scsi_bench sweep gate is ROTTED**: 532 failing cells on the
   UNMODIFIED tree (July baseline was 0). Chip task_5f610038. The 32KB
   ring (3e7dd2b) is therefore HW-gated: marathon settles byte-identical,
   PoP color intro streams clean (hw_gate/appgate_pop_intro_running.png).
4. **App-launch freeze NOT reproduced** on the final build (PoP launched
   from the carousel via `confirm`, loaded, intro running). The owner's
   Amazon Trail hang happened on the 6c412b45 slow-cache build — likely
   its fill-drag pathology; retest Amazon Trail in daylight if it recurs.
5. **ESC-menu keyboard shutdown is VIEW-DEPENDENT** (carousel arrows
   change category; my blind sequence changed the view mid-run once). The
   22:04 marathon "shutdowns" were no-ops — and 7.1 boots the dirty
   volume without complaint (no dialog, identical settles). Verified
   shutdown = grab the safe-to-switch-off screen (black, lum ~15-25).
   boot_marathon.sh has `SKIP_SHUTDOWN=1` for idle-desktop loops.
6. HDMI knife-edge per-netlist seed sweeps: capture-v2 netlist closed on
   SEED 2; cache-parked netlist needed 2→4→5→6 (seed 6 met). History in
   the qsf as always.

## Gates run tonight (all PASS unless noted)

- 48MB marathons: 5/5 on 6c412b45 (173-290s era), 5/5 on 378ece5f
  (223-225s), 5/5 on 52a433d9 (213-224s), 3/3 on 13219f0b (106-113s).
- No-CD A/B boots: 196s (378ece5f) / ~100s (dea200c6 nc baseline).
- App-launch gate: PoP via carousel confirm on 13219f0b — PASS.
- P600 32MHz timed boot on 13219f0b: ~100s, settle byte-identical — PASS.
- NOT done (needs owner/daylight): About This Macintosh IIvx-family check
  (guest mouse work), Amazon Trail retest, 8MB spot check on the final
  build, second P600 boot, merge call.

## Morning ladder

1. Owner tries the machine (it's live in P600 mode). Feel check vs last
   night's sluggish session — this build is the fast configuration.
2. About This Macintosh + Amazon Trail retest with the owner present.
3. The two chips: cache probe hunt (the big one), scsi_bench repair.
4. Merge call: the branch is 10 commits ahead tonight (e4253e7..8a4e542),
   all sim+HW gated in this doc + memory. 16MHz default is currently
   cache-parked = same speed as the pre-cache builds; P600 = turbo-only.
