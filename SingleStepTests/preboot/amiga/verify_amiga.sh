#!/bin/bash
# verify_amiga.sh -- extract an Amiga test floppy's Results.jsonl and diff
# it against the committed oracle, in one command. No AI, no hand-typed
# byte slicing.
#
# Usage:
#   verify_amiga.sh <fixture.adf> [oracle.json]
#
# What it does:
#   1. Pulls the result stream out of the raw ADF (bytes 0x78000..0xDC000;
#      see AMIGA_TESTBENCH.md), keeping only the JSONL rows so the
#      diagnostic marker slots (0xD8000+) can never reach the diff.
#   2. Auto-detects the suite (CPU vs PMMU) from the rows and runs the
#      matching gen/<area>_diff_corpus.py.
#   3. Diffs against results/<area>/golden_2026-06-13.json -- the
#      silicon-corrected oracle (MAME baseline + IIcx / LC II
#      adjudications). Pass an explicit oracle.json as arg 2 to override
#      (e.g. the raw MAME baseline).
#
# Exit status:
#   0  every compared row matches the oracle
#   1  one or more rows diverge, or a usage / I/O error
#
# On real silicon (LC II / IIcx) a clean run is 0 mismatches. FS-UAE still
# disagrees with silicon on the handful of cross-oracle rows tabulated in
# AMIGA_TESTBENCH.md section 5b, so a small non-zero count is EXPECTED
# there -- the printed row names tell you exactly which, so you can check
# them off against that table by eye.
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SST="$(cd "$SELF/../.." && pwd)"          # .../SingleStepTests
GEN="$SST/gen"
RESULTS="$SST/results"
ORACLE_DATE=2026-06-13

ADF="${1:-}"
if [[ -z "$ADF" || ! -f "$ADF" ]]; then
    echo "usage: $(basename "$0") <fixture.adf> [oracle.json]" >&2
    exit 1
fi
command -v python3 >/dev/null || { echo "python3 required" >&2; exit 1; }

JSONL="$(mktemp "${TMPDIR:-/tmp}/amiga_results.XXXXXX.jsonl")"
trap 'rm -f "$JSONL"' EXIT

python3 - "$ADF" "$JSONL" <<'PY'
import sys
raw = open(sys.argv[1], "rb").read()[0x78000:0xDC000]
rows = [ln for ln in raw.split(b"\n") if ln[:1] == b"{"]
with open(sys.argv[2], "wb") as f:
    if rows:
        f.write(b"\n".join(rows) + b"\n")
sys.stderr.write(f"extracted {len(rows)} result rows from {sys.argv[1]}\n")
if not rows:
    sys.exit("no JSONL rows found -- did the bench run and write results?")
PY

# PMMU runs emit a {"reloc":...} header / identity_probe / psr fields;
# CPU runs carry ccr/d/a register rows and none of those.
if grep -qE '"reloc"|"identity_probe"|"psr"' "$JSONL"; then
    area=pmmu; tool="$GEN/pmmu_diff_corpus.py"
else
    area=cpu;  tool="$GEN/cpu_diff_corpus.py"
fi
oracle="${2:-$RESULTS/$area/golden_${ORACLE_DATE}.json}"
[[ -f "$oracle" ]] || { echo "oracle not found: $oracle" >&2; exit 1; }
[[ -f "$tool"   ]] || { echo "diff tool not found: $tool" >&2; exit 1; }

echo "== verify_amiga: ${area^^} suite =="
echo "  adf:    $ADF"
echo "  oracle: $oracle"
echo

rc=0
if [[ "$area" == pmmu ]]; then
    # pmmu_diff_corpus.py already exits non-zero when any row fails.
    python3 "$tool" "$oracle" "$JSONL" || rc=$?
else
    # cpu_diff_corpus.py always exits 0; print its report, then derive the
    # verdict from its --json summary (match_count vs common_count).
    python3 "$tool" "$oracle" "$JSONL"
    rc=$(python3 "$tool" "$oracle" "$JSONL" --json | python3 -c '
import json, sys
r = json.load(sys.stdin)
print(0 if r["common_count"] == r["match_count"] else 1)')
fi

echo
if [[ "$rc" -eq 0 ]]; then
    echo "RESULT: all compared rows match the oracle  [PASS]"
else
    echo "RESULT: divergences vs oracle  [FAIL]"
    echo "        (expected on FS-UAE for the AMIGA_TESTBENCH.md section 5b"
    echo "         cross-oracle rows; should be 0 on LC II / IIcx silicon)"
fi
exit "$rc"
