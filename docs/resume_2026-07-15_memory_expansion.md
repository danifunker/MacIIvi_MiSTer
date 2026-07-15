# Resume 2026-07-15 — memory expansion: 8/20/36/48MB shipped, 68MB deferred

*Session record. Companion to [VASP_RETARGET.md](VASP_RETARGET.md) (the
"Verified size options" + "New SDRAM layout" sections carry the durable
design; this file carries the investigation trail and the validation state).*

**Outcome:** released `MacIIvi_Unstable_20260715.rbf` (md5 `f73b6ee2…`) with
an OSD-selectable, module-gated Memory option — **8 / 20 / 36 / 48 MB**, all
four hardware-validated on .143. 68 MB (the IIvi hardware max) is implemented
in RTL but OSD-hidden: its 128 MB-module second-chip path still freezes at
boot. Commits: `433711e` (root-cause + dual-chip RTL), `c1f2057` (48 MB
option / 68 MB hidden), `fcd8a3d` (the release).

## The question answered: was the 36MB failure a PMMU issue?

**No.** The pre-.143 "36MB boots but throws random Finder errors" was
**physical SDRAM-module aliasing**, below any address translation:

- RAM lives at SDRAM word `$380000` (fixed regions — ROM/VRAM/mdc824/floppy
  staging — occupy words `$0..$37FFFF`). RAM byte address B maps to word
  `$380000 + B/2`, so **RAM above ~25MB needs word bit 24** (past 32MB of
  module space).
- Word bit 24 is **column A9**, which exists on 64MB+ chips only. A 32MB
  MT48LC16M16 has a 9-bit column and **ignores A9 during CAS**: word X and
  word X+$1000000 address the same cell.
- Consequence at 36MB on a 32MB module: RAM ~25–32MB aliases onto the
  ROM image + VRAM + floppy staging words; RAM 32–36MB aliases onto the
  first few MB of RAM. The ROM's memory sizing probe writes and reads back
  through the alias **consistently**, so sizing "succeeds", the machine
  boots, and corruption lands only when the OS actually grows into high
  memory (System 7 allocates high) → delayed, random-looking Finder errors.
  At 20MB the top RAM word is `$D7FFFF` < 32MB — no alias, rock solid.
- The PMMU is upstream of all of this (logical→physical); physical RAM
  geometry is what broke. The tg68k PMMU corpus standing is unchanged.

## What shipped

1. **Module-aware gate + clamp (MacIIvi.sv).** hps_io reports the fitted
   module via `sdram_sz` ([15]=valid, [1:0] 1/2/3 = 32/64/128MB; the menu
   core probes it once and Main replays it to every core). The Memory field
   is `O234` (status[4:2], widened from the old 2-bit `O23`; status[4] was
   freed by the earlier Machine-option removal), carried by two
   module-tiered CONF_STR lines behind `status_menumask` bit0 = "module
   ≥64MB":
   - `H0` → **8/20MB** on a 32MB/unknown module,
   - `h0` → **8/20/36/48MB** on a ≥64MB module.
   `ram_size_bytes` additionally CLAMPS a stale oversized selection to the
   chip-0 max we trust: 48MB on a ≥64MB module, 20MB otherwise. So a config
   carried over from a bigger machine can never reach a size the module
   can't back (no alias, no dead chip).
2. **26-bit SDRAM word path.** Widened 25→26 bits end to end (`ram_size_bytes`
   26→27): addrDecoder compare, addrController bases/adders
   (`memoryAddr[25:0]`), MacIIvi.sv/sim.v muxes + download paths. 36MB tops
   at word `$157FFFF` and 48MB at `$1B7FFFF` (both inside chip 0's `$1FFFFFF`
   limit); 68MB would reach `$257FFFF` (chip 1).
3. **`rtl/sdram.v` dual-chip addressing (present, unverified on silicon).**
   MiSTer 128MB modules are two 64MB chips with **nCS inverted into the
   second one** (PSX_MiSTer precedent: `SDRAM_nCS = chip`). nCS is now its
   own register: the LEVEL selects the chip (`addr[25]`), idle stays 1
   (INHIBIT chip0 / NOP chip1). The init ladder runs PRECHARGE/8×REFRESH/
   LOAD-MODE for **both** chips (even/odd `reset` slots); idle-slot
   auto-refresh **alternates** chips. DQM stays aliased onto `sd_addr[12:11]`
   — that is **board wiring** (the module PCB shorts A12/A11 to DQMH/DQML;
   both are column don't-cares on every supported chip since columns stop at
   A9). This path is exercised only by 68MB, which is OSD-hidden, so it is
   **compiled but not reached** in the shipped core.
4. **Sim plumb.** `--ram 4|8|20|36|48|68` (replaces the dead 1-bit
   `cfg_memSize` LC hook) and `--sdram-module 32|64|128`: `sim_ram` (now the
   full 128MB space) emulates the physical failure modes — an undersized
   module aliases `addr[24]` / deselects `addr[25]` exactly like the real
   chips — so the 36MB-on-32MB corruption is reproducible in sim on purpose.
   NOTE the sim swaps `sdram.v` for `sim_ram`, so the real dual-chip
   controller is **never** exercised in sim; hardware is its only test.

## Hardware validation (.143, 128MB module fitted)

The bench MiSTer's module reports 128MB (`sdram_sz=3`, read from /dev/mem
`0x1FFFFF00` = `12 57 00 03` LE = signature + size 3).

| Size | About This Macintosh | Result |
|---|---|---|
| 8MB (default) | — | Boots to Finder (regression clean) |
| 36MB | Total Memory **36,864K** | Boots to Finder, stable ✅ |
| 48MB | Total Memory **49,152K** | Boots to Finder, stable ✅ |
| 68MB | — | **Freezes at the early Happy Mac** ❌ |

Evidence: `releases/hw_143_36mb_20260715.png`,
`releases/hw_143_48mb_finder_20260715.png`,
`scratchpad/hw_68mb_freeze.png`. The pre-.143 "random Finder error at 36MB"
is gone. 48MB is both a real feature (MAME-listed size, more RAM for
64MB+-module owners) and the decisive isolation probe — see below.

## 68MB: why it's deferred

68MB is the only size that crosses into the 128MB module's **second chip**
(`addr[25]→nCS`). It freezes at the early Happy Mac. Reading the signature:

- The cold RAM march evidently **passed** (the Happy Mac drew — a failed
  march shows a Sad Mac), then the OS load into high memory hung. That
  pattern = **chip-1 addresses aliasing back onto chip 0**, not a dead chip
  1: the march writes and reads "chip 1" through the same alias so it passes,
  then the OS uses low + "high" RAM and the high writes stomp the System in
  low RAM → hang. Same shape as the original 32MB-module alias, relocated to
  the chip-0/chip-1 word boundary (`$2000000`).
- **48MB isolates it.** 48MB uses *more* of chip 0 than 36MB (it exercises
  `addr[24]`/column A9 at higher addresses) and boots perfectly. So the
  26-bit widening is proven clean and the fault is **entirely** the
  `addr[25]→nCS` chip-select path.
- **Refresh-alternation is exonerated.** At 36MB and 48MB the shipped code
  already runs the halved (alternating) idle-slot refresh on chip 0 and boots
  clean, so the halved rate is adequate; refresh is not the cause.
- **Most likely cause:** `addr[25]→nCS` is not switching the physical chip on
  this module — either an nCS timing/polarity bug in `sdram.v`, or this
  particular 128MB module does not use the Sorg nCS-invert scheme the PSX
  core assumes. Cannot be bisected in sim (sim_ram replaces sdram.v).

68MB stays in the RTL and the clamp caps any stale selection to 48MB, so it
is safe; it is just not OSD-reachable until the second-chip path is fixed.

## Chronology note (for the trail)

The first build this session exposed 68MB directly (three masked CONF_STR
lines `H0`/`h0H1`/`h1` on the old 2-bit `O23`, offering up to 8/20/36/68 by
module tier). That build is what froze at 68MB. The shipped second build
dropped 68MB from the OSD, added 48MB (needing the 3rd status bit → `O234`),
and retired the now-unused 128MB menumask detection (`sdram_128`). The commit
history has both steps (`433711e` then `c1f2057`).

## Open follow-ups

- **Re-enable 68MB** once the second-chip path is confirmed against a specific
  module: identify the bench 128MB module (part number / XS-D vs other) and
  its chip-select wiring, or SignalTap the nCS line and a chip-1 access to see
  whether the second die is actually selected. When it works, re-add the
  `sdram_128` menumask bit and a `h1` CONF_STR line offering 68MB, and lift
  the clamp's cap to 68MB on a 128MB module. The RTL (`sdram.v` dual-chip
  init/refresh + `addr[25]→nCS`) is already in place.
- **Process gotcha:** blind OSD key-nav mis-selects because the MiSTer
  screenshot API does **not** capture the OSD overlay — the cursor row is
  invisible, so the owner must drive OSD Memory changes manually. Don't script
  blind `kbd:` sequences for OSD navigation; the deploy launcher's own nav is
  fine because it's timed against the menu, but in-core OSD option changes are
  not observable.
- **OSD cosmetic:** a selection made on a bigger-module machine reads as an
  out-of-range index if the SD card later moves to a smaller-module machine
  (harmless — the clamp governs actual behavior; re-selecting fixes it).
- **Unrelated, noticed again:** `verilator/check_boot.sh` still greps LC-era
  ROM PCs (`00A0xxxx`), stale for the IIvi ROM.
