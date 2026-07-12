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

## THE decisive check still open (in flight at session end)

**Does the ROM's boot screen (gray desktop / flashing "?") actually appear
on the CARD with sense=7?** montype-7 completing video init + ADB proves the
ROM didn't wedge, but NOT which display got the boot screen.

- `simsense_confirm/run2_*` — a `+montype=7 +mdc824` run screenshotting the
  CARD at **F800/1000/1200/1400** (AFTER video init this time — the first
  attempt's F300-650 shots were pre-video-init and blank; superseded) is
  RUNNING at session end. Harvest `simsense_confirm/screenshot_frame_0*.png`.
  **If the card shows a gray desktop / flashing "?" instead of the static
  PrimaryInit pattern → CONFIRMED: card-as-boot-display works with sense=7
  and Story A is essentially solved in RTL.** If still blank/PrimaryInit →
  the ROM completed video init but kept the boot screen on onboard (then
  need the card's own monitor sense, or model the 3-line extended sense).
- (ScrnBase $824 is the WRONG global to watch — it only gets its real value
  once the System loads, impossible with no disk; the ROM-era boot screen
  uses a different base. Use the screenshot, or trace the "?"/happy-Mac draw
  to find which VRAM it targets: onboard $60xxxxxx vs card slot-$E space.)
- If the card still shows only PrimaryInit gray → the ROM reached the boot
  wait but kept the boot screen on onboard; then either the ROM needs a real
  monitor-sense on the card side, or model the 3-line extended sense
  (modest: open-drain sense lines where a driven-low line reads back low).

## Next actions (in priority order)

1. **Harvest `simsense_confirm/` screenshots** → the confirm/deny above.
2. If confirmed: wire montype=7 into the FPGA path. Currently `MacIIvi.sv`
   `v8_monitor_id = status[10] ? 4'h2 : 4'h6` — add an OSD option (or make
   it default) to report sense 7 = "no onboard monitor" so the ROM boots the
   whole machine (happy Mac → Welcome → Finder) onto the card. Then the
   user's HDMI shows everything. Verify in sim WITH a disk (`--scsi0`,
   `+mdc824`, +montype=7) → expect Welcome/Finder ON THE CARD.
3. If a disk boots to Finder on the card: refresh `releases/MacIIvi.nvr`
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
