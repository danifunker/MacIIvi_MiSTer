#!/usr/bin/env python3
"""Patch the Mac LC/LC II ROM to make the POST RAM test *fast* without skipping it.

Unlike patch_skip_ramtest.py (which forces the warm-start path and thereby
bypasses the cold-boot bookkeeping that computes the post-MMU continuation
pointer A2 -> the ROM then `jmp (A5=A2=0)`s off into zeroed RAM), this patch
keeps the **entire cold-boot framework running** and only clamps the amount of
RAM each test marches.

Every memory test funnels through the shared fill+march+verify engine at
$46850. It derives all three phases (fill, eor.l march, verify) from the end
pointer A1. At entry:

  046850: 4cfa003f00fa  movem.l $4694c(pc),d0-d5   ; load patterns
  046856: 2448          movea.l a0,a2              ; a2 = start
  046858: 92fc 0078     suba.w  #$78,a1            ; a1 = end - 0x78  (fill guard)
  04685c: 6020          bra.s   $4687e

Replacing the `suba.w #$78,a1` with `lea $78(a0),a1` (same 4 bytes) forces
a1 = a0 + 0x78 on every call, so each test marches ~0x78..0xE4 bytes instead
of the whole 4 MB chunk. The framework still runs to completion (RAM sizing,
low-mem init, boot-globals, A2 setup all happen), so the cold boot stays sound
and reaches the post-POST boot in a handful of frames.

The header checksum (offset 0, sum of all big-endian words from offset 4) is
recomputed so the ROM-checksum POST test still passes.
"""
import struct
import sys

PATCH_OFFSET = 0x46858
OLD = bytes.fromhex("92fc0078")  # suba.w #$78,a1
NEW = bytes.fromhex("43e80078")  # lea    $78(a0),a1


def checksum(data: bytes) -> int:
    s = 0
    for (w,) in struct.iter_unpack(">H", data[4:]):
        s = (s + w) & 0xFFFFFFFF
    return s


def main() -> None:
    src = sys.argv[1] if len(sys.argv) > 1 else "boot0.rom"
    dst = sys.argv[2] if len(sys.argv) > 2 else "boot0_fastmem.rom"

    data = bytearray(open(src, "rb").read())
    if data[PATCH_OFFSET : PATCH_OFFSET + len(OLD)] != OLD:
        sys.exit(f"{src}: bytes at {PATCH_OFFSET:#x} don't match the expected "
                 f"suba.w #$78,a1 — wrong or already-patched ROM")

    data[PATCH_OFFSET : PATCH_OFFSET + len(NEW)] = NEW
    struct.pack_into(">I", data, 0, checksum(data))

    open(dst, "wb").write(data)
    print(f"{dst}: patched @ {PATCH_OFFSET:#x} (suba.w->lea), "
          f"new header checksum {checksum(data):08X}")


if __name__ == "__main__":
    main()
