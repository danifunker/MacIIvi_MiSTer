# PMMU corpus — oracle baselines + runs

Schema in [`../../SCHEMA.md`](../../SCHEMA.md). 40 tests
(PMOVE round-trips, PTEST/PLOAD/PFLUSH, live translation, fault frames).

| File | Provenance | Use for |
|---|---|---|
| `mame_baseline_2026-06-12.json` | **Raw MAME capture** (`maciici`, MC68030). Faithful record incl. MAME's PMMU-fidelity bugs. Do not edit. | Auditing MAME; provenance of record. |
| `golden_2026-06-13.json` | MAME baseline **with three rows corrected from real 68030 silicon** (Macintosh IIcx, 2026-06-13). | **Gating the PMMU RTL.** What a correct 68030 PMMU must satisfy. |
| `maciicx_pmmu_full_2026-06-13.jsonl` | **Real-silicon run** — IIcx, `maciivi-pmmu-full-mdc824` image (all 40 rows incl. `mmu_live` + faults). reloc header + identity_probe + 40 tests. | The hardware record. |
| `maciicx_pmmu_full_2026-06-13.diff.md` | `pmmu_diff_corpus.py` baseline-vs-IIcx output. | The 3 divergences at a glance. |
| `mame_harness_run_2026-06-12.jsonl` | The PMMU runner under a MAME flat-map harness (40/40). | Pre-hardware sanity of the runner. |

```
python3 ../../gen/pmmu_diff_corpus.py mame_baseline_2026-06-12.json \
    maciicx_pmmu_full_2026-06-13.jsonl          # -> 37 passed, 3 failed
python3 ../../gen/pmmu_diff_corpus.py golden_2026-06-13.json \
    maciicx_pmmu_full_2026-06-13.jsonl          # -> 40 passed, 0 failed
```

## The IIcx run — 37/40, identity_probe OK, everything executed

The IIcx's 32-bit-clean ROM boots identity-mapped, so the **`identity_probe`
passed** and the full bench ran — PMOVE round-trips, PTEST/PLOAD/PFLUSH,
all live-translation rows, and both bus-error fault frames. The
MMU-configuration-exception fault row took **vector 56**, matching MAME.

The 3 failures are all **MAME PMMU-fidelity bugs that real silicon
adjudicates** — and they are exactly the corrections baked into the
golden. Where the FS-UAE/WinUAE A3000 oracle was also run
(`../amiga/fsuae_a3000_pmmu_full_2026-06-12.jsonl`), all three oracles
disagree, so **real silicon is decisive**:

| Row (PSR readback) | MAME | **IIcx (real 030)** | WinUAE A3000 | What's true |
|---|---|---|---|---|
| `PMOVE PSR w/r write $FFFF` | `$FFFF` | **`$EE47`** | `$FFFF` | PSR is **not** fully writable; the implemented-bit mask is `$EE47`. Neither emulator models it — IIcx-only finding. |
| `PTESTR root-limit (L)` | `$0401` (I+N) | **`$4400`** (L+I) | `$0001` (N) | Real 030 sets the **L** (limit) bit; MAME folds it into I, WinUAE drops it. |
| `PTESTR through TT0 (T)` | `$0040` (T) | **`$0001`** (N=1) | `$0000` | 030 **PTEST ignores transparent-translation** and walks the table; the T bit is not set. |

(The 4th historical divergence — the bad-geometry MMU-config exception —
the IIcx settles in **MAME's** favor at vector 56, clearing the A3000's
`vec 11` as a WinUAE bug.)

Full adjudication and upstream-MAME notes:
[`../../test-blockers.md`](../../test-blockers.md) (§"MAME oracle quirks").

> The golden corrections are surgical `final.mmu.psr` edits (plus the two
> stored PSR bytes at `$1820/$1821` for the write-mask row). When the
> `maciivi` ROM set lands and the corpus is re-captured, re-apply these
> three corrections to the fresh MAME capture.
