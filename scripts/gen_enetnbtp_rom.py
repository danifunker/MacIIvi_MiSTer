#!/usr/bin/env python3
"""gen_enetnbtp_rom.py — build artifacts from the Apple Ethernet NB TP declROM.

Input: releases/341-1096_AppleEthernetNBTP.bin (32 KiB, byteLanes $D2 =
lane 1 only; the guest sees it ×4-expanded at $FsFE0000-$FsFFFFFF, but both
artifacts here carry the RAW byte stream — the FPGA does the lane expansion).
Verifies provenance (SHA1 + Apple FHeader + rotl1-add CRC) before emitting
anything — a wrong reference must fail loudly, never propagate.

Outputs:
  --hex PATH   verilator sim_ddr3.v staging image of the ROMRAW window region:
               4096 x 64-bit hex words, window byte i = raw ROM byte i (the
               "guest byte A = window byte A" mailbox convention; readmemh
               into words 0x4000..0x4FFF of the model).
  --rom PATH   the per-core Main_MiSTer asset (games/MacIIvi/ethernet.rom):
               the verified raw dump, byte-identical.

Usage (from the repo root):
  python scripts/gen_enetnbtp_rom.py --hex verilator/enetnbtp_declrom.hex
  python scripts/gen_enetnbtp_rom.py --rom /path/to/ethernet.rom
"""
import argparse
import hashlib
import struct
import sys

EXPECT_SHA1 = "dd14bf4328d9c1ea1d2e1d441da0233e6669e919"  # MAME enetnbtp 341-1096.bin
ROM_SIZE = 0x8000
BYTELANES = 0xD2  # lane 1 only


def apple_crc(span, crc_off):
    s = 0
    for i, b in enumerate(span):
        if crc_off <= i < crc_off + 4:
            b = 0
        s = (((s << 1) | (s >> 31)) + b) & 0xFFFFFFFF
    return s


def load_verified(path):
    d = open(path, "rb").read()
    if len(d) != ROM_SIZE:
        sys.exit(f"FATAL: {path} is {len(d)} bytes, expected {ROM_SIZE}")
    sha1 = hashlib.sha1(d).hexdigest()
    if sha1 != EXPECT_SHA1:
        sys.exit(f"FATAL: {path} sha1 {sha1} != expected {EXPECT_SHA1}")
    length, crc = struct.unpack(">II", d[-16:-8])
    testpat = struct.unpack(">I", d[-6:-2])[0]
    bytelanes = d[-1]
    if testpat != 0x5A932BC7 or bytelanes != BYTELANES or length != ROM_SIZE:
        sys.exit(f"FATAL: FHeader mismatch (testPattern={testpat:08x} "
                 f"byteLanes={bytelanes:02x} length={length:08x})")
    span = d[len(d) - length:]
    computed = apple_crc(span, len(span) - 12)
    if computed != crc:
        sys.exit(f"FATAL: Apple CRC {computed:08x} != stored {crc:08x}")
    return d


def emit_hex(rom, path):
    with open(path, "w", newline="\n") as f:
        for w in range(ROM_SIZE // 8):
            chunk = rom[w * 8:w * 8 + 8]
            f.write("".join(f"{b:02x}" for b in reversed(chunk)) + "\n")
    print(f"wrote {path}: {ROM_SIZE // 8} words")


def emit_rom(rom, path):
    with open(path, "wb") as f:
        f.write(rom)
    print(f"wrote {path}: {len(rom)} bytes")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default="releases/341-1096_AppleEthernetNBTP.bin")
    ap.add_argument("--hex")
    ap.add_argument("--rom")
    a = ap.parse_args()
    rom = load_verified(a.bin)
    if not a.hex and not a.rom:
        sys.exit("nothing to do: pass --hex and/or --rom")
    if a.hex:
        emit_hex(rom, a.hex)
    if a.rom:
        emit_rom(rom, a.rom)


if __name__ == "__main__":
    main()
