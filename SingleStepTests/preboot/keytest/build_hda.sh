#!/bin/bash
# build_hda.sh -- assemble a SCSI-bootable .hda for keytest.
#
# Inputs:
#   $1 -- template .hda (defaults to ~/testdisk.hda; APM + Apple_HFS @1)
#   $2 -- output .hda   (defaults to /tmp/keytest.hda)
set -euo pipefail

RB="${RB:-$HOME/repos/rusty-backup/target/release/rb-cli}"
TEMPLATE="${1:-$HOME/testdisk.hda}"
OUT="${2:-/tmp/keytest.hda}"
BUILD=build
BOOT="$BUILD/boot_stub.bin"
PAYLOAD="$BUILD/payload_keytest.bin"
IMG="${OUT}@1"

[[ -x "$RB" ]]       || { echo "rb-cli not found at $RB"; exit 1; }
[[ -f "$TEMPLATE" ]] || { echo "missing template $TEMPLATE"; exit 1; }
command -v jq >/dev/null || { echo "jq required"; exit 1; }

make all
[[ -f "$BOOT" ]]    || { echo "missing $BOOT"; exit 1; }
[[ -f "$PAYLOAD" ]] || { echo "missing $PAYLOAD"; exit 1; }

cp -f "$TEMPLATE" "$OUT"

put_get_rel() {
    local host="$1" dst="$2" dec
    dec=$("$RB" put --print-offset --quiet "$IMG" "$host" "$dst" |
          jq -r '.result.offset - .result.partition_offset')
    printf '%x' "$dec"
}

# Install boot stub at partition byte 0.
"$RB" put --boot "$BOOT" --quiet "$IMG" >/dev/null

# Place the payload, capturing its partition-relative offset.
PAYLOAD_OFF=$(put_get_rel "$PAYLOAD" /Payload)

"$RB" fsck --quiet "$IMG" >/dev/null

# Patch the boot stub's PAYLDOFF marker with the partition-relative
# /Payload offset. keytest's payload has no iotest-style results /
# sizes markers, so the full patch_offsets.py doesn't apply.
python3 - "$OUT" "0x${PAYLOAD_OFF}" <<'PY'
import struct, sys
image, payload_off = sys.argv[1], int(sys.argv[2], 0)
with open(image, "r+b") as f:
    data = f.read()
    pos = data.find(b"PAYLDOFF")
    if pos < 0:
        sys.exit("PAYLDOFF marker not found in boot stub")
    f.seek(pos + 8)
    f.write(struct.pack(">I", payload_off))
print(f"patched: payload@0x{payload_off:X}")
PY

echo ""
echo "boot stub:  $BOOT ($(stat -c%s "$BOOT") bytes)"
echo "payload:    $PAYLOAD ($(stat -c%s "$PAYLOAD") bytes) @ partition byte 0x${PAYLOAD_OFF}"
echo ""
echo "wrote $OUT ($(stat -c%s "$OUT") bytes)"
