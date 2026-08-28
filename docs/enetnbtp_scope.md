# NuBus Ethernet — Apple Ethernet NB Twisted Pair, 820-0511-A (2026-08-27)

Goal: the MacIIvi core gets the NuBus sibling of the MacLC's Ethernet card so
the Main_MiSTer upstream PR ships both card families. Same DP83932 SONIC, same
Main-side chip model (`support/mac/mac_sonic.cpp`, reused unchanged), same
mailbox architecture (`MacLC_MiSTer rtl/pds/pds_enet.sv` is the donor) — but
this card has **128 KiB of on-card RAM and its SONIC never touches guest
memory** (MAME: "SONIC's bus mastering capability appears to be unused outside
of the on-card RAM"). The LC's guest-RAM DMA-RPC engine is therefore absent
here; the card RAM is a plain DDR3 window both sides read and write directly.

## Card ground truth

Source: MAME 0.288 `src/devices/bus/nubus/enetnbtp.cpp` (+ `nubus.cpp`
install plumbing, `machine/dp83932c.cpp` for the register map).

- **Chip**: DP83932 SONIC @ 20 MHz; 64 × 16-bit registers.
- **declROM**: 32 KiB `341-1096.bin`, CRC32 `423f801b`,
  SHA1 `dd14bf4328d9c1ea1d2e1d441da0233e6669e919` — verified copy in
  `releases/341-1096_AppleEthernetNBTP.bin`. Apple rotl1-add CRC `985CE6D3`
  recomputes clean over the raw byte stream (length $8000, crc at tail-12).
- **★ byteLanes = $D2 — LANE 1 ONLY** (NOT the LC ROM's flat $0F). MAME
  expands ×4: raw byte i lands at guest byte `4i+1`, all other lanes $00.
  Guest footprint = 128 KiB at the TOP of standard slot space:
  `$FsFE0000-$FsFFFFFF` (install addr = slotspace + 0x1000000 − romlen).
- **Card map** (MAME `card_map()`, card-relative; installed in the 16 MiB
  STANDARD slot space only — `install_map`, not `install_super_map`, so
  super-slot $s000'0000 stays empty):

  ```
  0x000000-0x01FFFF  card RAM (128 KiB)
  0x0C0000-0x0C00FF  SONIC registers: 16-bit at consecutive WORD addresses,
                     reg index = A[6:1], first 0x80 bytes; 0x80-0xFF unmapped
  0x400000-0x40000F  MAC PROM, umask32(0x00ff00ff): PROM byte k at guest
                     byte 2k+1 (ODD bytes / 16-bit low lanes); even bytes $00
  0xC20000-0xC3FFFF  card RAM alias
  0xFE0000-0xFFFFFF  declaration ROM (lane-1 expanded, see above)
  ```

- **MAC PROM content**: OUI forced to Apple's `08:00:07`, then 3 configured
  bytes; each byte bit-swizzled `bitswap<8>(b, 0,1,2,3, 7,6,5,4)`; byte 6 =
  $00; byte 7 = XOR of bytes 0-5, complemented. Identical cooking to the LC
  card (Main's `stage_macprom()` unchanged; Main already uses OUI 08:00:07).
- **SONIC's own bus**: the card's private space, where card RAM ALSO appears
  at `slot_base+0..0x1FFFF`. The driver programs descriptor/buffer addresses
  as full guest slot addresses (`$Fs00xxxx`); the model's memory backend masks
  addresses to the 128 KiB window (`& 0x1FFFF`). Main therefore runs the
  SONIC model with `sonic_set_addr_bits(32)` — no 24-bit stripping, and the
  `ea_strip` witness stays meaningful.
- **IRQ**: SONIC INT (level) → slot /NMRQ → pseudoVIA slot-IFR bit → IPL 2.

## Core integration (MacIIvi specifics)

- **Slot $C** (`SLOT_ID = 4'hC`): $E is the mdc824 display card, $D stays
  free. Decode = standard slot space `cpuAddr[31:24] == 8'hFC` only. The
  card claims ONLY the mapped regions above; everything else in slot space
  keeps the top's HW-validated 32-clk open-bus $FFFF timeout (empty-slot
  convention, mdc824-era). PMMU note: unlike the LC (no MMU → the core needed
  a 24-bit decode), the IIvi's 68030 translates 24-bit-mode slot windows in
  the PMMU, so physical addresses here are always the 32-bit forms.
- **IRQ** → `pseudovia.slot_irq_c` (active high), beside the mdc824 on
  `slot_irq_e`.
- **Ack/data mux**: the card presents `card_sel/card_ack/card_dout`
  (pds_enet conventions); the top muxes it ahead of the mdc824 into the
  existing `nubusAck_card/nubusDataOut_card` pair — the timeout path is
  unchanged. Both tops (MacIIvi.sv, verilator/sim.v) in lockstep.
- **OSD**: `OJ,Ethernet,Off,On` (status[19] = ena_osd), plus the Main-owned
  `o45,Net interface` (status[37:36]) and `o03,MAC suffix` (status[35:32]) —
  the SAME bit addresses as MacLC, so Main's `mac_eth.cpp` option reads work
  for both cores without per-core tables.

## DDR3 window v3 (contract; core RTL + Main implement from THIS table)

ARM phys `0x1FF00000` (DDRAM u64 word `0x03FE0000`), `DDRAM_CLK = clk_sys`,
single domain. Same base as the LC/a2065 windows — only one core is loaded at
a time — but layout v3 with its own MAGIC, so a stale host/FPGA of either
family can never half-pair. Window size 0x29000 bytes.

```
+0x00000  128 KiB  CARDRAM  card RAM: window byte i = card byte i
+0x20000   32 KiB  ROMRAW   RAW declROM: window byte i = ROM byte i
                            (the FPGA does the lane-1 expansion on reads;
                            Main stages the file verbatim, no expansion code)
+0x28000   u64[]   control block (same word layout as the LC v2 block):
   w0  +0x00 MAGIC    ARM→FPGA  "McNBETH3" (64'h4D634E42_45544833)
   w1  +0x08 CMD_WPTR FPGA→ARM  32-bit monotonic doorbell write index
   w2..w17  SHAD      ARM→FPGA  64 regs × 16-bit, word n = regs 4n..4n+3
   w18 +0x90 INT      ARM→FPGA  bit0 = SONIC INT line
   w19 +0x98 MACPROM  ARM→FPGA  8 cooked PROM bytes (byte k = PROM byte k)
   w20 +0xA0 GEOMETRY ARM only  layout version = 3
   w21 +0xA8 RPTR     ARM→FPGA  ring read index (backpressure)
   w22/w23             reserved (the LC's DMA_CMD/DMA_STAT slots; unused)
+0x28800  2 KiB    CMD RING  256 × u64, entry format identical to v2:
                            [0] valid | [3:1] tag (0=REG_WR, 1=RESET)
                            | [9:4] reg | [31:16] data | [39:32] seq
```

Byte order: u64 byte k (bits [8k+7:8k]) = window byte 8w+k — the established
"guest byte A = window byte A" mailbox convention (ARM sees a plain byte
array; the FPGA picks byte lanes from addr[2:0]).

## FPGA front-end (rtl/nubus/nubus_enetnbtp.sv)

Donor: `pds_enet.sv` minus the DMA engine (no eth port, no V8 translation, no
XFER phases), plus the card-RAM window server. Kept verbatim: presence latch
(MAGIC ∧ ena_osd sampled during guest reset, sticky for the session), RESET
doorbell on warm restart, monotonic-wptr doorbell FSM + rptr backpressure,
poll walk (MAGIC, SHAD×16, INT, MACPROM, RPTR — the DMA_CMD step dropped),
the timed ISR clear-mask + irq-suppression timer (interrupt-ack livelock
fixes), and the ~4 ms host-access watchdog (open-bus retire).

Per-region behavior (sub = cpuAddr[23:0], word-aligned; strobes pick bytes):

- **Card RAM** (both windows): reads = one DDR3 u64 read, lanes from
  sub[2:0]; writes = one DDR3 write with byte enables from the strobes
  (posted; the cycle retires when the controller accepts it). No RMW needed.
- **SONIC regs**: reads served from the shadow block (reg = sub[6:1]; ISR
  reads masked by the timed clear-mask); full-word writes post a REG_WR
  doorbell (DTACK stretches only until the ring entry + wptr are in DDR3);
  byte writes and the unmapped 0x80-0xFF half serve $FFFF/complete inert.
- **MAC PROM**: instant from the MACPROM control word: data = {8'h00,
  prom[sub[3:1]]} (even lane $00 = MAME's unmapped-lane fill). Writes inert.
- **declROM**: sub[1]==1 (guest bytes ≡2,3 mod 4) serves a constant $0000 —
  no DDR3 trip; sub[1]==0 fetches raw byte r = sub[16:2] from ROMRAW and
  serves {8'h00, raw[r]} (guest byte 4k+1 on the low lane).

## Main side (support/mac, branch mac-ethernet-pr)

- `mac_eth.h`: v3 layout constants + MAGIC beside the v2 set.
- `mac_eth.cpp`: a card-personality switch on the exact core name — `maclc` =
  LC card (all current behavior), `maciivi` = NB card. NB differences:
  - `sonic_host_ops` backend = direct window access: read/write the CARDRAM
    bytes at `(addr & 0x1FFFF)` (words BE, stride 2/4 per the model's
    contract) — no DMA-RPC, no bounce, no spin.
  - declROM staging = copy the RAW file into ROMRAW verbatim.
  - `declrom_valid()` byteLanes check becomes per-personality ($0F for LC,
    $D2 for NB) — everything else (testPattern, length, Apple CRC over the
    raw stream) is common and already correct for both ROMs.
  - `sonic_set_addr_bits(32)`; guest MAC core byte 'V' (the LC keeps 'L');
    GEOMETRY = 3; MAGIC v3; window map size 0x29000.
  - eth.cfg `addrbits=` is LC-only generality; the NB personality ignores it
    (flagged to the owner as an open decision rather than removed).
- `mac_sonic.cpp/.h`: byte-identical — the model needs nothing.
- Asset: `games/MacIIvi/ethernet.rom` = the raw 341-1096 dump (validated at
  load exactly like the LC path; `core_has_card()` already keys on the file).

## Gates

1. Unit TB `verilator/tb_enetnbtp.v` (sim_ddr3-backed) green.
2. Both tops build; boot-smoke card-absent unchanged.
3. `mac_sonic_test` 104/104 cross-branch; `romtest` green with the NB ROM
   added; ARM build zero-warning.
4. Quartus fit: A&E clean, STA met, per-seed HW video+boot law.
5. HW (.143): desktop card-present AND card-absent; 3 MB FTP both ways.
   LC regression on .94 unchanged.
