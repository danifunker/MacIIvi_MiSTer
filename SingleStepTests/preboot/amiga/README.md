# preboot/amiga — bootable Amiga test floppies (68030+PMMU suite)

Boot disks that run the repo's CPU and PMMU corpora on Amiga targets:
the **custom MiSTer Minimig build with TG68K modified for 68030+MMU**
(the DUT — this is the hardware acceptance suite for that CPU), a
**real 68030+MMU Amiga** (A3000-class; third real-silicon oracle), and
**FS-UAE** (build-loop verifier + second emulation oracle). The disks
support **68030+MMU only**: a startup gate checks ExecBase AttnFlags
and probes a PMOVE, and refuses anything else with an on-screen
message.

Design + decisions: [`AMIGA_TESTBENCH.md`](../../../AMIGA_TESTBENCH.md).
Troubleshooting playbook: [`DEBUGGING.md`](DEBUGGING.md).

## Prebuilt disks

`SingleStepTests/prebuilt/amiga-{cpu,pmmu-safe,pmmu-full}.adf`
(committed raw — copy straight to the MiSTer SD card), plus per-fixture
tgz and `SHA256SUMS.amiga`.

| ADF | Suite | Run order |
|---|---|---|
| `amiga-pmmu-safe.adf` | 32 hw-safe PMMU rows (translation never enabled) | **first** |
| `amiga-pmmu-full.adf` | all 40 PMMU rows incl. live translation + deliberate bus faults | after safe runs clean |
| `amiga-cpu.adf` | 721-row CPU corpus incl. the 68030 discriminators (CACR mask, CALLM/RTM) | any time |

## Running

- **MiSTer Minimig:** mount the ADF in DF0:, reset. The Kickstart strap
  boots it (KS 2.0+; 3.1/3.2 fine). Live progress paints on screen;
  "DONE — writing results" means the run is complete.
- **Real Amiga:** Gotek (mount the ADF) or write a physical DD floppy.
- **FS-UAE:**
  ```
  cp prebuilt/amiga-pmmu-safe.adf /tmp/run.adf
  fs-uae --amiga-model=A3000 --kickstart-file=~/kickstarts/kicka3000.rom \
      --floppy-drive-0=/tmp/run.adf --writable_floppy_images=1 --stdout
  ```
  (`--writable_floppy_images=1` is required — otherwise results go to an
  overlay file instead of the ADF.)

## Getting results out

The disk is a raw layout, not a filesystem. Results are a JSONL stream
at byte offset `0x78000`:

```
python3 -c "open('out.jsonl','wb').write(\
open('run.adf','rb').read()[0x78000:0xDC000].rstrip(b'\x00'))"
# PMMU suites:
python3 ../../gen/pmmu_diff_corpus.py \
    ../../results/pmmu/mame_baseline_2026-06-12.json out.jsonl
```

Expected FS-UAE A3000 baselines (archived in `results/amiga/`):
pmmu-safe 25/32, pmmu-full 32/40 — the divergent rows are documented
emulator-model disagreements (AMIGA_TESTBENCH.md §5b), not bench bugs.
On the Minimig DUT, every divergence from the MAME baseline is signal
for the TG68K-030/MMU work.

## Building from source

```
make payloads          # bootblock + 3 payloads (repo's m68k GCC)
./build_amiga_adfs.sh            # ADFs -> /tmp/amiga_prebuilt/
./build_amiga_adfs.sh --package  # + tgz/adf/SHA256SUMS -> ../../prebuilt/
```

Disk layout (raw): bootblock `0x0-0x3FF` (checksummed; `PAYLLEN!` /
`ALLOCLN!` patch slots), payload flat binary at `0x400` (loaded to chip
RAM `0x80000`), results region `0x78000-0xDBFFF`, diagnostic marker
slots at `0xD8000+` (see DEBUGGING.md).

## What's shared vs Amiga-specific

Shared with the Mac preboot bench (NOT forked): `bench_main.c`,
`pmmu_bench_main.c`, `recovery.s`, `display_1bpp.c`, `jsonl_writer.c`,
`freestanding.c`. Amiga-specific platform layer (this directory):
`bootblock.s`, `payload_entry_amiga.s` (SuperState + custom-chip
takeover + copper/bitplane display), `jsonl_trackdisk.c` (trackdisk
CMD_WRITE backend + the VBR-swapping OS bracket), `amiga_gate.c`
(68030+MMU gate), `eject_amiga.c` (stub).
