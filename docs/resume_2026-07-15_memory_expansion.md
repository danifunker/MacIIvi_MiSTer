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
- **Hardware (pending, this session):** Quartus build → deploy to .143 →
  (a) 8MB default boots = regression, (b) OSD Memory 36MB + Reset & Apply →
  Finder + About This Macintosh shows ~36MB, stable session. 68MB requires
  a 128MB module — check which Memory line the OSD shows; that IS the
  module report. If only 8/20 show on real hardware, the fitted module is
  32MB (or Main is old / menu core never ran) — larger sizes are then a
  hardware shopping question, not an RTL bug.

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
