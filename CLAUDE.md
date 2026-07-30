# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Project Overview

**Macintosh IIvi core for MiSTer** — MC68030 @ 15.6672 MHz with on-chip PMMU,
VASP-equivalent chipset, NuBus (mdc824 video card as primary display), no FPU.

Lineage: the chipset/framework is the **MacLCII core imported at commit
`a254a02`** (see `docs/VASP_RETARGET.md` for the exact delta plan), because
per MAME "VASP is basically V8 with slightly different video and the RAM
limit lifted to 68MB". NuBus RTL comes from the Mac II core
(`../lbmactwo_MiSTer`). The CPU-verification corpora live in
`SingleStepTests/` (68030+PMMU, real-silicon adjudicated).

Key references:
- `MacIIvi_HardwareConfig.md` — the machine, MAME-verified (memory map, VIA,
  pseudoVIA, NuBus, interrupts)
- `docs/VASP_RETARGET.md` — V8→VASP delta plan + SDRAM layout + decisions
- `68030_CPU_IMPLEMENTATION_PLAN.md`, `68030_PMMU_TESTBENCH.md` — CPU/PMMU
- Local MAME source tree: `../mame/src/mame/apple/{maciivx,vasp,v8,maclc}.cpp`
  (tree = 0.288-132) — always check MAME before guessing hardware behavior.
- **MAME version discipline (owner decision 2026-07-17):** review against
  **0.288 source** (the local tree) as primary reference, BUT the installed
  runtime oracle and every HW-validated behavior of this core to date is
  **0.264** — and 0.288's sound/IRQ rework (afed5d318e4) is twice-suspect
  (error-41 hunt; the asc_v8 semantics port 6c95e20→reverted bc31773 broke
  app sound/froze games/slowed the clock on HW). When 0.288 and 0.264
  disagree, treat neither as automatically right: port coherent subsystem
  PAIRS (e.g., ASC + pseudoVIA latch semantics together, never one half),
  and gate on hardware sound/clock validation. 0.288 pairs maciivi's
  level-style ASC with the EDGE-latch base pseudovia — a fragile contract;
  the LC pairs it with a level-through v8_pseudovia (the ASCTester-validated
  combo). Our asc.sv+pseudovia.sv pair is 0.264-faithful and HW-proven.

## Hard rules

- **CPU sync rule**: `rtl/tg68k/` must stay byte-identical to
  `../MacLCII_MiSTer` at the pinned commit (currently `a254a02`). CPU fixes
  land in MacLCII first, then get re-copied. Never fork the kernel here.
- **Line endings**: repo policy is LF (`core.autocrlf=false`, enforced for
  *.sh via .gitattributes). The sim toolchain runs under **WSL** — CRLF in a
  shell script or Makefile breaks it.
- **Hardware deploys are ask-first**: never deploy/reboot the MiSTer without
  the owner's go for that specific build. Once authorized, HW validation on
  the device is the standard, decisive loop (deploy =
  `bash scripts/deploy_screenshot.sh` from Git-Bash, never WSL).
- **Framework files law** (adopted 2026-07-18 from MacLC `0d38a1a`): `sys/`
  is off-limits except wholesale template updates — constrain framework
  behavior from `rtl/` + qsf/sdc only. Q17 Lite has NO per-instance
  RAM_BLOCK_TYPE qsf assignment (illegal name); per-instance
  AUTO_SHIFT_REGISTER_RECOGNITION is legal.
- Work happens on feature branches, merged to `main` once validated (policy
  changed 2026-07-15 by the project owner; was direct-to-main).

## SCSI/CD family sync (MacLC lineage — laws adopted 2026-07-30)

The SCSI subsystem (`rtl/scsi.v`, `rtl/cd_audio.sv`, `rtl/cd_vol_lut.vh`,
`rtl/asc.sv`) syncs WHOLESALE from `../MacLC_MiSTer` master (they are kept
byte-identical modulo one comment); `rtl/ncr5380.sv` + `rtl/dataController_
top.sv` sync 3-way preserving the documented MacIIvi fixups (CD_RING_LOG=2,
disk RING_LOG i==0?5:4, local comments). The HPS contract is the Main_MiSTer
fork `add-bluescsi-toolbox-for-MacLC` — hps_io slots: disks 0/1, PRAM 2,
Toolbox 3, CD 4, CD-changer 5; CD-DA is served as ONE 2352-byte transaction
per frame (sd_buff_addr[12:8] carries the burst word address), so core and
Main MUST move together.

- **Always-on marginality anchor** (MacIIvi.sv, from MacLC `4dfb463`):
  probe-less fits corrupt the SCSI read path on HW while STA is met — the
  preserve+noprune anchor registers keep those cones loaded. Do NOT remove,
  ifdef, or fold them. Gate every new fit in the Finder on icon integrity.
- **CD-detach gating law** (MacLC 2026-07-30): a CUE/CHD attached AT BOOT can
  hang intermittently on ANY build, including known-good ones — never treat a
  boot-attach hang as a build verdict. For gating: detach the CD from the boot
  config (`mv /media/fat/config/MacIIvi.s4` aside), boot, judge, then remount.
  One boot is never a verdict; two boots of the same RBF can differ.
- SCSI writes + CD reads are validated upstream (word-pairing lane-slip fix +
  look-ahead boundary REQ stall, MacLC 2026-07-29, byte-identical copies on
  HW). `verilator/scsi_bench` full sweep + `--mode gapcmds/cdvol/wbyte/wword`
  is the fast regression gate for all of it.
- The ASC takes the FULL 16-bit write bus (both byte lanes per strobe) — the
  old [7:0]-only hookup dropped every other sample of word-filled audio
  (game audio at exactly 2x speed). Applies to MacIIvi.sv AND sim.v.

## Build Commands

### Verilator simulation (primary workflow — runs in WSL)

```bash
# from Windows:
wsl -e bash -lc "cd /mnt/c/Temp/mistercore/MacIIvi_MiSTer/verilator && make -j\$(nproc)"
# run headless (see CWD note below):
wsl -e bash -lc "cd /mnt/c/Temp/mistercore/MacIIvi_MiSTer/verilator && ./obj_dir/Vemu --headless --heartbeat --stop-at-frame 100"
```

Useful flags (see MacLCII CLAUDE.md heritage; `--help` is stale):
`--screenshot <frames>`, `--stop-at-frame <n>`, `--scsi0 <img>` (sim WRITES
the image — boot a copy), `--headless`, `--heartbeat` (one `[HB]` line per
frame), `--no-cpu-trace`, `--trace-frames A,B`.

- CWD must be a direct child of the repo root (`verilator/` works): the RTL
  `$readmemh` paths are CWD-relative (`../rtl/egret/egret_rom.hex`,
  `../rtl/egret/egret.pram`). A missing Egret ROM does NOT abort — the 68k
  just bus-errors at the reset vector (no `[HB]` lines ever).
- Parallel sims: one child dir per run + its own copy of the disk image.
- Any internal signal `sim_main.cpp` reads via `rootp->` must be listed in
  `verilator/tg68k_debug.vlt` (`public_flat_rd`) or Verilator optimizes it
  away and the C++ build breaks.
- Do NOT re-run the sim repeatedly to diagnose — run once, analyze
  `verilator/cpu_trace.log` + stderr.
- `./check_boot.sh [--run [frames]]` — boot analysis; exit 0=PASS.

### FPGA build (Quartus 17.0.2 Lite) — NOT part of the current phase

Open `MacIIvi.qpf`; output lands in `output_files/`. Do not deploy.

### CPU corpus benches

`SingleStepTests/` has its own benches/README (CPU corpus 721 rows, PMMU 40
rows, MAME-captured + IIcx-silicon-adjudicated). The tg68k Verilator bench:
`cd SingleStepTests/tg68k && make && ./obj_dir/Vtg68k_tests` (WSL).

## Architecture (top-down)

- `MacIIvi.sv` — emu top (MiSTer framework): clocks/PLLs, OSD/CONF_STR,
  DTACK/VPA/BERR glue, SCSI pseudo-DMA timeout, download paths, SDRAM wiring.
  `verilator/sim.v` is its sim twin — **keep the two tops in sync** (they
  share most glue verbatim; divergences are flagged in comments).
- `rtl/addrController_top.v` + `rtl/addrDecoder.v` — bus cycles/slots, address
  decode (moving from 24-bit V8 map to 32-bit VASP map), SDRAM word addresses,
  ROM overlay.
- `rtl/dataController_top.sv` — IPL encoder, peripheral data mux, VIA1, Egret
  (68HC05 `rtl/egret/`, firmware 341s0851 for IIvi), SWIM, SCC, NCR5380 SCSI.
- `rtl/pseudovia.sv` — VIA2-equivalent; IIvi uses the base-RBV variant
  (edge ASC IRQ, slot bits $C/$D/$E) — see `docs/VASP_RETARGET.md` §PseudoVIA.
- `rtl/asc.sv` — V8/EASC-type sound (correct for VASP as-is).
- `rtl/maclc_v8_video.sv` + `rtl/ariel_ramdac.sv` + `rtl/vram_bram.sv` —
  onboard video (LC V8 heritage; VASP's is "slightly different" — secondary
  to the mdc824).
- `rtl/nubus/` — Mac II NuBus arbiter + mdc824/toby/highres cards (from
  lbmactwo; integration pending).
- `rtl/tg68k/` — the pinned 68030+PMMU CPU (VHDL sources → ghdl-converted .v
  via `conv_lf.sh`; see how-to-convert-cpu.txt).
- `rtl/sdram.v` — SDR SDRAM controller (16-bit words; 25-bit addressing for
  64MB modules per the VASP_RETARGET layout).

## Machine quick facts (MAME-verified)

- ROM: 1MB `4957eb49` (CRC32 61be06e5) = `rom/MacIIvx-IIvi-Performa600.rom`;
  loads at CPU $40000000; overlay mirrors it at $0 until first ROM-region read.
- Box ID: $5FFFFFFC reads $A55A2016 (Mac IIvi) or $A55A2017 (Performa 600,
  OSD "Machine" select; ROM masks #$7 → BoxFlag table $4084AB4A). Both
  machines run 16MHz for now; P600 32MHz CPU mode is a tracked follow-up.
- RAM: contiguous at $0 — OSD options 8/20/36/48MB, gated by the fitted
  SDRAM module (hps_io sdram_sz; 36MB+48MB need a 64MB+ module — undersized
  selections clamp; sim: `--ram 4|8|20|36|48|68`, `--sdram-module 32|64|128`
  emulates module aliasing). 68MB (128MB-module 2nd chip) is in RTL but
  OSD-hidden — the chip-1/nCS path hangs at boot (see
  docs/resume_2026-07-15_memory_expansion.md).
- I/O at $50000000 (+ $00F00000 mirrors): VIA1 +$0, SCC +$4000, SCSI pDMA
  +$6000, SCSI +$10000, pDMA +$12000, ASC +$14000, SWIM +$16000, VDAC
  +$24000, pseudoVIA +$26000.
- IRQ levels: SCC=4, pseudoVIA=2 (slots $C/$D/$E + ASC + VBL + SCSI bits),
  VIA1=1. All autovectored.
- Egret 341S0851; VIA1 PA reads $D5; 60.15Hz tick on CA1.
- MAME oracle: `mame maciivi` (machine in `maciivx.cpp`); the LC-II-era
  compare tooling lives in `verilator/mame/` (retarget scripts to `maciivi`
  when first needed).
