# RESUME — Mac IIvi bring-up (session of 2026-07-11)

*Read this + `CLAUDE.md` + `docs/VASP_RETARGET.md` and you have the whole
picture. Everything is committed on `main`; work continues directly on main.
No MiSTer deploys until the user says go (a slot "may free up soon" —
deploy is one command when it does).*

## Where things stand (one paragraph)

The core boots the IIvi ROM end-to-end in Verilator (MAME-frame-aligned,
oracle map committed), fits the DE10-Nano at 90% ALM with every core clock
closing, discovers the mdc824 NuBus card byte-exact vs the MAME oracle, and
had its post-discovery sad-Mac root-caused TWICE (A0 wiring, then lane-3
word-read semantics) with the second fix bench-proven (full 32KB sweep
PASS) and a whole-system verification run in flight at session end. A
MAME-verified System 7.5.5 disk image is staged for the OS-boot campaign.

## Commit trail (newest first, all on main)

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
  was cleaned; **SEED currently = 4, sweep result unknown at session end**)
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

1. **Lane-fix verification** (bg task; results land in `simproberun/`):
   800-frame run, screenshots F690/F780 — the frames where the sad Mac
   appeared pre-fix. EXPECT: gray desktop (no sad Mac), `[NUBUS] CARD`
   lines with real bytes, boot reaching the no-disk wait ($4080786x).
   If the sad Mac persists: rerun with `--trace-frames 600,700` and diff
   the faulting PC against `/tmp/slot_tap_golden`-era MAME data.
2. **Seed-4 Quartus fit** (`output_files/MacIIvi.{fit,sta}.rpt`): compare
   vs seed-2 result (90% ALM; core clocks +2.6/+3.7ns; **HDMI-domain
   −1.305ns** — the only violation; LCII closes it at +0.42 so it's
   placement noise). If seed 4 doesn't close HDMI without hurting core
   clocks: revert `SEED` to 2 and ship bring-up with the HDMI caveat
   (scaler-domain only; VGA path unaffected).
3. **System 7.5.5 disk boot** (`simdiskrun/`, screenshots F1200/2000/2800):
   runs the PRE-A0 binary (card reads as empty there → no PrimaryInit, so
   its SCSI/OS evidence is INDEPENDENT of the card fixes). EXPECT happy
   Mac → Welcome. The image (`simdiskrun/boot755_copy.hd`, copy of
   `../MacLCII_MiSTer/scratch/mame755.hd`) is MAME-VERIFIED to boot
   maciivi. (Plain 7.1 does NOT boot a IIvi — needs Enabler 001; the MAME
   screenshot of that rejection dialog was captured this session.)

## Next actions (in order)

1. Harvest the three runs above.
2. If verification is clean → `bash scripts/build.sh` (git-bash, NOT WSL)
   so the RBF picks up the lane fix → that's the **deploy candidate**.
3. Disk-boot rerun on the CURRENT binary (card now discoverable + 7.5.5):
   `cd simdiskrun && cp <fresh copy> && ../verilator/obj_dir/Vemu --scsi0
   boot755_copy.hd --headless --heartbeat --no-cpu-trace --stop-at-frame
   3000 --screenshot 1200,2000,2800` — full OS boot WITH the card present.
   Watch for System-side card use (Monitors sees the 8*24).
4. **PRAM seeding for card-as-boot-display**: montype 7 is a DEAD END
   (MAME-proven ROM wedge — extended sense can't be faked statically).
   The real path: boot System, drag the menu bar to the 8*24 in Monitors,
   PRAM persists it; capture that PRAM → `releases/MacIIvi.nvr` so
   hardware boots straight onto the card. Also test: with BLANK PRAM,
   which display does the ROM pick as boot screen when both exist?
5. Deploy when the user gives the word: `bash scripts/deploy_screenshot.sh`
   (pushes RBF, reboots, OSD-selects from live menu, screenshots;
   config in gitignored `scripts/local.env` — host 192.168.99.143).
   ROM goes to `/media/fat/games/MacIIvi/boot0.rom` (= `releases/boot0.rom`).
6. Later: task #8 P600 32MHz CPU mode; task #9 SDRAM-backed video (frees
   the 553/553 M10K wall + unlocks 8/24bpp; analysis in VASP_RETARGET).
   Floppy stays glossed-over per user.

## Hard-won gotchas (do not relearn these)

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
  generic monitor-field scan grabs the CARD's config**; adding write taps
  to it broke all taps — unresolved, use tap.lua for writes instead).
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
- **The old `output_files/MacIIvi.rbf` predates the lane fix** — always
  rebuild before deploying.
- The `sdram_out_patched` LC-II warm-boot ROM patch was retired; if a
  warm-reset hang appears on the IIvi ROM, re-derive (VASP_RETARGET
  "LC-II-isms").
- MAME `-video none` for headless; never two captures concurrently.

## Verification assets

- `verilator/mdc_bench/` — card probe/sweep bench (seconds; run from
  `verilator/` so the hex resolves: `./mdc_bench/obj_dir/Vmdc_bench`).
- `docs/mame_maciivi_hb2400_4MB_nodisk.txt` — the no-disk boot milestone
  map (F800-1600 = SCSI-scan dwell happens ONLY with MAME's slow
  selection timeouts; our empty chain fails fast — both end in the
  $4080786x wait).
- SingleStepTests corpora (CPU 721 + PMMU 40, silicon-adjudicated) gate
  any CPU change — but CPU changes belong in ../MacLCII_MiSTer first.
