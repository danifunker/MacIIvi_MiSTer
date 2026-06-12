#!/bin/bash
# build_image.sh — assemble an 800K HFS floppy with our boot block + payload.
# Usage: ./build_image.sh [out.dsk] [cpu]
set -euo pipefail

RB="${RB:-$HOME/repos/rusty-backup/target/release/rusty-backup-cli}"
OUT="${1:-cpu.dsk}"
SUITE="${2:-cpu}"

BUILD=build
BOOT="$BUILD/boot_stub.bin"
PAYLOAD="$BUILD/payload.bin"   # TODO Step E: per-suite payloads (cpu/pmmu)

[[ -x "$RB" ]]      || { echo "rusty-backup-cli not found at $RB"; exit 1; }
[[ -f "$BOOT" ]]    || { echo "missing $BOOT — run make first"; exit 1; }
[[ -f "$PAYLOAD" ]] || { echo "missing $PAYLOAD — run make first"; exit 1; }

rm -f "$OUT"
"$RB" api hfs new      "$OUT" --size 800K --name "MacIIBench-${SUITE}"
"$RB" api hfs put-boot "$OUT" "$BOOT"
"$RB" api hfs put      "$OUT" "$PAYLOAD" /Payload
"$RB" api hfs put-zero "$OUT" /Results.jsonl 4096
"$RB" api hfs validate "$OUT"
"$RB" api hfs info     "$OUT"
echo "wrote $OUT (suite=$SUITE)"
