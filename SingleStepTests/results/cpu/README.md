# CPU corpus — oracle baselines

Two files, JSON Lines (one test per line), schema in
[`../../SCHEMA.md`](../../SCHEMA.md). They differ in exactly **two rows**.

| File | Provenance | Use for |
|---|---|---|
| `mame_baseline_2026-06-12.json` | **Raw MAME capture** (`maciici`, MC68030, 2026-06-12). Faithful record of what MAME emits — including its two known 030 bugs. Do not edit. | Auditing MAME; provenance of record. |
| `golden_2026-06-13.json` | MAME baseline **with two rows corrected from real 68030 silicon** (Macintosh IIcx, 2026-06-13). | **Gating the RTL core / hardware benches.** This is the corpus a correct 68030 must satisfy. |

Both are 721 rows. Diff them to see the whole delta:

```
python3 ../../gen/cpu_diff_corpus.py \
    mame_baseline_2026-06-12.json golden_2026-06-13.json --verbose
```

## The two corrected rows

These are the 68030 **discriminator** rows added 2026-06-12, which
deliberately carried MAME's known-bad goldens until real silicon could
adjudicate. Two independent real-silicon oracles now agree against MAME
(Macintosh IIcx — `../cpu_supervisor/maciicx_cpu_2026-06-13.jsonl`; and
the FS-UAE/WinUAE A3000 — `../amiga/fsuae_a3000_cpu_2026-06-12.jsonl`):

| Row | MAME (baseline) | Real 030 (golden) | Why MAME is wrong |
|---|---|---|---|
| `MOVEC.L D0,CACR; CACR,D1 write all-ones` | `final.d[1] = $0000FF13` | `final.d[1] = $00003313` | CACR bits 14–15 don't exist and CD/CED self-clear; MAME's mask leaves stale high bits. |
| `EXC: RTM D0` | no-op, `vec 0` | trap-form, `vec 4` | Musashi (`x06c0_rtm_l_234fc`) logs RTM as a no-op instead of taking the illegal-instruction trap the 030 owes. |

The `RTM` row is stored in the bench's **exception schema** (`vec` +
`trap_state`, no `final`) so a future core that wrongly treats RTM as a
no-op is flagged `exc_vec_diff` by `cpu_diff_corpus.py`. The `CACR` row is
a surgical `final.d[1]` edit, leaving the row in the baseline's address
coordinates (scratch @ `$1800`) so the register diff stays clean.

Full adjudication and the upstream-MAME-fix notes: see
[`../../test-blockers.md`](../../test-blockers.md) (§"68030 gap list"
items 2–3, §"MAME oracle quirks" #3).

> When the `maciivi` ROM set lands and the corpus is re-captured on
> `maciivi`, regenerate `golden_*` by re-applying these two corrections to
> the fresh MAME capture (or, better, re-run the capture against a
> MAME build that has the two upstream fixes).
