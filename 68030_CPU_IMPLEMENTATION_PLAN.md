# MacIIvi — 68030 + PMMU + Cache CPU Implementation Plan

*Companion to [68030_PMMU_TESTBENCH.md](68030_PMMU_TESTBENCH.md) (the test/oracle
campaign) and [MacIIvi_HardwareConfig.md](MacIIvi_HardwareConfig.md) (the target
machine). This document is the **RTL merge/integration plan**: how to build the
core's CPU by merging the Mac bus integration from `../MacLC_MiSTer` with the
MC68030 PMMU + cache work from `../Minimig-AGA_MiSTer` (branch `030_mmu2_fpu2`).*

---

## 1. Goal

Replace MacIIvi's current CPU (the MacLC TG68K integer core, ghdl-converted to
Verilog, **no PMMU, no caches**) with a true **MC68030**:

- on-chip **PMMU** (PMOVE/PTEST/PLOAD/PFLUSH, TC/TT0/TT1/CRP/SRP/MMUSR, 22-entry
  ATC, format-$B fault frames, vector-2 MMU faults);
- the **68030 internal caches** — 256 B instruction + 256 B data, controlled via
  `MOVEC CACR/CAAR`, with bus cache-inhibit for I/O space;
- driven inside the Mac (VASP) bus exactly where MacLC drives its CPU today;
- validated with the **Verilator** harness + the **SingleStepTests** CPU and
  PMMU corpora.

No FPU in the stock IIvi (the 68882 socket is empty). See §3 decision D2.

## 2. Source inventory

### From `../Minimig-AGA_MiSTer` (branch `030_mmu2_fpu2`) — the 68030 core (VHDL)
| File | Role |
|---|---|
| `rtl/tg68k/TG68K.vhd` | Top wrapper. Generics `CPU="10"` (68030), `FPU_Enable`, `FPU_Transcendental_Enable`, `FPU_Packed_Decimal_Enable`. Async bus (ADDR/FC/DATA/AS/UDS/LDS/RW/DTACK), sync bus (E/VPA/VMA), **cache iface** (cache_req/addr/data/ack/burst/burst_len/hit/miss). |
| `rtl/tg68k/TG68KdotC_Kernel.vhd` | Integer kernel, extended for 030 (MOVEC CACR/CAAR, MSP/ISP, PMMU decode, format-$A/$B frames). |
| `rtl/tg68k/TG68K_PMMU_030.vhd` | PMMU: table walker, 22-entry pseudo-LRU ATC, PTEST/PLOAD/PFLUSH, MMUSR. |
| `rtl/tg68k/TG68K_Cache_030.vhd` + `TG68K_CacheCtrl_030.vhd` | 68030 internal I/D caches + controller. |
| `rtl/tg68k/TG68K_ALU.vhd`, `TG68K_Pack.vhd` | ALU + package. |
| `rtl/tg68k/TG68K_FPU*.vhd` | Full 68881/882 FPU — **not ported** (D2: stock IIvi has no FPU). |
| `rtl/cpu_wrapper.v`, `Minimig.sv` | Reference for bus integration: logical→physical translation in the bus path, `pmmu_suppress_bus`/`walker_active`, cache fill arbitration (`cache_ramaddr`), `pmmu_cache_inhibit`. **Not copied — read as the integration pattern.** |
| `tests/tg68k_030/*` | ~50 VHDL regression benches (PMMU/cache/RTE/trace/MOVES). **Carried** into MacIIvi as a VHDL-source gate (D5). |
| `030_MMU_PORT_AUDIT.md`, `MMU_AUDIT.md` | The compliance record for the port (vector 2, ATC=22, MMUSR width, etc.). Required reading before touching the PMMU. |

### From `../MacLC_MiSTer` — the Mac bus integration (the "CPU code")
| File | Role |
|---|---|
| `rtl/tg68k/tg68k.v` | The async-bus wrapper that adapts TG68 to the Mac (auto-vector IACK, E/VMA/VPA, longword flag, BERR/RTE inhibit). The template for MacIIvi's wrapper. |
| `rtl/addrController_top.v`, `rtl/dataController_top.sv` | How the CPU's address/data/FC/IPL/DTACK are driven from the VASP-equivalent chipset + SDRAM. |

### Already in MacIIvi
- `rtl/tg68k/` — the **old** PMMU-less Verilog CPU (to be replaced) + `convert_to_verilog.sh` (ghdl) + `TG68K.qip`.
- `SingleStepTests/` — CPU corpus (68030-captured) + 40-row PMMU corpus + `gen/` capture pipelines.
- `verilator/` — full-system sim (`sim.v`, `sim_ram.v` = behavioral SDRAM, `sim_main.cpp`).

## 3. Key decisions

- **D1 — VHDL is the source of truth; ghdl → Verilog is the build step.**
  The Minimig work is VHDL and the master plan (§9) already mandates fixing in
  VHDL and re-running `convert_to_verilog.sh`. Verilator cannot simulate VHDL, so
  the converted `.v` is what both Quartus and the Verilator bench consume.
  *Consequence:* every CPU change is a VHDL edit + a conversion run.
- **D2 — FPU: omitted entirely.** The stock IIvi has no FPU; F-line traps are
  taken by the kernel and are covered by the CPU corpus. Do **not** copy the
  `TG68K_FPU*.vhd` files; instantiate `TG68K` with `FPU_Enable=0` and stub the
  FPU-shell port if the wrapper still requires the entity to exist. A future
  **IIvx 32 MHz** mode can re-import the FPU.
- **D3 — Caches: the 68030 internal I/D caches (`TG68K_Cache_030`) only**, not
  Minimig's external `cpu_cache_new.v` (that's a Minimig accelerator, not a 68030
  architectural feature). This is the "correct caches" requirement.
- **D4 — Reuse the bus position, rewrite the wrapper.** Keep MacLC's chipset/SDRAM
  drive points; replace the thin `tg68k.v` with an 030-aware wrapper that carries
  the cache + MMU-translation interface (modeled on Minimig `cpu_wrapper.v`).
- **D5 — Carry the Minimig VHDL bench suite.** Import `tests/tg68k_030/` as a
  VHDL-source gate (adds a ghdl/ModelSim dependency); see §6.

## 4. Target module hierarchy

```
MacIIvi.sv
└─ <chipset: VASP-equivalent addr/dataController>     (from MacLC, retargeted)
   └─ cpu030_wrapper.v        NEW — Mac-bus ↔ 030 glue (modeled on cpu_wrapper.v)
      ├─ TG68K (CPU="10", FPU_Enable=0)               (converted from Minimig VHDL)
      │   ├─ TG68KdotC_Kernel
      │   ├─ TG68K_PMMU_030      (logical→physical, ATC, walker)
      │   ├─ TG68K_Cache_030 + CacheCtrl  (I/D caches)
      │   └─ TG68K_ALU      (no FPU — F-line traps, D2)
      ├─ logical→physical mux + pmmu_suppress_bus / walker_active
      ├─ cache fill arbitration → SDRAM read path
      └─ cache-inhibit (CIIN) decode for VASP I/O ($50xxxxxx), VRAM, NuBus
```

## 5. Phased implementation (each phase gated by a test)

### Phase 0 — Import the VHDL core and get it converting
- Copy the Minimig `030_mmu2_fpu2` `rtl/tg68k/*.vhd` (kernel, PMMU_030, Cache_030
  + CacheCtrl, ALU, Pack, TG68K.vhd) into `MacIIvi/rtl/tg68k/`, replacing the
  PMMU-less set. **Do not** copy the `TG68K_FPU*.vhd` files (D2).
- Update `TG68K.qip` + `convert_to_verilog.sh`: add the PMMU/Cache files, set
  kernel/wrapper generics for the 030 (`CPU="10"`, `FPU_Enable=0`), keep the
  existing synthesis params (`SR_Read=2`, `VBR_Stackframe=2`, `extAddr_Mode=2`, …).
  Resolve any FPU-shell references left by `FPU_Enable=0` (stub or guard).
- Import Minimig `tests/tg68k_030/` into MacIIvi for the VHDL-source gate (D5).
- **Gate:** `./convert_to_verilog.sh` produces Verilog with no ghdl errors;
  Quartus *Analysis & Elaboration* of the generated `.v` passes.

### Phase 1 — Verilator CPU bench green (integer ISA)
- Point `SingleStepTests/tg68k/` (the Verilator CPU bench) at the converted 030
  Verilog as DUT.
- Run the 68030-captured single-step corpus.
- **Gate:** reproduce the documented pass/fail census (known TG68K-kernel bugs
  aside, per `test-blockers.md`); the three 030 discriminator rows (CACR
  all-ones `D1=$0000FF13`, CALLM/RTM illegal-trap) behave per `68030_PMMU_TESTBENCH.md` §2.

### Phase 2 — Drop the 030 into the Mac bus
- Write `cpu030_wrapper.v`: adapt MacLC's `tg68k.v` to the 030 entity — auto-vector
  IACK, E/VMA/VPA for the VIA, IPL, DTACK, BERR, longword. Leave cache + MMU
  interfaces in pass-through/identity for now (`cpucfg`-style 030 enable).
- Replace the CPU instance in the MacIIvi chipset with the wrapper.
- **Gate:** in the `verilator/` full-system sim, the gathered IIvi ROM boot-overlay
  works — reset overlay maps ROM at 0, first fetch flips RAM in (per
  `MacIIvi_HardwareConfig.md` §4.3); CPU fetches real ROM from `sim_ram`.

### Phase 3 — Wire the 68030 caches (the "correct caches" requirement)
- Connect `cache_req/addr/data/ack/burst/burst_len` to the SDRAM read path; honor
  `cache_hit` on `cpu_din` (guard against walker reads — Minimig BUG #406).
- Drive **cache-inhibit** for non-cacheable space: VASP I/O `$50000000` block,
  VRAM `$60000000`, NuBus `$C/D/E…`/`$FC/FD/FE…`. CACR/CAAR already in the kernel.
- **Gate:** CACR discriminator corpus rows green; sim shows I/O reads bypass the
  cache and RAM reads populate it; ROM boot unaffected.

### Phase 4 — PMMU translation in the bus path (the merge core)
- Insert logical→physical translation (`pmmu_addr_log → pmmu_addr_phys`) ahead of
  the SDRAM address; suppress the external bus during walks
  (`pmmu_suppress_bus`/`walker_active`); point the descriptor walker at Mac RAM.
- Build out per the master plan's PMMU ladder, each rung gated by PMMU-corpus rows:

  | Rung | RTL brought live | Corpus rows (of 40) |
  |---|---|---|
  | 1 | PMOVE reg file + F-line decode (trap 68851-only ops) | 16 PMOVE round-trips |
  | 2 | Table walker (short/long, early-term, limits, U/M) + PTEST/PLOAD | 11 PTEST/PLOAD |
  | 3 | Translation datapath + TT0/TT1 matching | identity / remap / M-U |
  | 4 | ATC (22-entry) + PFLUSH variants | 2 ATC-staleness rows |
  | 5 | Format-$B fault frames + restart; MMU-config exception (vec 56) | 3 fault rows |

- Cross-check against the carried Minimig VHDL benches if D3 = yes.
- **Gate:** all 40 PMMU corpus rows green (modulo the two known MAME quirks the
  testbench plan flags for LC-II adjudication).

### Phase 5 — Full-system bring-up
- Boot the IIvi ROM with MMU + cache enabled in the Verilator full sim; wire
  `cpu_ce` (16/32 MHz) and the 62.6688 MHz PLL regeneration.
- **Gate:** ROM reaches Egret handshake / early boot; then synthesize and bring up
  on FPGA. Physical adjudication follows the LC-II campaign (testbench plan §7).

## 6. Test strategy

- **Primary (per the user's ask):** the Verilator `SingleStepTests/tg68k/` CPU
  bench + the 40-row PMMU corpus in `results/pmmu/`. These are the acceptance gates
  in §5.
- **Secondary (D5, carried):** the Minimig `tests/tg68k_030/` VHDL benches — the
  exact regressions that proved the port (ATC, walker, RTE/format, trace, MOVES).
  They validate the **VHDL source** before conversion; run under ghdl/ModelSim.
- **System:** `verilator/` full sim booting the gathered ROM (overlay → Egret →
  early ROM). Later, the LC-II physical campaign as the silicon oracle.

## 7. Risks / open questions

- **R1 — ghdl conversion of the larger fileset.** The current `convert_to_verilog.sh`
  only converts the base kernel; PMMU/Cache(/FPU) add big files and generics.
  Conversion errors here block everything — Phase 0 exists to de-risk it first.
- **R2 — bus-protocol impedance.** Minimig's bus (chip/fast RAM, `ramsel`, DDR
  remap) differs from the Mac's VASP+SDRAM. The translation/suppression *logic* is
  portable; the *bus plumbing* must be rewritten, not copied (D4).
- **R3 — cache-inhibit completeness.** Missing a non-cacheable region (I/O, VRAM,
  slot space) yields stale reads that look like core bugs. Decode it from the VASP
  map (`MacIIvi_HardwareConfig.md` §5) explicitly.
- **R4 — known TG68K-kernel integer bugs** predate this work; fix in VHDL, not the
  converted Verilog (master plan §9).
- **R5 — MAME PMMU quirks** (depth-limited PTEST fatalerror; limit-violation L
  bit) — 2 of 40 rows need LC-II silicon to finalize; don't block the core on them.

## 8. Resolved decisions
- **D2 — FPU: omitted.** Stock-IIvi behavior; F-line traps. (2026-06-14)
- **D5 — VHDL bench suite: carried.** Minimig `tests/tg68k_030/` imported as a
  VHDL-source gate (adds a ghdl/ModelSim dependency). (2026-06-14)
