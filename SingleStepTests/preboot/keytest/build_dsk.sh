#!/bin/bash
# build_dsk.sh -- assemble an 800K HFS floppy for keytest.
set -euo pipefail

RB="${RB:-$HOME/repos/rusty-backup/target/release/rb-cli}"
OUT="${1:-/tmp/keytest.dsk}"
BUILD=build
BOOT="$BUILD/boot_stub.bin"
PAYLOAD="$BUILD/payload_keytest.bin"
IMG="$OUT"

[[ -x "$RB" ]] || { echo "rb-cli not found at $RB"; exit 1; }
command -v jq >/dev/null || { echo "jq required"; exit 1; }

make all
[[ -f "$BOOT" ]]    || { echo "missing $BOOT"; exit 1; }
[[ -f "$PAYLOAD" ]] || { echo "missing $PAYLOAD"; exit 1; }

rm -f "$OUT"
"$RB" new --quiet --fs hfs --size 800K --name KeyTest "$OUT" >/dev/null

put_get_off() {
    local host="$1" dst="$2" dec
    dec=$("$RB" put --print-offset --quiet "$IMG" "$host" "$dst" |
          jq -r '.result.offset - .result.partition_offset')
    printf '%x' "$dec"
}

"$RB" put --boot "$BOOT" --quiet "$IMG" >/dev/null
PAYLOAD_OFF=$(put_get_off "$PAYLOAD" /Payload)

"$RB" fsck --quiet "$IMG" >/dev/null

# Patch the boot stub's PAYLDOFF marker with the partition-relative
# /Payload offset (big-endian u32 immediately following the 8-byte
# "PAYLDOFF" marker bytes). keytest doesn't have IORESLT_ or IOSZTABL
# markers in its payload (no results writer, no sizes table), so the
# full patch_offsets.py used by iotest doesn't apply.
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
