# RESUME — Mac IIvi: the gray-screen is a DISPLAY-ROUTING problem (2026-07-12, evening)

*Start here + `CLAUDE.md`. Prior context, in order:
`docs/resume_2026-07-12_adb_investigation.md` (this session's full detail —
its later sections supersede its earlier ones) and
`docs/resume_2026-07-11_iivi_bringup.md` (the 8-root-cause sad-Mac campaign).
Everything committed on `main`. NO hardware reboots/redeploys without the
user's explicit go — the core is LIVE on the .189 MiSTer.*

## The one-paragraph state

The `.189` "hangs at a gray screen" is **NOT a hang** — the ROM boots fine,
it just paints the OS onto the **onboard VASP display**, while our FPGA
scans out **only the mdc824 card** (which shows its static gray PrimaryInit
pattern). Proven three ways: MAME golden (7.5.5 desktop on onboard, card
gray — `releases/mame_iivi_755_dualhead_F3200.png`), our own core
(`+mdc824` scanout at F1200 = card gray while onboard has "Welcome"), and
the GDevice walk (onboard = main, card = gray secondary, regardless of
PRAM). **The fix in progress: make the onboard report "no monitor
connected" (sense code 7) so the ROM routes the boot display to the card.**
This session PROVED that path viable — with onboard sense=7 our core boots
cleanly to the no-disk boot-device wait ($807A5x by F538), i.e. video init
SUCCEEDS and does not wedge. The "montype-7 is a dead end" note from
2026-07-11 was wrong (an inherited over-conclusion, see below).

## What was learned this session (in order)

1. **ADB is exonerated.** The original hypothesis (ADB-init hang) is dead.
   Injecting a real mouse (new `--mouse-from` sim flag; the headless path
   never drove `ps2_mouse` before — see below) shows the ADB/Egret stack is
   healthy under load. Details: `docs/resume_2026-07-12_adb_investigation.md`.
2. **Story A (the user-visible bug) = display routing**, per the one-
   paragraph state above. This is the thing to fix.
3. **Story B (a real but SECONDARY bug): mouse motion during boot wedges
   the ROM** in an unbounded QuickDraw fill (boot rounded-desktop paint at
   ROM $40800530; StdRRect painter presets its row bound to #$7FFF at
   $4083496A and never narrows it → fills to row 32767). Latent (needs
   mouse motion) and DEFERRED per user until Story A is verified. Evidence:
   `simtracerun/` (F738-748 trace), `simwatchrun/` (+ramwatch values).
4. **montype-7 correction (the live thread).** The user challenged "onboard
   can't be disabled." They were right. `VASP_RETARGET.md:174` shows "no
   monitor → NuBus card" was the DESIGN INTENT all along. Our monitor sense
   is STATIC (pseudovia reg $10 bits 5:3 = `monitor_id`, identical to MAME's
   `montype<<3`; neither models a sense-line DRIVE). New `+montype=<n>`
   plusarg in `verilator/sim.v` overrides `v8_monitor_id`. Results:
   - `+montype=7` boots cleanly through the early checksum ($846BE6), the
     full RAM test ($846xxx, F38-458), into **video init (stack climbs to
     $0020FExx by F507)**, and reaches the **ADB driver loop $814908 by
     F608** — the SAME code the montype-6 control runs during ADB
     enumeration. i.e. POST + video init + Slot Manager all COMPLETED with
     the onboard monitor "unplugged". No wedge. (Evidence: `simscrnbase/`
     run_stderr.log heartbeats.)
   - So static sense=7 is SUFFICIENT to get the ROM through video init — it
     handled "no onboard monitor" and kept booting. The earlier MAME
     "montype-7 wedge" was MAME-specific and is NOT evidence about our core.
   - **CORRECTIONS to earlier claims (I twice over-read the data — verify,
     don't trust summaries):** (a) `$807A5x` is a TIMING DELAY loop
     (`mulu #$1F4 / dbf`), NOT the boot-device wait — "reached the boot
     wait" was wrong; the real evidence is the ADB loop $814908 above.
     (b) The first `+montype=7 +mdc824` screenshot run
     (`simsense_confirm/screenshot_frame_0{300,450,550,650}`) showed a BLANK
     light-gray card — but those frames were all DURING the RAM test (that
     run was slow, still in $846xxx at F650), i.e. BEFORE any display setup.
     Screenshotting the card pre-video-init proves nothing.
   - **OPEN puzzle:** the two `+montype=7` runs diverged in timing — the
     `simscrnbase` run reached video init by F507, but the
     `simsense_confirm` run (same montype, + `+mdc824` + screenshots) was
     still RAM-testing at F650 (a2 sweeping up through onboard VRAM
     $60B8xxxx — testing it as free RAM, consistent with card-as-display).
     `+mdc824` only feeds output muxes (sim.v:176-188), so it should NOT
     change CPU timing — unexplained. Re-verify determinism if it matters.

## RESOLVED (2026-07-13): sense-7 ROUTES THE BOOT DISPLAY OFF ONBOARD ✓

The clean, unconfounded test finally landed. Method: montype-6 vs montype-7,
**no disk, ONBOARD scanout (no +mdc824), same binary**, each watching every
write to onboard VRAM ($60000000-$60FFFFFF via +ramwatch), run to F1750 (past
montype-7's slower paint phase — it reaches the boot-wait $80786E by F1748).
Discriminator = the QuickDraw boot-desktop fill at PC $4082f1 (the routine
that paints the gray boot desktop):

| | QuickDraw fill $4082f1 → onboard VRAM |
|---|---|
| **montype-6** | **1,081,664 writes** (boot desktop painted on onboard) |
| **montype-7** | **0 writes** (never paints onboard, even past the paint phase) |

(The 688k `$00005262` writes in montype-7 are a low-RAM clear routine, common
to BOTH — montype-6 has ~1.07M of them too — NOT the discriminator.)

**Conclusion: with onboard sense=7 ("no monitor"), the ROM does NOT use
onboard as the display** — the boot-desktop paint goes elsewhere (the card,
the only other display). Corroborating signals, all consistent:
- montype-7's RAM test runs ~340 frames LONGER because it tests onboard VRAM
  as FREE RAM (the ROM no longer reserves it as a framebuffer).
- montype-7 (no-mdc824) still boots normally to the no-disk boot-wait
  $80786E — same end state as montype-6, just with the display rerouted.
- The card scanout (montype-7 +mdc824) shows the gray boot-desktop dither.

So the montype-7 / "report no onboard monitor" path is VIABLE and is the
fix for Story A: the user's HDMI (the card) will show the boot screen.

## REMAINING CAVEAT before FPGA (real, must resolve): `+mdc824` wedge/timing

The sim's `+mdc824` scanout flag has a CPU-visible side effect it should NOT
have (it only feeds output muxes, sim.v:176-188; VBL sources are
+mdc824-independent, lines 663/667). Evidence:
- montype-7 + `+mdc824` WEDGES at $803F2C (SwapMMUMode tail; `cd7`, last HBs
  all $803F2A-30, constant stack) — but montype-7 WITHOUT `+mdc824` reaches
  the boot-wait fine (`ob7ext`). So the wedge is a `+mdc824` interaction.
- montype-6 + `+mdc824` (`m6mdc`) stalled at the boot-wait with a mounted
  disk instead of booting the System, while montype-6 without it booted.
This matters because the FPGA ALWAYS scans out the card. EITHER it's a
sim-only artifact of the `+mdc824` plusarg (then the FPGA card-scanout path,
wired differently, is fine) OR it's a real card-scanout↔CPU interaction that
would bite on hardware. MUST check how the FPGA (MacIIvi.sv) does card
scanout vs the sim's `+mdc824`, and repro/trace the $803F2x wedge. Likely
near the VBL/interrupt or a signal the scanout mux inadvertently gates.

## (superseded) earlier MIXED + CONFOUNDED reading — kept for the trail

**Does sense=7 route the boot display to the card AND still boot to Welcome?**
Ran `+montype=7 +mdc824 --scsi0 <disk>` (`simsense_confirm/run3_*`,
screenshots F1200-1800). Results — read carefully, DON'T over-claim:

- **The disk boot WEDGED at $803F2C** (SwapMMUMode's `move (A7)+,SR / rts`
  tail): last 200 heartbeats ALL in $803F2A-30, constant a7=$20FB94, from
  F1259 to F1636+. It reached ADB ($814842, F1079) then stalled — did NOT
  reach Welcome. So sense=7 alone does NOT cleanly boot to Welcome; it hits a
  later wedge/tight-loop in the MMU-swap region.
- **The card image is AMBIGUOUS**: montype-7 card F1400/1600 = gray desktop
  dither ($EE/$22 50/50) + an arrow cursor top-left — BUT the montype-6 card
  (simcardrun) shows the SAME cursor + dither. So "cursor on card" does NOT
  distinguish main-vs-secondary; it appears in both.
- **BIG CONFOUND — `+mdc824` changes CPU timing.** The montype-6 CONTROL
  (simdiskrun, NO +mdc824, onboard scanout) reached the System ($00CA74,
  a7=$2F9F64 = the 7.5.5 stack signature) by F1200. The montype-6 KEYSTONE
  (simcardrun, +mdc824) was STILL in the boot ADB loop ($81490x, low stack
  $20FExx) at F1210 — same montype, same ROM, only +mdc824 differs. Yet
  +mdc824 only feeds output muxes (sim.v:176-188) and the VBL sources
  (v8_vblank→pseudovia line 663, card VBL→slot_irq_e line 667) are
  NOT +mdc824-dependent. So the timing shift is UNEXPLAINED and it confounds
  EVERY montype-6-vs-7 comparison this session. Possible real causes to check:
  the two runs used different disk-image copies (sim WRITES the image — prior
  state could differ); or +mdc824 has a subtle CPU-visible effect I missed;
  or a nondeterminism. RESOLVE THIS FIRST — a clean controlled A/B
  (montype 6 vs 7, +mdc824 BOTH, fresh identical disk copies, run to F2200+)
  is the only trustworthy comparison, and none of tonight's runs were clean.

**Net:** sense=7 is NOT a dead end (boots through video init + ADB — the
07-11 note was wrong, user was right), but it is NOT a proven turnkey fix
either — the disk boot wedged at $803F2x and the display evidence is
confounded. The next step is careful controlled experiments, not more
one-off runs. (ScrnBase $824 was the WRONG global — RAM-test noise + only
set once the System loads. Better discriminator: trace the happy-Mac/"?"
draw to see which VRAM it targets — onboard $60xxxxxx vs card slot-$E.)

## Next actions (in priority order)

1. **Untangle the `+mdc824` timing confound FIRST** (see the MIXED-result
   section). Clean A/B: montype 6 vs 7, `+mdc824` on BOTH, fresh identical
   `MacLC_7-5-5.hda` copies, `--heartbeat --no-cpu-trace`, run to F2200+.
   Compare where each ends up. If montype-6+mdc824 reaches the System/Finder
   while montype-7+mdc824 wedges at $803F2x → the wedge is montype-7-specific
   and real. If BOTH wedge at $803F2x → +mdc824 (or the disk copy) is the
   culprit, not montype-7. Also settle whether +mdc824 truly changes CPU
   timing (run montype-6 with vs without +mdc824, same fresh disk, diff the
   heartbeat trajectories frame-by-frame).
2. **Discriminate which display is main WITHOUT relying on the ambiguous
   card image**: trace the boot-screen / happy-Mac draw (or the "?" draw) and
   see which VRAM base it writes — onboard $60xxxxxx vs card slot-$E space.
   That is the unambiguous "is the card the boot display" answer.
3. Only if montype-7 proves to cleanly boot to Welcome-on-card: wire it into
   the FPGA path. `MacIIvi.sv` `v8_monitor_id = status[10] ? 4'h2 : 4'h6` —
   add an OSD option (or default) to report sense 7 = "no onboard monitor".
   Verify in sim (disk, +mdc824, +montype=7) → Welcome/Finder ON THE CARD.
   If montype-7 does NOT cleanly work, fall back to Path A (scan onboard —
   ONBOARD_DISPLAY shape) or Path B (PRAM main-display→card).
4. If a disk boots to Finder on the card: refresh `releases/MacIIvi.nvr`
   from a MAME 7.5.5 run if any PRAM display bytes matter.
4. THEN, and only on the user's go: rebuild RBF + redeploy to .189.
5. Later / deferred: Story B (mouse-boot QuickDraw fill) — root-cause the
   $7FFF-unbounded fill (harvest `simwatchrun` +ramwatch; diff visRgn/
   screenBits vs MAME) so a boot-time mouse wiggle can't wedge the machine
   once the display is fixed.

## Key tooling added this session (all committed)

- `verilator/sim.v`: `+montype=<n>` plusarg (override `v8_monitor_id`;
  7 = no onboard monitor) + `+ramwatch_lo/hi/f0/f1` (log RAM writes to an
  addr range in a frame window: `[F..] RAMWATCH_WR: addr= data= PC=`).
- `verilator/sim_main.cpp`: `--mouse-from <frame> [--mouse-to <frame>]`
  synthetic ADB mouse motion — the headless path NEVER built `ps2_mouse`
  packets before, so every headless run had a dead mouse (that's why the
  ADB device path was never exercised; and why sim reached Welcome while
  hardware "hung"). `adb_device.sv` gained SIMULATION-gated mouse-event /
  SRQ probes.
- MAME kit (`verilator/mame/`): `display_probe.lua` (GDevice/ScrnBase walk +
  `DP_MONTYPE` forcing), `cursor_ctx.lua` / `gdev_dump.lua` (mouse-wiggle
  ioport injection, RawMouse-verified), `monitors_drag.lua` (7.5.5 boot +
  dual-head snapshot). NOTE: MAME debugger bp/printf/dump actions are INERT
  under `-debugger none` in this 0.264 build — value capture must use lua
  memory reads or our sim's ramwatch.

## Gotchas (don't relearn)

- **The headless sim drives NO HPS-style inputs by itself** — mouse was
  frozen zero until `--mouse-from`. When hardware and sim diverge, FIRST
  audit which HPS inputs (mouse, keyboard, RTC, OSD status) the sim models.
- **Our monitor sense is STATIC** (no extended sense-line drive), same as
  MAME. A "montype-7 wedge" in either proves nothing about the real ROM.
- Rebuilding `verilator/obj_dir/Vemu` KILLS live sims running that file —
  each run execs its own copy (`Vemu_<tag>`) from its run dir. Fresh disk
  copies too (sim WRITES the image); pristine source
  `../MacLCII_MiSTer/scratch/MacLC_7-5-5.hda` (md5 13cbbaad…).
- `[HB]` heartbeats land in STDERR; `$display`/RAMWATCH in STDOUT (block-
  buffered ~4KB when redirected). EGRET debug lines log HC05 ticks ≈
  `$time/8`. Sim ~2-5s/frame; video init ~F450, no-disk boot wait ~F540.
- MAME cfg-poison: any ioport `set_value` from lua is saved to
  `~/.mame/cfg/maciivi.cfg` — `rm` it (and `nvram/maciivi/egret`) before any
  golden capture. `run_mame_maciivi.sh -nbe mdc824 ...` is the oracle.
- CPU sync rule still in force: `rtl/tg68k/` byte-identical to MacLCII @
  `a254a02`.

## Commit trail this session (newest first, all on main)

- `66aa70a` Correction: montype-7 does NOT early-wedge; card viable
- `d77a47a` Story A investigation: card cannot be boot display statically
  (SUPERSEDED by 66aa70a — that conclusion was the over-reach the user caught)
- `60e61a2` MAME visual proof: 7.5.5 desktop on onboard, card gray
- `4a4890d` REFRAME: gray-on-.189 = a scanout story (A) + mouse wedge (B)
- `ee88a6d` trace deep-dive: endless QuickDraw fill decoded; +ramwatch
- `b126a8e` findings: gray hang REPRODUCED in sim — cursor engine, not ADB
- `e62cafe` sim: headless path never built ps2_mouse — inject there too
- `f52dd67` sim: --mouse-from/--mouse-to synthetic ADB mouse motion
