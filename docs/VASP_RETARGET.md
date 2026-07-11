# V8 → VASP retarget plan (MacLCII base → Macintosh IIvi)

*Design record for turning the imported MacLCII core (commit `a254a02`) into a
Macintosh IIvi. Facts verified against the local MAME tree
(`../mame`, `src/mame/apple/maciivx.cpp`, `vasp.cpp`, `v8.cpp`,
`src/devices/machine/pseudovia.cpp`) on 2026-07-11. Companion to
[MacIIvi_HardwareConfig.md](../MacIIvi_HardwareConfig.md) (machine reference)
and [68030_CPU_IMPLEMENTATION_PLAN.md](../68030_CPU_IMPLEMENTATION_PLAN.md)
(CPU heritage).*

## The one-sentence summary

MAME (`maciivx.cpp:15`): *"They run on the 'VASP' system ASIC, which is
basically V8 with slightly different video and the RAM size limit lifted to
68 MB"* — so the IIvi core **is** the LC II core with a 32-bit address map,
a bigger contiguous RAM ceiling, a 1MB ROM, the base-RBV pseudoVIA variant,
and three NuBus slots. Same 15.6672 MHz 68030, same 16-bit memory bus, same
V8-type ASC, same Egret protocol (different firmware), same SCC/SCSI/SWIM at
the same relative offsets.

## Address map: 24-bit V8 → 32-bit VASP

The LC II decode (`global_mask(0x80ffffff)`, ROM at $A00000, I/O at $F0xxxx)
is replaced by the full 32-bit VASP map:

| CPU range | Contents | Notes |
|---|---|---|
| `$00000000 + ram` | RAM, contiguous | overlay: ROM mirrored here at reset; any ROM-region read clears it (MAME `vasp.cpp rom_switch_r`) |
| `$40000000-$4FFFFFFF` | ROM 1MB | mirrored every 1MB (`mirror(0x0ff00000)`) |
| `$50000000 block` | I/O, mirrored every 1MB (`mirror(0x00f00000)`) | same low-offset layout as V8's $F0xxxx block: |
| ` +$00000` | VIA1 | $200 stride, upper byte, 16 regs |
| ` +$04000` | SCC | |
| ` +$06000` | SCSI pseudo-DMA | |
| ` +$10000` | SCSI (NCR5380) PIO | |
| ` +$12000` | SCSI pseudo-DMA mirror | |
| ` +$14000` | ASC (V8/EASC type) | |
| ` +$16000` | SWIM | |
| ` +$24000` | VDAC/CLUT (inside VASP; LC used the discrete Ariel — same address, same interface) | |
| ` +$26000` | PseudoVIA | base-RBV variant (see below) |
| `$5FFFFFFC` | box-ID longword, reads **$A55A2016** (IIvi; IIvx=$...15) | |
| `$60000000-$6FFFFFFF` | onboard-video VRAM window (512KB, mirrored) | deprioritized — mdc824 NuBus card is the primary display |
| `$FC/FD/FE000000` | NuBus slot space $C/$D/$E | declaration ROM probing; empty slots BERR via arbiter timeout |
| `$C0/D0/E0000000` | NuBus super-slot space | |

24-bit compatibility mode needs **no hardware translation** on an 030 Mac —
the OS implements it with the PMMU (which this CPU core has); MAME's `maciivi`
models none either. The LC II core's FC=7 probe/IACK handling, SCSI pseudo-DMA
DTACK gating, and periph_din_reg staging all carry over; region tests move
from `cpuAddr[23:...]` to the full 32-bit decode.

## RAM: contiguous, no V8 config-register banking

MAME's VASP takes `set_ram_info(ptr, size)` and installs one contiguous block
at $0 — there is **no** SIMM/motherboard placement register dance like V8
(`v8.cpp ram_size()`), and vasp.cpp connects no pseudoVIA config handlers.
The ROM sizes memory by probing. Consequences:

- `addrController`/`addrDecoder` drop `ram_config`/`ram_config_phys`/
  `ram_configured` banking entirely: `selectRAM = addr < ram_size` (plus
  overlay), SDRAM mapping is `base + offset`.
- The pseudoVIA RAM-config register becomes what MAME has: reg $01 reads via
  the (unconnected → 0) config handler, writes dropped.

### Verified size options (OSD: 4/8/20/36 MB)

MAME `maciivx.cpp:316`: default `4M`, extras `8M,16M,32M,36M,48M,64M,68M`
(model: 4MB motherboard + one SIMM bank up to 64MB).
Real IIvi: 4MB soldered + 4× 30-pin SIMM slots (one bank).

| OSD | Composition | Validity |
|---|---|---|
| 4MB | motherboard only | Apple base config; MAME default |
| 8MB | 4 + 4×1MB SIMMs | Apple-supported; MAME option |
| 20MB | 4 + 4×4MB SIMMs | Apple-supported real config; **not** in MAME's list (their list is round numbers, not bank math) — contiguous model boots regardless |
| 36MB | 4 + 32 (4×8MB) | in MAME's list; 8MB 30-pin SIMMs are nonstandard-but-real |
| *68MB* | 4 + 4×16MB | hardware max — **deferred**: doesn't fit a 64MB SDRAM module; revisit for 128MB modules |

36MB requires a 64MB SDRAM module (gate via `sdram_sz` from hps_io; hide the
OSD option or clamp when only 32MB is present). 4/8/20 fit 32MB modules with
the layout below.

### New SDRAM layout (16-bit word addresses, 25-bit space)

Fixed regions LOW so small-RAM configs work on 32MB modules; RAM after:

| SDRAM words | Contents |
|---|---|
| `$0000000-$007FFFF` | ROM (1MB) — also the boot0.rom download target |
| `$0080000-$00BFFFF` | onboard-video VRAM (512KB) |
| `$0100000-$017FFFF` | reserved: mdc824 VRAM (1MB) if it lands in SDRAM |
| `$0180000-$027FFFF` | floppy image 1 (2MB window) |
| `$0280000-$037FFFF` | floppy image 2 (2MB window) |
| `$0380000 + word` | RAM, contiguous (4/8/20/36MB → tops out at `$157FFFF`) |

20MB config ends at `$D7FFFF` (< 32MB module limit ✓); 36MB ends at
`$157FFFF` (64MB module ✓). `sdram.v` grows `addr` to `[24:0]`; on 64MB
modules (MT48LC32M16: 10-bit column) `addr[24]` drives column A9. The LC II
`mb_hi` upper-16MB relocation trick is retired — the address is linear now.

## PseudoVIA: V8 variant → base-RBV variant

`vasp.cpp:90` instantiates `APPLE_PSEUDOVIA` (base RBV behavior), not the
`APPLE_V8_PSEUDOVIA` the LC II uses. Deltas to port into `rtl/pseudovia.sv`
(from `pseudovia.cpp`):

1. **ASC IRQ is edge-set + W1C-acked** (base `asc_irq_w`: sets IFR bit 4 on
   the source's rising edge only; IFR write with bit 4 clears it). The V8
   variant is level-follow with ack-NOP — the LC II RTL models that today.
2. **Three slot bits**: reg $02 bits 3/4/5 = NuBus slots $C/$D/$E
   (active-low), VBL stays bit 6. Slot summary → IFR bit 1 gated by slot
   IER $12 (mask 0x78) as today.
3. **Reg $01 (config)**: read = 0 (unconnected handler on VASP), write
   dropped. Kill the `ram_config_out`/`ram_configured` outputs.
4. **Reg $10 (video)**: read = stored value with bits [5:3] replaced by
   `montype << 3` (base variant keeps the other stored bits — the LC II RTL
   currently returns montype only).
5. Reset values per MAME `device_reset`: reg2=$7F, reg3=$1B. IER $FF-write
   quirk (→$1F) already matches.
6. IFR semantics mask stays $1B (SCSI DRQ=0, any-slot=1, SCSI IRQ=3, ASC=4).
   SCSI IRQ/DRQ stay LEVEL (unchanged from LC II — MAME scsi_irq_w/drq_w
   follow the line both ways). NOTE: whether to *wire* the SCSI flags is a
   bring-up decision — the LC II core ties them off for a documented System 7
   crash; re-evaluate against MAME maciivi behavior during bring-up.

## Machine variants (one board, one ROM, three personalities)

The IIvi/IIvx/Performa 600 share the motherboard, VASP, and this exact 1MB
ROM. The ROM picks the personality from the box-ID longword at $5FFFFFFC:
its reader at $4084AB2A does `and.l #$7` and indexes the 8-byte BoxFlag
table at $4084AB4A (disassembly-verified):

| boxID & 7 | BoxFlag | Machine |
|---|---|---|
| 5 ($A55A2015) | $2A | Macintosh IIvx (32MHz, 68882, 32KB L2 — NOT this core yet) |
| 6 ($A55A2016) | $26 | **Macintosh IIvi** (also the fallback for unknown IDs) |
| 7 ($A55A2017) | $31 | **Performa 600** |

The OSD "Machine" option (status[4], reset-applied) switches the box-ID
between IIvi and P600. Both run the IIvi 16MHz CPU clock for now — the
P600's 32MHz CPU mode is tracked as follow-up work (the 16-bit 16MHz bus
is identical on real hardware; only internal CPU cycles differ). An IIvx
mode would additionally need the FPU (deliberately omitted, decision D2)
and the L2 model, so it stays out of scope.

## What carries over UNCHANGED

- **ASC**: `vasp.cpp:95` = `ASC_V8(config, m_asc, C15M)` — the exact type the
  LC II already implements. **No new ASC needed.** (Downstream DFAC exists on
  real hardware for volume/filter; MAME routes ASC→DFAC→speaker. Skip DFAC
  initially, like the LC II core does.)
- **Clocks**: C15M = 15.6672 MHz CPU ("16 MHz"), C7M/10 VIA1, SCC/SCSI clocks
  — identical to LC II. No PLL changes.
- **Egret protocol/wiring** (VIA1 CB1/CB2/PB3/PB4/PB5), 60.15Hz CA1 tick.
  Firmware changes to **341S0851** (`rtl/egret/341s0851.bin`, already present;
  regen `rtl/egret/egret_rom.hex` via `convert_firmware.py`).
- **SCC / SCSI(+pseudo-DMA semantics) / SWIM** at the same relative offsets,
  same byte lanes (upper byte, even addresses).
- **Interrupt levels**: SCC=4, pseudoVIA=2, VIA1=1, autovectored; NMI=7 debug.
- **VIA1 pin map** (PA5 HDSEL, PB3/4/5 Egret, CA1 tick); `via_in_a` constant
  becomes **$D5** (`vasp.cpp via_in_a`; LC=$D4|FPU, core currently $55 — the
  IIvi ROM gets the MAME-truth value from day one).

## NuBus (new vs LC II; RTL already in `rtl/nubus/` from lbmactwo)

- Slots $C/$D/$E; mdc824 in slot $C as primary display, others empty
  (BERR on timeout — `nubus_arbiter.sv` carries the timeout logic).
- Slot IRQs → pseudoVIA reg2 bits 3/4/5.
- Integration pattern from `../lbmactwo_MiSTer` (its dataController/
  addrController hooks + `TG68K_WIRING_NOTES.md`).
- Declaration ROM: `mdc824.rom` (32KB) — hex into BRAM or SDRAM lane; check
  lbmactwo's `boot2.hex` convention.
- Video output mux: mdc824 scanout becomes the MiSTer video out; the LC
  V8 video module stays for the onboard framebuffer until VASP video is done
  (montype can also report "no monitor" to push the ROM to the NuBus card).

## Known LC-II-isms to retire during bring-up

- `sdram_out_patched` cold-boot branch patch targets the **LC II ROM**
  ($4655E `bne.w`); guarded by address+opcode so it's inert for the IIvi ROM,
  but remove/re-derive once IIvi warm-reset behavior is understood.
- The FC=7 `moves` probe → BERR behavior (STM diagnostic avoidance) was
  LC-ROM-derived; the IIvi ROM has its own probe patterns — keep the FC=7
  fault correct (it's architecturally right) and re-verify against MAME.
- `slot_space` VPA/$FFFF handling ($F1-$FE) predates real NuBus; replaced by
  the arbiter + BERR path when NuBus lands.
- OSD "Monitor" option and montype values: IIvi onboard video sense codes are
  1 (Portrait) / 2 (12" RGB) / 6 (13" RGB) per `vasp.cpp` — same encoding the
  LC II uses today.

## Post-a254a02 MacLCII cherry-pick candidates (deliberately NOT imported)

| Commit | What | When to consider |
|---|---|---|
| `363b978` | SCSI: fail-open dead pseudo-DMA DACK accesses | if disk boots hang like the LC II POP-intro freeze |
| `ddad62a` | pseudo-VIA rewritten as faithful MAME v8_pseudovia port | reference for the RBV-variant rewrite (do not copy verbatim — different variant) |
| `83ccf91` | ~1.5× faster Verilator build (drop trace/timing) | early — build speed pays for itself |
| `7f3a952`/`b1fb014` | BRAM/PIPT 2KB I-cache work | after boot is stable; CPU-side change (sync rule: adopt via MacLCII, keep kernels identical) |
| `f3f2c2d`+ | video fixed-PLL / pixel-clock work | only if V8-video-derived scanout misbehaves |

## CPU sync rule (unchanged)

`rtl/tg68k/` stays **byte-identical** to MacLCII's — currently pinned at
`a254a02`. CPU changes are made in the MacLCII repo first (where the LC II
boot is the silicon oracle), then re-copied here. Do not fork the kernel.
