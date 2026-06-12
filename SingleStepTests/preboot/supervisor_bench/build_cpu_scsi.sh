#!/bin/bash
# build_cpu_scsi.sh — assemble a SCSI-bootable disk containing the
# full CPU bench. Reuses ~/testdisk.hda as APM template.
set -euo pipefail

RB="${RB:-$HOME/repos/rusty-backup/target/release/rusty-backup-cli}"
TEMPLATE="${1:-$HOME/testdisk.hda}"
OUT="${2:-/tmp/cpu_scsi.hda}"

BOOT=build/boot_stub_scsi.bin
PAYLOAD=build/payload_cpu_scsi.bin
RESULTS_SIZE=409600                    # 400 KB pre-allocation

[[ -x "$RB" ]]    || { echo "rusty-backup-cli not found"; exit 1; }
[[ -f "$BOOT" ]]  || { echo "missing $BOOT — run 'make cpu_scsi' first"; exit 1; }
[[ -f "$PAYLOAD" ]] || { echo "missing $PAYLOAD — run 'make cpu_scsi' first"; exit 1; }

cp "$TEMPLATE" "$OUT"

PART=/tmp/cpu_scsi_part.dsk
dd if="$OUT" of="$PART" bs=512 skip=96 count=40960 status=none

"$RB" api hfs put-boot "$PART" "$BOOT" >/dev/null
"$RB" api hfs put      "$PART" "$PAYLOAD" /Payload >/dev/null

# Probe /Results.jsonl's actual extent by putting then re-zeroing it.
RP=/tmp/cpu_scsi_probe.bin
printf 'XJSONLPROBEMARKERXX' > "$RP"
truncate -s "$RESULTS_SIZE" "$RP"
"$RB" api hfs put "$PART" "$RP" /Results.jsonl >/dev/null
set +o pipefail
RESULTS_OFFSET=$(xxd "$PART" | grep -m1 "584a 534f 4e4c 5052" | cut -d: -f1)
set -o pipefail

ZF=/tmp/cpu_scsi_zero.bin
truncate -s "$RESULTS_SIZE" "$ZF"
"$RB" api hfs rm  "$PART" /Results.jsonl >/dev/null
"$RB" api hfs put "$PART" "$ZF" /Results.jsonl >/dev/null
rm -f "$RP" "$ZF"

"$RB" api hfs validate "$PART"

set +o pipefail
PAYLOAD_SIG=$(xxd -l 6 "$PAYLOAD" | head -1 | awk '{print $2" "$3" "$4}')
PAYLOAD_OFFSET=$(xxd -s 1024 "$PART" | grep -m1 "$PAYLOAD_SIG" | cut -d: -f1)
set -o pipefail

# Patch the measured /Results.jsonl offset into the payload bytes on
# the partition image (locates the RJSNLTAG marker).
../common/tools/old/patch_results_offset.py "$PART" "0x$RESULTS_OFFSET"

dd if="$PART" of="$OUT" bs=512 seek=96 count=40960 conv=notrunc status=none

echo ""
echo "boot stub:           $BOOT ($(stat -c%s $BOOT) bytes)"
echo "payload:             $PAYLOAD ($(stat -c%s $PAYLOAD) bytes)"
echo "/Payload offset:        0x$PAYLOAD_OFFSET  (boot_stub_scsi.s expects 0x51600)"
echo "/Results.jsonl offset:  0x$RESULTS_OFFSET  (patched into payload)"
echo ""
echo "wrote $OUT ($(stat -c%s $OUT) bytes)"
