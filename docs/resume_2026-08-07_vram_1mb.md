# RESUME: 1MB mdc824 card VRAM off BRAM (branch `change_vram`)

**Written 2026-08-07 as a handoff. Read this whole file before touching
anything.** The owner's standing instruction at handoff time: **do NOT keep
iterating on the RTL / testbenches for the open issue below** — come back with
a different approach (see §6), or with the owner's direction.

---

## 0. STATE OF THE HARDWARE RIGHT NOW ⚠

**.143 is running a WEDGED build.** The v2.2 core (`b3ca894` + sdc `63382e8`,
rbf md5 `ced3c8e9f7a2be50c66b069f0e675ae3`) was deployed at ~19:33 and never
draws anything: 7 screenshots over ~4 minutes are byte-identical blank
light-gray (`hw_gate/boot2_t0..t6.png`). The machine is not booting.

The known-good fallback is `releases/MacIIvi_20260807.rbf` (the morning F-line
release, 4533744 bytes) — a `bash scripts/deploy_screenshot.sh` after copying
it over `output_files/MacIIvi.rbf` restores a working machine. **Ask the owner
before deploying anything** (there is a deploy hold; one exception was granted
for the 19:33 push and it is spent).

Also note: the CD-detach gating law was RETIRED by the owner today
(commit `5169890`) — no need to move `config/MacIIvi.s4` aside before judging.

---

## 1. What the work is

Goal (owner's ask): give the mdc824 NuBus card a real 1MB of VRAM without
using FPGA block RAM, keeping things "snappy"; try at most 3 approaches, and
**commit between each attempt so any of them can be rolled back**.

Before this work: the card *presented* 1MB but only 384KB was real BRAM
(`vram_ram`, ~384 of the device's 553 M10K); words above that were a
CPU-accessible "cold tail" in SDRAM that could never be scanned out.

After this work (branch `change_vram`, 9 commits + the uncommitted fix in §4):
BRAM usage went **98% → 19%** (~380 M10K freed), and the whole 1MB is both
CPU-accessible and scannable.

---

## 2. The three options (owner asked for max 3)

| | Approach | Status |
|---|---|---|
| **A** | **SDRAM**: all card VRAM in the reserved window at word `$100000`; scanout via a new burst video port in `sdram.v` feeding a line buffer in the card | **SHIPPED DEFAULT.** Boots on HW (see §3), one open bug (§4) |
| **B** | **DDR3**: same client contracts on the MiSTer DDRAM channel (`rtl/nubus/mdc_vram_ddr.sv` + `verilator/sim_ddram.v`) | Integrated, bench-passed, **dormant**: enable with `MDC_VRAM_DDR` in the qsf, or `+vramddr` in sim. Never built for HW. The escape hatch if SDRAM contention proves unfixable, and the growth path to 2MB/24bpp |
| **C** | Deterministic slot reservation (video owns fixed slots / hblank burst, costing CPU) | **Never built.** A's fix made it unnecessary. Still the fallback if the release mechanism (§4) is abandoned — it needs no cleverness, just CPU throughput |

### Commit map (rollback points)

```
060b6b4  docs: scoping of the three options
8c60798  A: SDRAM-backed 1MB + burst video port + mdc_scan_fetch   <- HW-booted, right-edge artifact
bf55e4a  B: DDR3 backing behind MDC_VRAM_DDR (default off)
c87cafe  A v2: released windows + 2-line-ahead triple buffer
39f2abc  A v2.1: pipeline the release qualifier off the timing path
e21d384  docs: verdict table
5169890  CLAUDE.md: retire the CD-detach gating law (owner call)
b3ca894  A v2.2: registered din capture                            <- DEPLOYED, WEDGES
63382e8  sdc: sd_data duplicate + rls_* multicycles (STA closes)
```

`docs/VRAM_1MB_OPTIONS.md` carries the design rationale and the verdict table.

---

## 3. How Option A works (enough to change it safely)

- **`rtl/sdram.v`** grew a read-only **video burst port**. In a command window
  where the cpu/chipset presents no op, it runs `ACTIVE` @T0, up to 4 chained
  single-beat `READ`s @T2..T5, explicit `PRECHARGE` @T6 — 4 words per window,
  strictly lowest priority, never two windows in a row. Refresh moved from
  "every idle window" to a 24-window forced credit (still ~5.9µs/chip vs the
  7.8µs JEDEC requirement). Served words stream out on `vid_data` with
  `vid_tog` flipping per word and `vid_dseq` tagging which fetch group they
  belong to.
- **`rtl/nubus/mdc_scan_fetch.sv`** (new) turns a card line request into
  sequential video-port reads and drops stale-tagged words after a line abort.
  Shared verbatim by `MacIIvi.sv` (→ sdram.v) and `verilator/sim.v` (→
  sim_ram.v's port twin), and by Option B (→ mdc_vram_ddr.sv).
- **`rtl/nubus/nubus_video_mdc824.sv`** picks its scanout backend at
  elaboration on `VRAM_WORDS`: `0` = SDRAM/line-buffer path; non-zero = the
  legacy BRAM port-B path (still used by `ONBOARD_DISPLAY` and by
  `verilator/mdc_bench`). In the `0` path it prefetches **two lines ahead**
  into a **3-bank rotating line buffer** (4 M10K); fill and scan rotations are
  both forced to bank 0 at line 0 so they resync every frame (525 and 407
  total-line counts are not both mod-3 friendly).
- **CPU access** to card VRAM goes entirely through the card's `ext_*` port →
  the SDRAM window (the pre-existing, HW-proven cold-tail plumbing, now
  covering word 0 upward). `MacIIvi.sv` counts 3 `clk8_en_p` edges to declare
  an ext write complete.

---

## 4. THE OPEN ISSUE — the window-release mechanism

### Why it exists

The **first HW boot of Option A worked**: System 7.5.5 → MacAtrium **on the
card**, content pixel-correct, no colour noise, no tearing
(`hw_gate/boot1_t4.png`). But the right ~27% of every scanline showed a frozen
row-parity pattern from x≈468 — the line buffers' stale tails. Under a drawing
workload the fetch engine was only completing ~73% of each line.

Root cause: **a 68030 bus cycle holds `oe`/`we` presented across 2-3 command
windows** (the controller re-executes the same op idempotently in each). So
real window occupancy is 2-3× the useful access rate, and the lowest-priority
video port starves mid-line. The Verilator sim never showed this — `sim_ram.v`
serves the cpu port in one cycle, so its contention model is far too mild.

### The fix that is in the tree (v2/v2.1/v2.2 + uncommitted §4.3)

**Redundant-window release**: track write completion the same way read
completion is already tracked (`dout_valid`/`dout_addr`), and let a window
whose presented op is *already served* go to video/refresh instead of a
redundant re-execution.

Two constraints shaped the implementation:

1. **Timing.** The first cut put the comparison combinationally in front of
   the 65MHz T0 arbitration → STA `-8.1ns`, TNS `-535` (tg68k opcode →
   sd_addr). v2.1 moved it into a 2-stage register pipeline with a
   3-consecutive-verdict counter (`rls_cnt`); v2.2 additionally sourced the
   recorded write data from the stage-1 sample instead of live `din`.
   `MacIIvi.sdc` (`63382e8`) then had to widen the long-standing `sd_data`
   multicycle keeper pattern to `~reg0*` — the fitter had started *duplicating*
   that register and the clone's name escaped the waiver, resurfacing an
   already-waived path as a "new" `-1.9ns` violation. **Final STA: zero
   negative slack design-wide** (clk_64 +0.823, HDMI +0.406).

2. **Correctness.** ← this is where it stands broken.

### 4.3 The bug found after the wedge (fix UNCOMMITTED in `rtl/sdram.v`)

The write comparison used **address + data only**. Byte strobes (`ds`) were
not compared, so a byte write matching a previous write's address and data but
targeting the **other byte lane** was skipped as "already served" — and that
lane never got written. The canonical trigger is a byte-wise clear loop
(`din`=0000 twice, `ds`=01 then 10), which is everywhere in early boot. That
is almost certainly why v2.2 wedges before drawing anything.

The working tree has the fix (record and compare `ds`; `wr_done_ds`/`rls_ds_q`
in `rtl/sdram.v`) — **uncommitted, never built for hardware, never HW-tested.**

Bench evidence for it, using `verilator/vram_bench/run.sh sdram`:
- The bug **only reproduces when the bench sweeps the bus phase.** With the
  op presented at a fixed phase it passes even on the broken RTL. Sweeping 8
  phases: broken RTL fails (`mem[0380052] = ff00` where `0000` expected — high
  byte never cleared); with the `ds` fix, all phases pass.
- Phase matters because the release qualifier needs 5 cycles to arm, and a
  command window boundary comes every 8: **an op presented early enough in a
  window can have its first and only execution window released out from under
  it.** The claim in earlier commit messages that "a new op's first window
  always executes" is therefore **WRONG** — that is the deep issue below.

### 4.4 Why the whole mechanism is suspect (read before reusing it)

Even with `ds` compared, the release rests on: *"if (addr, din, ds) equal the
last served write, memory already holds that, so skipping is a no-op."* That
is sound in isolation, but the v2.2 wedge proved the surrounding reasoning was
too loose, and one hazard class is now known to be real (phase-dependent
loss of an op's only window). Before trusting it again, someone must convince
themselves about at least:

- **Single-slot record.** Only the *last* served write is remembered. Any
  reader of that record must be sure no other agent mutated that address in
  between. Every writer does share this port today (CPU, floppy staging, card
  ext, ROM download) — but that is an invariant worth re-proving, not assuming.
- **The read side.** A read releases when `dout_valid && dout_addr == addr`,
  which is exactly `ram_ready`. Believed safe (any write clears `dout_valid`),
  and it was never implicated in the wedge — but it has the same 5-cycle arm
  latency and so the same first-window hazard.
- **Ext-write completion.** `MacIIvi.sv` declares a card ext write done after
  3 `clk8_en_p` edges — a *time*-based count, not an execution-based one. If a
  release ever suppresses the only execution of an ext write, the card is told
  the write completed and VRAM silently loses it.

---

## 5. What is proven, and what the gates are

**Proven on hardware** (Option A v1, `8c60798`): 1MB SDRAM-backed card VRAM
boots System 7.5.5 to MacAtrium on the card with correct content — the data
path, address math, CLUT, stride, byte order, ext CPU access and the burst
scanout are all right on real silicon. Only the *supply rate* was short.

**Proven in benches only:** the release mechanism and the triple buffer.

**Bench tooling** (preserved from the session scratchpad into
`verilator/vram_bench/`, run with `bash verilator/vram_bench/run.sh <sdram|scan|ddr>`):

- `tb_sdram_vid.v` — **the important one.** Drives the REAL `rtl/sdram.v`
  against a protocol-checking behavioral SDR chip model (flags READ/WRITE to a
  closed row, counts refreshes). The main Verilator sim swaps `sdram.v` for
  `sim_ram.v`, so this bench is the **only** pre-hardware coverage the
  controller has. Covers: cpu read/write integrity under concurrent video,
  chained-group legality, refresh cadence under saturated video, a
  saturating-CPU case (held multi-window ops) that reproduces the HW
  starvation, and the phase-swept byte-strobe cases from §4.3.
  `sdram_split.v` is regenerated from `rtl/sdram.v` on every run (the `inout`
  bus is split for Verilator) — never hand-edit it.
- `tb_scan_fetch.v` — `mdc_scan_fetch` against sim_ram's port twin.
- `tb_vram_ddr.v` — Option B's adapter + `sim_ddram`.

**Sim gates that stayed green throughout** (and are NOT sufficient — they were
green for the wedging build too): `verilator/check_boot.sh` at montype 6 and
7, and full-frame scanout in sim via
`./obj_dir/Vemu --headless +montype=7 +mdc824`.

---

## 6. Suggested approaches from here (owner asked for options, not more of the same)

1. **Drop the release mechanism entirely; take Option C instead.** Give video
   a *reserved* supply — e.g. the two currently-unused "extra" bus slots
   (`addrController_top.v` gives the CPU 3 of 4 slots; slot `10` serves floppy
   and has spare capacity), or a burst during hblank with a short CPU stall.
   Cost is a few percent of CPU throughput, bought with no correctness
   cleverness at all. Given that the machine is already architecturally slow
   for other reasons, this is the lowest-risk path to a working 1MB card.
2. **Switch the default to Option B (DDR3).** It is written, integrated and
   bench-passed, and it removes card VRAM from the SDRAM contention problem
   *entirely* rather than fighting for windows. Cost: one Quartus build with
   `MDC_VRAM_DDR` to find out, plus DDR latency on CPU VRAM reads. This is
   probably the fastest route to "1MB, snappy, no starvation".
3. **Make the release safe by construction rather than by comparison.** The
   hazard is that a release can fire *before* an op's first execution. A
   design where a window is released only if that specific op has been
   observed to execute at least once (an explicit per-op "executed" flag set
   by the CAS phase and cleared when the presented op changes) has no
   phase-dependent window and needs no data comparison at all — no `ds`, no
   `din`, no single-slot-record reasoning. Strictly simpler than what is in
   the tree.
4. **Reduce demand instead of increasing supply.** 8bpp @ 640×480 is the worst
   case; the visible artifact appears only under that. Fetching at a lower
   depth, or fetching only the words the current mode actually needs, buys
   headroom without touching arbitration.

Whatever route: **re-validate on hardware**, and remember that
`scripts/deploy_screenshot.sh` gates on Fitter status only — it will happily
ship a build with failing timing. Check `output_files/MacIIvi.sta.summary` for
negative slack before every deploy (that is how the `-8.1ns` v2 build nearly
went out).

---

## 7. Session gotchas worth keeping

- Sim boot with the stock ROM spends 700+ frames before drawing (RAM march +
  boot chime). The ASC FIFO poll at `$50F14804` is the **chime**, not a hang.
  `verilator/patch_fast_ramtest.py` was retargeted from the LC's fixed offset
  to a signature search (the IIvi march engine is at `$46958`) — use it to get
  a drawing screen in ~120 frames.
- The card-as-display sim run is `+montype=7 +mdc824`. Sense-7 boots fine (an
  old note claiming it wedges the ROM is wrong and is corrected in `sim.v`).
- The MiSTer screenshot API does not capture the OSD overlay.
- Deploying over a live guest risks HFS damage; `scripts/mac_clean_shutdown.sh`
  is the polite path (it needs the guest at the Finder and was skipped for the
  19:33 deploy because the guest was already stuck).
