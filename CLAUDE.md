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

- **CPU sync rule** (re-pinned 2026-08-15 by owner request): the CPU upstream
  is now `../Minimig-AGA_MiSTer` (the 030_mmu lineage, BUG #447–#470 era +
  LASTWRITE frame fix) — the VHDL in `rtl/tg68k/` is a wholesale LF-normalized
  copy of their `rtl/tg68k/` (kernel/ALU/PMMU/Cache/Pack + CacheCtrl kept as
  reference). Kernel fixes land in Minimig-AGA first, then get re-copied —
  never fork the kernel here. `tg68k.v` (the Mac bus wrapper) is OURS and
  carries the integration contract: clkena held across the walker-request
  window and PMMU-busy, force-released on pmmu_fault with beat_valid=0, bus
  FSM parked during busy/fault, berr-hold with walk_cycle gating, E-clock/VMA,
  BR/BG/BGACK, autovectoring. The pre-2026-08 MacLCII pin (`a254a02` era, the
  in-kernel walk-hold gates) is history — see git log of rtl/tg68k/.
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

## MacLC family sync (laws adopted 2026-07-30, broadened 2026-08-06)

WHOLESALE from `../MacLC_MiSTer` master (kept byte-identical modulo one
asc.sv comment): the SCSI/CD set (`rtl/scsi.v`, `rtl/cd_audio.sv`,
`rtl/cd_vol_lut.vh`, `rtl/asc.sv`, `rtl/scsi_vendor.vh`) AND — since the
2026-08-06 family sync (MacLC master `182186b`, their release state) — the
floppy stack (`rtl/swim.v`, `rtl/floppy.v`, `rtl/mfm_track_encoder.v`,
`rtl/floppy_track_encoder.v`) plus the standalone floppy TBs
(`verilator/tb_*.v`) and `verilator/scsi_bench/`.

3-WAY (apply the MacLC delta, preserve the documented MacIIvi fixups):
- `rtl/ncr5380.sv` + `rtl/dataController_top.sv` — fixups: CD_RING_LOG=2,
  disk RING_LOG i==0?6:4 (boot ring 32KB since 2026-08-15, owner request;
  was 5), local comments. (TB_ADDRW i==0?12:8 now MATCHES
  MacLC — 12 is load-bearing: scsi.v TB_SEND_CAP/CAP_LARGE_SEND gate on it.)
- `rtl/via6522.sv` — IIvi-local hunks flagged "MacIIvi-local" in-file: the
  ORB output-latch read merge (POST root cause #6 — sad Mac $0F/$33 without
  it; MacLC keeps a pins-only ORB read) and one `SIMULATION` trace ifdef.
- The emu tops re-derive by hand: MacLC.sv changes port to BOTH MacIIvi.sv
  and verilator/sim.v (mount presentation, dio_menu, anchors). MacLC's
  USE_DBG_HUD on-screen forensics deck is deliberately NOT ported (single
  v8-video assumption vs our ONBOARD_DISPLAY/mdc824 mux) — fetch + adapt
  from MacLC.sv if a floppy hunt ever needs it here.

The HPS contract is the Main_MiSTer fork `add-bluescsi-toolbox-for-MacLC` —
hps_io slots: disks 0/1, PRAM 2, Toolbox 3, CD 4, CD-changer 5; CD-DA is
served as ONE 2352-byte transaction per frame (sd_buff_addr[12:8] carries
the burst word address), so core and Main MUST move together. Toolbox caps
0x82 (multi-block GET + CAP_LARGE_SEND) additionally needs the HPS lineage
MacLC ships (their releases/ MiSTer binary, dda65f18+) — older Main still
works but the client falls back to slow single-block transfers.

- **Media-change pairing law** (MacLC 2026-08-05/06): the emu-top
  DSK_EMPTY_CY leave→insert hold and floppy.v's `disk_switched` SWITCHED
  sense reg landed TOGETHER and must move together — the hold alone was the
  reverted ebbdac6 regression (guest sees eject+insert while the
  disk-switched flag says nothing changed; no real machine produces that).

- **Always-on marginality anchor** (MacIIvi.sv, from MacLC `4dfb463`):
  probe-less fits corrupt the SCSI read path on HW while STA is met — the
  preserve+noprune anchor registers keep those cones loaded. Do NOT remove,
  ifdef, or fold them. Gate every new fit in the Finder on icon integrity.
- **CD-detach gating law — RETIRED by the owner 2026-08-07** ("CD booting
  isn't causing issues anymore; this was a stale reference"): no need to
  detach `config/MacIIvi.s4` before judging a build. Kept for history: the
  MacLC 2026-07-30 finding was that a CUE/CHD attached at boot could hang
  intermittently on any build. Still in force: one boot is never a verdict;
  two boots of the same RBF can differ.
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
- OSD "Original" aspect is TRUE 4:3 (both machine modes are 4:3). The
  256:171 it replaced (2026-08-08) was a Mac Plus 512x342 leftover that
  blanked 5:4 panels via integer-scale width overflow —
  `scripts/aspect_check.py` is the offline gate (video_freak is never
  simulated); run it whenever the video_freak instance or AR values move.
- `rtl/tg68k/` — the pinned 68030+PMMU CPU (VHDL sources → ghdl-converted .v
  via `conv_lf.sh`; see how-to-convert-cpu.txt).
- `rtl/sdram.v` — SDR SDRAM controller (16-bit words; 25-bit addressing for
  64MB modules per the VASP_RETARGET layout).

## Machine quick facts (MAME-verified)

- ROM: 1MB `4957eb49` (CRC32 61be06e5) = `rom/MacIIvx-IIvi-Performa600.rom`;
  loads at CPU $40000000; overlay mirrors it at $0 until first ROM-region read.
- Box ID: $5FFFFFFC reads $A55A2016 (Mac IIvi) or $A55A2015 (IIvx — the
  OSD "Machine" O1 32MHz option, reset-latched like Memory; ROM masks #$7
  → BoxFlag table $4084AB4A). MAME defines ONLY 2015/2016 on this ROM;
  the old $A55A2017 "Performa 600" guess was HW-falsified 2026-08-15
  (every System rejects it — the real P600 is a rebadged IIvx and boots
  with the IIvx ID). The 32MHz machine also runs the CPU at "32 MHz":
  tg68k.v cpu_turbo pulses kernel clkena on BOTH phi edges for off-bus
  beats (internal micro-cycles + cache hits) — bus cycles, phi grid, E/VIA
  pacing and every peripheral rate are untouched (the real P600 shape:
  32 MHz 68030 on the IIvi's 16 MHz bus).
- 68030 on-chip I-cache (256B, TG68K_Cache_030) ENABLED 2026-08-15:
  logical-tagged, physical line fill, CACR-controlled. Cacheable = fitted
  RAM + ROM only (IIvi 32-bit map decode in tg68k.v); FC=7 (CPU space,
  the ROM's must-BERR moves probes) and PMMU-busy/fault windows excluded.
  D-cache present but tied off (USE_68030_DCACHE=0 — did not fit: fabric
  regs; re-enable = M10K rework). Line-fill reads borrow the parked bus
  with NORMAL slot-start DTACK; each captured word is retro-checked
  against sdram_ram_ready and a dirty line is dropped, never installed
  (fills must never stall the CPU — the DTACK-gated first cut froze HW).
  Hits bypass the bus only at s_state 0 (cache_hit_beat): an unqualified
  hit racing a fill-install stranded AS asserted and wedged HW while sim
  stayed green — the orphaned-AS tripwire in tg68k.v guards this forever.
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
