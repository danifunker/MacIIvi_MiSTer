#!/usr/bin/env python3
"""Wrap a raw 800K .dsk in a DiskCopy 4.2 header so Disk Copy 6.3.3
accepts it. Spec: https://www.discferret.com/wiki/Apple_DiskCopy_4.2"""

import struct, sys


def dc42_checksum(data: bytes) -> int:
    s = 0
    for i in range(0, len(data), 2):
        word = (data[i] << 8) | data[i + 1]
        s = (s + word) & 0xFFFFFFFF
        s = ((s >> 1) | ((s & 1) << 31)) & 0xFFFFFFFF
    return s


def main():
    if len(sys.argv) != 4:
        sys.exit("usage: raw_to_dc42.py <in.dsk> <out.image> <image-name>")
    inp, outp, name = sys.argv[1], sys.argv[2], sys.argv[3]
    data = open(inp, "rb").read()
    if len(data) != 800 * 1024:
        sys.exit(f"{inp} is {len(data)} bytes, expected 819200")

    name_b = name.encode("mac-roman")[:63]
    name_field = bytes([len(name_b)]) + name_b + b"\x00" * (63 - len(name_b))
    data_size = len(data)                # 819200
    # 800K Mac disks have 12 bytes of tags per 512-byte sector.
    # Disk Copy 6.3.3 chokes when this is omitted, so include zero tags.
    sectors = data_size // 512           # 1600
    tags = b"\x00" * (sectors * 12)      # 19200 bytes
    tag_size = len(tags)
    data_csum = dc42_checksum(data)
    tag_csum = dc42_checksum(tags[12:])  # first sector's tags excluded per spec
    disk_format = 1                      # 1 = 800K Mac
    fmt_byte = 0x22                      # GCR CLV dsdd
    magic = 0x0100

    header = (
        name_field
        + struct.pack(">II", data_size, tag_size)
        + struct.pack(">II", data_csum, tag_csum)
        + struct.pack(">BBH", disk_format, fmt_byte, magic)
    )
    assert len(header) == 84, len(header)
    # DC42 layout: header, user data, then tag data (NOT the other way around).
    open(outp, "wb").write(header + data + tags)
    print(f"wrote {outp} ({len(header)+len(tags)+len(data)} bytes), "
          f"data csum 0x{data_csum:08X}, tag csum 0x{tag_csum:08X}")


if __name__ == "__main__":
    main()
