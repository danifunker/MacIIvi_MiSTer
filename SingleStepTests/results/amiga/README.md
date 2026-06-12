# Amiga bench results

Runs of the bootable Amiga test floppies (`preboot/amiga/`), extracted
from the ADF results region (byte offset 0x78000) after the run.

## FS-UAE A3000 baseline (2026-06-12)

FS-UAE 3.1.66 (WinUAE CPU core), A3000 model = 68030+MMU, KS 3.2.
Diffed against `../pmmu/mame_baseline_2026-06-12.json` with
`gen/pmmu_diff_corpus.py`:

- `fsuae_a3000_pmmu_safe_2026-06-12.jsonl` — 25/32 executed rows match
  (8 hw_unsafe skipped by the safe build).
- `fsuae_a3000_pmmu_full_2026-06-12.jsonl` — 32/40 match, including
  ALL live-translation rows and both bus-error fault frames.
- `fsuae_a3000_cpu_2026-06-12.jsonl` — full CPU corpus; 698 clean rows,
  EXC rows on their designed vectors. Discriminators: CACR all-ones
  reads back **$3313** (vs MAME's $FF13 — WinUAE matches the
  real-silicon prediction), CALLM **and RTM** both trap vec 4
  (confirming MAME's RTM no-op as a MAME bug from a second oracle).

The failing PMMU rows are emulator-model divergences (PTEST deep-walk
PSR semantics, root-limit handling, TT0 T-bit, MMU-config exception
vs F-line), tabulated in `AMIGA_TESTBENCH.md` §5b. Real silicon
(A3000 hardware / Macintosh LC II) adjudicates all of them.

Minimig (custom TG68K-030/MMU core) and real-A3000 runs land here next.
