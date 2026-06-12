#!/usr/bin/env python3
"""
cpu_diff_corpus.py -- compare two CPU test JSONL files (MAME oracle vs
hardware/verilator/etc) and categorize divergences.

Sibling of diff_corpus.py (FPU). Same CLI shape:
    python3 cpu_diff_corpus.py BASELINE.jsonl CANDIDATE.jsonl [OPTIONS]

Options:
    --json        Emit machine-parseable JSON summary.
    --markdown    Emit a markdown report.
    --verbose     (terminal mode) list every divergent test.
    (no flag)     Print the human-friendly terminal report.

Comparison fields (per snapshot.final):
  - d[0..7]   (8 data registers)
  - a[0..6]   (7 address registers; a7 excluded -- stack pointer is
              platform-dependent residue from the C invoke_program JSR)
  - ccr       (8-bit condition code register)
  - ram[64]   (scratch RAM window written by the test)
  - pc        (compared as DELTA = final.pc - initial.pc; both sides
              produce absolute addresses but in different RAM layouts,
              so only the delta = test instruction length is invariant).
              Skipped when either side lacks the field (older corpora).

Categories:
  - match          : identical on all compared fields
  - skipped        : test marked privileged; both sides recorded zeroed snaps
                     (or one side did and the other didn't)
  - ccr_only       : data identical, CCR byte differs
  - flag_only      : like ccr_only but data also differs in a way that
                     suggests a flag-driven path (X-bit cascades, etc.).
                     Conservative: only fires when CCR diverges AND exactly
                     one D-register differs.
  - dreg_diff      : one or more D-registers differ on the value level
  - areg_diff      : address register diff (typically A0/A1, since the dump
                     epilogue clobbers them; also catches MOVEA / LEA bugs)
  - ram_diff       : scratch RAM bytes differ (memory write went wrong)
  - pc_diff        : PC delta differs (test instruction effective length
                     diverged -- branch behavior, exception unwinding,
                     prefetch differences)
  - sign_extension : a D-reg's low 16/8 bits match but upper bits diverge
                     consistent with sign vs zero extension
  - unknown        : uncategorized divergence
"""
import json
import sys
from collections import defaultdict


def load(path):
    return [json.loads(l) for l in open(path) if l.strip()]


# Address registers we actually compare. Excluded:
#   - A7 = the Mac C stack pointer on hardware (post-JSR residue) and an
#     arbitrary harness-set value on MAME -- never aligned across platforms.
#   - A6 = the scratch RAM base register; set by each harness to its
#     platform-specific RAM address ($1800 on MAME, &scratch_ram[0] on
#     the Mac heap). Tests that USE A6 do so only via (A6)/d16(A6)
#     addressing, which yields identical scratch RAM mutations on both
#     sides (compared via the ram[] field).
COMPARE_AREGS = list(range(6))   # A0..A5


def is_zeroed(snap):
    if any(snap['d']) or any(snap['a']): return False
    if snap.get('ccr', 0): return False
    if any(snap.get('ram', [])): return False
    return True


def signext_w(v):     # sign-extend 16->32
    v &= 0xFFFFFFFF
    return v if (v & 0x8000) == 0 else (v | 0xFFFF0000) & 0xFFFFFFFF
def signext_b(v):
    v &= 0xFFFFFFFF
    return v if (v & 0x80) == 0 else (v | 0xFFFFFF00) & 0xFFFFFFFF


def classify(name, baseline_final, cand_final, baseline_init, cand_init):
    # Skipped: either side has zero-zero snap pair (privileged-skip marker).
    base_skipped = is_zeroed(baseline_final) and is_zeroed(baseline_init)
    cand_skipped = is_zeroed(cand_final)     and is_zeroed(cand_init)
    if cand_skipped and not base_skipped:
        return ("skipped", "candidate skipped this test (privileged)")
    if base_skipped and cand_skipped:
        return ("match", None)

    bf, cf = baseline_final, cand_final

    # A6 is the platform-specific scratch base ($1800 on MAME, &scratch_ram[0]
    # on the Mac heap). Tests that derive An from A6 (LEA (A6),An; MOVE.L
    # (A1)+,D0 after preload_an_scratch; etc.) yield An values that differ
    # in absolute terms but match exactly in A6-relative terms. Accept an
    # An as matching if either the raw value matches (covers An=0 untouched
    # and absolute-#imm preloads) or the offset-from-A6 matches (covers
    # A6-derived An values). A true bug would shift the offset.
    def a_matches(i):
        if bf['a'][i] == cf['a'][i]:
            return True
        bo = (bf['a'][i] - bf['a'][6]) & 0xFFFFFFFF
        co = (cf['a'][i] - cf['a'][6]) & 0xFFFFFFFF
        return bo == co
    a_diffs = [i for i in COMPARE_AREGS if not a_matches(i)]

    d_diffs = [i for i in range(8) if bf['d'][i] != cf['d'][i]]
    ccr_diff = bf['ccr'] != cf['ccr']
    ram_diff = bf.get('ram', []) != cf.get('ram', [])

    # PC compared as delta (final - initial). The absolute PCs live in
    # different RAM layouts on each platform; the delta = test
    # instruction length is the only platform-invariant. Skip when
    # either side omits pc (older corpora, or the Mac bench's privileged
    # MOVE SR/USP fields stay absent on purpose).
    pc_diff = False
    pc_detail = None
    if 'pc' in bf and 'pc' in cf and 'pc' in baseline_init and 'pc' in cand_init:
        b_delta = (bf['pc'] - baseline_init['pc']) & 0xFFFFFFFF
        c_delta = (cf['pc'] - cand_init['pc']) & 0xFFFFFFFF
        if b_delta != c_delta:
            pc_diff = True
            pc_detail = (f"PC delta base={b_delta} cand={c_delta}"
                         f" (base abs {bf['pc']:#x} cand abs {cf['pc']:#x})")

    if not d_diffs and not a_diffs and not ccr_diff and not ram_diff \
       and not pc_diff:
        return ("match", None)

    # PC-only divergence: data and flags identical, but the test
    # instruction "ate" a different number of bytes. Strong signal of a
    # branch/exception bug.
    if pc_diff and not d_diffs and not a_diffs and not ccr_diff \
       and not ram_diff:
        return ("pc_diff", pc_detail)

    if not d_diffs and not a_diffs and not ram_diff and ccr_diff:
        return ("ccr_only",
                f"CCR base=0x{bf['ccr']:02x} cand=0x{cf['ccr']:02x}")

    if ram_diff and not d_diffs and not a_diffs:
        # Find first divergent byte for the detail.
        for i, (a, b) in enumerate(zip(bf['ram'], cf['ram'])):
            if a != b:
                return ("ram_diff",
                        f"scratch[{i}] base=0x{a:02x} cand=0x{b:02x}")
        return ("ram_diff", "scratch bytes differ")

    # Sign-extension: a single D-reg differs but low 16 or 8 bits match.
    if len(d_diffs) == 1 and not a_diffs and not ram_diff:
        i = d_diffs[0]
        bv, cv = bf['d'][i] & 0xFFFFFFFF, cf['d'][i] & 0xFFFFFFFF
        if (bv & 0xFFFF) == (cv & 0xFFFF):
            return ("sign_extension",
                    f"D{i} low16 match; base=0x{bv:08x} cand=0x{cv:08x}")
        if (bv & 0xFF) == (cv & 0xFF):
            return ("sign_extension",
                    f"D{i} low8 match; base=0x{bv:08x} cand=0x{cv:08x}")

    if ccr_diff and len(d_diffs) == 1 and not a_diffs and not ram_diff:
        i = d_diffs[0]
        return ("flag_only",
                f"D{i} base=0x{bf['d'][i]:08x} cand=0x{cf['d'][i]:08x}; "
                f"CCR base=0x{bf['ccr']:02x} cand=0x{cf['ccr']:02x}")

    if d_diffs and not a_diffs and not ram_diff:
        i = d_diffs[0]
        return ("dreg_diff",
                f"D{i} base=0x{bf['d'][i]:08x} cand=0x{cf['d'][i]:08x}"
                f" (+{len(d_diffs)-1} more)" if len(d_diffs) > 1 else
                f"D{i} base=0x{bf['d'][i]:08x} cand=0x{cf['d'][i]:08x}")

    if a_diffs and not d_diffs and not ram_diff:
        i = a_diffs[0]
        return ("areg_diff",
                f"A{i} base=0x{bf['a'][i]:08x} cand=0x{cf['a'][i]:08x}")

    return ("unknown",
            f"D diff={d_diffs} A diff={a_diffs} ccr_diff={ccr_diff} "
            f"ram_diff={ram_diff} pc_diff={pc_diff}")


CATEGORY_ORDER = ['match', 'skipped', 'ccr_only', 'flag_only',
                  'dreg_diff', 'areg_diff', 'ram_diff',
                  'pc_diff', 'sign_extension', 'unknown']

CATEGORY_HELP = {
    'match':           "candidate matches baseline byte-for-byte",
    'skipped':         "candidate skipped (privileged on this bench)",
    'ccr_only':        "data identical but CCR byte differs",
    'flag_only':       "one D-reg + CCR differ; probable flag path",
    'dreg_diff':       "D-register value(s) differ",
    'areg_diff':       "A-register (A0..A6) differs",
    'ram_diff':        "scratch RAM bytes differ",
    'pc_diff':         "PC delta differs (test instruction length diverged)",
    'sign_extension':  "low 16/8 bits match; upper bits diverge",
    'unknown':         "uncategorized divergence",
}


def build_report(baseline_path, candidate_path):
    baseline  = load(baseline_path)
    candidate = load(candidate_path)
    base_by = {t['name']: t for t in baseline}
    cand_by = {t['name']: t for t in candidate}
    common = sorted(set(base_by) & set(cand_by))

    cat_counts = defaultdict(int)
    op_cat = defaultdict(lambda: defaultdict(list))
    test_rows = []
    for name in common:
        b, c = base_by[name], cand_by[name]
        cat, detail = classify(name, b['final'], c['final'],
                               b['initial'], c['initial'])
        cat_counts[cat] += 1
        op = name.split(' ')[0].split('.')[0].rstrip(':')
        if op == "DBG":
            op = "smoke"
        op_cat[op][cat].append((name, detail))
        test_rows.append({"name": name, "op": op,
                          "category": cat, "detail": detail})

    per_op = {}
    for op, cats in op_cat.items():
        total = sum(len(v) for v in cats.values())
        per_op[op] = {
            "total": total,
            **{c: len(cats.get(c, [])) for c in CATEGORY_ORDER},
            "pass_rate": (len(cats.get('match', [])) / total) if total else 0,
        }

    return {
        "baseline_path":  baseline_path,
        "candidate_path": candidate_path,
        "baseline_count":  len(baseline),
        "candidate_count": len(candidate),
        "common_count": len(common),
        "match_count":  cat_counts['match'],
        "pass_rate": (cat_counts['match'] / len(common)) if common else 0,
        "categories": {c: cat_counts[c] for c in CATEGORY_ORDER},
        "per_op": per_op,
        "tests": test_rows,
    }


def render_terminal(rep, verbose=False):
    print(f"Baseline ({rep['baseline_path']}):  {rep['baseline_count']} tests")
    print(f"Candidate ({rep['candidate_path']}): {rep['candidate_count']} tests")
    print(f"Tests in common: {rep['common_count']}\n")
    print("=== category totals ===")
    for c in CATEGORY_ORDER:
        n = rep['categories'].get(c, 0)
        if n:
            pct = 100.0 * n / rep['common_count']
            print(f"  {c:<16} {n:>4}  ({pct:5.1f}%)")
    print("\n=== per-op breakdown ===")
    short = ['match','skip','ccr','flag','dreg','areg','ram','pc','sext','unk']
    print("{:<10}  ".format("op") +
          " ".join(f"{s:>5}" for s in short) + f"  {'total':>6}")
    for op in sorted(rep['per_op']):
        d = rep['per_op'][op]
        cells = [d['match'], d['skipped'], d['ccr_only'], d['flag_only'],
                 d['dreg_diff'], d['areg_diff'], d['ram_diff'],
                 d['pc_diff'], d['sign_extension'], d['unknown']]
        print("  {:<8}  ".format(op) +
              " ".join(f"{v:>5}" for v in cells) + f"  {d['total']:>6}")
    if verbose:
        print("\n=== divergent tests ===")
        for t in rep['tests']:
            if t['category'] not in ('match',):
                print(f"  [{t['category']}] {t['name']}")
                if t['detail']: print(f"        {t['detail']}")
    print(f"\n{rep['match_count']}/{rep['common_count']} pass "
          f"({100.0 * rep['pass_rate']:.1f}%).")


def render_json(rep):
    print(json.dumps(rep, indent=2))


def render_markdown(rep):
    print("# CPU corpus comparison\n")
    print(f"- **Baseline:** `{rep['baseline_path']}` ({rep['baseline_count']} tests)")
    print(f"- **Candidate:** `{rep['candidate_path']}` ({rep['candidate_count']} tests)")
    print(f"- **Tests compared:** {rep['common_count']}")
    print(f"- **Pass rate:** **{rep['match_count']} / {rep['common_count']} "
          f"({100.0 * rep['pass_rate']:.1f}%)**\n")
    print("## Category totals\n")
    print("| Category | Count | % | Meaning |")
    print("|---|---:|---:|---|")
    for c in CATEGORY_ORDER:
        n = rep['categories'].get(c, 0)
        if n:
            pct = 100.0 * n / rep['common_count']
            print(f"| `{c}` | {n} | {pct:.1f}% | {CATEGORY_HELP[c]} |")
    print("\n## Per-op breakdown\n")
    print("| op | total | match | skip | ccr | flag | dreg | areg | ram | pc | sext | unk | pass% |")
    print("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    for op in sorted(rep['per_op']):
        d = rep['per_op'][op]
        pct = 100.0 * d['pass_rate']
        print(f"| `{op}` | {d['total']} | {d['match']} | {d['skipped']} | "
              f"{d['ccr_only']} | {d['flag_only']} | {d['dreg_diff']} | "
              f"{d['areg_diff']} | {d['ram_diff']} | {d['pc_diff']} | "
              f"{d['sign_extension']} | {d['unknown']} | {pct:.0f}% |")


def main():
    args  = [a for a in sys.argv[1:] if not a.startswith('-')]
    flags = [a for a in sys.argv[1:] if a.startswith('-')]
    if len(args) < 2:
        print(__doc__); sys.exit(1)
    rep = build_report(args[0], args[1])
    if '--json' in flags:
        render_json(rep)
    elif '--markdown' in flags or '--md' in flags:
        render_markdown(rep)
    else:
        render_terminal(rep, verbose=('--verbose' in flags or '-v' in flags))


if __name__ == '__main__':
    main()
