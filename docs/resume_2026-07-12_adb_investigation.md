# RESUME — Mac IIvi hardware bring-up: the ADB-init hang (2026-07-12)

*Start here + `CLAUDE.md` + `docs/resume_2026-07-11_iivi_bringup.md` (the
8-root-cause sad-Mac campaign that precedes this) and you have the whole
picture. Everything committed on `main`. No further hardware reboots
without the user's go — the core is LIVE on the .189 MiSTer.*

## The one-paragraph state

The core **boots the IIvi ROM through POST on real silicon** — deployed
`releases/MacIIvi_Unstable_20260712.rbf` to MiSTer .189, activated, and
the mdc824 card paints its gray desktop pattern over HDMI with no sad Mac
(all eight sad-Mac fixes from the 2026-07-11 campaign hold on hardware).
But the machine **hangs at that gray screen** and never reaches the OS:
no "Welcome to Macintosh", no flashing "?" boot-disk icon, no mouse
cursor. In Verilator the *same RBF source* reaches "Welcome to Macintosh"
at F1200 — so this is a hardware-only divergence. **Working hypothesis
(user's, and well-supported): the ROM is hung in ADB initialization.**

## Why ADB, and why the sim never caught it (the crux)

Two symptoms pin the hang UPSTREAM of the boot-device scan:

- **No flashing "?" disk.** A Mac that finishes early boot and finds no
  bootable volume shows a flashing "?" floppy. We DON'T see it → the ROM
  never reached the boot-device-scan stage. **This deprioritizes the
  earlier "SC0 disk didn't mount" theory** (from the 07-11 doc): the disk
  mount is moot if the ROM hangs before it would ever look for a disk.
- **No mouse cursor, no happy Mac.** The ROM hasn't reached cursor/boot
  init. Consistent with a hang during ADB device enumeration.

**The smoking gun for why every green sim run missed this:** the headless
sim never drives the ADB mouse. `verilator/sim_main.cpp:1254` drives
`ps2_mouse` ONLY from real SDL mouse capture (click the VGA window to
capture). Every marathon ran `--headless` = no window = `ps2_mouse`
idle/zero the whole run. On hardware the MiSTer HPS drives `ps2_mouse`
(and the mouse-present init) for real. So **the ADB *device* path
(`rtl/adb_device.sv`) was never exercised in any sim that reached
Welcome.** Sim reached Welcome *because* ADB had no device to enumerate;
hardware hangs *because* it does. That resolves the sim-vs-hardware
tension cleanly and is the strongest single piece of evidence.

**Extra prior:** this exact Egret/CUDA PB3/4/5 ADB-handshake path was
already touched THIS campaign — root cause #7 (`dd85c78`, VIA1 Port B
inputs = TREQ only, killed LC-era hblank/sense debug bits on PB7/PB2-0).
A lingering ADB-layer bug adjacent to that fix is entirely plausible.

**Critical architecture fact:** the **Egret gates the 68000 out of
reset** (`rtl/dataController_top.sv:159`, Port C bit 3). The Egret 68HC05
(`rtl/egret/`, firmware 341S0851) is not just ADB — a wedged Egret can
stall the whole machine. ADB rides the Egret via the VIA1 shift register
(CB1/CB2/PB3-5). So "ADB hang" and "Egret hang" are the same suspect family.

## First experiments, in priority order

1. **Reproduce in sim by driving the mouse.** This is the whole ballgame
   — if it repros, the hardware-only bug becomes trace-able the same way
   all 8 root causes were cracked.
   - Non-headless: build the SDL sim, run WITHOUT `--headless`, click the
     window to capture the mouse, move it during boot, watch for the gray
     hang instead of Welcome.
   - OR headless injection: add a synthetic `ps2_mouse` stimulus in
     `sim_main.cpp` (toggle the 25-bit word with motion/button deltas
     from ~F300 onward, mimicking the HPS) and rerun the F1200 marathon.
     If Welcome no longer appears → **reproduced**; then
     `--trace-frames` the hang window and diff the ADB/Egret conversation
     against MAME exactly as before.
2. **MAME oracle for the ADB boot handshake.** `mame maciivi -nbe mdc824`
   with the Egret/ADB tap: capture the ROM↔Egret↔ADB transaction sequence
   during boot (VIA SR bytes, TREQ/TIP/BYTEACK handshake, ADB Talk/Listen
   commands, device addresses). Diff against our Egret's behavior. First
   divergence = the bug. (Egret debug `$display`s already exist in
   `dataController_top.sv` ~line 234; the run logs show
   `EGRET[...]: CB1 FALL / PB_W 0xd9 CB1=1` and `VIA: shift-in ...`.)
3. **On-hardware observability** (if the sim stubbornly reaches Welcome →
   the divergence is physical: Egret HC05 real-clock timing, SDRAM under
   load, or a reset-sequence race). Two ready hooks:
   - `egret_dbg_*` outputs (running/treq/tip/byteack/reset_680x0,
     `dataController_top.sv:132-140`) are already wired "for an on-screen
     indicator" — surface them on hardware to see if the Egret is alive
     and where the handshake stalls.
   - The JTAG probe deck (`USE_DEBUG_PROBES`, gated off for the fitter —
     07-11 doc) is the hardware equivalent of `cpu_trace.log`: re-enable
     to watch the CPU PC live and see exactly where it loops.

## Code entry points

- ADB subsystem: `rtl/adb.sv`, `rtl/adb_device.sv`, `rtl/cuda_adb.sv`,
  `rtl/cuda_maclc.sv` (CUDA-style ADB transceiver — note the IIvi uses
  Egret, confirm which path the ROM actually drives).
- Egret 68HC05: `rtl/egret/` (`m68hc05_core.sv`, `egret_wrapper.sv`,
  `egret_rom.hex` ← 341S0851.bin), plus `rtl/egret.sv`,
  `rtl/egret_behavioral.sv` (`EGRET_BEHAVIORAL` macro swaps a C-model in).
- VIA1 shift-register/Egret handshake: `rtl/dataController_top.sv`
  (PB3=TREQ, PB4=BYTEACK, PB5=TIP ~line 435-464; the `cuda_treq` /
  `pb3_cuda_pulling_low` polarity is the root-cause-#7 neighborhood).
- Mouse/keyboard feed: `ps2_mouse`/`ps2_key` into dataController
  (`dataController_top.sv:65,69`), from `MacIIvi.sv:1682` / `sim.v:1008`.
- MAME truth: `../mame/src/mame/apple/vasp.cpp` (via_in_b, Egret wiring),
  `../mame/src/devices/machine/egret.cpp` if present, else `cuda.cpp`.

## Hardware state (MiSTer .189) — as left

- Running: `MacIIvi` core (`MacIIvi_Unstable_20260712.rbf`, all 8 fixes),
  gray screen, POST-passed, hung pre-OS.
- Staged on .189 AND .143 (`/media/fat/`): the RBF; and in
  `/media/fat/games/MacIIvi/`: `boot0.rom`, clean-PRAM `MacIIvi.nvr`.
  On .189 only: `boot755.hda` (7.5.5 disk, renamed FROM `.hd` so the OSD
  `SC0,IMGVHDHDA` picker shows it) + `config/MacIIvi.s0` (SCSI-0
  mount-memory) + `config/MacIIvi.s2` (PRAM mount).
- The disk-mount question is now secondary (see the "?" reasoning) but
  UNRESOLVED: unknown whether the framework auto-mounts SC0 from `.s0` on
  core-load, or only save-slots persist. If the ADB fix lands and the ROM
  reaches the boot scan, revisit: user mounts SCSI-0 at the OSD (they
  chose this path) → `boot755.hda` → R0 "Reset & Apply" to re-scan.

## Tooling / gotchas (don't relearn)

- **Toolchain split**: Verilator sim = WSL (`wsl -e bash -lc`); Quartus
  build/deploy = git-bash on Windows. Sim CWD must be a direct child of
  the repo root (`$readmemh` paths). ~5s/frame; run once, analyze
  `cpu_trace.log` — don't re-run to diagnose.
- **Deploy** (git-bash): `MSYS_NO_PATHCONV=1 python
  tools/misterdeploy/launch_unstable_core.py --host <ip> --port 8182
  --ssh-key ~/.ssh/mister_only --core MacIIvi.rbf [--push output_files/
  MacIIvi.rbf --seed-file releases/MacIIvi.nvr ...]`. Config in gitignored
  `scripts/local.env` (host defaults to .143 — pass `--host 192.168.99.189`
  explicitly). No-`--push` relaunch just reboots+reselects the core.
- **Screenshot** the live screen: `scripts/grab.sh` (POST
  `:8182/api/screenshots`, download newest). **The API does NOT capture
  the OSD**, and its JSON endpoints only serve the web SPA shell — read
  mount state from the actual OSD, not curl. Latest hw grabs:
  `simdiskrun/hw_189_*.png`, `releases/hw_189_first_light_20260712.png`.
- **MAME oracle** (WSL): `verilator/mame/run_mame_maciivi.sh -nbe mdc824
  [-harddisk copy.hd] -autoboot_script <lua>`. Boot writes
  `~/.mame/nvram/maciivi/egret` (PRAM); diff vs a saved baseline to read
  System-written PRAM bytes. `rm ~/.mame/cfg/maciivi.cfg + nvram/egret`
  before goldens (cfg-poison gotcha). MAME's RUNNING 0.264 binary is the
  oracle of record, NOT the local `../mame` source tree (they disagree on
  pseudoVIA regs — root cause #6).
- **CPU sync rule** still in force: `rtl/tg68k/` byte-identical to
  MacLCII @ `a254a02`. If the hang implicates the CPU (unlikely — it's
  ADB/Egret/chipset), fixes land in MacLCII first.

## Commit trail this campaign (newest first, all on main)

- `1d9ee0d` HARDWARE FIRST LIGHT (.189): POST passes on silicon
- `341094c` releases: MacIIvi_Unstable_20260712.rbf (all 8 fixes)
- `c118c69` resume doc: IT BOOTS (sim) — Welcome at F1200
- `4da816f` root cause #8: mdc824 VBL decodes byte $13F not $13C
- `dd85c78` root cause #7: VIA1 Port B inputs = TREQ only  ← ADB neighborhood
- `f4e3d5f` root cause #6: VIA DDR-merge + pseudoVIA regs $00/$01
- (see `docs/resume_2026-07-11_iivi_bringup.md` for #1-#5 and full context)

## The mental model that solved the last 8 — apply it here

The IIvi ROM fingerprints/handshakes every subsystem it can reach, and
MAME's *running binary* — not its source, not the datasheet, not an
inherited comment — is the oracle of record. Eight sad-Mac causes were
all "a register/handshake answered with the wrong value/timing." The ADB
hang is very likely the ninth of the same family: the Egret/ADB handshake
answering wrong when a real mouse device is present. **Reproduce it in sim
by giving the sim a mouse, then diff the handshake against MAME.**
