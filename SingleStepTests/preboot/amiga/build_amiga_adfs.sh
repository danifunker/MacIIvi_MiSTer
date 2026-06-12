#!/bin/bash
# build_amiga_adfs.sh — assemble the three bootable Amiga test floppies.
#
# Raw disk layout (no filesystem — see AMIGA_TESTBENCH.md):
#   0x00000-0x003FF  boot block ('DOS\0', checksummed)
#   0x00400-...      payload flat binary
#   0x78000-0xDBFFF  results region (Results.jsonl stream, 400 KB)
#
# Outputs ADFs into $STAGE and (with --package) tgz fixtures into
# SingleStepTests/prebuilt/.
set -euo pipefail

STAGE="${STAGE:-/tmp/amiga_prebuilt}"
OUTDIR="${OUTDIR:-../../prebuilt}"
OBJDUMP="${OBJDUMP:-$HOME/repos/Retro68-build/toolchain/bin/m68k-apple-macos-objdump}"
ADF_SIZE=901120
PAYLOAD_DOFF=$((0x400))
RESULTS_OFF=$((0x78000))
LOAD_ADDR=$((0x80000))

make payloads

mkdir -p "$STAGE"

build_adf() {  # payload.bin payload.elf out.adf
    local bin="$1" elf="$2" out="$3"
    local bss_end alloclen paylen
    bss_end=$((16#$($OBJDUMP -t "$elf" | awk '/_payload_bss_end$/{print $1}')))
    alloclen=$(( (bss_end - LOAD_ADDR + 511) / 512 * 512 ))
    paylen=$(( ($(stat -c%s "$bin") + 511) / 512 * 512 ))
    python3 - "$bin" "$out" "$paylen" "$alloclen" <<'PY'
import struct, sys
bin_path, out_path, paylen, alloclen = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
ADF_SIZE, PAYLOAD_DOFF = 901120, 0x400

boot = bytearray(open("build/bootblock.bin", "rb").read())
boot += b"\0" * (1024 - len(boot))
def patch(marker, value):
    i = boot.find(marker)
    assert i >= 0, f"marker {marker} not found"
    boot[i+8:i+12] = struct.pack(">I", value)
patch(b"PAYLLEN!", paylen)
patch(b"ALLOCLN!", alloclen)

# Amiga boot block checksum: sum of the 256 longs with end-around
# carry must equal 0xFFFFFFFF; the field at offset 4 makes it so.
boot[4:8] = b"\0\0\0\0"
s = 0
for i in range(0, 1024, 4):
    s += struct.unpack(">I", boot[i:i+4])[0]
    if s > 0xFFFFFFFF:
        s = (s & 0xFFFFFFFF) + 1
boot[4:8] = struct.pack(">I", (~s) & 0xFFFFFFFF)

img = bytearray(ADF_SIZE)
img[0:1024] = boot
payload = open(bin_path, "rb").read()
assert PAYLOAD_DOFF + len(payload) <= 0x78000, "payload overlaps results region"
img[PAYLOAD_DOFF:PAYLOAD_DOFF+len(payload)] = payload
open(out_path, "wb").write(img)
print(f"  {out_path}: payload {len(payload)}B (read {paylen}B, alloc {alloclen}B)")
PY
}

echo "== assembling ADFs =="
build_adf build/payload_cpu_amiga.bin       build/payload_cpu_amiga.elf       "$STAGE/amiga-cpu.adf"
build_adf build/payload_pmmu_amiga.bin      build/payload_pmmu_amiga.elf      "$STAGE/amiga-pmmu-safe.adf"
build_adf build/payload_pmmu_full_amiga.bin build/payload_pmmu_full_amiga.elf "$STAGE/amiga-pmmu-full.adf"

if [[ "${1:-}" == "--package" ]]; then
    echo "== packaging =="
    STAMP=$(date +%F)
    mkdir -p "$OUTDIR"
    ( cd "$STAGE"
      for fx in cpu pmmu-safe pmmu-full; do
          tar czf "amiga-$fx-$STAMP.tgz" "amiga-$fx.adf"
      done
      sha256sum amiga-*.tgz amiga-*.adf > SHA256SUMS.amiga )
    cp -f "$STAGE"/amiga-*-"$STAMP".tgz "$STAGE/SHA256SUMS.amiga" "$OUTDIR/"
    ls -la "$OUTDIR" | grep amiga
fi
