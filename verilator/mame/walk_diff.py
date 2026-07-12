#!/usr/bin/env python3
"""walk_diff.py — diff the MAME slot-walk golden against the sim's [NUBUS] stream.

The smRecNotFnd hunt (2026-07-11): MAME maciivi+mdc824 boots clean; our core
sad-Macs $0F/$33 (Slot Manager -351) after discovering the card. The declaration
ROM data one side serves and the other doesn't is the bug. This tool aligns the
two read streams and reports the first divergence.

Inputs:
  golden: slot_probe_tap.lua output (read taps on $FE000000-$FEFFFFFF +
          super slot). Byte reads log as (aligned addr, mask=000000FF,
          data=byte in lane 0) -> true byte address = addr+3 (lane 3 of a
          big-endian long). mask=FFFFFFFF logs are 32-bit reads (PrimaryInit
          register/VRAM touches).
  sim:    Vemu stdout containing "[NUBUS] CARD  addr=... rw=... data=..."
          lines from verilator/sim.v (16-bit cycles, addr carries real A0;
          rw=1 read, rw=0 write). A CPU byte read of a lane-3 decl byte is a
          16-bit cycle at the odd address with the byte in data[7:0].

Usage: walk_diff.py <mame_golden.txt> <sim_stdout.log> [--context N]

CWD-independent; prints a phase summary of both streams, then the lockstep
byte-read diff (address path + data), then the 32-bit access comparison.
"""
import re
import sys

MASK_BYTE_OFF = {  # BE lane -> byte offset within the aligned long
    0xFF000000: 0, 0x00FF0000: 1, 0x0000FF00: 2, 0x000000FF: 3,
}


def parse_golden(path):
    """-> (byte_reads [(seq, frame, pc, byteaddr, val)], longs [(frame, pc, addr, val)])"""
    byte_reads, longs = [], []
    pat = re.compile(
        r"^\[(slot|super)\] F(\d+) pc=([0-9A-F]+) addr=([0-9A-F]+) "
        r"data=([0-9A-F]+) mask=([0-9A-F]+)")
    for line in open(path):
        m = pat.match(line)
        if not m:
            continue
        frame, pc, addr, data, mask = (int(m.group(i), 16 if i > 2 else 10)
                                       for i in range(2, 7))
        if mask == 0xFFFFFFFF:
            longs.append((frame, pc, addr, data))
        elif mask in MASK_BYTE_OFF:
            byteaddr = addr + MASK_BYTE_OFF[mask]
            byte_reads.append((len(byte_reads), frame, pc, byteaddr, data & 0xFF))
        elif mask in (0xFFFF0000, 0x0000FFFF):  # word read: two byte events
            base = addr + (0 if mask == 0xFFFF0000 else 2)
            for k in range(2):
                byte_reads.append((len(byte_reads), frame, pc, base + k,
                                   (data >> (8 * (1 - k))) & 0xFF))
    return byte_reads, longs


def parse_sim(path):
    """-> (odd_reads [(seq, addr, lobyte)], even_reads [(addr, data16)],
           writes [(addr, data16)])"""
    odd_reads, even_reads, writes = [], [], []
    pat = re.compile(
        r"\[NUBUS\] CARD\s+addr=([0-9a-f]+) rw=([01]) data=([0-9a-f]+)", re.I)
    for line in open(path, errors="replace"):
        m = pat.search(line)
        if not m:
            continue
        addr, rw, data = int(m.group(1), 16), m.group(2), int(m.group(3), 16)
        if rw == "0":
            writes.append((addr, data))
        elif addr & 1:
            odd_reads.append((len(odd_reads), addr, data & 0xFF))
        else:
            even_reads.append((addr, data))
    return odd_reads, even_reads, writes


def region_summary(events, addr_ix, n=8):
    from collections import Counter
    c = Counter(e[addr_ix] >> 8 << 8 for e in events)
    return ", ".join(f"{a:08X}:{k}" for a, k in sorted(c.items())[:n]) + (
        f" ... ({len(c)} pages)" if len(c) > n else "")


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    ctx = int(sys.argv[sys.argv.index("--context") + 1]) if "--context" in sys.argv else 8
    g_bytes, g_longs = parse_golden(sys.argv[1])
    s_odd, s_even, s_writes = parse_sim(sys.argv[2])

    print(f"golden: {len(g_bytes)} byte reads, {len(g_longs)} long reads")
    print(f"sim:    {len(s_odd)} odd-addr (byte) reads, {len(s_even)} even-addr "
          f"cycles, {len(s_writes)} writes")
    print(f"golden byte-read pages: {region_summary(g_bytes, 3)}")
    print(f"sim    byte-read pages: {region_summary(s_odd, 1)}")
    print()

    # Lockstep diff of the byte-read streams.
    n = min(len(g_bytes), len(s_odd))
    div = None
    for i in range(n):
        _, gf, gpc, ga, gv = g_bytes[i]
        _, sa, sv = s_odd[i]
        if ga != sa or gv != sv:
            div = i
            break
    if div is None:
        if len(g_bytes) == len(s_odd):
            print(f"BYTE STREAMS IDENTICAL ({n} reads)")
        else:
            print(f"byte streams match for all {n} common reads; lengths differ:"
                  f" golden={len(g_bytes)} sim={len(s_odd)}")
            print("  (sim shorter = sim died mid-walk at the point below;"
                  " sim longer = extra reads)")
            side = g_bytes if len(g_bytes) > n else s_odd
            for e in side[n:n + ctx]:
                if side is g_bytes:
                    print(f"  golden-only: F{e[1]} pc={e[2]:08X} "
                          f"addr={e[3]:08X} val={e[4]:02X}")
                else:
                    print(f"  sim-only:    addr={e[1]:08X} val={e[2]:02X}")
    else:
        _, gf, gpc, ga, gv = g_bytes[div]
        _, sa, sv = s_odd[div]
        kind = "ADDRESS PATH" if ga != sa else "DATA"
        print(f"FIRST DIVERGENCE at byte-read #{div} ({kind}):")
        print(f"  golden: F{gf} pc={gpc:08X} addr={ga:08X} val={gv:02X}")
        print(f"  sim:                        addr={sa:08X} val={sv:02X}")
        print(f"  context (golden | sim), reads #{max(0, div - ctx)}..#{div + ctx}:")
        for i in range(max(0, div - ctx), min(n, div + ctx + 1)):
            _, gf, gpc, ga, gv = g_bytes[i]
            _, sa, sv = s_odd[i]
            mark = " <-- " if i == div else "     "
            eq = "  " if (ga, gv) == (sa, sv) else "!="
            print(f"  #{i:6d} {ga:08X}={gv:02X} {eq} {sa:08X}={sv:02X}{mark}")

    print()
    print(f"golden 32-bit reads (PrimaryInit phase):")
    for f, pc, a, d in g_longs:
        print(f"  F{f} pc={pc:08X} addr={a:08X} data={d:08X}")
    if s_even:
        print(f"sim even-addr cycles (first/last {ctx}):")
        for a, d in s_even[:ctx]:
            print(f"  addr={a:08X} data={d:04X}")
        if len(s_even) > ctx:
            print("  ...")
            for a, d in s_even[-ctx:]:
                print(f"  addr={a:08X} data={d:04X}")
    if s_writes:
        print(f"sim writes (first {ctx}):")
        for a, d in s_writes[:ctx]:
            print(f"  addr={a:08X} data={d:04X}")


if __name__ == "__main__":
    main()
