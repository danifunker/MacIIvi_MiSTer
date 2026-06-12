# Prebuilt test images — Macintosh IIvi / LC II campaign (2026-06-12)

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

## Rebuilding

```
cd SingleStepTests/preboot/supervisor_bench
./build_prebuilts.sh          # → SingleStepTests/prebuilt/*.tgz
```
