#!/bin/bash
# build_hda.sh — assemble a SCSI-bootable .hda for IOTest.
#
# Inputs:
#   $1 — template .hda (defaults to ~/testdisk.hda; APM + Apple_HFS @1)
#   $2 — output .hda    (defaults to /tmp/iotest.hda)
#
# Uses rb-cli's flat verbs (put / put --boot / put --print-offset /
# locate / fsck), all of which emit JSON envelopes. The deprecated
# `api hfs *` namespace is intentionally avoided.

set -euo pipefail

RB="${RB:-$HOME/repos/rusty-backup/target/release/rb-cli}"
TEMPLATE="${1:-$HOME/testdisk.hda}"
OUT="${2:-/tmp/iotest.hda}"
BUILD=build
BOOT="$BUILD/boot_stub.bin"
PAYLOAD="$BUILD/payload_iotest_hda.bin"
RESULTS_SIZE=32768

# Image reference for rb-cli — Apple_HFS is partition #1 (the only
# FS-bearing partition in our template). Built once, reused for every
# rb-cli call below so the partition_offset arithmetic is identical
# across them.
IMG="${OUT}@1"

# Ordered list matching IOTEST_SHARED_SIZES + IOTEST_HDA_LARGE_SIZES.
SIZES=(
    "1B:1"
    "512B:512"
    "1KB:1024"
    "2KB:2048"
    "16KB:16384"
    "32KB:32768"
    "64KB:65536"
    "256KB:262144"
    "512KB:524288"
    "1MB:1048576"
    "2MB:2097152"
    "4MB:4194304"
)

[[ -x "$RB" ]]      || { echo "rb-cli not found at $RB"; exit 1; }
[[ -f "$TEMPLATE" ]] || { echo "missing template $TEMPLATE"; exit 1; }
command -v jq >/dev/null || { echo "jq required for parsing rb-cli output"; exit 1; }

make hda
[[ -f "$BOOT" ]]    || { echo "missing $BOOT"; exit 1; }
[[ -f "$PAYLOAD" ]] || { echo "missing $PAYLOAD"; exit 1; }

cp -f "$TEMPLATE" "$OUT"

# put_and_locate <host-file> <hfs-path>  →  prints partition-relative offset (hex)
# rb-cli's `offset` is image-absolute; the partition_offset field tells
# us where the partition starts. The boot stub and payload use
# partition-relative offsets via the SCSI driver's fsFromStart on the
# partition refnum, so we subtract once here.
put_and_locate() {
    local host="$1" dst="$2"
    "$RB" put --print-offset --quiet "$IMG" "$host" "$dst" |
        jq -r '"%x" | (.result.offset - .result.partition_offset) as $rel |
               .result.offset, .result.partition_offset | tostring' \
        >/dev/null
    "$RB" locate --quiet "$IMG" "$dst" |
        jq -r '(.result.offset - .result.partition_offset) | "%x" % .'
}

# Simpler single-call form: put once with --print-offset, parse out
# (offset - partition_offset) → hex.
put_get_rel() {
    local host="$1" dst="$2"
    "$RB" put --print-offset --quiet "$IMG" "$host" "$dst" |
        jq -r '(.result.offset - .result.partition_offset) | tostring as $d |
               "%x" % ($d | tonumber)'
}

# jq doesn't have printf "%x" for integers directly — use the shell.
put_get_rel() {
    local host="$1" dst="$2"
    local dec
    dec=$("$RB" put --print-offset --quiet "$IMG" "$host" "$dst" |
          jq -r '.result.offset - .result.partition_offset')
    printf '%x' "$dec"
}

# 1. Install boot stub (1024 bytes at byte 0 of the partition).
"$RB" put --boot "$BOOT" --quiet "$IMG" >/dev/null

# 2. Place /Payload, capturing its partition-relative offset.
PAYLOAD_OFF=$(put_get_rel "$PAYLOAD" /Payload)

# 3. Pre-allocate /Results.jsonl with zeros — the payload writes
#    JSONL lines into it via _Write at this offset.
"$RB" put --zero "$RESULTS_SIZE" --dst /Results.jsonl --quiet "$IMG" >/dev/null
RESULTS_OFF=$(
    "$RB" locate --quiet "$IMG" /Results.jsonl |
    jq -r '.result.offset - .result.partition_offset' |
    xargs printf '%x'
)

# 4. Per-size read sources + write scratch. Body bytes are
#    pseudo-random; the test compares post-write readback against a
#    pattern computed in C, so the on-disk content here doesn't matter.
mk_blob() {
    local length=$1 out=$2
    local size=$length
    # The payload rounds every raw block-driver transfer up to a whole
    # 512-byte sector (sector_round_up in diskio_main.c), so each blob
    # must reserve at least one full sector or the rounded read/write
    # would run past the file's allocated extent.
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

    rfile=/tmp/iotest_hda_read_${label}.bin
    wfile=/tmp/iotest_hda_write_${label}.bin
    mk_blob "$length" "$rfile"
    mk_blob "$length" "$wfile"

    roff=$(put_get_rel "$rfile" "/Read_${label}")
    woff=$(put_get_rel "$wfile" "/Write_${label}")
    READS_KV="${READS_KV:+$READS_KV,}${label}=0x${roff}"
    WRITES_KV="${WRITES_KV:+$WRITES_KV,}${label}=0x${woff}"
done

# 5. Sanity: fsck before patching. rb-cli emits status JSON on stdout;
#    fail loudly if it's not happy.
"$RB" fsck --quiet "$IMG" >/dev/null

# 6. Patch all offsets into the boot stub + payload bytes that now
#    live in the partition image.
../common/tools/patch_offsets.py "$OUT" \
    --payload-offset "0x${PAYLOAD_OFF}" \
    --results-offset "0x${RESULTS_OFF}" \
    --reads   "$READS_KV" \
    --writes  "$WRITES_KV" \
    --labels-order "$LABEL_ORDER"

# Cleanup intermediate files.
rm -f /tmp/iotest_hda_read_*.bin /tmp/iotest_hda_write_*.bin

echo ""
echo "boot stub:  $BOOT ($(stat -c%s "$BOOT") bytes)"
echo "payload:    $PAYLOAD ($(stat -c%s "$PAYLOAD") bytes) @ partition byte 0x${PAYLOAD_OFF}"
echo "results:    @ partition byte 0x${RESULTS_OFF} ($RESULTS_SIZE bytes pre-allocated)"
echo ""
echo "wrote $OUT ($(stat -c%s "$OUT") bytes)"
