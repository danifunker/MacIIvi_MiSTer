#!/usr/bin/env python3
"""Find the 'RJSNLTAG' marker in a disk-image partition and patch the
4 bytes immediately after it with the supplied big-endian u32. Used by
the bench build scripts so the payload knows where /Results.jsonl
actually sits on disk without us hand-coding it."""

import struct
import sys

MARKER = b"RJSNLTAG"


def main():
    if len(sys.argv) != 3:
        sys.exit(f"usage: {sys.argv[0]} <partition.dsk> <offset_hex>")
    part = sys.argv[1]
    offset = int(sys.argv[2], 16) if sys.argv[2].startswith("0x") else int(sys.argv[2], 16)

    with open(part, "r+b") as f:
        data = f.read()
        pos = data.find(MARKER)
        if pos < 0:
            sys.exit(f"marker {MARKER!r} not found in {part}")
        if data.find(MARKER, pos + 1) != -1:
            sys.exit(f"marker {MARKER!r} found multiple times — ambiguous")
        patch_pos = pos + len(MARKER)
        f.seek(patch_pos)
        f.write(struct.pack(">I", offset))
        print(f"patched g_results_offset @ disk byte 0x{patch_pos:X} = 0x{offset:08X}")


if __name__ == "__main__":
    main()
