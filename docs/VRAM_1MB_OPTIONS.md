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

## Verdict

(filled in as attempts land — see commit map below)

| Attempt | Commit | Sim gate | Notes |
|---|---|---|---|
| scoping doc | 060b6b4 | — | — |
| A: SDRAM burst port | (this commit) | check_boot PASS at montype 6 AND 7 (Slot Manager card probes ride the new all-ext path); standalone benches PASS (see below); card-view boot run to frame 710: stable, artifact-free scanout, zero underruns (desktop-pattern confirmation via fast-ramtest ROM in flight — the stock ROM's full 4MB march hasn't reached drawing by frame 710) | |
| B: DDR3 backing | TBD | TBD | adapter+DDR model bench PASS pre-integration |

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
