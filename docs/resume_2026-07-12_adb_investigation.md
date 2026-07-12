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

---

# FINDINGS — session of 2026-07-12 afternoon (hang REPRODUCED in sim)

## Verdict: reproduced, and it is NOT an ADB-protocol bug

**The gray hang reproduces in Verilator with one variable: synthetic mouse
motion.** `--mouse-from 300` (one ps2 packet/frame, alternating ±2 deltas,
new flags in `sim_main.cpp`, commits `f52dd67`+`e62cafe`) against the exact
control-run conditions. Control (simdiskrun marathon) reaches Welcome at
F1200; the mouse run parks at **F742 in a 4-PC blit loop at $4082EA18-1E
and never leaves** (still there at F1000+; screenshot: dithered desktop,
arrow cursor at top-left, NO Welcome, NO "?"). That is the .189 symptom.

## Why every previous sim was blind (two layers)

1. `sim_main.cpp`'s **headless fast path never touched ps2_mouse at all**
   (the packet build lived only in the GUI path). Every headless run ever
   made had a frozen all-zero mouse input — strobe never toggled.
   First injection attempt (GUI-path edit) was a dud for exactly this
   reason: it reproduced the control run timestamp-for-timestamp (bonus:
   proves the sim is bit-exact deterministic; archived
   `simmouserun/dud_noinject/`).
2. With zero deltas, `adb_device.sv` never raised `mouse_evt`, so the
   Talk-R0-with-data and S_SRQ paths had never executed in any sim.

## What the ADB layer did when finally exercised — IT IS HEALTHY

Timeline (all in `simmouserun/`, time scale ≈845,472 sim-units/frame):
- F624: Egret bus enumeration begins (identical instant to control —
  lockstep held from F0 to F623 with data pending since F300).
- F624-741: the ROM's ADBReInit address dance runs its exact 50 cycles
  (same count as control) but ~2× slower — every non-dance command draws
  an `SRQ asserted (mouse_evt=1)` from the device (new probe lines).
- F741: dance done. Egret autopolls mouse Talk R0 ~8×/frame; device
  answers `resp_len=2` once per injected event (correct ADB: silent when
  no data). Egret→host deliveries: exactly 1.02/frame (no amplification;
  975 TREQ-ACTIVE handshakes, all accepted by the ROM). The pseudoVIA
  ack traffic (`50f26002 data=8282`) is ~110/frame vs control's ~125 —
  i.e. NORMAL for this machine, not an interrupt storm.
- **F742: the ROM enters the cursor engine and never returns to the
  boot mainline.** Egret/device keep running fine underneath forever.

## The stuck code, disassembled (ROM offset $2EA18 = CPU $4082EA18)

`$2E9E2`: TST.B $0D62 / BMI skip; MOVEA.L ([$0D62]),A0 (low-mem vector →
cursor context struct); MOVEA.L $12(A0),A1; JSR ([$644]);
**MOVEM.L $3C(A0)+,D2-D4/A2** ← blit params (rows, longs, stride, dest)
come from the struct; JSR ([$574]); then the blit:
```
$2EA18: 24D9        MOVE.L (A1)+,(A2)+     ; row copy
$2EA1A: 51CB FFFC   DBF D3,$2EA18
$2EA1E: 2608        MOVE.L A0,D3           ; reload inner count
$2EA20: D4C4        ADDA.L D4,A2           ; add row stride
$2EA22: 51CA FFF4   DBF D2,$2EA18
$2EA26: JSR ([$574]); CLR.B $08CC (CrsrVis=0!); MOVEM/RTS
```
= the **cursor hide/restore rect blit**. Live values: A2 walks
$60B0B818↔$60B0C818 (a $1000 window, forever), stride D4=$1000. The
$60xxxxxx range decodes to **onboard VASP VRAM** (`addrDecoder.v`
$60000000-$6FFFFFFF → selectVRAM; SDRAM-backed in BOTH tops, so the
cycles complete — no DTACK hang — the CPU just never escapes the
cursor engine). Stride $1000 matches neither the card ($400/$800) nor
onboard 8bpp ($800): the cursor screen context looks WRONG/stale, and
the cursor "home screen" pointer aims at the onboard framebuffer, not
the mdc824 the desktop lives on.

## Puzzle pieces still open (the in-flight trace answers these)

- WHO calls the hide-blit per frame and HOW OFTEN (per-VBL cursor task?
  per ADB packet? re-entry storm?), and per-call duration — i.e. is it
  huge-counts-per-call or saturating call rate.
- The struct at ([$D62]): dump D2/D3/D4/A1/A2 at entry; identify
  ([$574])/([$644]) vector targets.
- Why sim F1000 SHOWS an arrow on the card while the user reported no
  cursor on .189 (draw path landed once in sim — different engage timing
  on hardware, or hardware drew to un-scanned memory?).
- **In-flight**: `simtracerun/` re-run with `--trace-frames 738,748`
  (full instruction trace across the park onset), --stop-at-frame 750.
  Analyze cpu_trace.log: entry registers, return addresses, calls/frame.

## Corrected earlier beliefs (do not relearn)

- "No cursor" does NOT discriminate ADB-hang vs later hangs: the pointer
  only appears at the Welcome transition on these ROMs.
- The SCSI pseudo-DMA timeout glue is IDENTICAL in MacIIvi.sv and sim.v
  (sdma_berr → cpu_berr both) — audited, not a divergence.
- The no-disk scan theory is now SECONDARY (cursor hang explains gray
  w/ or w/o disk); `simnodiskrun/` is staged if ever needed.
- EGRET debug lines log in the HC05 tick domain (≈$time/8) — don't read
  them as $time.

## Next actions

1. Harvest `simtracerun/` cpu_trace.log → name the caller/rate → then the
   RTL-vs-MAME question becomes concrete (likely candidates: onboard
   video's VBL/slot-$E interplay feeding the cursor task, or the screen
   record the ROM builds for the onboard display when the card is main).
2. MAME oracle with mouse motion during boot (lua ioport deltas) if the
   trace points at ROM-visible state we can diff (which screen the
   healthy cursor context targets, pseudoVIA reg2 bits).
3. Fix, re-run mouse marathon to Welcome, THEN rebuild RBF — hardware
   redeploy only on the user's go.

---

# DEEP DIVE 2 — the endless fill decoded to the ROM level (same session, later)

## Corrections to "Findings" above (trace-informed)

- The marathon's F800+ "park in the cursor blit" was **HB aliasing**: the
  per-frame PC sample lands in the VBL-synced cursor task; the other ~99%
  of each frame is ONE gigantic QuickDraw fill (the F1B2 loop below). The
  cursor hide/restore blit itself is a bit-player (224 tiny runs/11 frames).
- Interrupt load is modest (7-10 rte/frame) — no IRQ storm. ~16-21
  SwapMMUMode round-trips/frame (pmove srp/crp inside the Egret/ADB
  delivery path) — expensive but not the hang.
- The fill is well-formed mechanically: strictly monotonic longword writes,
  ~616 bytes/row at the correct VASP $800 stride, ~14 rows/frame — but it
  runs to row ~32767 ($7FFF) instead of 480. One fill invocation spans
  hundreds of frames, marching through the mirrored 1MB VRAM window.

## The instruction-level chain (all from simtracerun/cpu_trace.log F738-748)

1. F741: ADB dance ends; first mouse packet delivered; cursor first-draw
   (315 blit insns).
2. F742: boot code at **$40800530** runs the boot-UI screen paint routine
   (ROM offset $530): InitGraf → OpenCPort → SetCursor(arrow) → copy
   screenBits.bounds→$9FA (cursor pin!) → InsetRect(-3,-3) → PenSize(3,3)
   → **_FrameRoundRect ($A8B0, corners 22,22)** → PenNormal →
   FillRoundRect(16,16) — i.e. the rounded-corner desktop/border paint.
3. _FrameRoundRect dispatches (trap table $1E00) → verb glue $40834630 →
   thePort->grafProcs (default: low-mem $10BC) → **StdRRect painter at
   $40834680** (LINK A6,#-$1C4).
4. Painter: `jsr ([$1A08])` extracts the port PixMap into the frame
   (baseAddr at -$F4, rowBytes -$F0 — masked #$7FFF at $40834A56 —
   dest ptr -$12C computed at $40834A62-A7A: base + top*rowBytes + left/8).
5. Painter intersects: rect arg ∩ visRgn->bbox ∩ clipRgn->bbox ∩ one more
   (4-rect intersect via `jsr ([$1A84])` at $40834740; empty → skip-all
   branch at $34746).
6. **$4083496A: `move.w #$7FFF,(-$164,A6)`** presets the row bound to the
   region sentinel; only a valid rect/region walk narrows it. Ours never
   narrows: row loop (`cmp.w (-$164,A6),D7 / blt` at $40834BD4) runs to
   32767. The per-invocation region walker stub that returns the $7FFF
   sentinel is at $4083B0D4.
7. Net: **the port's visRgn (and/or the rect from screenBits.bounds) must
   be wide-open garbage** — clipRgn after OpenCPort is wide-open BY DESIGN,
   visRgn should be screenBits.bounds (480x640). screenBits is rebuilt by
   InitGraf (F742) from the low-mem video globals / MainDevice GDevice
   PixMap — structures the cursor engine (armed F741 by the first-ever
   early mouse delivery) also manipulates (CrsrPin $834 neighborhood,
   GDevice cursor fields). Control run (no mouse): same routine, bounded,
   exits in ~30 frames. MAME + wiggle: cursor stabilizes ~50 frames BEFORE
   this paint → healthy. Ours: cursor first-draw and InitGraf land in
   ADJACENT FRAMES (F741/F742) — the race window.

## In flight: the value capture

`simwatchrun/` re-run with the new `+ramwatch_*` plusarg RAM-write watch
(sim.v; logs addr/data/PC for writes in a range+frame window — the
instruction trace has no data values). Window F739-745, range $0-$21FFFF.
Read out: (a) the writes into the A6 frame slots (-$164/-$74/-$F4/-$12C
relative to the painter's A6 ≈ $20FExx) — the actual bounds values;
(b) any cursor-path PC writing into the GDevice/PixMap/low-mem video
globals before InitGraf reads them (the corruption, if that theory holds).

## MAME oracle status

- maciivi + mdc824 + continuous wiggle (ioport lua injection, delivery
  verified via RawMouse $82C movement): boots healthy, CrsrVis=1 from
  ~F650-700, scan-wait $4080786x reached. Kit: verilator/mame/
  cursor_ctx.lua (+ paint_bounds.lua / cursor_blit_bp.dbg / paint_dump.dbg
  — NOTE: debugger breakpoints DO NOT FIRE under `-debugger none` in this
  0.264 build; printf/consolelog and dump actions are all inert. Value
  capture must go through lua memory reads or our sim's ramwatch.)

---

# REFRAME (governing insight, late 2026-07-12) — TWO overlapping stories, not one

**MAME golden: ScrnBase ($824) = $60B00000 — the IIvi's boot screen with an
mdc824 present and clean PRAM is STILL THE ONBOARD VASP DISPLAY.** And
`sim.v` defaults its scanout to the onboard video (`+mdc824` plusarg
switches to the card — sim.v:167-188). Therefore:

## Story A — why the USER sees gray forever (very likely THE user-visible bug)

Every sim screenshot ever taken (including "Welcome at F1200") showed the
ONBOARD framebuffer. The FPGA default shape REMOVED onboard scanout
(mdc824-only display). So on hardware the ROM boots normally, painting
desktop/"?"-icon/Welcome into onboard VRAM (SDRAM-backed, invisible), while
the visible mdc824 shows only the static gray PrimaryInit pattern. Gray
forever, no Welcome, no "?", no cursor — all four symptoms, NO hang
required. "Sim=Welcome vs hw=gray" was a SCANOUT difference, not machine
divergence. **Fix direction (already the 07-11 doc's next-action #4): make
the ROM adopt the mdc824 as startup screen via PRAM main-display bytes**
(capture from a MAME 7.5.5 Monitors drag → seed releases/MacIIvi.nvr +
rtl/egret/egret.pram), or ship an onboard-scanout shape.
Verification queued: no-mouse sim, `+mdc824`, screenshot F1200 → expect
card still gray while onboard (default scanout) got Welcome.

## Story B — the mouse-motion wedge (REAL secondary bug, found en route)

With mouse motion from F300, the boot genuinely wedges at F742 in an
unbounded StdRRect fill (deep-dive above). Real users wiggle mice during
boot; MAME survives the same stimulus. Still worth fixing after Story A —
but it is NOT required to explain the .189 symptom. Value capture for it:
simwatchrun (+ramwatch, F739-745) — harvest regardless.

## Immediate next steps (reordered)

1. Harvest simwatchrun (bug B values: painter A6 slots + any pre-InitGraf
   corruption of GDevice/screenBits).
2. Keystone run: `+mdc824` no-mouse marathon to F1210 with screenshots —
   prove the card shows only PrimaryInit gray at Welcome-time in OUR core.
3. MAME Monitors-drag automation (lua mouse injection, snap-verified) on
   /tmp/mame755_scratch.hd → PRAM diff → the main-display byte encoding →
   seed egret.pram → sim marathon → expect WELCOME ON THE CARD (+mdc824).
4. Only then: RBF + hardware, on the user's go.
