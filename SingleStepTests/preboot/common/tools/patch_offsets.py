#!/usr/bin/env python3
"""Patch IOTest disk-offset constants into a built image.

Two binaries inside the image need patching:

1. The boot stub (1024 bytes at byte 0 of the HFS volume):
     PAYLDOFF\xDE\xAD\xBE\xEF  ->  PAYLDOFF<big-endian /Payload offset>

2. The payload binary embedded as /Payload — its `g_iotest_sizes[]`
   table has zero-initialized `read_offset` / `write_offset` slots
   that we fill from rb-cli locate output for each test size, plus
   a `g_results_slot` whose `.offset` holds /Results.jsonl's byte
   offset within the partition.

The `IOSZTABL` and `IORESLT_` markers are still needed for #2: they
live inside the payload binary's .data, which is a file embedded in
the image. rb-cli locate gives us the byte offset of /Payload's first
byte; we have to seek to one of these markers WITHIN that file.
For the boot stub we no longer need a search at all — the file lives
at image byte 0 and the PAYLDOFF marker is at a fixed offset in it,
but searching is still cheap and tolerant of future boot-stub changes.

Usage (driven by build_hda.sh / build_dsk.sh):
    patch_offsets.py IMAGE \\
        --payload-offset      0x..      # /Payload partition-relative
        --results-offset      0x..      # /Results.jsonl partition-relative
        --reads  1B=0x..,512B=0x..,...  # /Read_<label>  partition-relative
        --writes 1B=0x..,512B=0x..,...  # /Write_<label> partition-relative
        --labels-order 1B,512B,...

All offsets are PARTITION-RELATIVE — for raw .dsk that's the same as
image-absolute, for APM .hda you subtract `partition_offset` from
rb-cli's absolute offset before passing them in. Build scripts do
that subtraction once with jq.
"""

import argparse
import struct
import sys

PAYLDOFF_MARKER  = b"PAYLDOFF"
SIZES_MARKER     = b"IOSZTABL"
RESULTS_MARKER   = b"IORESLT_"

ENTRY_SIZE         = 16
READ_OFF_IN_ENTRY  = 8
WRITE_OFF_IN_ENTRY = 12


def parse_kv(s):
    out = {}
    for part in s.split(","):
        if not part.strip():
            continue
        k, v = part.split("=", 1)
        out[k.strip()] = int(v, 0)
    return out


def find_marker_unique(data, marker, what):
    pos = data.find(marker)
    if pos < 0:
        sys.exit(f"{what}: marker {marker!r} not found")
    if data.find(marker, pos + 1) != -1:
        sys.exit(f"{what}: marker {marker!r} appears more than once")
    return pos


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("--payload-offset", required=True, type=lambda x: int(x, 0))
    ap.add_argument("--results-offset", required=True, type=lambda x: int(x, 0))
    ap.add_argument("--reads",   required=True)
    ap.add_argument("--writes",  required=True)
    ap.add_argument("--labels-order", required=True)
    args = ap.parse_args()

    reads  = parse_kv(args.reads)
    writes = parse_kv(args.writes)
    order  = [s.strip() for s in args.labels_order.split(",") if s.strip()]

    with open(args.image, "r+b") as f:
        data = f.read()

        # --- Boot stub: patch /Payload offset after PAYLDOFF marker ---
        pos = find_marker_unique(data, PAYLDOFF_MARKER, "boot stub PAYLDOFF")
        f.seek(pos + len(PAYLDOFF_MARKER))
        f.write(struct.pack(">I", args.payload_offset))

        # --- Payload: patch /Results.jsonl offset (in g_results_slot) ---
        pos = find_marker_unique(data, RESULTS_MARKER, "payload IORESLT_")
        f.seek(pos + len(RESULTS_MARKER))
        f.write(struct.pack(">I", args.results_offset))

        # --- Payload: patch g_iotest_sizes[] read/write offsets ---
        # The linker places g_iotest_sizes[] immediately BEFORE the
        # IOSZTABL marker in m68k-apple-macos-ld's output, so back up
        # by N * ENTRY_SIZE from the marker to find the table start.
        pos = find_marker_unique(data, SIZES_MARKER, "payload IOSZTABL")
        table_start = pos - len(order) * ENTRY_SIZE
        for i, label in enumerate(order):
            if label not in reads or label not in writes:
                sys.exit(f"missing read/write offset for size {label}")
            entry_off = table_start + i * ENTRY_SIZE
            f.seek(entry_off + READ_OFF_IN_ENTRY)
            f.write(struct.pack(">I", reads[label]))
            f.seek(entry_off + WRITE_OFF_IN_ENTRY)
            f.write(struct.pack(">I", writes[label]))

    print(f"patched: payload@0x{args.payload_offset:X}, "
          f"results@0x{args.results_offset:X}, "
          f"{len(order)} sizes")


if __name__ == "__main__":
    main()
