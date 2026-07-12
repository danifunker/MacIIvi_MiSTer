# RESUME — Mac IIvi bring-up (session of 2026-07-11)

*Read this + `CLAUDE.md` + `docs/VASP_RETARGET.md` and you have the whole
picture. Everything is committed on `main`; work continues directly on main.
No MiSTer deploys until the user says go (a slot "may free up soon" —
deploy is one command when it does).*

## Where things stand (one paragraph)

The core boots the IIvi ROM end-to-end in Verilator, discovers the mdc824
byte-exact, and the post-discovery sad Mac is root-caused for the THIRD and
final time: the IIvi ROM (unlike the Mac II ROM, which boots this card at
plain 384KB — lbmactwo) hard-fails the card when PrimaryInit's VRAM sizing
probe (write $AAAAAAAA @ byte $F4B00 ~979KB, read back) misses — the Slot
Manager drops the video sResources, the boot-display hunt dies smRecNotFnd,
sad Mac $0F/$33. Fix = task #9 as a HYBRID per the project owner: the card
presents 1MB — the 384KB hot framebuffer stays in BRAM (scanout untouched),
the cold tail rides the reserved SDRAM window at word $100000 through the
existing cpu-slot port (sdram.v unchanged; commit e7bce31, bench PINIT
PASS). Along the way the MAME oracle was found silently wedged since 16:43
by POISONED PERSISTENT CFG (montype set_value saved to
~/.mame/cfg/maciivi.cfg — the real story behind "write taps broke all
taps"); cleaned, MAME+card boots clean and the complete 19,551-read
slot-walk golden is committed. The hybrid 7.5.5 disk-boot sim and the
hybrid Quartus build were IN FLIGHT at session end.

## Commit trail (newest first, all on main)

- `e7bce31` task #9 HYBRID: card presents 1MB = 384KB hot BRAM + SDRAM
  cold tail (word $100000 window via the cpu-slot port, no sdram.v
  changes); NuBus no-card timeout 4→32 clk; bench boundary + ext-RMW PASS
- `9e4aa88` sad-Mac root cause #3 (PrimaryInit VRAM sizing) + MAME
  cfg-poison discovery + full slot-walk golden (19,551 reads,
  `docs/mame_maciivi_slot_walk_golden.txt`) + `walk_diff.py` + PINIT bench
- `71fc433` mdc824 lane-3 decl ROM served on WORD reads (sad-Mac fix #2;
  bench SWEEP PASS all 32768 bytes) — **sim verification was IN FLIGHT**
- `7bf0497` card gets REAL A0 (sad-Mac fix #1 — card was invisible;
  `verilator/mdc_bench/` proves the probe walk = MAME oracle $FF78...)
- `40bc9b5` ASC FIFO + ariel CLUT → true M10K (~7.7K ALMs; smoke frame-exact)
- `f902f8a` mdc824-only display = DEFAULT FPGA shape (CLK_VIDEO=clk_sys,
  card 384KB/8bpp, onboard vram_bram removed; `ONBOARD_DISPLAY` macro =
  guaranteed-picture fallback w/ 128KB card); JTAG probe deck gated off
  (`USE_DEBUG_PROBES`)
- `4f1d862`+follow-up: SEED experiments (qsf had SEED 2 pinned by LCII all
  along at ~line 51 w/ tuning rationale ~line 360; a stray no-newline append
  was cleaned; sweep RESULT: seed 4 fits 90% ALM w/ core clocks +3.1/+4.0
  but HDMI-domain WORSENS to -1.49 — seeds are not the lever for that
  domain. REVERTED to SEED 2; ship bring-up with the -1.3ns HDMI-scaler
  caveat, VGA/direct path unaffected)
- `95a08e7` MacLCII build/deploy/probe toolkit imported+retargeted
  (`scripts/`, `tools/misterdeploy/`; local.env gitignored, example committed)
- `f956ad1` MAME no-disk boot heartbeat map → `docs/mame_maciivi_hb2400_4MB_nodisk.txt`
- `88931f9` [NUBUS] logger fixed (latch-during-cycle; selects are dead at
  AS-rise) + `slot_probe_tap.lua` MAME oracle tap
- `6ed5b1c` mdc824 bus integration (slot $E, open-bus $C/$D, IRQ→pseudoVIA)
- `bda0696` VASP video stride = 2048-byte rows (uniform desktop verified)
- `11a019a` sim `+mdc824` display-source flag (montype strap later REMOVED)
- `540c368` Machine select: Mac IIvi ($A55A2016) / Performa 600 ($A55A2017)
  — ROM's table at $4084AB4A masks box-ID with #$7 (disasm-verified)
- `68ac1e8` VASP retarget (32-bit map, contiguous RAM 4/8/20/36MB, RBV
  pseudoVIA, box-ID, 25-bit SDRAM layout)
- `059b8d7` MacLCII imported VERBATIM @ a254a02 (CPU sync rule: rtl/tg68k
  byte-identical to that pin; CPU fixes land in MacLCII first)

## In-flight at session end — HARVEST THESE FIRST

1. **Hybrid 7.5.5 disk-boot sim** (`simdiskrun/`, running `./Vemu_hybrid`
   — a DEDICATED binary copy, see gotchas — with a fresh
   `boot755_copy.hd`, `--stop-at-frame 4000`, screenshots
   450/700/1200/2000/2800/3600/4000):
   a. F450 = card-as-boot-display gray pattern expected (the 1MB-BRAM
      control run had it: `run_1mb_bram_20260711/screenshot_frame_0450.png`).
   b. F700 screenshot = the sad-Mac verdict on the SHIPPING config
      (expect none: the control run passed F628 healthy; sad Mac used to
      show by F690).
   c. F2000/F2800 = "Mac OS starting up" + extension parade (yesterday's
      pre-A0 run reached mid-parade at F3000:
      `run_prea0_20260710/` screenshots); F4000 = hopefully Finder.
   d. `walk_diff.py` the run's [NUBUS] stream vs the golden:
      `python3 verilator/mame/walk_diff.py docs/mame_maciivi_slot_walk_golden.txt simdiskrun/run_stdout.log`
      — first divergence (if any) = remaining card-model bug. Note the
      golden is MAME's no-disk boot; the walk portion (F400-F418) is
      disk-independent so the diff is valid until the OS starts touching
      the card (driver CLUT/VRAM writes — reads-only diff still holds).
2. **Hybrid Quartus build** (`simdiskrun/quartus_build_hybrid.log`,
   launched from git-bash `scripts/build.sh`): verify fit (expect ≈90%
   ALM as before — BRAM unchanged, ext port is a few hundred ALMs) and
   timing (core clocks must close; the known HDMI-scaler -1.3ns caveat
   stands). Output → `output_files/MacIIvi.rbf`; stage as
   `releases/MacIIvi_Unstable_<date>.rbf` when BOTH gates pass.
3. The pre-hybrid `releases/MacIIvi_Unstable_20260711.rbf` is
   **superseded and KNOWN-BROKEN for card display** (384KB-only card →
   sad Mac on the IIvi ROM). Do not deploy it.

## Next actions (in order)

1. Harvest the two in-flights above (sim + Quartus).
2. Both clean → stage `releases/MacIIvi_Unstable_<date>.rbf` = the deploy
   candidate. Deploy ONLY on the user's word:
   `bash scripts/deploy_screenshot.sh` (git-bash; pushes RBF, reboots,
   OSD-selects, screenshots; config in gitignored `scripts/local.env` —
   host 192.168.99.143). ROM goes to
   `/media/fat/games/MacIIvi/boot0.rom` (= `releases/boot0.rom`).
3. Finder + Monitors campaign (needs the booted System from #1): confirm
   the 8*24 shows in Monitors, set depths, exercise the desktop on the
   card. If the run stopped short of Finder, continue past F4000.
4. **PRAM seeding for card-as-boot-display**: montype 7 is a DEAD END
   (MAME-proven ROM wedge — extended sense can't be faked statically).
   The real path: boot System, drag the menu bar to the 8*24 in Monitors,
   PRAM persists it; capture that PRAM → `releases/MacIIvi.nvr` so
   hardware boots straight onto the card. Also test: with BLANK PRAM,
   which display does the ROM pick as boot screen when both exist?
5. Hybrid refinement (optional): present the card 512KB-shaped to kill
   the 24bpp-offered-but-garbage caveat — FIRST test in MAME whether the
   IIvi ROM accepts a 512KB mdc824 (cfg: `:nbe:mdc824:CONFIG` mask 16
   value 0) and rw-tap capture how PrimaryInit sizes it; only then mirror
   in RTL. Full SDRAM-scanout burst port (24bpp + frees the 384KB BRAM)
   stays future work per VASP_RETARGET §SDRAM-backed video.
6. Later: task #8 P600 32MHz CPU mode. Floppy stays glossed-over per user.

## Hard-won gotchas (do not relearn these)

- **MAME PERSISTENT-CFG POISON** (cost half a day): any ioport set_value
  from lua (montype forcing, the CONFIG-field "Run B trap") is SAVED to
  `~/.mame/cfg/maciivi.cfg` on exit and silently applied to EVERY later
  run — the machine wedges in chime code (F300 pc=$40845Fxx instead of
  healthy $40847xxx; then the $40849Axx/$4084A1xx loop forever) and never
  touches slot space. ZERO tap hits that look exactly like "the taps
  broke" — the "write taps broke all taps" mystery WAS this, and the
  18:14 "golden" of 2026-07-11 was a wedge artifact. After any
  montype-forcing run: `rm ~/.mame/cfg/maciivi.cfg
  ~/.mame/nvram/maciivi/egret` before trusting a capture.
- **Rebuilding Vemu KILLS live sims** (DrvFS): `make` in verilator/
  replaces `obj_dir/Vemu` in place and any running sim executing that
  file dies mid-run (lost the 1MB-BRAM control run at F628). Long runs
  copy the binary into their run dir and exec the copy (`./Vemu_hybrid`)
  — same discipline as disk-image copies.
- **Foreground `wsl` sim calls need an explicit timeout** — the harness
  default kills at 120s, and 25 sim frames take longer than that.
- **IIvi ROM ≠ Mac II ROM on Slot Manager strictness**: the Mac II ROM
  tolerates a card whose PrimaryInit VRAM probe fails (lbmactwo boots the
  mdc824 at plain 384KB); the IIvi ROM drops the card's sResources and
  sad-Macs $0F/$33 smRecNotFnd hunting the boot display. Don't
  cross-assume card behavior between the two cores.
- **Toolchain split**: Verilator sim = WSL (`wsl -e bash -lc`); Quartus
  build/deploy scripts = git-bash on Windows (they use tasklist + /c/
  paths). build.sh in WSL fails "quartus_sh: command not found".
- **Sim CWD**: must be a direct child of repo root (`verilator/` or
  `sim*run/` dirs) for `$readmemh` paths (egret + mdc824 hex). Parallel
  sims: one dir each. ~5s/frame; MAME oracle for anything behavioral.
- **MAME oracle kit** (all WSL): `verilator/mame/run_mame_maciivi.sh`
  (romset verified good); `pc_sp_hb.lua` (HB_FRAMES/HB_OUT) = PC-per-frame
  map; `tap.lua` (TAP_LO/HI/MODE) = memory taps; `slot_probe_tap.lua` =
  slot-space reads + montype forcing (**must target :vasp:MONTYPE — the
  generic monitor-field scan grabs the CARD's config**; the "write taps
  broke all taps" scare is RESOLVED — it was the persistent-cfg poison
  above, not write taps; tap.lua rw mode works fine and captured the
  whole PrimaryInit conversation).
- **Bus-cycle logging**: decoder selects are combinational on !_cpuAS —
  dead at AS-rise. Latch during the cycle, report at the edge.
- **NuBus lane-3 rule**: decl ROM byte visible whenever LDS addresses
  byte 3 (`local_addr[1] && LDS`), NOT `A1:A0==11` (word/long copies!).
  The card needs REAL A0 (`{cpuAddr[31:1], tg68_a[0]}`) — this 16-bit bus
  forces cpuAddr[0]=0.
- **Quartus fit levers already used**: probe deck OFF, ASC/ariel in M10K,
  onboard vram_bram removed (default shape). qsf carries LCII's fitter
  tuning (aggressive routability, duplication OFF, SEED pinned — their
  seed-3 note says it broke clk_sys THERE). M10K = 553/553: no BRAM
  headroom left; next BRAM need = do task #9 first.
- `output_files/MacIIvi.rbf` (20:04, = releases/MacIIvi_Unstable_20260711
  .rbf) IS the current deploy candidate: seed 2 + lane fix + all of
  today's RTL. Fit 90% ALM, core clocks +1.4/+3.5ns, HDMI-scaler domain
  -1.5ns (known caveat, scaler-only). Rebuild only after further RTL
  changes.
- The `sdram_out_patched` LC-II warm-boot ROM patch was retired; if a
  warm-reset hang appears on the IIvi ROM, re-derive (VASP_RETARGET
  "LC-II-isms").
- MAME `-video none` for headless; never two captures concurrently.

## Verification assets

- `verilator/mdc_bench/` — card probe/sweep bench (seconds; run from
  `verilator/` so the hex resolves: `./mdc_bench/obj_dir/Vmdc_bench`).
  Now also the PINIT smoke: ctrl sense, reg $300, the $F4B00 1MB sizing
  probe into the cold tail, BRAM/tail boundary straddle, ext RMW, beam
  toggle — the hybrid card shape (384KB BRAM + latency-modeled tail).
- `docs/mame_maciivi_slot_walk_golden.txt` — the COMPLETE clean-cfg MAME
  slot walk (19,551 reads F400-F418 incl. PrimaryInit's register/VRAM
  longs); diff a sim run against it with
  `python3 verilator/mame/walk_diff.py <golden> <sim run_stdout.log>`.
- `docs/mame_maciivi_pinit_rw_trimmed.txt` — PrimaryInit's register/VRAM
  write+read conversation (tap.lua rw capture, VRAM-clear flood trimmed).
- `docs/mame_maciivi_hb2400_4MB_nodisk.txt` — the no-disk boot milestone
  map (F800-1600 = SCSI-scan dwell happens ONLY with MAME's slow
  selection timeouts; our empty chain fails fast — both end in the
  $4080786x wait).
- SingleStepTests corpora (CPU 721 + PMMU 40, silicon-adjudicated) gate
  any CPU change — but CPU changes belong in ../MacLCII_MiSTer first.
