# PRAM boot-hold fix — hardware validation record (2026-07-16)

Branch `PRAM-fix`, RTL commit `18a8492` (port of MacLC `5cef15d`), build
md5 `98e03e8e687548e8e58cb973d26deb2d` (SEED 5, Fitter Successful, all
timing met, worst setup +0.417 ns, ALM 35,611). Staged copy:
`scratch/MacIIvi_pramfix_98e03e8e.rbf`. All hardware runs on .143 with
the shipped 7.6.1 image; **every core reload was preceded by a clean
guest shutdown** (`scripts/mac_clean_shutdown.sh`, virtual-mouse-driven
Finder Special > Shut Down) so no boot ever started from a dirty HFS
volume.

## Gate results

1. **Consecutive fresh loads — PASS (4/4).** `load_core` x4, each boot
   reached the Finder desktop unassisted in <240 s with PRAM applied
   (identical desktop layout; guest menu clock tracked host minutes
   across every cycle: 3:51/3:56/4:00/4:05 PM vs 16:51-17:05 host).
   Clean-shutdown end screens byte-identical across all cycles
   (md5 `f3c57a16bd0cf2fefe35a366c8860d5e` — the deterministic PASS
   signature; boot screenshots can't be byte-identical because the
   menu clock is live). Evidence: `scratch/pramC_boot{1-4}.png`,
   `pramC_safe{1-4}.png`.
2. **Virgin NVRAM — fix mechanisms PASS; pre-existing wedge found.**
   With a 512-zero-byte .nvr the CPU is released promptly, the ROM runs
   and paints the boot screen (no black-screen hold — the failure class
   this fix targets is absent). However boot then wedges at the
   happy-Mac screen (byte-stable frame ~10 min). **A/B-proven
   pre-existing:** the previous release build
   (`MacIIvi_Unstable_20260716.rbf`, no PRAM-FSM changes) wedges at a
   BYTE-IDENTICAL frame (md5 `b5d8473072d6ff27266a1d371aaee96c`, both
   builds). Filed separately (prime suspect: 1-bit/default video depth
   path; see the zero-PRAM wedge task). Evidence:
   `scratch/pramC_virgin_boot.png`, `virgin_still.png`,
   `ab_prev_virgin.png`. The good .nvr was restored afterwards
   (md5 `b91f102f83cec89e9014446977a5c63a`; backup kept on the SD as
   `games/MacIIvi/MacIIvi.nvr.good`).
3. **Persistence round-trip — PASS** (adapted: no guest-settings change
   was made because the harness drives nav-keys/mouse only; the
   critical no-wipe property is fully covered). Valid .nvr → fresh load
   → desktop with PRAM applied → OSD open/close (autosave path) → .nvr
   hash UNCHANGED (`b91f102f…` — the historical short-timeout
   regression would have wiped/rewritten it) → clean shutdown → fresh
   load → desktop again → final hash still `b91f102f…`. Evidence:
   `scratch/g3_boot{1,2}.png`, `g3_safe{1,2}.png`.
4. **Late-load auto-restart — absent (as expected).** All mounts were
   healthy/fast; no boot showed more than zero auto-restarts (a restart
   loop would be a bug; none observed across 7 desktop boots).

## Environment audit (pre-coding, all clean)

- .nvr valid: `NuMc` at 0x0C, SPValid 0xA8 at 0x10, 53 nonzero bytes.
- `config/MacIIvi.s0` -> `games/MacIIvi/HD10_7_6_1 60MB.hda`, `.s2` ->
  `games/MacIIvi/MacIIvi.nvr`, no `.s1`, all paths resolve.
- No root-level `/media/fat/MacIIvi`.

## Egret-wrapper invariants verified before porting

- `reset_680x0 = reset_680x0_latched | ~pram_loaded` (egret_wrapper.sv:594)
- boot-copy gate `!pram_loaded && !reset_680x0_latched && pram_ready` (:766)
- `pram_loaded` cleared by reset (:753) — the late-load restart re-fires
  the boot-copy through the same mechanism the R6 path uses.

## Incidental findings

- The 2026-07-16-morning one-off CFM-68K bus-error bomb did not recur
  across 7 clean-filesystem boots — consistent with the dirty-HFS
  attribution (reloading the core under a live Mac). The clean-shutdown
  script exists so automated reloads never do that again.
- The clock fix (main @ 8c65574) held minute-sync mod DST through every
  reboot and PRAM cycle in this session.
