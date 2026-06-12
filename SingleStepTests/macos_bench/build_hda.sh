#!/bin/bash
# build_hda.sh — assemble /tmp/macos_bench.hda from scratch.
#
# Pipeline (mirrors the workflow that produced the original
# /tmp/cpubench_macos.hda artifact — the one the Mac mounted quickly):
#   1. Take ~/testdisk.hda as APM template (DDR + driver + Apple_HFS).
#   2. Extract the HFS partition to a flat .dsk.
#   3. hformat that partition fresh with volume label "MacBench".
#      Re-formatting wipes the catalog/bitmap cruft inherited from
#      testdisk.hda's HFS area and produces a layout that hfsutils
#      (and the classic Mac Finder) accepts without a desktop rebuild.
#   4. hmount + hcopy -m each MacBinary'd APPL. -m unpacks both forks
#      and the full Finder info, which is what makes the Finder boot
#      fast (no scanning resources to recover icon metadata).
#   5. humount, splice the partition back into the .hda in place.
#
# Why not rb-cli put + setrsrc: that works but only writes type + creator;
# Finder flags, dates, and window position are zeroed, so the Finder
# desktop-rebuilds on every mount — perceived as a slow startup.

set -euo pipefail

TEMPLATE="${TEMPLATE:-$HOME/testdisk.hda}"
HDA="${HDA:-/tmp/macos_bench.hda}"
BUILD="${BUILD:-$(dirname "$0")/build}"
VOL_LABEL="${VOL_LABEL:-MacBench}"
PART_OFFSET=96             # HFS partition start, in 512-byte blocks
PART_BLOCKS=40960          # 20 MiB partition
PART_TMP="/tmp/macos_bench_hfs.dsk"

RB="${RB:-$HOME/repos/rusty-backup/target/release/rb-cli}"

# (mac_name, host_bin)
BENCHES=(
    "CpuBench;CpuBench.bin"
)

# ---- Sanity --------------------------------------------------------------
[[ -f "$TEMPLATE" ]] || { echo "missing template $TEMPLATE"; exit 1; }
command -v hformat >/dev/null  || { echo "hformat not found (apt install hfsutils)"; exit 1; }
command -v hmount  >/dev/null  || { echo "hmount not found"; exit 1; }
command -v hcopy   >/dev/null  || { echo "hcopy not found"; exit 1; }
for b in "${BENCHES[@]}"; do
    bin="${b##*;}"
    [[ -f "$BUILD/$bin" ]] || { echo "missing $BUILD/$bin — run cmake --build $BUILD first"; exit 1; }
done

# Verify APM layout so the splice-back math is right.
if [[ -x "$RB" ]]; then
    "$RB" inspect "$TEMPLATE" | grep -q "Apple_HFS" || {
        echo "$TEMPLATE doesn't look like an APM disk with Apple_HFS"; exit 1; }
fi

# ---- Build the .hda ------------------------------------------------------
cp -f "$TEMPLATE" "$HDA"
echo "seeded $HDA from $TEMPLATE"

dd if="$HDA" of="$PART_TMP" bs=512 skip="$PART_OFFSET" count="$PART_BLOCKS" status=none

# Fresh HFS format. -f forces (won't prompt about overwriting), -l sets
# the volume name visible in the Finder.
hformat -f -l "$VOL_LABEL" "$PART_TMP" >/dev/null
echo "formatted HFS volume '$VOL_LABEL'"

hmount "$PART_TMP" >/dev/null
trap 'humount "$PART_TMP" >/dev/null 2>&1 || true' EXIT

for b in "${BENCHES[@]}"; do
    IFS=';' read -r name bin <<<"$b"
    # hcopy -m: MacBinary unpack → data fork + resource fork + Finder info.
    hcopy -m "$BUILD/$bin" ":$name"
    echo "  injected $name"
done

echo ""
echo "--- post-injection volume contents ---"
hls -la

humount "$PART_TMP" >/dev/null
trap - EXIT

# Splice the freshly-built partition back into the APM container.
dd if="$PART_TMP" of="$HDA" bs=512 seek="$PART_OFFSET" count="$PART_BLOCKS" conv=notrunc status=none
rm -f "$PART_TMP"

echo ""
echo "wrote $HDA ($(stat -c%s "$HDA") bytes) — ready for BlueSCSI"
