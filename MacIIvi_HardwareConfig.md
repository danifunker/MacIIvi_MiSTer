# Macintosh IIvi — Hardware Configuration & MAME Implementation

A reference for the Apple Macintosh IIvi covering its data-bus layout, CPU cache, the
real-hardware vs. MAME differences, support-chip wiring, a curated subset of
compatible NuBus cards, serial/modem options, PPP networking, and the interrupt/VIA
register map.

MAME references are to the `maciivi` machine in `src/mame/apple/maciivx.cpp` and the
`VASP` system ASIC in `src/mame/apple/vasp.cpp`, plus the NuBus card infrastructure in
`src/devices/bus/nubus/`, the RS-232 devices in `src/devices/bus/rs232/`, and
`src/devices/machine/pseudovia.cpp`. Line numbers reflect the tree at time of writing.

> **The IIvi in one sentence:** a 16 MHz 68030 with NuBus, built around the **VASP**
> ASIC — which MAME's own source describes as *"basically V8 [the LC chip] with
> slightly different video and the RAM size limit lifted to 68 MB."* In other words,
> the IIvi is essentially an LC-class **16-bit-memory-bus** machine wearing a Mac II
> body. That single fact drives almost everything below, and earned the IIvx/IIvi
> their "Road Apple" reputation.

The `maciivx.cpp` driver covers two machines:

| Machine | CPU clock | FPU | L2 cache | MAME ctor |
|---|---|---|---|---|
| **Macintosh IIvi** (this doc) | **15.6672 MHz** (`C15M`) | optional (config switch) | none | `maciivx_state::maciivi`, `maciivx.cpp:424` |
| Macintosh IIvx | 31.3344 MHz (`C32M`) | 68882 standard | 32 KB | `maciivx_state::maciivx`, `maciivx.cpp:398` |

Both share the VASP ASIC, the same 1 MB ROM, Egret, 3 NuBus slots, and the **16-bit
memory bus**. The IIvx just doubles the CPU clock and adds the FPU + L2 cache — the
*bus* stays the same speed and width, which is why the IIvx is only modestly faster.

---

## Table of Contents

1. [Data-bus specifications (MAME-configured)](#1-data-bus-specifications-mame-configured)
2. [Data-bus specifications (actual hardware)](#2-data-bus-specifications-actual-hardware)
3. [CPU cache](#3-cpu-cache)
4. [Hardware layout & MAME-implementation notes](#4-hardware-layout--mame-implementation-notes)
5. [Memory map](#5-memory-map)
6. [Compatible NuBus cards (curated subset)](#6-compatible-nubus-cards-curated-subset)
7. [NuBus card connection deep-dives](#7-nubus-card-connection-deep-dives)
8. [Serial ports, modems, and PPP](#8-serial-ports-modems-and-ppp)
9. [Interrupt map (68k levels)](#9-interrupt-map-68k-levels)
10. [VIA1 register & pin map](#10-via1-register--pin-map)
11. [PseudoVIA ("VIA2") register & IRQ map](#11-pseudovia-via2-register--irq-map)

---

## 1. Data-bus specifications (MAME-configured)

The IIvi is a **68030 with a full 32-bit data bus**, and the **VASP gate array** is the
gatekeeper for memory and most I/O — exactly the V8 pattern from the LC. VASP decodes
the bus and presents the support chips at mixed widths, with the narrow devices
wrapped onto byte lanes.

This table is how the **emulator** wires the buses (a functional model — the handler
widths used in code):

| Component | MAME handler width | CPU address | Source |
|---|---|---|---|
| CPU — M68030 | **32-bit** | whole `AS_PROGRAM` | `maciivx.cpp:428` (IIvi `C15M`) |
| ROM | **32-bit** (`ROM_REGION32_BE`, 1 MB) | `0x40000000` (+ overlay at `0`) | `maciivx.cpp:438`, `vasp.cpp:56` |
| RAM (DRAM) | **32-bit** (`u32*`) | `0x00000000` | `maciivx.cpp:140`, `vasp.cpp:200` |
| VRAM | **32-bit** (`u32[]`, 1 MB alloc) | `0x60000000` | `vasp.cpp:63, 379-387` |
| VASP ASIC | mixed (sub-map) | `0x40000000–0x600FFFFF` | `maciivx.cpp:159` (`.m()`) |
| VIA1 (65C22) | **16-bit** wrapper / 8-bit core | `0x50000000` | `vasp.cpp:328-354` |
| PseudoVIA (RBV) | **8-bit** | `0x50026000` | `vasp.cpp:61` |
| ASC (sound) | **8-bit** | `0x50014000` | `vasp.cpp:59` |
| DAC / CLUT (built into VASP) | **8-bit** | `0x50024000` | `vasp.cpp:60, 389-439` |
| SCC (85C30 serial) | **16-bit** wrapper / 8-bit core | `0x50004000` | `maciivx.cpp:102-110, 161` |
| SCSI (NCR5380) PIO | **16-bit** (high byte) | `0x50010000` | `maciivx.cpp:180-194` |
| SCSI pseudo-DMA | **32-bit** (mem_mask) | `0x50006000`, `0x50012000` | `maciivx.cpp:196-240` |
| SWIM1 (floppy) | **16-bit** (high byte) | `0x50016000` | `maciivx.cpp:242-261` |
| NuBus slots $C/$D/$E | 32-bit (card-defined) | `0xFC/0xFD/0xFE000000` (slot), `0xC/D/E0000000` (super) | `maciivx.cpp:380-388` |

### Per-component detail (with source)

**CPU — Motorola MC68030, 32-bit data bus.** `maciivx.cpp:428`
`M68030(config.replace(), m_maincpu, C15M);` — IIvi clock `C15M` = 31.3344 MHz ÷ 2 =
**15.6672 MHz**. (The IIvx uses `C32M` = 31.3344 MHz at `maciivx.cpp:400`.) The 68030
has a true on-chip PMMU, so unlike the LC there is **no HMMU** glue.

**VASP memory controller — the bus decoder.** `maciivx.cpp:159` routes
`0x40000000–0x600FFFFF` into VASP with `.m(m_vasp, FUNC(vasp_device::map))`. VASP's
internal map (`vasp.cpp:54-64`) places ROM at device `0x00000000` (→ CPU `0x40000000`),
the VIA/ASC/DAC/PseudoVIA block at device `0x10000000` (→ CPU `0x50000000`), and VRAM
at device `0x20000000` (→ CPU `0x60000000`).

**ROM / RAM / VRAM — all 32-bit in MAME.** ROM is `ROM_REGION32_BE`, a single 1 MB
image (`maciivx.cpp:438-441`). RAM is handed to VASP as `m_ram->pointer<u32>()`
(`maciivx.cpp:140`) and installed by the boot-overlay handler (`vasp.cpp:200`). VRAM
is a `u32[]` with `vram_r`/`vram_w` (`vasp.cpp:379-387`).

**VIA1 (65C22) — 8-bit chip on a 16-bit window, byte-mirrored.** `vasp.cpp:328-340`
reads the 8-bit VIA and returns `(data & 0xff) | (data << 8)` (duplicated across both
lanes); writes accept either lane via `ACCESSING_BITS_*` (`vasp.cpp:343-354`). VIA
clock `C7M/10` ≈ 783.36 kHz (`vasp.cpp:82`), hence `via_sync()` cycle-stealing.

**PseudoVIA — native 8-bit, base RBV variant.** `vasp.cpp:61, 90`. Note VASP uses
`APPLE_PSEUDOVIA` (the base IIci/RBV behaviour), **not** the `APPLE_V8_PSEUDOVIA`
variant the LC uses — a small but real difference (see §11).

**ASC (sound) — 8-bit.** `vasp.cpp:59` (`ASC_V8`), output through DFAC →
speaker (`maciivx.cpp:367-369`).

**DAC / CLUT — 8-bit, built into VASP.** Unlike the LC (which has a separate "Ariel"
device), VASP implements the palette DAC directly via `dac_r`/`dac_w`
(`vasp.cpp:389-439`) at CPU `0x50024000`.

**SCC (Z85C30 serial) — 8-bit core on a 16-bit window.** `maciivx.cpp:161` + wrapper
at `maciivx.cpp:102-110`: read returns `(result<<8)|result` (mirrored), write takes
`data>>8` (high byte).

**SCSI (NCR53C80)** — PIO 16-bit high-byte (`maciivx.cpp:180-194`); pseudo-DMA 32-bit
mem_mask-driven, MSB-first byte stream (`maciivx.cpp:196-240`).

**SWIM1 (floppy) — 8-bit core on a 16-bit window, high byte**, with a 5-cycle access
penalty (`maciivx.cpp:242-261`).

---

## 2. Data-bus specifications (actual hardware)

Apple's own spec sheets describe the IIvi as a 68030 with a *"32-bit / 16-bit data
path"*: the CPU is 32-bit, but the VASP narrows the **memory and I/O system to 16
bits**, and the 68030 splits each 32-bit access into two 16-bit cycles. The CPU runs
at 16 MHz; on the IIvx the CPU runs at 32 MHz but the **motherboard/memory bus still
runs at 16 MHz / 16-bit**.

| Component | Real data-bus width | Notes |
|---|---|---|
| CPU — MC68030 @ 16 MHz (IIvi) | **32-bit core, 16-bit external path** | VASP presents a 16-bit memory port; each longword = two bus cycles. IIvx = 32 MHz CPU on the same 16-bit/16 MHz bus. |
| System / memory bus (through VASP) | **16-bit** | VASP = V8 derivative; the 16-bit bus is the defining bottleneck (the "Road Apple" cause). |
| RAM — 4 MB onboard + SIMM (max 68 MB) | **16-bit** | MAME models 4 MB soldered + one 64 MB SIMM bank = 68 MB (`vasp.cpp:8`). Real board has multiple 30-pin SIMM slots filled in pairs. |
| ROM (1 MB) | **16-bit** | On the same 16-bit VASP bus. |
| VRAM (built-in video, 512 KB) | **16-bit** | VASP framebuffer; on-board video. |
| VASP ASIC | **32-bit ↔ 16-bit bridge** | Integrates memory controller, video, ASC sound, a full VIA1, a VIA2-equivalent PseudoVIA, and glue (ADB/FDC/NuBus/SCC/SCSI). |
| VIA1 (65C22) | **8-bit** | Byte lane of the 16-bit bus. |
| PseudoVIA (= VIA2-equivalent) | **8-bit** | **Not a discrete chip** — a register block inside VASP. |
| ASC (Apple Sound Chip) | **8-bit** | Integrated into VASP. |
| CLUT / video DAC | **8-bit** | Integrated into VASP. |
| SCC (Zilog 85C30 serial) | **8-bit** | Byte lane. |
| SCSI (NCR 5380) | **8-bit** | Byte lane; pseudo-DMA streams successive bytes. |
| SWIM (floppy controller) | **8-bit** | Byte lane. |
| NuBus (3 slots, $C/$D/$E) | **32-bit** | Full 32-bit NuBus — cards transfer 32-bit even though main memory is 16-bit. |

### Reading the two tables together

Same story as the LC, one tier up:

- **CPU:** Same 68030, but MAME runs it against a 32-bit memory model and skips the
  real two-cycle-per-longword penalty (it approximates slowness via `via_sync()` and
  `adjust_icount` on slow devices).
- **RAM / ROM / VRAM:** MAME = 32-bit (`u32`); hardware = **16-bit**. This is the
  whole reason a 32 MHz IIvx barely outran a 25 MHz IIci.
- **8-bit peripherals (VIA, SCC, SCSI, SWIM, ASC, CLUT, PseudoVIA):** genuinely 8-bit
  in both columns; MAME's "16-bit wrapper" entries just place the byte on the upper
  lane of VASP's 16-bit bus (the `<<8` smear; VIA duplicates across both lanes).
- **NuBus is the exception:** the slots are full 32-bit, so NuBus cards (video,
  Ethernet) move data 32 bits at a time even though main RAM is only 16-bit wide.

**Sources:** [EveryMac — Mac IIvi](https://everymac.com/systems/apple/mac_ii/specs/mac_iivi.html),
[EveryMac — Mac IIvx](https://everymac.com/systems/apple/mac_ii/specs/mac_iivx.html),
[Apple — Macintosh IIvi Tech Specs](https://support.apple.com/kb/SP201),
[Low End Mac — Performa 600 & Mac IIvx, Road Apples](https://lowendmac.com/2014/performa-600-and-mac-iivx-road-apples/),
[Wikipedia — Macintosh IIvi](https://en.wikipedia.org/wiki/Macintosh_IIvi).

---

## 3. CPU cache

- **L1 (on-chip 68030):** **256-byte instruction + 256-byte data = 512 bytes** total
  ("0.5 KB" in Apple's spec sheets). Unlike the 68020 in the LC, the 68030 adds the
  256-byte **data** cache — a real advantage over the LC, partly offsetting the
  16-bit bus.
- **L2 cache:** **None on the IIvi.** The otherwise-identical **IIvx** carries a
  **32 KB** external L2 cache (on a dedicated cache card/slot). The IIvi shipped
  without it.
- **MAME models neither the L2 cache nor a cache/PDS slot** — the `maciivx.cpp`
  driver instantiates only the 68030 (with its built-in L1) and three NuBus slots.

Given the 16-bit memory bus, both cache levels matter more here than on a 32-bit-bus
machine: every miss pays the double-cycle penalty. The IIvx's 32 KB L2 existed
precisely to paper over the slow bus, which is why removing it (the IIvi) hurt more
than the clock difference alone would suggest.

---

## 4. Hardware layout & MAME-implementation notes

### Hardware-layout things specific to the IIvi

**1. Full 68030 + PMMU — no HMMU.** Because the 68030 has a real on-chip MMU, the IIvi
needs none of the LC's HMMU glue. There is no `hmmu_enable` callback anywhere in VASP
(contrast the LC's V8). It runs 32-bit clean.

**2. The CPU is held in reset until Egret wakes it.** As on the LC, VASP asserts
`INPUT_LINE_HALT` at reset (`vasp.cpp:170`, comment *"main cpu shouldn't start until
Egret wakes it up"*). Egret (`341S0851`, `maciivx.cpp:406-407`) releases it via
`egret_reset_w`, and Egret↔system comms ride on **VIA1's shift register** (CB1/CB2,
`maciivx.cpp:413-414`, `vasp.cpp:318-326`). A pre-Welcome boot hang is most often this
handshake or the VIA IRQ path.

**3. Classic boot-overlay trick.** At reset VASP mirrors ROM at `0x00000000`
(`m_overlay=true`, `vasp.cpp:172-182`); the first ROM fetch through `rom_switch_r`
swaps RAM back in at `0` (`vasp.cpp:190-205`).

**4. Three-level autovectored interrupts.** VASP collapses everything to 68k levels
SCC=4, VIA2/PseudoVIA=2, VIA1=1 (`vasp.cpp:257-285`). The PseudoVIA aggregates the
three **NuBus slot** IRQs ($C/$D/$E), the ASC IRQ, and screen VBL.

**5. Two 60 Hz sources.** The **60.15 Hz timer** toggles VIA1 CA1
(`vasp.cpp:163-164, 213-217`); the **real screen VBL** goes to the PseudoVIA
(`vasp.cpp:77`).

**6. Built-in video + 3 NuBus slots.** VASP provides on-board video at CPU
`0x60000000` (monitor type selectable, `vasp.cpp:33-39`). The three NuBus slots are
`nbc`/`nbd`/`nbe` = slots **$C/$D/$E** (`maciivx.cpp:386-388`), standard Mac II NuBus
(NORMAL bus mode — slot space `0xFs000000`, super-slot space `0xs0000000`).

**7. First Macs with an internal CD-ROM bay.** The IIvi/IIvx were rushed to market to
ship with a built-in CD-ROM (`maciivx.cpp:11-13`); MAME wires an Apple SCSI CD-ROM at
`scsi:3` (`maciivx.cpp:323-328`).

**8. Sound chain ASC → DFAC → speaker, Egret controls the filter.** As on the LC,
Egret programs the DFAC over an I²C-ish SCL/SDA/latch line (`maciivx.cpp:409-411`).

### MAME-implementation caveats

- **Two machines, one driver.** `maciivi` and `maciivx` differ only by CPU clock (and
  the box-ID longword: IIvx returns `0xa55a2015`, IIvi `0xa55a2016`, at `0x5ffffffc`
  — `maciivx.cpp:171-178`).
- **The 16-bit bus is not modeled as 16-bit.** RAM/ROM/VRAM are `u32`; slowness is
  approximated via `via_sync()` (`vasp.cpp:356-377`) and `adjust_icount(-5)` on slow
  devices.
- **VRAM is over-allocated.** VASP always carves a fixed **1 MB** `u32` VRAM array
  (`vasp.cpp:132`) regardless of the real 512 KB.
- **No L2 cache / no cache slot modeled** (see §3).
- **Optional FPU via config switch** on the IIvi (`maciivx.cpp:302-307, 147-150`); the
  real IIvi had no FPU, the IIvx had a 68882.

---

## 5. Memory map

CPU-side addresses (after the boot overlay is cleared):

| Range | Contents |
|---|---|
| `0x00000000–…` | RAM (overlaid by ROM at reset) |
| `0x40000000–0x4FFFFFFF` | ROM (1 MB image, mirrored) |
| `0x50000000` | VIA1 (`vasp` device `0x10000000`) |
| `0x50004000` | SCC (channel A = modem, B = printer) |
| `0x50006000` | SCSI pseudo-DMA |
| `0x50010000` | SCSI (NCR5380) registers (PIO) |
| `0x50012000` | SCSI pseudo-DMA (mirror) |
| `0x50014000` | ASC (sound) |
| `0x50016000` | SWIM1 (floppy) |
| `0x50024000` | CLUT / video DAC (in VASP) |
| `0x50026000` | PseudoVIA ("VIA2") |
| `0x60000000` | Built-in video VRAM |
| `0xC/D/E0000000` | NuBus super-slot space ($C/$D/$E) |
| `0xFC/FD/FE000000` | NuBus slot space ($C/$D/$E) |

Most I/O in the `0x50xxxxxx` block is mirrored every 1 MB (`.mirror(0x00f00000)`).

---

## 6. Compatible NuBus cards (curated subset)

The IIvi exposes its three slots with the full `mac_nubus_cards` option list
(`cards.cpp:33-56`). Below is a small, period-appropriate, genuinely useful subset for
this machine — a video card, Ethernet, and a couple of utility cards. (MAME option
name in `code`, device type in parentheses.)

| Card | MAME option | Device | What it's for |
|---|---|---|---|
| **Apple Macintosh Display Card 8•24 (MDC 1.2)** | `mdc824` | `NUBUS_MDC824` | The headline video card — up to 24-bit color at 640×480, 8-bit at higher res. *(See deep-dive.)* |
| Apple Macintosh Display Card 4•8 | `mdc48` | `NUBUS_MDC48` | Same hardware, 512 KB VRAM, 8-bit max — the budget sibling of the 8•24. |
| **Apple NuBus Ethernet** | `enetnb` | `NUBUS_APPLEENET` | 10 Mbps Ethernet (AAUI/thick). *(See deep-dive.)* |
| Apple Ethernet NB Twisted-Pair | `enetnbtp` | `NUBUS_ENETNBTP` | 10BASE-T variant (SONIC-based). |
| Asanté MC3NB Ethernet | `asmc3nb` | `NUBUS_ASNTMC3NB` | Popular 3rd-party NE2000-style Ethernet card. |
| AE QuadraLink serial | `quadralink` | `NUBUS_QUADRALINK` | Four extra serial ports — handy if you want more than the two built-in for modems/serial. |
| Brigent BootBug | `bootbug` | `NUBUS_BOOTBUG` | A debugger card; useful while bringing up a core. |
| Disk Image pseudo-card | `image` | `NUBUS_IMAGE` | MAME-only convenience: mounts a host disk image over NuBus. |

Recommended minimal loadout for a networked, color IIvi:
```
mame maciivi -nbc mdc824 -nbd enetnb
```
(`-nbc`/`-nbd`/`-nbe` choose what goes in slots $C/$D/$E.)

> The full `mac_nubus_cards` list also includes RasterOps ColorBoard 264, SuperMac
> Spectrum/8 & PDQ, Radius cards, Moniterm Viking, Lapis ProColor, Sigma LaserView,
> and more — all selectable, but the subset above is the practical core set for this
> machine.

---

## 7. NuBus card connection deep-dives

### A. Apple Macintosh Display Card 8•24 — the video card (`nubus_48gc.cpp`)

The MDC 4•8 and 8•24 are the **same board** (framebuffer controller "JMFB" + CRTC +
clock synthesiser + RAMDAC) with different ROMs, monitor profiles, and VRAM
(`nubus_48gc.cpp:5-9`). The 8•24 (`NUBUS_MDC824`, `nubus_824gc_device`) defaults to
**1 MB VRAM** (`824gc` config bit 0x10 default-on, `nubus_48gc.cpp:224-226`).

- **Capabilities:** 24-bit direct color up to 640×480; 8-bit indexed at all supported
  resolutions; 1:2:1 convolution for interlaced indexed modes (`nubus_48gc.cpp:11-17`).
  Modes implemented: 1/2/4/8 bpp indexed + 24 bpp direct (`nubus_48gc.cpp:551-575`).
- **Connection (NuBus card interface):**
  - `install_declaration_rom(GC48_ROM_REGION)` — the card's NuBus declaration ROM
    (`nubus_48gc.cpp:365`).
  - VRAM is mapped at `get_slotspace()` (e.g. slot $C → `0xFC000000`) via a
    `memory_view` (`nubus_48gc.cpp:372`), with **two view states**: state 0 = raw
    packed (indexed / 16bpp), state 1 = **RGB-unpacked** for 24-bit direct color
    (3 bytes/pixel ⇄ longwords, `nubus_48gc.cpp:430-433, 1145-1160`). The control
    register's RGB bit flips the view (`nubus_48gc.cpp:982`).
  - Registers via `nubus().install_map(card_map)` at `slotspace + 0x200000`:
    JMFB framebuffer regs `+0x200000`, CRTC `+0x200100`, RAMDAC `+0x200200`, clock
    synth `+0x200300` (`nubus_48gc.cpp:351-357`).
- **Register width:** framebuffer/CRTC registers are **16-bit** ("16 bits wide, but
  lane select is ignored and firmware relies on smearing" — `nubus_48gc.cpp:966, 1005`),
  the RAMDAC is **8-bit** (`nubus_48gc.cpp:1077`), the clock synth is **4-bit**
  (`nubus_48gc.cpp:1112`). "Smearing" = the byte-lane duplication the firmware depends
  on.
- **Monitor sense:** the card returns Apple monitor sense codes for the selected
  monitor type (`nubus_48gc.cpp:815-829`, table at `:246-265`).
- **IRQ:** VBL → `raise_slot_irq()` (`nubus_48gc.cpp:518-526`); VBL is masked via CRTC
  `0x3c` bit 1 (`:1062-1064`); writing CRTC `0x48` clears the slot IRQ
  (`:1066-1068`). The slot IRQ travels to VASP → PseudoVIA → 68k level 2 (see §9).

### B. Apple NuBus Ethernet — the network card (`nubus_asntmc3b.cpp`)

`NUBUS_APPLEENET` shares the `nubus_mac8390_device` base with the Asanté MC3NB and the
Farallon SE/30 card — all **DP8390-based, NE2000-style** designs (`nubus_asntmc3b.cpp:13-16`).

- **Chip:** National **DP8390D** Ethernet controller (`nubus_asntmc3b.cpp:121`),
  declaration ROM `aenet1` (`:40-43`).
- **No host DMA.** The CPU copies packets to/from the card's on-card RAM; the DP8390
  only DMAs *within that local buffer* (`dp_mem_read`/`dp_mem_write`, `:280-290`). The
  card carries **64 KB** of buffer RAM (`:186`).
- **Connection:** `install_declaration_rom`, then `nubus().install_device(...)` maps
  the buffer RAM at `slotspace + 0xD0000` (8-bit) and the DP8390 registers at
  `slotspace + 0xE0000` (32-bit handlers, but data on the **high byte** with an
  inverted register index `0xf-offset`, `:195-198, 233-254`). A second mapping at
  `slotspace + (slotno<<20)` provides the 24-bit-mode mirror (`:194, 197-198`).
- **Register vs. DMA:** distinguished by `mem_mask` — `0xff000000` = a register byte,
  `0xffff0000` = remote-DMA 16-bit word (`:233-266`).
- **IRQ:** `dp_irq_w → raise/lower_slot_irq` (`:268-278`).

> The **twisted-pair** sibling `enetnbtp` (`NUBUS_ENETNBTP`) instead uses a **DP83932
> "SONIC"** with 128 KB RAM, but per its own comment *"SONIC's bus-mastering
> capability appears to be unused outside of the on-card RAM, making this essentially
> the same as the DP8390x cards"* (`enetnbtp.cpp:5-11`). It maps via `install_map`
> (`enetnbtp.cpp:90`) and IRQs through `slot_irq_w` (`:60`). Pick `enetnb` for
> AAUI/thick-net or `enetnbtp` for 10BASE-T; both behave the same to software.

---

## 8. Serial ports, modems, and PPP

### The two serial ports

The IIvi has a single **Zilog Z85C30** SCC providing two channels (`maciivx.cpp:349`):

| SCC channel | MAME RS-232 slot | Real-Mac port | Wiring |
|---|---|---|---|
| A | `modem` | Modem port (DIN-8) | `out_txda → "modem"`, rxd/dcd/cts → `rxa/dcda/ctsa` (`maciivx.cpp:352, 355-358`) |
| B | `printer` | Printer/LocalTalk port | `out_txdb → "printer"`, rxd/dcd/cts → `rxb/dcdb/ctsb` (`maciivx.cpp:353, 360-363`) |

Either slot accepts any option from `default_rs232_devices` (`rs232.cpp:178-199`). For
modem/PPP work you attach a device to the **`modem`** slot (SCC channel A).

### Modem option 1 — `null_modem` (raw serial bridge)

`NULL_MODEM` (`null_modem.cpp`) is a raw serial pipe built on a **BITBANGER**
(`null_modem.cpp:29`). The bitbanger streams the SCC's bytes to/from a host endpoint
selected with MAME's `-bitbanger` option:

- a file, or
- a **TCP socket**: `socket.<host>:<port>`, or
- a named pipe: `pipe.<name>`.

```
# Bridge the IIvi modem port to a TCP socket (e.g. to reach a telnet BBS or link two Macs)
mame maciivi -modem null_modem -bitbanger socket.localhost:1234
```

It exposes configurable baud / data bits / parity / stop bits / flow control
(RTS, DTR, XON-XOFF) and CR/LF translation (`null_modem.cpp:32-59`). **Limitation:** it
is *only* a serial pipe — it does **not** emulate a Hayes modem (no `AT` command set,
no dialing), and DCD/DSR/CTS are tied to fixed states (`null_modem.cpp:88-91`).

### Modem option 2 — `pty` (pseudo-terminal, the bridge for host networking)

`PSEUDO_TERMINAL` (`pty.cpp`) connects the serial port to a host **PTY** that MAME
opens at start (`pty.cpp:75-80`). On macOS/Linux the host gets a `/dev/ttysNN` (slave)
device you can attach software to. This is the cleanest way to put host-side
networking tools behind the emulated modem port:

```
mame maciivi -modem pty          # MAME prints the slave PTY path, e.g. /dev/ttys012
```

### A "common period modem" + PPP

**Important:** MAME has **no built-in Hayes/`AT` modem device** and no simulated phone
line. A period-correct modem experience (dial tone, `ATDT`, `CONNECT`, carrier
detect) is supplied by a **host-side helper**, with MAME only bridging the serial port
out via `pty` (preferred) or `null_modem`+socket. Two common host-side pieces:

1. **tcpser** — emulates a Hayes-compatible modem on the host PTY/serial. It answers
   `AT` commands and turns `ATDT <host:port>` into a TCP/telnet connection. The Mac's
   comm software (ZTerm, MicroPhone, a PPP dialer) believes it's talking to a real
   modem. Chain: `MAME -modem pty` ⇄ `tcpser` ⇄ TCP.
2. **pppd** — the host PPP daemon attached directly to MAME's PTY; it speaks PPP to the
   Mac's PPP client and routes the Mac's IP onto the host network.

### How PPP works on this core

PPP is just a link-layer framing protocol carried over the serial line — it is not
modem-specific. The pieces:

- **On the emulated Mac** (System 7): install **MacTCP** (7.0/7.1) or **Open
  Transport/TCP** (7.5+), the TCP/IP stack, plus a **PPP client** — **MacPPP**
  ("PPP" + "Config PPP" control panels), **FreePPP**, or **OT/PPP**.
- The PPP client opens **SCC channel A** (the "modem" port), optionally runs a modem
  script (`ATDT…`) to "dial", then performs PPP **LCP/IPCP** negotiation to obtain an
  IP address and routes.
- There is no phone line in emulation; the serial bytes flow:

```
Mac PPP client → SCC ch.A → MAME "modem" RS-232 slot → pty (or null_modem+socket)
   → host pppd  → host network / Internet     (host does NAT/routing)
```

If **tcpser** is in the chain, it absorbs the `AT`/dial commands and opens the TCP
path; once "connected", PPP frames pass through transparently to a PPP server on the
far end.

**Recipe A — direct PPP via PTY + host `pppd` (macOS/Linux):**
```
mame maciivi -modem pty
# MAME prints e.g. /dev/ttys012  (the slave PTY)

sudo pppd /dev/ttys012 115200 \
     192.168.7.1:192.168.7.2 \
     noauth local proxyarp
# On the Mac: MacTCP/OT set to "PPP"; MacPPP/FreePPP "dials" (any number);
# PPP negotiates; the Mac gets 192.168.7.2 and routes through the host.
```

**Recipe B — Hayes feel via PTY + `tcpser`:**
```
mame maciivi -modem pty                      # -> /dev/ttys012
tcpser -d /dev/ttys012 -s 19200 -p 6400      # Hayes-modem emulation -> TCP/telnet
# The Mac's comm app dials ATDT<host>; tcpser bridges to TCP.
```

Notes:
- `tcpser` and `pppd` are **external host tools**, not part of MAME. MAME's job is
  only the serial bridge (`pty` / `null_modem`).
- **Match baud on both ends.** MAME's `pty`/`null_modem` default to 9600
  (`pty.cpp:56-57`, `null_modem.cpp:33-34`); for usable PPP bump both the device baud
  (via its in-emulation DIP/`-modem:...RS232_TXBAUD`) and the host tool to the same
  rate (e.g. 19200/38400/57600).
- If you'd rather have *real* Ethernet networking instead of dial-up PPP, use a NuBus
  Ethernet card (§6/§7) with MacTCP/OT in Ethernet mode — simpler and faster than PPP,
  but less period-authentic for a "modem" experience.

---

## 9. Interrupt map (68k levels)

VASP collapses everything to three autovectored levels (`vasp_device::field_interrupts`,
`vasp.cpp:257-285`):

| 68k level | Source | Wired by |
|---|---|---|
| **4** | SCC (serial) | `scc_irq_w` (`vasp.cpp:287-291`) |
| **2** | VIA2 / PseudoVIA (NuBus slots, ASC, VBL) | `via2_irq` (`vasp.cpp:251-255`) |
| **1** | VIA1 | `via1_irq` (`vasp.cpp:245-249`) |

Only the highest pending level is asserted; the previously-asserted line is cleared
first (`vasp.cpp:274-284`).

**NuBus slot IRQs** route through the PseudoVIA's slot bits (`vasp.cpp:293-306`,
`maciivx.cpp:382-384`):

| NuBus slot | VASP handler | PseudoVIA bit |
|---|---|---|
| $C | `slot0_irq_w` | `slot_irq_w<0x08>` |
| $D | `slot1_irq_w` | `slot_irq_w<0x10>` |
| $E | `slot2_irq_w` | `slot_irq_w<0x20>` |

---

## 10. VIA1 register & pin map

VIA1 is a real **Rockwell 65C22** (`R65NC22`) clocked at `C7M/10` ≈ **783.36 kHz**
(`vasp.cpp:82`), reached at **`0x50000000`**, registers spaced **0x200 apart**
(`offset >>= 8; offset &= 0x0f` in `mac_via_r`, `vasp.cpp:332-333`). Standard 6522
layout:

| Reg | Addr (`0x50000000+`) | 6522 function | IIvi use |
|---|---|---|---|
| 0 | `+0x000` | ORB/IRB (Port B) | Egret handshake (see pins) |
| 1 | `+0x200` | ORA/IRA (Port A) | mostly fixed |
| 2 | `+0x400` | DDRB | |
| 3 | `+0x600` | DDRA | |
| 4–7 | `+0x800…E00` | T1 counter/latch | timers |
| 8–9 | `+0x1000…1200` | T2 counter | timer |
| A | `+0x1400` | **SR (shift register)** | **ADB/Egret serial data** |
| B | `+0x1600` | ACR | |
| C | `+0x1800` | PCR | |
| D | `+0x1A00` | IFR | level-1 flags |
| E | `+0x1C00` | IER | |
| F | `+0x1E00` | ORA/IRA (no handshake) | |

**Port pins, as wired in VASP:**

| Pin | Dir | Function | Source |
|---|---|---|---|
| PA (in) | R | reads fixed `0xD5` | `via_in_a`, `vasp.cpp:219-222` |
| PA5 (out) | W | **floppy head-select (HDSEL)** | `via_out_a`, `vasp.cpp:234-237` |
| PB3 (in) | R | Egret transceiver session (`get_xcvr_session`) | `via_in_b`, `vasp.cpp:224-227` |
| PB4 (out) | W | Egret `set_via_full` | `via_out_b`, `vasp.cpp:239-243` |
| PB5 (out) | W | Egret `set_sys_session` | `via_out_b`, `vasp.cpp:239-243` |
| CA1 (in) | — | **60.15 Hz tick** | `mac_6015_tick`, `vasp.cpp:213-217` |
| CB1 (in) | — | Egret clock (drives the SR) | `cb1_w`, `vasp.cpp:318-321` |
| CB2 (i/o) | — | Egret data (in via `cb2_w`, out via `via_out_cb2`) | `vasp.cpp:229-232, 323-326` |
| IRQ (out) | — | → 68k **level 1** | `via1_irq`, `vasp.cpp:245-249` |

As on the LC, VIA1 is primarily the **Egret comms channel** (PB3/4/5 + CB1/CB2 shift
register) plus floppy HDSEL and the 60 Hz tick.

---

## 11. PseudoVIA ("VIA2") register & IRQ map

VASP's "VIA2" is a register block inside the ASIC — here the **base RBV** variant
`APPLE_PSEUDOVIA` (`vasp.cpp:90`), **not** the LC's `APPLE_V8_PSEUDOVIA`. It's reached
at **`0x50026000`**, a 6522-ish interface with **no timers, no shift register, no
DDRs**, decoding only A0/A1/A4 → registers 0,1,2,3,0x10,0x11,0x12,0x13
(`pseudovia.cpp:9-20`).

| Reg | Function | IIvi specifics |
|---|---|---|
| `0x00` | Port B | general GPIO (in/out B handlers) |
| `0x01` | Port A / config | in/out config handlers |
| `0x02` | Slot/VBL flag register | bit `0x40`=VBL; bits `0x20/0x10/0x08`=slots $E/$D/$C (active-low); reset `0x7f` |
| `0x03` | **IFR** | bit0=SCSI DRQ, bit1=any-slot, bit3=SCSI IRQ, bit4=ASC IRQ, bit7=summary; write to ack; reset `0x1b` |
| `0x10` | Video config | read = `montype<<3` (`via2_video_config_r`, `vasp.cpp:308-311`) |
| `0x12` | Slot interrupt enable | mask of `0x78` slot bits (`pseudovia.cpp:193-194`) |
| `0x13` | **IER** | bit7 set/clear convention; bit7 reads back as 0 (`pseudovia.cpp:242-245`) |

**IRQ aggregation (`pseudovia_recalc_irqs`, `pseudovia.cpp:190-218`):**

```
slot_irqs = (~reg2 & 0x78) & (reg0x12 & 0x78);   // enabled, active slots ($C/$D/$E)
if (slot_irqs) reg3 |= 0x02;                      // "any slot" into IFR
ifr = reg3 & reg0x13 & 0x1b;                       // mask = SCSI-DRQ|slot|SCSI|ASC
if (ifr) -> assert IRQ (reg3 |= 0x80)  else clear
```

Output → `irq_callback → via2_irq →` 68k **level 2** (`vasp.cpp:93, 251-255`).

> **LC vs IIvi PseudoVIA difference:** the LC's V8 uses the `APPLE_V8_PSEUDOVIA`
> variant where the **ASC interrupt is level-triggered** and ack is a NOP
> (`pseudovia.cpp:309-327, 354`). VASP uses the **base RBV** `APPLE_PSEUDOVIA`
> (`pseudovia.cpp:136-146`), which is edge-oriented for the ASC. If you're sharing
> code/registers between an LC core and an IIvi core, this is the one spot to watch.

---

*Generated from analysis of the MAME source tree (`src/mame/apple/maciivx.cpp`,
`src/mame/apple/vasp.cpp`, `src/devices/bus/nubus/`, `src/devices/bus/rs232/`,
`src/devices/machine/pseudovia.cpp`) cross-referenced with EveryMac / Apple / Low End
Mac / Wikipedia hardware specifications. Companion to MacLC_HardwareConfig.md.*
