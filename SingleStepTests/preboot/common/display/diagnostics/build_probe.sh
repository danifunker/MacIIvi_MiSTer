#!/bin/bash
# build_probe.sh — assemble a SCSI boot image with the polarity probe
# boot block. Boot it on real Mac II, then describe what you see:
#   - leftmost stripe ($00) — what color?
#   - second stripe ($55) — what color?
#   - third stripe ($AA) — what color?
#   - rightmost stripe ($FF) — what color?
# That tells us pixel polarity + whether the framebuffer layout matches.
#
# Historical name: preboot/supervisor_bench/build_m2hires_probe.sh.
# Migrated into the shared diagnostics tree alongside boot_stub_probe.s.
# Still uses deprecated `api hfs *` rb-cli verbs because the
# supervisor_bench-side migration to flat verbs is deferred — see
# preboot/iotest/build_hda.sh for the flat-verb pattern.

set -euo pipefail

RB="${RB:-$HOME/repos/rusty-backup/target/release/rb-cli}"
TEMPLATE="${1:-$HOME/testdisk.hda}"
OUT="${2:-/tmp/probe.hda}"

# Build the probe stub from supervisor_bench/ — that's where the
# Makefile lives. Adjust if you invoke from elsewhere.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SB_DIR="$SCRIPT_DIR/../../../supervisor_bench"
BOOT="$SB_DIR/build/boot_stub_probe.bin"

[[ -x "$RB" ]]   || { echo "rb-cli not found at $RB"; exit 1; }
if [[ ! -f "$BOOT" ]]; then
    echo "building probe stub via $SB_DIR..."
    make -C "$SB_DIR" probe >/dev/null
fi
[[ -f "$BOOT" ]] || { echo "missing $BOOT — make probe failed?"; exit 1; }

cp "$TEMPLATE" "$OUT"
PART=/tmp/probe_part.dsk
dd if="$OUT" of="$PART" bs=512 skip=96 count=40960 status=none
"$RB" api hfs put-boot "$PART" "$BOOT" >/dev/null
"$RB" api hfs validate "$PART"
dd if="$PART" of="$OUT" bs=512 seek=96 count=40960 conv=notrunc status=none

echo "wrote $OUT — boot it on the target Mac and describe the stripes"
