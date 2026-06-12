# Amiga Test Floppies — 68030+PMMU Suite on the Minimig / Real Amiga

*Plan settled 2026-06-12. Companion to
[68030_PMMU_TESTBENCH.md](68030_PMMU_TESTBENCH.md). Decisions fixed
with Dani: execution model B (bootblock + minimal Exec), targets =
MiSTer Minimig with the custom TG68K-68030+MMU CPU build + a real
68030+MMU Amiga, verifier = FS-UAE locally, fixtures = CPU +
PMMU-safe + PMMU-full. The disks support **68030+MMU only** — a
startup gate refuses anything else.*

---

## 1. Why this exists

The TG68K kernel modified for 68030+PMMU — the CPU that will
eventually drive the IIvi core — lives **first in a custom MiSTer
Minimig build**. These boot floppies run the exact same MAME-derived
corpora (`results/cpu/`, `results/pmmu/`) on that platform, making the
Amiga the *first hardware gate* for the 030/PMMU RTL work:

| Target | What a run proves |
|---|---|
| **Minimig + custom TG68K-030/MMU core** | The DUT. Same corpus rows that gate the PMMU RTL rungs in the plan (PMOVE regs → PTEST/walker → live translation → faults) plus the CPU discriminator rows (CACR mask, CALLM/RTM traps) — now at hardware speed, in the core's current home |
| **Real Amiga, 68030 + real MMU** (A3000-class / full-030 accelerator) | Third real-silicon oracle (after the LC II): independently adjudicates the documented MAME quirks (depth-limited PTEST, limit L bit, RTM no-op) |
| **FS-UAE (WinUAE CPU core, 68030+MMU)** | Build-loop verifier — and a *second emulation oracle* whose 030 MMU model is independent of MAME's; anywhere FS-UAE and MAME disagree is a row to flag for silicon |

Amiga is structurally the easy port: **Kickstart leaves the MMU off
and memory flat** — the two hardest Mac problems (ROM boots with
translation live; non-identity boot mappings) don't exist here. The
existing PMMU runner already handles exactly this environment (it's
what the 40/40 MAME-harness verification ran in: `rom_tc=0`, restore
no-ops, identity probe passes trivially).

## 2. Execution model (decision: B)

A 1 KB **bootblock** (`'DOS'` magic + checksum; entered by the
Kickstart strap with `A1 = trackdisk.device IOStdReq`, `A6 = ExecBase`)
loads the payload into chip RAM and jumps to it. From there:

- **Supervisor + takeover during tests**: `SuperState()`, interrupts
  masked (SR IPL7 + INTENA cleared), VBR pointed at our own vector
  table (`recovery.s` ports unchanged — the 030 always has VBR). While
  a test executes, the machine is effectively bare metal.
- **Exec kept minimally alive between batches** — exactly like the Mac
  preboot bench keeps the ROM `_Write` path: results are written by
  `trackdisk.device` `CMD_WRITE` at 512-byte sector offsets into a
  **preallocated `/Results.jsonl`** on the ADF, with
  interrupts/multitasking re-enabled only around the I/O call
  (`jsonl_writer` backend swap; same base_offset + batch design).
- **Screen**: we own the display — a single static copper list + one
  hires bitplane (640×256 PAL / 640×200 NTSC, 1bpp) allocated in chip
  RAM. That is an **80-byte row stride**, the same default
  `display_1bpp.c` already paints; it only needs a framebuffer-pointer
  shim in place of Mac's ScrnBase (`$0824`).

**68030+MMU-only gate** (per decision): at startup the payload checks
ExecBase `AttnFlags` for the 68030 bit *and* probes a PMOVE under the
recovery handler. Anything else (stock 68020 Minimig, 68000, EC030)
paints `THIS DISK REQUIRES 68030+MMU`, writes a JSONL marker, and
halts. On the custom Minimig core, a failing probe is itself signal
(F-line decode missing = PMMU rung 1 not working).

### Payload placement

Linked at a fixed chip-RAM address (**`0x80000`** — clear of the OS's
early bottom-up allocations and, for the PMMU runner's dynamic
identity mapping, of the corpus-owned levb slots 0/7) and claimed via
`AllocAbs()` from the bootblock; a failed `AllocAbs` flashes the
screen rather than stomping Exec. Corpus low-address relocation is
already handled by the existing runner design (payload statics), so
Exec's low chip-RAM structures are never touched by tests.

### Disk format (implemented: raw layout — simpler than the FFS plan)

ADF (880 KB) with **no filesystem at all**: the strap only validates
the bootblock's `DOS` magic + checksum, and we never start a DOS
handler, so the disk needs no volume structure. Fixed raw layout:

| bytes | contents |
|---|---|
| `0x00000-0x003FF` | boot block (checksummed; `PAYLLEN!`/`ALLOCLN!` patch slots) |
| `0x00400-...` | payload flat binary |
| `0x78000-0xDBFFF` | results region — raw `Results.jsonl` stream (400 KB) |
| `0xD8000-0xD9FFF` | diagnostic marker slots (overlap the results tail; see below) |

This eliminates the FFS-extension-block contiguity problem outright;
host-side extraction is a `dd`/python slice at `0x78000` (and on
MiSTer the ADF is just a file on SD). Kickstart floor stays 2.0+
(3.1/3.2 on all agreed targets).

**Diagnostic marker slots** (512 B each, written via the same takeover
bracket as the results writer — gold for headless/MiSTer bring-up):
slot 0 `0xD8000` bootblock ran + writes land; slot 1 `0xD8200` payload
entry reached; slot 2 GAT0 bracket works; slot 4 `'ATN'`+AttnFlags;
slot 5 VBRI vectors installed; slot 6 `'VEC'`+probe vector; slot 3
GATE gate passed.

## 3. Deliverables

Three fixtures, packaged like the Mac set under
`SingleStepTests/prebuilt/` (tgz per fixture + SHA256SUMS + manifest
section):

| ADF | Suite |
|---|---|
| `amiga-cpu.adf` | CPU corpus, 721 rows (privileged + exception rows run; hw_unsafe skipped) — includes the 68030 discriminators (CACR all-ones mask, CALLM/RTM illegal traps) |
| `amiga-pmmu-safe.adf` | PMMU corpus, 32 hw-safe rows (translation never enabled) |
| `amiga-pmmu-full.adf` | All 40 PMMU rows incl. live translation + deliberate bus faults |

No display variants needed (we own the display on every Amiga).
Output contract identical to the Mac images: live on-screen progress
tally, `/Results.jsonl` extracted on the host with `xdftool`, diffed
with the existing `gen/cpu_diff_corpus.py` / `gen/pmmu_diff_corpus.py`
(the reloc-header mechanism carries over unchanged). On MiSTer there
is no physical floppy: the ADF mounts directly from the SD card.

## 4. Software needed

| Tool | Install | Role | Status |
|---|---|---|---|
| **amitools** (xdftool) | `pip install amitools` | create/format ADFs, install bootblock, verify block layout, extract results | not installed yet |
| **FS-UAE 3.x** | `sudo apt install fs-uae` (3.1.66 in apt) | boot verification; WinUAE-derived CPU core with full 68030 MMU (`uae_cpu_model=68030` + MMU enabled) | not installed (needs your sudo) |
| **Kickstart ROM file(s)** | **you**: copy from the MiSTer SD card (KS 3.1 preferred; 2.0+ fine) | FS-UAE only — MiSTer and the real Amiga have their own | **user action** |
| Toolchain | none — the repo's existing m68k GCC builds the freestanding flat-binary payloads; the bootblock is GAS, checksummed by the build script | | ready |
| **WinUAE** (optional) | Windows box | second-opinion 030/MMU accuracy check on the final ADFs | optional |
| **Gotek / ADF writer** (optional) | only if the real Amiga boots from physical floppy | | optional |

MAME is deliberately **not** used here: its Amiga drivers are all
flagged `MACHINE_NOT_WORKING` (verified in our checkout).

## 5. Work plan

**P0 — setup (user + me):** install amitools + FS-UAE; Kickstart files
land in e.g. `~/kickstarts/`.

**P1 — Amiga platform layer** (new, in
`SingleStepTests/preboot/amiga/`):
`bootblock.s` (checksummed loader using the strap-provided trackdisk
IOStdReq, PAYLDOFF-style patched payload location), `payload_entry_amiga.s`
(AllocAbs, SuperState, INTENA/VBR takeover, copper + bitplane init,
030+MMU gate), `jsonl_trackdisk.c` (CMD_WRITE backend behind the
existing JsonlWriter API), framebuffer shim for `display_1bpp.c`.
`bench_main.c` / `pmmu_bench_main.c` are **shared, not forked** — a
small platform-define selects the I/O backend and screen source.

**P2 — `build_amiga_prebuilts.sh`:** make payloads → xdftool format
FFS ADF → install bootblock → write payload + preallocate
`/Results.jsonl` → verify contiguity → patch offsets → checksum →
package tgz.

**P3 — FS-UAE verification (the gate before hardware):**
- CPU ADF on a 68030+MMU config: full run, extract, diff. The CACR
  discriminator row also characterizes WinUAE's 030 CACR mask — a
  third oracle datapoint next to MAME (`$FF13`) and real silicon.
- PMMU safe + full ADFs likewise; **divergences between FS-UAE and
  the MAME baseline get logged in test-blockers.md** — in particular,
  FS-UAE may execute the depth-limited PTEST forms MAME fatally
  crashes on, giving provisional goldens for rows the corpus is
  missing.
- One boot check on a stock-68020 config to prove the 030-only gate
  refuses politely.

**P4 — hardware runs:**
1. **Minimig custom TG68K-030/MMU core** (the DUT): CPU ADF first —
   integer regressions + discriminators; then PMMU safe; PMMU full
   only after safe runs clean. Failures map directly to the RTL rung
   ladder in the master plan.
2. **Real 68030+MMU Amiga**: all three ADFs; results become the
   second real-silicon adjudication of the MAME quirks (alongside the
   LC II), archived under `SingleStepTests/results/`.

**P5 — docs + commit:** MANIFEST section, README next-steps update,
results archived with provenance.

## 5b. Bring-up findings (FS-UAE, 2026-06-12) — read before touching the bracket

1. **exec reaches supervisor mode by deliberately faulting.**
   `SuperState()`/`Supervisor()` work by trapping from user mode, so
   *any* exception vector stolen by the recovery table poisons the
   next OS call with a stale-context longjmp (zombie execution that
   scribbled 397 KB of junk before diagnosis). The I/O bracket
   therefore swaps the **entire VBR** back to the OS original around
   every `DoIO` (`use_os_vbr`/`use_recovery_vbr` in recovery.s) — the
   Amiga twin of the Mac lesson "leave Line-A alone".
2. **VBR lifecycle ordering**: `install_vbr()` must run before any
   bracketed I/O (else the bracket exits onto an unpopulated, all-zero
   vector table), and must be idempotent (the gate and the shared
   bench both call it; a second capture would snapshot our own stubbed
   table as the "OS original"). Both now enforced in recovery.s
   (`g_vbr_ready`).
3. **Verified end-to-end on FS-UAE A3000 (68030+MMU, KS 3.2):**
   boot → gate (AttnFlags `0xCE37`, PMOVE probe vec=0) → identity
   probe ok → full corpus → results extracted from the ADF.
   - **pmmu-safe: 25/32 executed rows match the MAME baseline** (8
     hw_unsafe skipped as designed).
   - **pmmu-full: 32/40** — including **all live-translation rows**
     (identity/remap stores and loads, M/U descriptor bits, ATC
     staleness ± PFLUSHA) **and both bus-error fault rows**.
4. **Cross-oracle divergences (FS-UAE/WinUAE vs MAME)** — the 7-8
   failing rows are emulator-model disagreements, not bench bugs;
   real silicon (A3000 / LC II) adjudicates:
   | Row class | MAME | FS-UAE (WinUAE core) |
   |---|---|---|
   | PTEST multi-level walk (N=3, An writeback, WP, invalid) | full walk; PSR N/W/I as PRM | stops early: PSR `I\|N=2`, descriptor addr = level-B entry |
   | PTEST root-limit violation | PSR `I\|N=1` (no L bit) | limit ignored: PSR `0x1` |
   | PTEST through enabled TT0 | PSR `T` (0x40) | no T bit |
   | PMOVE TC bad geometry (E=1) | MMU-config exception, vector 56 | **F-line, vector 11** |

## 6. Risks / open items

- **FS-UAE MMU fidelity**: excellent reputation (boots MMU-requiring
  OSes), but PTEST/PSR corner semantics get cross-checked against the
  MAME baseline during P3 — disagreements are findings, not blockers.
- **trackdisk writes from a takeover context**: the
  re-enable-around-I/O bracketing is the same pattern the Mac bench
  proved with the ROM `_Write` path; FS-UAE verification covers it
  before any hardware boot.
- **FFS block contiguity** assumption is enforced at build time, not
  assumed at runtime.
- **FS-UAE floppy write-back**: must run with writable ADFs
  (`writable_floppy_images`) rather than FS-UAE's default overlay
  files — handled in the verification script.
- **Minimig chip-RAM map**: `0x40000` must be free chip RAM on all
  targets (2 MB chip on Minimig, 1–2 MB on A3000) — guarded by
  `AllocAbs`, falls back to an on-screen error, never a silent stomp.
