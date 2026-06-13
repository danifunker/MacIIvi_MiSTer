# Prebuilt test images — Macintosh IIvi / LC II campaign (2026-06-13)

One tgz per fixture; each contains a SCSI **`.hda`** (BlueSCSI / SCSI2SD
/ real drive) and an 800K floppy **`.dsk`**. Checksums in `SHA256SUMS`.
Built by `preboot/supervisor_bench/build_prebuilts.sh` (Retro68
toolchain + rb-cli); source tree state = the commit that contains this
file.

| Fixture | Suite | Display stride | Notes |
|---|---|---|---|
| `maciivi-cpu-mdc824` | CPU corpus (721 rows; privileged + exception rows run, hw_unsafe skipped) | fixed 80 B (mdc824/Toby NuBus) | |
| `maciivi-cpu-autovideo` | same | runtime ScrnRow ($0106) detect — works on mdc824, **LC II V8**, IIvi VASP | **recommended for the LC II** |
| `maciivi-pmmu-safe-mdc824` | PMMU corpus, hw-safe rows only (32 of 40; translation never enabled) | fixed 80 B | |
| `maciivi-pmmu-safe-autovideo` | same | auto | **boot this first on the LC II** |
| `maciivi-pmmu-full-mdc824` | PMMU corpus, ALL 40 rows incl. live translation + deliberate bus faults | fixed 80 B | only after safe runs clean |
| `maciivi-pmmu-full-autovideo` | same | auto | |

## Running

1. Write the `.hda` to a BlueSCSI/SCSI2SD card (or `dd` to a SCSI
   disk), or the `.dsk` to an 800K floppy. Boot the Mac from it.
2. The bench paints live progress (test index + run/ok/trap/skip
   tally), then "DONE — writing results".
3. Pull the results back on the host:
   ```
   rb-cli get IMG.hda@1 /Results.jsonl out.jsonl     # or IMG.dsk (no @1)
   ```
4. Diff against the MAME oracle:
   ```
   # CPU suite:
   python3 SingleStepTests/gen/cpu_diff_corpus.py \
       SingleStepTests/results/cpu/mame_baseline_2026-06-12.json out.jsonl
   # PMMU suite:
   python3 SingleStepTests/gen/pmmu_diff_corpus.py \
       SingleStepTests/results/pmmu/mame_baseline_2026-06-12.json out.jsonl
   ```

## The identity probe (PMMU images)

PMMU images print **"MMU IDENTITY PROBE (wedge here = not identity)"**
on screen and write `{"identity_probe":"attempting"}` to the results
file before first touching the MMU. 32-bit-clean Mac ROMs boot with the
68030's translation ENABLED; the bench requires the boot mapping to
keep low RAM virtual==physical ("identity"), which holds on
dedicated-VRAM machines (LC II / IIvi) but NOT on vampiric-video
RBV-class machines (e.g. IIci — verified under MAME: its main RAM
lives in Bank B physically). **If the machine freezes showing the probe
banner, the mapping is not identity — do not run the PMMU bench on that
machine.** After a wedge, power off; the results file still contains
the reloc header (including the ROM's saved TC/CRP — itself useful
data) and the probe marker.

## PMMU full image — extra warnings

The `pmmu-full` fixtures enable live translation and take deliberate
bus errors on your machine. The runner force-disables translation on
every exit path (including inside the fault handler) and restores the
ROM's MMU state after every test, but a divergence between your 68030
and the MAME oracle could still wedge mid-test — the on-screen test
index identifies the culprit. Run `pmmu-safe` to completion first.

## Verification status (what was actually tested before packaging)

| Check | Result |
|---|---|
| CPU `.hda` boots + full corpus runs (MAME `maciici`, 68030) | ✅ 720 result rows written and extracted |
| PMMU runner, all 40 rows incl. live translation + faults (MAME harness build, flat-map environment) | ✅ **40/40 match** vs `results/pmmu/mame_baseline_2026-06-12.json` via `gen/pmmu_diff_corpus.py` (run archived as `results/pmmu/mame_harness_run_2026-06-12.jsonl`) |
| PMMU `.hda` boot path + identity-probe guard (MAME `maciici`, a known non-identity machine) | ✅ boots, writes reloc header + probe marker, wedges with the documented banner (expected on IIci-class) |
| Full-boot PMMU run on an identity machine | ⏳ pending the physical LC II (or MAME `maclc2` once its ROMs are dumped) |
| `.dsk` floppy boot | ⏳ not MAME-verifiable headless (known MAME floppy-boot limitation); same payload bytes as `.hda` |
| V8/VASP `autovideo` stride on real hardware | ⏳ pending LC II; falls back to 80 B if ScrnRow is implausible |

## Amiga fixtures (2026-06-12)

Bootable ADFs for the Minimig TG68K-030/MMU build and real 68030+MMU
Amigas — **68030+MMU only** (startup gate refuses anything else). Raw
disk layout, no filesystem; design in `AMIGA_TESTBENCH.md`, usage in
`preboot/amiga/README.md`, troubleshooting in
`preboot/amiga/DEBUGGING.md`. **The raw `.adf` files are committed
right here** (`amiga-*.adf`) — copy straight to the MiSTer SD card;
per-fixture tgz alongside, and
`maciivi-testbench-all.tgz` bundles every image (12 Mac
.hda/.dsk + 3 ADFs) in one download.

| Fixture | Suite |
|---|---|
| `amiga-cpu` | CPU corpus (721 rows incl. 030 discriminators) |
| `amiga-pmmu-safe` | PMMU hw-safe rows (32 of 40) — **run first** |
| `amiga-pmmu-full` | all 40 PMMU rows incl. live translation + faults |

Verify a run against the oracle in one step (extract + auto-detect
CPU/PMMU + diff vs `results/<area>/golden_2026-06-13.json`):

```
preboot/amiga/verify_amiga.sh ran.adf      # exit 0 = clean, 1 = divergences
```

On FS-UAE a few rows still diverge from silicon (the cross-oracle set in
`AMIGA_TESTBENCH.md` §5b); on real LC II / IIcx silicon a clean run is
zero mismatches. To do it by hand instead, pull the result stream from
ADF byte `0x78000` (`python3 -c "open('out.jsonl','wb').write(open('x.adf','rb').read()[0x78000:0xDC000].rstrip(b'\x00'))"`)
and diff with `gen/pmmu_diff_corpus.py` / `gen/cpu_diff_corpus.py`.
Diagnostic marker slots at `0xD8000+` identify how far a failed boot got
(see AMIGA_TESTBENCH.md §2).

Verification status: all three boot-verified end-to-end on FS-UAE
A3000 (68030+MMU, KS 3.2). PMMU-full: 32/40 vs the MAME baseline with
all live-translation and fault rows passing; the 8 divergent rows are
documented FS-UAE↔MAME emulator-model disagreements
(AMIGA_TESTBENCH.md §5b) awaiting real-silicon adjudication. CPU: 720
rows, EXC vectors as designed; CACR mask reads `$3313` (vs MAME
`$FF13`) and RTM traps vec 4 (vs MAME no-op) — both supporting the
real-silicon predictions against MAME. Archived runs:
`results/amiga/`.

## Rebuilding

```
cd SingleStepTests/preboot/supervisor_bench
./build_prebuilts.sh          # → SingleStepTests/prebuilt/*.tgz
```

**Rebuilt 2026-06-13** from the current bench source (the commit
containing this file), which now includes the shared-runtime refactor
made for the Amiga port (commit `bd9e134`, after the 2026-06-12 images
were first built in `49ac1b9`). The **CPU images are functionally
identical** to the 2026-06-12 set: all 721 embedded test names are
byte-identical, and the only payload delta is +398 B of dead code from
the shared `recovery.s` VBR helpers (`use_os_vbr`/`use_recovery_vbr`/
`restore_os_traps`/`install_recovery_traps`) — assembled in but never
called on the Mac build. The **PMMU images** now derive their
runner-owned identity blocks from the payload's actual placement, so the
reloc header reports `"masked_levb_slots":[4]` (the payload occupies only
64K block 4) instead of the previously hardcoded `[4,5,6]`. Corpus
outcomes are expected to be unchanged (blocks 5–6 are unused), but were
**not** re-run for this rebuild: MAME `maciici` can't host the PMMU disk
boot (non-identity machine — see the identity probe above), so re-verify
the PMMU set on an identity machine (LC II / IIcx) before relying on it.
