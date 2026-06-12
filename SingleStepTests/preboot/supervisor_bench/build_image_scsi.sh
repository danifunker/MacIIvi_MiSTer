#!/bin/bash
# build_image_scsi.sh — assemble a SCSI-bootable disk by injecting our
# boot block + payload into the HFS partition of testdisk.hda.
#
# Inputs:
#   $1 — template .hda (defaults to ~/testdisk.hda)
#   $2 — output .hda    (defaults to /tmp/testdisk_bench.hda)
#
# Assumes testdisk.hda has APM with Apple_HFS partition at byte 0xC000,
# 20 MB long. If your template differs, adjust HFS_PART_OFFSET / SIZE.

set -euo pipefail

RB="${RB:-$HOME/repos/rusty-backup/target/release/rusty-backup-cli}"
TEMPLATE="${1:-$HOME/testdisk.hda}"
OUT="${2:-/tmp/testdisk_bench.hda}"

BUILD=build
BOOT="$BUILD/boot_stub_scsi.bin"
PAYLOAD="$BUILD/payload_scsi.bin"

HFS_PART_OFFSET=49152          # 0xC000 = block 96
HFS_PART_SIZE=20971520         # 20 MB = 40960 blocks

[[ -x "$RB" ]]      || { echo "rusty-backup-cli not found"; exit 1; }
[[ -f "$BOOT" ]]    || { echo "missing $BOOT — run 'make scsi' first"; exit 1; }
[[ -f "$PAYLOAD" ]] || { echo "missing $PAYLOAD — run 'make scsi' first"; exit 1; }
[[ -f "$TEMPLATE" ]] || { echo "template $TEMPLATE not found"; exit 1; }

cp "$TEMPLATE" "$OUT"

# Extract HFS partition to a separate file we can manipulate.
PART=/tmp/hfs_part_scsi.dsk
dd if="$OUT" of="$PART" bs=512 skip=96 count=40960 status=none

# Install our boot block + payload.
"$RB" api hfs put-boot "$PART" "$BOOT"
"$RB" api hfs put      "$PART" "$PAYLOAD" /Payload
"$RB" api hfs put-zero "$PART" /Results.jsonl 4096
"$RB" api hfs validate "$PART"

# Splice the modified partition back in.
dd if="$PART" of="$OUT" bs=512 seek=96 count=40960 conv=notrunc status=none

# Sanity: verify /Payload's byte offset within the partition is still
# what boot_stub_scsi.s expects (0x51600 = 333312).
set +o pipefail
PAYLOAD_SIG=$(xxd -l 6 "$PAYLOAD" | head -1 | awk '{print $2" "$3" "$4}')
PAYLOAD_OFFSET=$(xxd "$PART" | grep -m1 "$PAYLOAD_SIG" | cut -d: -f1)

# Probe /Results.jsonl by replacing the zero-fill with a known marker,
# locate it, then put the zeros back so the file is fresh for boot.
RP=/tmp/results_probe_marker.bin
printf 'XJSONLPROBEMARKERXX' > "$RP"
truncate -s 4096 "$RP"
"$RB" api hfs rm  "$PART" /Results.jsonl >/dev/null
"$RB" api hfs put "$PART" "$RP" /Results.jsonl >/dev/null
RESULTS_OFFSET=$(xxd "$PART" | grep -m1 "584a 534f 4e4c 5052" | cut -d: -f1)
# Put it back as zeros so the bench writes into a clean file.
ZF=/tmp/results_zero_marker.bin
truncate -s 4096 "$ZF"
"$RB" api hfs rm  "$PART" /Results.jsonl >/dev/null
"$RB" api hfs put "$PART" "$ZF" /Results.jsonl >/dev/null
rm -f "$RP" "$ZF"
set -o pipefail

echo ""
echo "boot stub:        $BOOT ($(stat -c%s $BOOT) bytes)"
echo "payload:          $PAYLOAD ($(stat -c%s $PAYLOAD) bytes)"
echo "/Payload offset:        0x$PAYLOAD_OFFSET  (boot_stub_scsi.s expects 0x51600)"
echo "/Results.jsonl offset:  0x$RESULTS_OFFSET  (payload_entry_scsi.s expects 0x51C00)"
echo ""
echo "wrote $OUT (image total $(stat -c%s $OUT) bytes)"
