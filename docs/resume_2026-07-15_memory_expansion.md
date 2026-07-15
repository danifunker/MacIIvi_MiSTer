# Resume 2026-07-15 — memory expansion: 36MB fixed, 68MB added

*Session record. Companion to [VASP_RETARGET.md](VASP_RETARGET.md) (the
"Verified size options" + "New SDRAM layout" sections carry the durable
design; this file carries the investigation trail and the validation state).*

## The question answered: was the 36MB failure a PMMU issue?

**No.** The pre-.143 "36MB boots but throws random Finder errors" was
**physical SDRAM-module aliasing**, below any address translation:

- RAM lives at SDRAM word `$380000` (fixed regions — ROM/VRAM/mdc824/floppy
  staging — occupy words `$0..$37FFFF`). RAM byte address B maps to word
  `$380000 + B/2`, so **RAM above 25MB needs word bit 24** (≥ 32MB of module).
- Word bit 24 is **column A9**, which exists on 64MB+ chips only. A 32MB
  MT48LC16M16 has a 9-bit column and **ignores A9 during CAS**: word X and
  word X+$1000000 address the same cell.
- Consequence at 36MB on a 32MB module: RAM 25–32MB aliases onto the
  ROM image + VRAM + floppy staging words; RAM 32–36MB aliases onto the
  first 4MB of RAM. The ROM's memory sizing probe writes and reads back
  through the alias **consistently**, so sizing "succeeds", the machine
  boots, and corruption lands only when the OS actually grows into high
  memory (System 7 allocates high) → delayed, random-looking Finder errors.
  At 20MB the top RAM word is `$D7FFFF` < 32MB — no alias, rock solid.
- The PMMU is upstream of all of this (logical→physical); physical RAM
  geometry is what broke. The tg68k PMMU corpus standing is unchanged.

## What changed (all committed with this doc)

1. **`sdram_sz` gate + clamp (MacIIvi.sv)** — hps_io reports the fitted
   module ([15]=valid, [1:0] 1/2/3 = 32/64/128MB; the menu core probes it
   once and Main replays it to every core). CONF_STR now carries three
   masked Memory lines sharing O23 (8/20 | 8/20/36 | 8/20/36/68) behind
   `status_menumask` bits {≥64MB, =128MB}, so **impossible sizes are never
   offered**; `ram_size_bytes` additionally clamps a stale oversized
   selection (36→20, 68→36→20). Unknown module (old Main / menu never run)
   = conservative 8/20 only.
2. **68MB support (hardware max, 4 + 4×16MB SIMMs)** — the whole SDRAM word
   path widened 25→26 bits (`ram_size_bytes` 26→27): addrDecoder compare,
   addrController bases/adders (`memoryAddr[25:0]`), MacIIvi.sv/sim.v
   muxes + download paths. RAM tops out at word `$257FFFF` on a 128MB
   module.
3. **`rtl/sdram.v` dual-chip addressing** — MiSTer 128MB modules are two
   64MB chips with **nCS inverted into the second one** (PSX_MiSTer
   precedent: `SDRAM_nCS = chip`). nCS is now its own register: the LEVEL
   selects the chip (`addr[25]`), idle stays 1 (INHIBIT chip0 / NOP chip1,
   same pins as before). The init ladder runs PRECHARGE/8×REFRESH/LOAD-MODE
   for **both** chips (even/odd `reset` slots), and idle-slot auto-refresh
   **alternates** chips (each still ≥8× faster than the 7.8µs JEDEC
   cadence; a chip-1 refresh is inert on 32/64MB modules). DQM stays aliased
   onto `sd_addr[12:11]` — that is **board wiring** (the module PCB shorts
   A12/A11 to DQMH/DQML; both are column don't-cares on every supported
   chip since columns stop at A9).
4. **Sim plumb** — `--ram 4|8|20|36|68` (kills the dead `cfg_memSize` LC
   hook), and `--sdram-module 32|64|128`: `sim_ram` (now the full 128MB
   space) emulates the physical failure modes — undersized module ⇒
   `addr[24]` aliases / `addr[25]` deselects exactly like real chips — so
   the 36MB-on-32MB corruption is reproducible in sim on purpose.

## Validation state

- **Sim (done):** clean build; 60-frame smoke at 4MB boots identically to
  pre-change (chime, VIDDBG, PERF counters). March-window logs at
  8/20/36/68 confirm the CPU→SDRAM word mapping (`cpuAddr $25FC →
  sdramAddr $3812FE` = `$380000 + word`). Long Finder-boot sims were
  **deliberately killed** — per project owner, hardware is the fast
  validation loop (sim ≈ 5.8s/frame; a Finder boot is hours). Note
  `rtl/sdram.v` is *not* exercised by the sim at all (sim_ram replaces
  it) — hardware is the only real test of the dual-chip changes.
- **Hardware (2026-07-15, .143 — 36MB CONFIRMED):** Quartus build
  (fitter Successful, timing met, M10K 77%) → deploy →
  - **8MB default:** boots to Finder = clean regression
    (scratchpad/hw_8mb_finder.png).
  - **36MB:** About This Macintosh reads **Total Memory 36,864K** (= 36×1024
    exactly), System 30,797K, largest unused 6,036K, stable at the Finder
    with the disk mounted (scratchpad/hw_36mb_boot.png). The pre-.143
    "random Finder error" is GONE — root cause was the 32MB-module alias,
    not the RAM logic. NOTE: blind OSD nav (osd_keys.py) mis-selected — the
    screenshot API doesn't capture the OSD overlay, so the cursor row can't
    be seen; the project owner set the memory manually. Drive OSD changes
    via the owner, not blind key sequences.
  - The fitted module reports **128MB** (`sdram_sz=3`, read from
    /dev/mem 0x1FFFFF00 = `12 57 00 03` LE = sig + size 3), so the OSD
    shows the full 8/20/36/68 list.
  - **68MB:** **FREEZES at the early Happy Mac** (scratchpad/
    hw_68mb_freeze.png — small Mac icon mid-screen, no progress to disk
    hand-off). Diagnosis: the second-chip (nCS) path is not delivering a
    distinct chip 1. Signature analysis: the cold RAM march evidently
    PASSED (Happy Mac drew — a failed march = Sad Mac), then the OS load
    into high memory froze. That pattern = **chip-1 addresses aliasing onto
    chip 0**, not a dead chip 1: the march writes & reads "chip 1" through
    the same alias so it passes, then the OS uses low + "high" RAM and the
    high writes stomp the System in low RAM → hang. Same shape as the
    original 32MB-module alias, now at the chip-0/chip-1 word boundary
    ($2000000). Refresh-alternation is EXONERATED: at 36MB my new code
    already runs the halved (alternating) refresh on chip 0 and boots
    clean, so the halved rate is adequate. So the fault is specifically
    **addr[25]→nCS not switching the physical chip** on this module —
    either a bug in the sdram.v nCS timing/polarity, or this particular
    128MB module doesn't use the Sorg nCS-invert scheme the PSX core
    assumes. Can't be bisected in sim (sim replaces sdram.v with sim_ram).
    NOTE 64MB would NOT isolate it: 64MB Mac RAM tops at word $237FFFF,
    also above the $1FFFFFF chip-0 boundary, so it exercises the same
    (broken) chip-1 path — and it isn't an OSD option (needs a rebuild).
    The clean isolator is a chip-0-only size >36MB (≤57MB fits chip 0):
    a 48MB probe build that boots would prove the 26-bit widening itself
    is clean and pin the fault to nCS. Needs the exact module part number
    to check its chip-select wiring before more build cycles.

## 2026-07-15 second build: 48MB added, 68MB hidden

Per owner decision after the 68MB freeze:
- **OSD Memory is now 8/20/36/48MB** (68MB dropped from the menu). Needed a
  3rd status bit: `status_mem` widened [1:0]→[2:0], field `O23`→`O234`
  (status[4:2]; status[4] was freed by the earlier Machine-option removal).
  CONF_STR collapses to two module-tiered lines — `H0` = 8/20 (32MB/unknown
  module), `h0` = 8/20/36/48 (≥64MB module). 128MB detection (`sdram_128`)
  retired from the gate since the top offered size is now chip-0-only.
- **48MB** (word top `$1B7FFFF`) is chip-0-only, so on a ≥64MB module it
  should boot exactly like 36MB — and it's a MAME-listed size, so it's a
  real feature, not just a probe. If it boots to the Finder (expect
  ~49,152K), it PROVES the 26-bit widening is clean and pins the 68MB fault
  entirely to the chip-1/nCS path.
- **68MB** stays in the RTL (26-bit path, nCS logic untouched) but is
  OSD-unreachable and the clamp caps any stale selection to 48MB (`mem_cap`
  = 48MB on ≥64MB module, else 20MB). Re-expose when chip-1 is fixed.
- Sim kept in sync: `--ram` now accepts 48 (`ram_mb_table` = {4,8,20,36,48,
  68}; sim.v decode + sim_main help updated).
- 2nd Quartus build (Fitter Successful, timing met) deployed to .143.
  **48MB CONFIRMED ON HARDWARE**: About This Macintosh = Total Memory
  **49,152K** (= 48×1024), System 43,046K, stable Finder with disk + CD
  mounted (releases/hw_143_48mb_finder_20260715.png). This is the clean
  isolation result: 48MB uses more of chip 0 than 36MB (addr[24]/column A9
  exercised) and boots perfectly, so the **26-bit address widening is
  proven correct** and the 68MB freeze is **definitively** the chip-1/nCS
  path alone. 8MB default also re-confirmed. Shipping config = 8/20/36/48MB.
  Released as MacIIvi_Unstable_20260715.rbf (md5 f73b6ee2…).

## Open follow-ups

- If 36MB Finder-boot works on hardware but 68MB can't be tested (no 128MB
  module on the bench), leave 68MB marked experimental in the next release
  note. The dual-chip refresh/init logic is PSX-pattern-faithful but
  silicon-untested in this core.
- OSD cosmetic: a selection made on a bigger-module machine reads as an
  out-of-range index if the SD card moves to a smaller-module machine
  (harmless; the clamp governs actual behavior; re-selecting fixes it).
- `verilator/check_boot.sh` still greps LC-era ROM PCs (00A0xxxx) — stale
  for the IIvi ROM; unrelated to this session but noticed again.
