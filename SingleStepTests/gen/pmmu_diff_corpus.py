#!/usr/bin/env python3
"""pmmu_diff_corpus.py -- compare a PMMU bench run (real hardware via
preboot/supervisor_bench/pmmu_bench_main.c, or the MAME harness build)
against the MAME oracle corpus (results/pmmu/mame_baseline_*.json).

The bench RELOCATES the corpus's fixed addresses into payload statics
and reports the mapping in its first JSONL line ({"reloc":...}). This
tool translates corpus-side addresses through that mapping before
comparing:
  - A-register values that point into corpus regions (e.g. the PTEST
    descriptor-address writeback)
  - CRP/SRP aptr values
  - descriptor address fields inside the table windows

Fault rows: the bench can't capture GP registers (the epilogue never
ran), and exception-frame PC/address fields are payload-relative — for
those rows we compare the taken vector, the PSR, the table/remap
windows, and the stacked frame's format/vector word only.

Usage:
  pmmu_diff_corpus.py <mame_baseline.json> <bench_run.jsonl> [--verbose]
"""
import json
import sys

WINDOWS = [(0x1800, 0x40), (0x3000, 0x40), (0x3100, 0x40), (0x3200, 0x40),
           (0x4000, 0x40), (0x9000, 0x40), (0xA000, 0x40), (0x7FFA0, 0x60)]
TABLE_WINDOWS = {0x3000, 0x3100, 0x3200, 0x4000}

# Vectors the corpus fault rows take (by name fragment).
EXPECTED_VEC = [("FAULT store", 2), ("bad geometry", 56)]


def load_jsonl(path):
    rows = []
    for line in open(path, "rb").read().decode("ascii", "replace").splitlines():
        line = line.strip().strip("\x00").rstrip()
        if not line or not line.startswith("{"):
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    return rows


class Reloc:
    REGIONS = [("data", 0x1800, 0x40), ("root", 0x3000, 0x40),
               ("levb", 0x3100, 0x40), ("levc", 0x3200, 0x40),
               ("srp", 0x4000, 0x40), ("remap1", 0x9000, 0x1000),
               ("remap2", 0xA000, 0x1000)]

    def __init__(self, hdr):
        self.map = hdr
        self.masked_levb = set(hdr.get("masked_levb_slots", []))

    def addr(self, a):
        if a == 0x17F8:
            return self.map["tc_off"]
        for name, base, size in self.REGIONS:
            if base <= a < base + size:
                return self.map[name] + (a - base)
        if a == 0x80000:
            return self.map["stack_top"]
        if a == 0x70000:
            return self.map["stack_top"] & 0xFFFF0000
        return a

    def desc(self, v):
        dt = v & 3
        if dt == 0:
            return v
        if dt in (2, 3):
            return self.addr(v & 0xFFFFFFF0) | (v & 0xF)
        return self.addr(v & 0xFFFFFF00) | (v & 0xFF)


def corpus_expected_windows(row):
    """Reconstruct per-window expected byte arrays from initial.ram
    (plants) overlaid with final.ram (diffs)."""
    mem = {}
    for a, b in row["initial"]["ram"]:
        mem[a] = b
    for a, b in row["final"]["ram"]:
        mem[a] = b
    out = {}
    for base, length in WINDOWS:
        out[base] = [mem.get(base + i, 0) for i in range(length)]
    return out


def bench_windows(brow):
    out = {}
    for w in brow.get("windows", []):
        if "hex" in w:
            data = bytes.fromhex(w["hex"])
        else:
            data = bytes(w["bytes"])
        out[w["base"]] = list(data)
    return out


def translate_table_window(reloc, base, expected, masked_slots=()):
    """Apply descriptor-address relocation to a corpus table window and
    zero runner-masked slots."""
    out = list(expected)
    for i in range(0, len(expected), 4):
        v = int.from_bytes(bytes(expected[i:i+4]), "big")
        nv = reloc.desc(v)
        out[i:i+4] = nv.to_bytes(4, "big")
    if base == 0x3100:
        for slot in masked_slots:
            out[slot*4:slot*4+4] = b"\x00\x00\x00\x00"
    return out


U_BIT = 0x08
M_BIT = 0x10

# Descriptor slots whose U/M flags encode WHERE the capture
# environment's program, vectors, stack, and tables lived (their own
# fetches/stores walk the tables too). The relocated runner touches
# different descriptors for the same activity, so these flags are
# environment artifacts, not corpus signal. The remap-page descriptors
# (levc[8..15]) keep strict U+M comparison — they ARE the signal.
ENV_SLOTS = {0x3100: (0, 7), 0x3200: (0, 1, 2, 3)}

def mask_placement_bits(base, buf):
    """On mmu_live / fault rows: clear U everywhere (any walk sets
    it) and clear M on the environment slots above."""
    out = list(buf)
    for i in range(3, len(out), 4):
        out[i] &= ~U_BIT & 0xFF
    for slot in ENV_SLOTS.get(base, ()):
        out[slot*4+3] &= ~M_BIT & 0xFF
    return out


def main():
    verbose = "--verbose" in sys.argv
    base_rows = {r["name"]: r for r in load_jsonl(sys.argv[1])}
    bench = load_jsonl(sys.argv[2])

    reloc = None
    n_pass = n_fail = n_skip = 0
    for brow in bench:
        if "reloc" in brow:
            reloc = Reloc(brow["reloc"])
            continue
        if "identity_probe" in brow:
            print(f"identity_probe: {brow['identity_probe']}")
            continue
        name = brow.get("name")
        if name is None or reloc is None:
            continue
        if brow.get("skipped"):
            n_skip += 1
            continue
        crow = base_rows.get(name)
        if crow is None:
            print(f"?? no corpus row: {name}")
            n_fail += 1
            continue

        problems = []
        is_fault = crow["flags"]["raises_exception"]

        # vector
        want_vec = 0
        if is_fault:
            for frag, v in EXPECTED_VEC:
                if frag in name:
                    want_vec = v
        if "known-bad" in name:
            want_vec = brow["vec"]    # MAME oracle no-ops RTM; HW may trap
        if brow["vec"] != want_vec:
            problems.append(f"vec: got {brow['vec']}, expected {want_vec}")

        # MMU regs (always capturable)
        cm = crow["final"]["mmu"]
        bm = brow["final"]["mmu"]
        for k in ("tc", "tt0", "tt1", "psr"):
            if bm[k] != cm[k]:
                problems.append(f"mmu.{k}: got {bm[k]:#x}, expected {cm[k]:#x}")
        for k in ("crp_aptr", "srp_aptr"):
            # accept translated (register survived from the relocated
            # initial state) or raw (the test itself reloaded it from
            # raw data-window plants, e.g. the PMOVE round-trip rows)
            if bm[k] not in (reloc.addr(cm[k]), cm[k]):
                problems.append(
                    f"mmu.{k}: got {bm[k]:#x}, expected "
                    f"{reloc.addr(cm[k]):#x} or {cm[k]:#x}")
        for k in ("crp_limit", "srp_limit"):
            if bm[k] != cm[k]:
                problems.append(f"mmu.{k}: got {bm[k]:#x}, expected {cm[k]:#x}")

        # GP regs (non-fault rows only)
        if not is_fault and brow.get("regs_valid"):
            cd, ca = crow["final"]["d"], crow["final"]["a"]
            bd, ba = brow["final"]["d"], brow["final"]["a"]
            for i in range(8):
                if bd[i] != cd[i]:
                    problems.append(f"d{i}: got {bd[i]:#x}, expected {cd[i]:#x}")
            for i in range(7):
                # raw (walk VAs pass through unrelocated) or translated
                # (the PTEST descriptor-address writeback is physical)
                if ba[i] not in (ca[i], reloc.addr(ca[i])):
                    problems.append(
                        f"a{i}: got {ba[i]:#x}, expected {ca[i]:#x} "
                        f"or {reloc.addr(ca[i]):#x}")
            if ba[7] != reloc.addr(ca[7]):
                problems.append(
                    f"a7: got {ba[7]:#x}, expected {reloc.addr(ca[7]):#x}")

        # windows
        cw = corpus_expected_windows(crow)
        bw = bench_windows(brow)
        for base, length in WINDOWS:
            if base not in bw:
                continue
            expected = cw[base]
            if base in TABLE_WINDOWS:
                expected = translate_table_window(
                    reloc, base, expected, reloc.masked_levb)
            got = bw[base]
            if base in TABLE_WINDOWS and (crow["flags"]["mmu_live"] or is_fault):
                expected = mask_placement_bits(base, expected)
                got = mask_placement_bits(base, got)
            if base == 0x7FFA0:
                if not is_fault:
                    if any(got):
                        problems.append("stack window dirty on non-fault row")
                else:
                    # compare only the frame's format/vector word
                    a7_off = (crow["final"]["a"][7] - 0x7FFA0)
                    fv_off = a7_off + 6
                    if 0 <= fv_off < length - 1:
                        if got[fv_off:fv_off+2] != expected[fv_off:fv_off+2]:
                            problems.append(
                                f"frame fmt/vec: got "
                                f"{bytes(got[fv_off:fv_off+2]).hex()}, expected "
                                f"{bytes(expected[fv_off:fv_off+2]).hex()}")
                continue
            if got != expected:
                diffs = [i for i in range(length) if got[i] != expected[i]]
                problems.append(
                    f"window ${base:X}: {len(diffs)} byte diffs at "
                    f"+{[hex(d) for d in diffs[:8]]}")

        if problems:
            n_fail += 1
            print(f"FAIL {name}")
            for p in problems[: None if verbose else 4]:
                print(f"      {p}")
        else:
            n_pass += 1
            if verbose:
                print(f"PASS {name}")

    print(f"\n{n_pass} passed, {n_fail} failed, {n_skip} skipped "
          f"(corpus rows: {len(base_rows)})")
    return 1 if n_fail else 0


if __name__ == "__main__":
    sys.exit(main())
