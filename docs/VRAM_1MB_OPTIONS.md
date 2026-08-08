# mdc824 1MB VRAM off-BRAM — options scoping (branch `change_vram`, 2026-08-07)

Goal: make the card's full 1MB (`TOTAL_WORDS = 524288`) real — CPU-accessible
AND scannable from any offset — with the framebuffer master copy off-chip,
freeing the 384KB BRAM (`vram_ram`, ~384 M10K of the 553 on the device).
"Snappy" = CPU VRAM access stays near BRAM-era speed, scanout never starves.

## Fixed facts (recon 2026-08-07)

- Card already PRESENTS 1MB: BRAM holds words `[0, VRAM_WORDS)`, the cold
  tail rides `ext_*` → SDRAM word `$100000` (the layout's reserved 1MB
  window). CPU R/W over ext is HW-proven — but only the BRAM part scans out.
- The card FSM tolerates arbitrary VRAM latency (`ready` handshakes on both
  ports). Scanout (port B) expects word-per-pixel-clock — the hard part.
- `sdram.v` (MiST heritage): ONE single-beat 16-bit op per 123ns window =
  8.125M words/s TOTAL, shared CPU/floppy/refresh. Scanout needs (during
  active lines): 1bpp 1.4M, 2bpp 2.8M, 4bpp 5.6M, 8bpp 11.2M words/s.
  8bpp@640x480 EXCEEDS the whole controller — hence the historical
  "cyan/green/red noise" and the retreat to BRAM. Any SDRAM plan needs
  bursts: the chip itself (65MHz CL2) streams 1 word/clk within a row.
- The sim swaps `sdram.v` for `sim_ram.v` — controller changes need a sim
  twin model; the REAL controller is only provable on HW.

## Option A — SDRAM burst video port + scanline FIFO  ← try 1st

The plan VASP_RETARGET.md §"SDRAM-backed video" already reserves space for.

- `sdram.v` grows a read-only video port: in a window with no CPU/chipset
  op and no refresh due, run ACTIVE @T0, up to 4 chained BL1 READs @T2-T5,
  explicit PRECHARGE @T6 — 4 words/window, self-contained, CPU windows
  untouched (video is lowest priority, capped at every-other window =
  16.25M words/s ceiling). Refresh moves from "every idle window" to a
  24-window credit counter (still ≥4x JEDEC cadence with both chips).
- Card scans from a 2×512-word ping-pong line buffer (2 M10K); a prefetch
  engine fetches line v+1 during line v (320 words worst mode). Underruns
  show the previous line + bump a debug counter (sim prints it).
- CPU access: ALL card words ride the proven ext path (`VRAM_WORDS=0`);
  writes become POSTED (1-deep buffer, ack immediately, drain on the clk8
  window grid; reads and RMW drain the buffer first) — fill speed returns
  to ~BRAM-era (NuBus ack dominates), reads ~2x BRAM latency (still faster
  than a real NuBus card).
- Risk: sustained-worst-case CPU window occupancy could starve the fetch;
  counters + HW judgement. Escalation: low-water preempt or Option C.

## Option B — DDR3 (MiSTer DDRAM port) full VRAM  ← try 2nd

- 1MB lives in HPS DDR3; the emu DDRAM channel (currently tied off) gets a
  small adapter: scanout line prefetch as 64-bit bursts + CPU ext ops.
  SDRAM completely untouched — zero contention with RAM/floppy/SCSI paths;
  headroom for a future 2MB/24bpp card.
- Cost: CPU VRAM reads ~500-900ns (DDR round trip incl. scaler sharing);
  posted writes hide write latency. Sim needs a behavioral DDR model
  (latency + bursts) — one more divergence between sim and HW.

## Option C — deterministic SDRAM slots (fallback, only if A starves)

Guaranteed-rate variants of A, trading CPU speed for worst-case bounds:
video owns the 2 unused extra-slot phases (4.06M words/s floor) and/or a
full-line hblank burst with CPU lockout (~15-18% CPU cost). Only worth
building if A's counters show real starvation on HW.

## Verdict (updated 2026-08-07 late pm)

**Option B is the default as of `8bc03cb`**: card VRAM lives on DDR3
(`MDC_VRAM_DDR`), and the paired `SDRAM_NO_WIN_RELEASE` macro compiles the
window-release mechanism out of sdram.v — with the video port idle it bought
nothing, and it is unvalidated on hardware (the v2.2 wedge; the resume doc's
§4.4 explains why the whole comparison-based release is suspect). Comment
both macros out together to fall back to Option A. Option A v1's data path
remains the HW-proven foundation; A's v2.x release mechanism is retired
unvalidated — if window-releasing is ever revisited, do it as the §6.3
executed-flag redesign, not another compare patch. B is also the growth
path past 1MB (24bpp @ 640x480 needs a 2MB card).

| Attempt | Commit | Gates | Notes |
|---|---|---|---|
| scoping doc | 060b6b4 | — | — |
| A: SDRAM burst port | 8c60798 | sim build + check_boot montype 6/7 PASS; benches PASS; sim desktop dither pixel-perfect full-frame (fast-ramtest ROM, frames 350-650) | **HW boot 2026-08-07 (.143): System 7.5.5 → MacAtrium on the card** — content correct, no noise/tearing; right ~27% of each line froze (line-fetch shortfall under load) → v2 |
| A v2: released windows + triple buffer | c87cafe | tb_sdram_vid saturating-cpu case: 320-word line in ~1 line-time (was starving); all correctness cases PASS | first fit FAILED STA (-8.1ns): live release compare in the T0 path |
| A v2.1: pipelined release qualifier | 39f2abc | bench PASS (1078 clk_sys / 1860 budget); check_boot PASS | first respin -1.6ns: live din into the new wr_done_din endpoint |
| A v2.2: registered din capture + sdc | b3ca894 + (sdc commit) | bench PASS; **STA CLOSED: 0 negative slack design-wide (clk_64 +0.823, HDMI +0.406)** — the residual -1.9 was the long-waived sd_data din-cone path on a fitter DUPLICATE register whose name escaped the sdc keeper pattern; pattern widened + same-argument MCP2 for the rls_* sampling regs | rbf 2026-08-07 18:56 **DEPLOYED 19:33 → WEDGED on HW** (blank light-gray, 7 grabs / 4 min, never draws — hw_gate/boot2_t*.png) |
| A v2.2 root cause + retire | 1316d2b | bench reproduces the wedge ONLY with bus-phase sweeping: the release write-compare omitted the byte strobes, so a byte-clear loop's second lane was skipped as already-served; with ds recorded+compared all phases PASS | ds fix committed for the record, NOT HW-validated; the phase hazard falsifies "a new op's first window always executes" → owner: stop iterating, mechanism needs rethinking |
| B: DDR3 backing | bf55e4a | sim build clean; check_boot PASS with +vramddr (card probes via DDR); tb_vram_ddr bench PASS | HW untested; needs its own RBF with the qsf macro |
| **B as default + release compiled out** | 8bc03cb (+227aadc: vram_bench run.sh python3 fix — the sdram bench had silently never run under stock WSL) | vram_bench sdram/scan/ddr ALL PASS; lint of the SDRAM_NO_WIN_RELEASE branch clean; Quartus fitter OK, **STA CLEAN on SEED 4: HDMI worst +0.123, 0 negative design-wide** (seed sweep 2→-0.175/TNS-3.3, 5→-0.106, 4→met; HDMI-scaler-only, clk_sys ≥ +2.1); ALM 97%, RAM 138/553 blocks (19% bits) | **rbf md5 ec708dc8 (2026-08-07 21:40) = the deploy candidate; NOT deployed — owner hold.** SDRAM carries zero card traffic; CPU↔VRAM ops ride the DDR adapter (posted writes / ~1-burst-drain reads) |

### Open items

- .143 currently runs the WEDGED v2.2 build (deployed 19:33). Sequence once
  the owner clears deploys: (1) restore releases/MacIIvi_20260807.rbf to
  re-baseline the box, then (2) deploy the B candidate (ec708dc8) and
  judge: MacAtrium animation with NO right-edge band, Finder colour-icon
  integrity (icon_gate.py cells are STALE — visual + two-boot pixel
  compare per its 2026-08-06 header note), a second boot of the same rbf,
  and a snappiness feel-pass (CPU VRAM ops now cross the DDR adapter).
- If B misbehaves on HW: Option C (reserved slots / hblank burst) is the
  no-cleverness fallback. A window-release only comes back as the resume
  doc's §6.3 executed-flag redesign — never another compare patch.
- verilator/sim.v still defaults to the Option A backend (`+vramddr` opts
  in) — flip the sim default too if B becomes permanent, per the
  keep-the-tops-in-sync law.
- deploy_screenshot.sh gates on Fitter status only — it would have shipped
  the STA-failed v2 fit. Consider adding an sta.summary "no negative
  slack" check.
- 24bpp mode plumbing (RAMDAC mode 0xD) is still mapped to 8bpp in the
  card; the 1MB framebuffer it needs is now fully scannable — follow-up.
- The h==0 pixel column renders from stale buffer data by design (was
  port-B prefetch-during-blank garbage before, black now); invisible on
  real monitors' overscan, cosmetic in sim screenshots.

### Bench coverage added while landing A (scratchpad, results 2026-08-07)

- `tb_scan_fetch`: mdc_scan_fetch against the sim_ram video-port twin —
  aligned/unaligned bases, mid-line abort (seq-tag word dropping), cpu-port
  contention stalls. PASS.
- `tb_sdram_vid`: the REAL sdram.v (bench-split inout) + mdc_scan_fetch
  against a protocol-checking behavioral SDR chip — CPU reads/writes stay
  correct under concurrent video scavenging, chained-read groups legal
  (ACTIVE/READ×4/PRECHARGE; zero protocol errors), refresh credit holds
  under saturated video (243 refreshes where ≥40 demanded). PASS. This is
  the only pre-hardware coverage sdram.v gets — the main sim swaps it for
  sim_ram.
- `tb_vram_ddr` (Option B prep): mdc_vram_ddr + sim_ddram — 64-bit lane
  packing/byte enables, cross-burst word order, abort tagging, ext ops
  preempting between scan bursts. PASS. Caught a real contract bug (level-
  held requests re-latched as phantom ops → stale-completion aliasing);
  fixed with edge-qualified accept + level ready.
