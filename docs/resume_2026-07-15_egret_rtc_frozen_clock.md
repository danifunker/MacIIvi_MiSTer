# Resume: Egret RTC frozen-clock investigation (2026-07-15)

**Status: ROOT CAUSE FOUND + FIXED + SIM-VALIDATED END-TO-END, committed on
`fix/egret-rtc` (RTL fix = a339fea; tooling + this doc = the branch tip). The frozen Mac
time-of-day clock was a deadlock in our 68HC05 core's interrupt sampling
(edge-detect swallowed one-second ticks); fix = level-sensitive internal
IRQs in `rtl/egret/m68hc05_core.sv`, on top of the earlier (correct but
insufficient) `$12` register fix in `egret_wrapper.sv`. Gates 1-3 PASSED
(sustained sim Time advance, check_boot, Quartus timing-clean rbf built).
REMAINING: owner-gated deploy to .143 + hardware clock soak, then merge.**

---

## TL;DR

1. **What drives the displayed clock (MAME-proven):** classic Mac OS / the
   ROM advances `Time` ($20C) once per second when the **Egret pushes a
   one-second packet over the VIA1 shift-register channel** (TREQ asserted,
   ~16 CB1 edges clocking bytes $00,$03 into the SR blind). The ROM's
   level-1 VIA SR interrupt reads SR twice ($40814970) and increments Time
   at **$4080B146**. Boot-time Time-set from the Egret RTC is at
   **$40815640**, and per-second ticking starts ~0.2 s after that. The
   60.15 Hz CA1 tick / `Ticks` global is NOT involved in Time. (MAME probe:
   `verilator/mame/clock_probe.lua`, logs in `scratch/clockprobe/`.)
2. **Why ours froze:** `m68hc05_core.sv` accepted interrupts only on a
   falling **edge** of the request line sampled while unmasked
   (`flagI==0`). The one-second line (`~(flag & enable)`) falls once when
   the flag sets; if that instant lands in a SEI window (e.g. the firmware's
   CB1 shift routine `$14EC` starts with SEI) or inside another ISR, the
   edge is swallowed — and because the flag stays set, the line stays low
   and **no edge ever occurs again**: one-second ISRs stop permanently.
   Real 68HC05 / MAME sample the latched flag as a LEVEL at instruction
   boundaries, so a masked tick is simply taken late. This deadlock is why
   the earlier `$12` fix (flag semantics, free-running counter) didn't cure
   the freeze — the flag was being SET correctly and never taken.
3. **The fix:** one-second + timer requests are now level-sensitive
   (`m68hc05_core.sv` ~line 186); external /IRQ pin keeps edge sensing
   (tied inactive). Re-entry safe: every firmware ISR path clears its flag
   before RTI (onesec `BCLR 6,$12` at $1E2A/$1E31/$1E4B; timer clears
   $08.7).
4. **Verified so far (sim, ONESEC_PERIOD=8192≈2 ms):** one-second ISR
   entered on EVERY tick for the whole run (7,664 `$CC` writes over 300
   frames, drains healthy, no plateau — pre-fix it died almost
   immediately). Host-side Time-set/ticking not yet observed **only
   because the ROM was still in its RAM test at frame 300**; a 700-frame
   run is in flight to see the ROM reach clock-init and Time increment
   sustained.

## Verification gates before deploy

1. [PASS] 700-frame sim (2026-07-16 am): Time set from Egret RTC at
   $40815640 (F474: `move.l $1e4.w,$20c.w`), then the tick handler
   `addq.l #1,$20c.w` at $4080B146 executed in EVERY frame F509-F699 —
   812 increments, 7,451 VIA SR IRQs, 905 Egret notify sessions, 17,902
   $CC ISR writes; sustained the entire run (log:
   scratch/clockprobe/sim_clock3.log; pre-fix run for contrast:
   sim_clock2.log — ISR alive but boot hadn't reached clock-init;
   sim_clock.log = pre-fix, ISR dead).
2. [PASS] `check_boot.sh --run 30`: exit 0, all six stages, ADVANCING,
   1,283,735 insns (baseline 1,283,227).
3. [PASS] Quartus rebuild: Fitter Successful, timing FULLY MET — worst
   setup +0.183 ns, TNS 0.000 on all domains (the previous build's
   −0.149 ns HDMI-PLL violation is GONE; ALM 35,614 = −19 vs bad build,
   the level-IRQ change nets smaller). output_files/MacIIvi.rbf
   (Jul 15 23:57) is the deployable artifact.
4. [PENDING — owner gate] Deploy to .143 + hardware soak: menu-bar clock
   advancing 1:1 over ≥30 min. NO deploy without explicit request. Then
   merge to main.

## Watch item RESOLVED: via6522 SR external-clock arming

Empirically cleared by gate 1 — 7,451 unsolicited-notify SR IRQs fired
with the existing armed-trigger model (the ROM's SR read after every byte
keeps it armed in steady state). The MAME divergence below remains as
background only (NOT a live bug):

MAME's 6522 free-runs the ext-clock shift counter (`m_shift_counter`
decrements on EVERY CB1 edge, IFR.SR fires each mod-16 wrap; SR access just
re-syncs to 0x0F). Ours (`rtl/via6522.sv` ~825-940) only counts while
`shift_active`, which is armed ONLY by a CPU SR read/write
(`trigger_serial`); unsolicited CB1 edges into an un-armed SR shift data
but never fire IFR. The steady-state tick flow (ROM reads SR after every
byte → always re-armed) should work, but if the long sim shows Egret
notifies arriving with no "SR IRQ fired", port MAME's free-running counter.
The "COMPLETE (ext) SR=0x.." $display prints shift_reg one shift stale
(0x07 shows as 0x83) — display artifact, not a data bug.

---

## Git / working-tree state

- Branch: **`fix/egret-rtc`** (cut from `main` @ `53580ba`), COMMITTED:
  `a339fea` (RTL: m68hc05_core level-IRQ fix + egret_wrapper $12 fix +
  probe displays + via6522 display) + a tooling/doc commit at the branch
  tip (clock_probe.lua + this doc). Not pushed, not merged — merge after
  the hardware soak.
- `main` @ `53580ba` clean and validated (not pushed).

## The MAME experiment (how the mechanism was proven)

`verilator/mame/clock_probe.lua` taps, per guest second: maincpu writes to
$20C/$16A (with writer PC), VIA1 SR/PB traffic (both $5000xxxx/$50F0xxxx
mirrors), and Egret-internal writes ($CC seconds counter, $AB-$AE RTC, $A2
notify flags, port B CB1/CB2 bit-banging). Runs (MAME 0.264, WSL):

- `scratch/clockprobe/probe.log` — desktop steady state: every second,
  Egret ISR fires ($1E10, INC $CC@$1E17, $A2|=0x98@$1E2A) → mainline runs
  notify ($1549/$14EC PC cluster, TREQ + ~16 CB1 edges, egPBw≈42) → host
  reads SR twice at $40814970 (values $00 then $03) → Time++ at $4080B146
  → Egret clears pending ($A2→0x90 @$1AF3). `Ticks` counts 60/s
  independently; `dTickW` never correlates with Time.
- `scratch/clockprobe/probe_early.log` — boot onset: 68030 starts ~f=480,
  big Egret exchange (PRAM cmd $07 reads / $0C writes; response packet
  framing `[01][00][cmd][data...]`), Time set from RTC at f=534
  (pc=$40815640), first tick-increment f=547, every second after.
- Protocol notes: Egret RTC ($AB-$AE) and host Time stay in lockstep but
  are independent counters (Egret ISR-drain vs host tick-packets). MAME
  seeds the Egret RTC at 68k-reset-release from `get_local_seconds()`
  (LOCAL time in MAC epoch — see egret.cpp pc_w) — relevant to our
  separate epoch bug (we seed raw UNIX `timestamp`).

## Sim instrumentation added (SIMULATION-gated, kept)

- `EGRET_CC_WRITE` (egret_wrapper.sv ~777): $CC is written ONLY by the
  one-second ISR ($1E15/$1E36 INC) and the $1E4E drain (DEC) — the
  ISR-liveness probe.
- `EGRET_ONESEC ... Timer fired!` (egret_wrapper.sv ~256): flag-set events.
- `VIA: SR IRQ fired!` (via6522.sv ~942): IFR.SR delivery to the host.
- Host-side: grep cpu_trace.log for `] 40815640:` / `] 4080B146:` /
  `] 40814970:` (executed PCs) and `@0000020C` (Time writes).

## Reproduction / analysis commands

```bash
# MAME oracle probe (WSL; always a COPY of the disk image):
PROBE_START=1800 MAX_FRAME=8400 /usr/games/mame maciivi \
  -rompath verilator/mame/roms -ramsize 8M -scsi:0 harddisk \
  -hard1 scratch/clockprobe/boot.hda -skip_gameinfo -video none -sound none \
  -nothrottle -seconds_to_run 150 -autoboot_script verilator/mame/clock_probe.lua \
  -snapname 'maciivi/f%i' -snapshot_directory scratch/clockprobe

# Sim verification (WSL, from verilator/):
./obj_dir/Vemu --headless --heartbeat --stop-at-frame 700 --trace-frames 350,700
# Boot timeline (sim): Egret boot exchange ~F3-F78 (190 SR bytes), RAM test
# F80-F490ish (two+ passes, ~45KB/frame on pass 2), clock-init after.
```

## Separate / adjacent bugs still standing (unchanged from first session)

- **RTC epoch delta (~66-year date error).** We seed the Egret RTC from raw
  UNIX `timestamp` without the +2082844800 Mac-epoch correction (and without
  local-time offset). MAME's egret uses local-time Mac-epoch seconds. Fix on
  this branch or follow-up once the freeze fix lands.
- **DST hour** (HPS delivers fixed EST) — framework, revisit later.
- **7.6.1 "error 41" — RESOLVED, not a core bug** (image needed first boot;
  archived `scratch/HD10_761_ORIG_error41.hda` / `HD10_761_NEW.hda`).
- **CPU cache — none exists** (CACR plumbed, nothing consumes it). Biggest
  perf lever for "sluggish"; own project (MacLCII-first per CPU sync rule).
- **"Sluggish" complaint is NOT explained by the clock fix** — clock-audit
  facts (CPU +3.7%, tick sources) still the working thread. Note: pre-fix,
  swallowed TIMER edges also deadlocked the Egret's internal timer ISR the
  same way; post-fix Egret housekeeping (ADB autopoll cadence) may improve
  feel. Re-evaluate sluggishness on hardware after this fix.
- **MacLCII_MiSTer has the same m68hc05_core edge-swallow bug** (this core's
  egret came from there). Port the level-IRQ fix once validated here.

## Hardware / .143 state (unchanged)

- `.143` runs the bad validation build (`/media/fat/_Unstable/MacIIvi.rbf`,
  Jul 15 21:29, egret $12 fix + −0.149 ns HDMI-PLL slack). Owner said keep.
- Known-good restore: `releases/MacIIvi_Unstable_20260715.rbf`.
- Disks on .143: `games/MacIIvi/"HD10_7_6_1 60MB.hda"` (s0), `boot755.hda`.
- Timing: the −0.149 ns is on `pll_hdmi|…|divclk` only, fitter variance
  under +36 ALM pressure (SEED 2); clk_sys/egret domains +2.5-4.1 ns.

## Tooling cheatsheet (verified; see first-session doc in git history for prose)

- Build FPGA: `bash scripts/build.sh` (~25 min, background; artifact
  `output_files/MacIIvi.rbf`; verify `MacIIvi.fit.summary` + `sta.summary`).
- Deploy+screenshot: `bash scripts/deploy_screenshot.sh`; reload-only:
  `ssh -i ~/.ssh/mister_only root@192.168.99.143 "echo 'load_core /media/fat/_Unstable/MacIIvi.rbf' > /dev/MiSTer_cmd"`.
- Screenshot: `bash scripts/grab.sh scratch/<name>.png`. Guest keys:
  `python scripts/mister_ws.py --host 192.168.99.143 --port 8182 --delay 0.5 confirm`
  (named nav keys only).
- MAME snapshots land in `<snapdir>/maciivi/fNNNN.png`; 60 frames =
  1 guest-second; ~450% speed headless.
- HFS forensics: `python scratch/hfs_tool.py {info|ls|extract|vers|diff}`.
- check_boot: `verilator/check_boot.sh [--run [frames]]` — NOTE `--run`
  overwrites `cpu_trace.log`; extract evidence from a long run BEFORE
  invoking it.

## Key files

- `rtl/egret/m68hc05_core.sv` ~160-215 — the IRQ sampling fix (level for
  internal sources). Vector dispatch at the `8'h83` SWI/IRQ entry (~1418).
- `rtl/egret/egret_wrapper.sv` — $12 semantics fix (~204-271: free-running
  armed counter, flag=bit6, IRQ=flag&bit4; $12 read mux ~887), cen =
  clk_sys/8 = 4.0625 MHz exactly, ONESEC_PERIOD 4062499 (HW) / 8192 (sim).
- `rtl/via6522.sv` ~825-958 — SR ext-clock logic + the arming watch item.
- `rtl/egret/egret_rom_disasm.md` — one-second ISR $1E10, drain $1E4E,
  reset-init $0F71 (writes $12=$10 at $0F76-78: armed+enabled from reset).
- `../mame/src/mame/apple/maciivx.cpp` (egret↔vasp wiring), `vasp.cpp`
  (60.15 Hz timer → CA1 only; CA2 unconnected in MAME — our CA2=1 Hz
  synthesized is harmless), `egret.cpp` (ports, PRAM/RTC seeding),
  `6522via.cpp` (free-running shift counter), `m68hc05e1.cpp` ($12
  semantics oracle).

## One-line prompt to resume

> MacIIvi frozen-clock fix on `fix/egret-rtc` is sim-validated end-to-end
> and committed (a339fea+f380d80); output_files/MacIIvi.rbf is built and
> timing-clean. On owner go: deploy to .143 (scripts/deploy_screenshot.sh),
> soak the menu-bar clock ≥30 min for 1:1 advance, then merge to main and
> port the m68hc05_core level-IRQ fix to ../MacLCII_MiSTer. Follow-ups
> after: RTC epoch seed (+2082844800 + local time), DST hour, sluggishness
> (architectural — see clock-audit notes).
