#!/bin/bash
# build_dsk.sh -- assemble an 800K HFS floppy that boots the diskcopy app.
# The booted disk is just the launcher: at runtime the operator swaps in
# the real source disk (single-drive) or switches the FloppyEmu to the
# source image (two-drive).
set -euo pipefail

RB="${RB:-$HOME/repos/rusty-backup/target/release/rb-cli}"
OUT="${1:-/tmp/diskcopy.dsk}"
BUILD=build
BOOT="$BUILD/boot_stub.bin"
PAYLOAD="$BUILD/payload_diskcopy.bin"
IMG="$OUT"

[[ -x "$RB" ]] || { echo "rb-cli not found at $RB"; exit 1; }
command -v jq >/dev/null || { echo "jq required"; exit 1; }

make all
[[ -f "$BOOT" ]]    || { echo "missing $BOOT"; exit 1; }
[[ -f "$PAYLOAD" ]] || { echo "missing $PAYLOAD"; exit 1; }

rm -f "$OUT"
"$RB" new --quiet --fs hfs --size 800K --name DiskCopy "$OUT" >/dev/null

put_get_off() {
    local host="$1" dst="$2" dec
    dec=$("$RB" put --print-offset --quiet "$IMG" "$host" "$dst" |
          jq -r '.result.offset - .result.partition_offset')
    printf '%x' "$dec"
}

"$RB" put --boot "$BOOT" --quiet "$IMG" >/dev/null
PAYLOAD_OFF=$(put_get_off "$PAYLOAD" /Payload)

"$RB" fsck --quiet "$IMG" >/dev/null

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
echo "payload:    $PAYLOAD ($(stat -c%s "$PAYLOAD") bytes) @ byte 0x${PAYLOAD_OFF}"
echo ""
echo "wrote $OUT ($(stat -c%s "$OUT") bytes)"
