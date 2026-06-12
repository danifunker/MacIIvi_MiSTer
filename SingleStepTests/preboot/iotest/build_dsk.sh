#!/bin/bash
# build_dsk.sh — assemble an 800K HFS floppy for IOTest.
#
# Raw .dsk image (no partition table — the whole file is the HFS
# volume) so there's no @N selector. Uses rb-cli flat verbs only.
#
# 800K is tight: 8 sizes (1B..128KB) for read + write + 16KB results +
# payload + boot block fits with a modest margin.

set -euo pipefail

RB="${RB:-$HOME/repos/rusty-backup/target/release/rb-cli}"
OUT="${1:-/tmp/iotest.dsk}"
BUILD=build
BOOT="$BUILD/boot_stub.bin"
PAYLOAD="$BUILD/payload_iotest_dsk.bin"
RESULTS_SIZE=16384
IMG="$OUT"  # no @N — raw HFS

SIZES=(
    "1B:1"
    "512B:512"
    "1KB:1024"
    "2KB:2048"
    "16KB:16384"
    "32KB:32768"
    "64KB:65536"
    "128KB:131072"
)

[[ -x "$RB" ]] || { echo "rb-cli not found at $RB"; exit 1; }
command -v jq >/dev/null || { echo "jq required"; exit 1; }

make dsk
[[ -f "$BOOT" ]]    || { echo "missing $BOOT"; exit 1; }
[[ -f "$PAYLOAD" ]] || { echo "missing $PAYLOAD"; exit 1; }

rm -f "$OUT"
"$RB" new --quiet --fs hfs --size 800K --name IOTest "$OUT" >/dev/null

# rb-cli put --print-offset for a file we're about to insert; returns
# the file's offset in the image (raw HFS, so absolute = partition-
# relative; partition_offset is 0).
put_get_off() {
    local host="$1" dst="$2"
    local dec
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

mk_blob() {
    local length=$1 out=$2
    local size=$length
    # Payload rounds every raw block-driver transfer up to a whole
    # 512-byte sector (sector_round_up in diskio_main.c); reserve at
    # least one full sector so the rounded transfer stays in-extent.
    [[ $size -lt 512 ]] && size=512
    dd if=/dev/urandom of="$out" bs=1 count="$size" status=none
}

READS_KV=""
WRITES_KV=""
LABEL_ORDER=""

for ent in "${SIZES[@]}"; do
    label="${ent%%:*}"
    length="${ent##*:}"
    LABEL_ORDER="${LABEL_ORDER:+$LABEL_ORDER,}${label}"

    rfile=/tmp/iotest_dsk_read_${label}.bin
    wfile=/tmp/iotest_dsk_write_${label}.bin
    mk_blob "$length" "$rfile"
    mk_blob "$length" "$wfile"

    roff=$(put_get_off "$rfile" "/Read_${label}")
    woff=$(put_get_off "$wfile" "/Write_${label}")
    READS_KV="${READS_KV:+$READS_KV,}${label}=0x${roff}"
    WRITES_KV="${WRITES_KV:+$WRITES_KV,}${label}=0x${woff}"
done

"$RB" fsck --quiet "$IMG" >/dev/null

../common/tools/patch_offsets.py "$OUT" \
    --payload-offset "0x${PAYLOAD_OFF}" \
    --results-offset "0x${RESULTS_OFF}" \
    --reads   "$READS_KV" \
    --writes  "$WRITES_KV" \
    --labels-order "$LABEL_ORDER"

rm -f /tmp/iotest_dsk_read_*.bin /tmp/iotest_dsk_write_*.bin

echo ""
echo "boot stub:  $BOOT ($(stat -c%s "$BOOT") bytes)"
echo "payload:    $PAYLOAD ($(stat -c%s "$PAYLOAD") bytes) @ byte 0x${PAYLOAD_OFF}"
echo "results:    @ byte 0x${RESULTS_OFF} ($RESULTS_SIZE bytes)"
echo ""
echo "wrote $OUT ($(stat -c%s "$OUT") bytes)"
