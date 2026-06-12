#!/bin/bash
# build_cpu_dsk.sh -- assemble an 800K HFS floppy that boots the
# consolidated CPU bench (full corpus, supervisor + exception tests).
#
# Patches two markers:
#   PAYLDOFF (boot stub) -> /Payload partition-relative byte offset
#   RJSNLTAG (payload)   -> /Results.jsonl partition-relative byte offset
set -euo pipefail

RB="${RB:-$HOME/repos/rusty-backup/target/release/rb-cli}"
OUT="${1:-/tmp/cpubench.dsk}"
BUILD=build
BOOT="$BUILD/boot_stub_patch.bin"
PAYLOAD="$BUILD/payload_cpu_scsi.bin"
RESULTS_SIZE=409600          # must be >= g_results_max_bytes in variant_cpu_scsi.s
IMG="$OUT"

[[ -x "$RB" ]] || { echo "rb-cli not found at $RB"; exit 1; }
command -v jq >/dev/null || { echo "jq required"; exit 1; }

make cpu
[[ -f "$BOOT" ]]    || { echo "missing $BOOT"; exit 1; }
[[ -f "$PAYLOAD" ]] || { echo "missing $PAYLOAD"; exit 1; }

rm -f "$OUT"
"$RB" new --quiet --fs hfs --size 800K --name CPUBench "$OUT" >/dev/null

put_get_off() {
    local host="$1" dst="$2" dec
    dec=$("$RB" put --print-offset --quiet "$IMG" "$host" "$dst" |
          jq -r '.result.offset - .result.partition_offset')
    printf '%x' "$dec"
}

"$RB" put --boot "$BOOT" --quiet "$IMG" >/dev/null
PAYLOAD_OFF=$(put_get_off "$PAYLOAD" /Payload)

"$RB" put --zero "$RESULTS_SIZE" --dst /Results.jsonl --quiet "$IMG" >/dev/null
RESULTS_OFF=$(
    "$RB" locate --quiet "$IMG" /Results.jsonl |
    jq -r '.result.offset - .result.partition_offset' |
    xargs printf '%x'
)

"$RB" fsck --quiet "$IMG" >/dev/null

python3 - "$OUT" "0x${PAYLOAD_OFF}" "0x${RESULTS_OFF}" <<'PY'
import struct, sys
image, payload_off, results_off = sys.argv[1], int(sys.argv[2], 0), int(sys.argv[3], 0)
with open(image, "r+b") as f:
    data = f.read()
    p = data.find(b"PAYLDOFF")
    if p < 0: sys.exit("PAYLDOFF marker not found in boot stub")
    f.seek(p + 8); f.write(struct.pack(">I", payload_off))
    r = data.find(b"RJSNLTAG")
    if r < 0: sys.exit("RJSNLTAG marker not found in payload")
    f.seek(r + 8); f.write(struct.pack(">I", results_off))
print(f"patched: payload@0x{payload_off:X}, results@0x{results_off:X}")
PY

echo ""
echo "boot stub:  $BOOT ($(stat -c%s "$BOOT") bytes)"
echo "payload:    $PAYLOAD ($(stat -c%s "$PAYLOAD") bytes) @ byte 0x${PAYLOAD_OFF}"
echo "results:    @ byte 0x${RESULTS_OFF} ($RESULTS_SIZE bytes pre-allocated)"
echo ""
echo "wrote $OUT ($(stat -c%s "$OUT") bytes)"
