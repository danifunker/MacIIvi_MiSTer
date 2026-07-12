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
    """-> (read_cycles [(seq, addr16, data16)], writes [(addr, data16)])

    The sim's [NUBUS] logger latches cpuAddr, whose bit 0 is forced 0 on
    the 16-bit bus (only the CARD gets real A0), so every cycle logs at
    an even address. A lane-3 byte read of byte B therefore appears as a
    cycle at B&~1 with the byte in data[7:0] (data[15:8] = $FF lane
    fill), e.g. the ByteLanes read of $FEFFFFFF logs as
    "addr=fefffffe data=ff78"."""
    read_cycles, writes = [], []
    pat = re.compile(
        r"\[NUBUS\] CARD\s+addr=([0-9a-f]+) rw=([01]) data=([0-9a-f]+)", re.I)
    for line in open(path, errors="replace"):
        m = pat.search(line)
        if not m:
            continue
        addr, rw, data = int(m.group(1), 16), m.group(2), int(m.group(3), 16)
        if rw == "0":
            writes.append((addr, data))
        else:
            read_cycles.append((len(read_cycles), addr, data))
    return read_cycles, writes


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
    s_reads, s_writes = parse_sim(sys.argv[2])

    print(f"golden: {len(g_bytes)} byte reads, {len(g_longs)} long reads")
    print(f"sim:    {len(s_reads)} read cycles, {len(s_writes)} writes"
          f" (16-bit cycles; logger caps apply)")
    print()

    # Lockstep: golden byte read #i <-> sim 16-bit read cycle #i. A golden
    # byte read of byte B must appear as a sim cycle at B&~1 with the byte
    # in the lane B&1 selects (odd -> data[7:0], even -> data[15:8]).
    n = min(len(g_bytes), len(s_reads))
    div = None
    for i in range(n):
        _, gf, gpc, ga, gv = g_bytes[i]
        _, sa, sd = s_reads[i]
        sv = (sd & 0xFF) if (ga & 1) else (sd >> 8) & 0xFF
        if (ga & ~1) != sa or gv != sv:
            div = i
            break
    if div is None:
        if len(g_bytes) <= len(s_reads):
            print(f"WALK MATCHES: all {n} golden byte reads reproduced"
                  f" byte-exact by the sim stream")
            extra = len(s_reads) - len(g_bytes)
            if extra:
                print(f"  sim continues with {extra} further read cycles"
                      f" (PrimaryInit longs + post-walk driver traffic)")
        else:
            print(f"sim stream ENDS after {n} reads (golden has"
                  f" {len(g_bytes)}) — sim died mid-walk at:")
            for e in g_bytes[n:n + ctx]:
                print(f"  golden-only: F{e[1]} pc={e[2]:08X} "
                      f"addr={e[3]:08X} val={e[4]:02X}")
    else:
        _, gf, gpc, ga, gv = g_bytes[div]
        _, sa, sd = s_reads[div]
        kind = "ADDRESS PATH" if (ga & ~1) != sa else "DATA"
        print(f"FIRST DIVERGENCE at read #{div} ({kind}):")
        print(f"  golden: F{gf} pc={gpc:08X} byte addr={ga:08X} val={gv:02X}")
        print(f"  sim:    cycle addr={sa:08X} data={sd:04X}")
        print(f"  context (golden byte | sim cycle):")
        for i in range(max(0, div - ctx), min(n, div + ctx + 1)):
            _, gf, gpc, ga, gv = g_bytes[i]
            _, sa, sd = s_reads[i]
            sv = (sd & 0xFF) if (ga & 1) else (sd >> 8) & 0xFF
            mark = " <-- " if i == div else ""
            eq = "  " if ((ga & ~1) == sa and gv == sv) else "!="
            print(f"  #{i:6d} {ga:08X}={gv:02X} {eq} {sa:08X}={sd:04X}{mark}")

    # The 32-bit PrimaryInit reads appear in the sim stream as TWO 16-bit
    # cycles right after the byte walk. Show both sides for eyeballing.
    print()
    print("golden 32-bit reads (PrimaryInit phase):")
    for f, pc, a, d in g_longs:
        print(f"  F{f} pc={pc:08X} addr={a:08X} data={d:08X}")
    base = len(g_bytes)
    if len(s_reads) > base:
        print(f"sim read cycles #{base}..#{min(len(s_reads), base + 2 * len(g_longs) + ctx) - 1}"
              f" (should cover the longs, two cycles each):")
        for seq, a, d in s_reads[base:base + 2 * len(g_longs) + ctx]:
            print(f"  #{seq} addr={a:08X} data={d:04X}")
    if s_writes:
        print(f"sim writes: {len(s_writes)} total, first {ctx}:")
        for a, d in s_writes[:ctx]:
            print(f"  addr={a:08X} data={d:04X}")


if __name__ == "__main__":
    main()
