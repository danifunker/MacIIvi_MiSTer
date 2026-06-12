# 680x0 Function Codes, MOVES, and the FC=0 Bus Error

> Carried over from the Mac II (68020) project. Function-code semantics
> are identical on the Macintosh IIvi's 68030 (FC2:0 lines, FC=0
> "Undefined, Reserved", SFC/DFC via MOVEC) — with one addition: on the
> 68030 the function code also selects the PMMU translation root
> (TC.SRE) and is an input to TT0/TT1 transparent-translation matching
> and to PTEST/PLOAD/PFLUSH. The empirical Mac II observations below
> should be re-verified on the LC II during the hardware campaign.

While bringing up the supervisor bench (`SingleStepTests/supervisor_bench/`)
on real Mac II hardware, our first privileged test (`MOVES.L D0,(A1)`,
test index 171 in the corpus) raised a **bus error (vector 2)** even
though the destination address in A1 was perfectly valid RAM in our
own static `scratch_ram` buffer. The cause is architecturally subtle
and is worth recording: it affects any code that uses `MOVES` and
matters for our own FPGA core's bus decoding.

This page summarises the relevant 68020 architecture, the empirical
behaviour we observed on the Mac II, and the implications for our
core's NuBus + SCSI bus decoding logic.

References: `docs/MC68020UM.pdf` (Motorola MC68020/MC68EC020 User's
Manual, 1st ed., 1992) — sections cited inline below.

## 1. What function codes are

Every external bus cycle on the 68020 carries three function-code
signals **FC2, FC1, FC0** alongside the address. They tell the rest
of the system *which address space* the access belongs to. Per the
manual (§3.2), they're "three-state outputs [that] identify the
address space of the current bus cycle." So FC isn't a CPU mode bit
— it's a hardware signal pinned out on every cycle, on every Mac II
68020.

The full encoding (manual §2.2, Table 2-1):

| FC2 | FC1 | FC0 | Address Space |
|---|---|---|---|
| 0 | 0 | 0 | **(Undefined, Reserved)** — reserved for future use by Motorola |
| 0 | 0 | 1 | User Data Space |
| 0 | 1 | 0 | User Program Space |
| 0 | 1 | 1 | (Undefined, Reserved) — reserved for user definition |
| 1 | 0 | 0 | **(Undefined, Reserved)** — reserved for future use by Motorola |
| 1 | 0 | 1 | Supervisor Data Space |
| 1 | 1 | 0 | Supervisor Program Space |
| 1 | 1 | 1 | CPU Space (interrupt ack, breakpoint ack, coprocessor) |

Three encodings (0, 3, 4) are explicitly "Undefined, Reserved." The
manual doesn't specify what the hardware should do when it sees them
— that's a *system* design decision.

## 2. Normal vs MOVES bus cycles

For normal instructions (`MOVE.L D0,(A1)`, etc.) the CPU automatically
asserts FC based on its current mode:

- In **user mode**: FC = 1 (data) or 2 (program)
- In **supervisor mode**: FC = 5 (data) or 6 (program)
- For **interrupt ack / breakpoint / coprocessor**: FC = 7

The programmer never sees FC=0 from these instructions.

**`MOVES`** is the exception. From §2.2:

> Supervisor programs can use the MOVES instruction to access all
> address spaces, including the user spaces and the CPU address space.

The `MOVES` instruction sources FC from two dedicated control
registers: **SFC** (for `MOVES ea, Dn` — loads) and **DFC** (for
`MOVES Dn, ea` — stores). These are *3-bit* registers — they can
hold any value 0..7, including the "undefined" ones.

`SFC` and `DFC` are loaded with `MOVEC Dn, SFC` (`$4E7B`+ext `$0000`)
and `MOVEC Dn, DFC` (`$4E7B`+ext `$0001`). They are privileged
control registers — only accessible in supervisor mode.

## 3. The reset value problem

At hardware reset (§2.2 / §6 Exception Processing), the 68020
initializes a defined subset of state from the reset vector:

> During reset, the first two long words beginning at memory location
> zero in the supervisor program space are used for processor
> initialization. No other memory locations are explicitly defined by
> the MC68020/EC020.

That's the SSP and PC. **SFC and DFC are not in that defined set.**
The manual doesn't promise an initial value for them. In practice on
a 68020 cold reset they read back as 0 — i.e., the "Undefined,
Reserved" function code.

If supervisor code then executes a `MOVES` *without first programming
SFC/DFC*, the CPU drives FC=0 on the bus.

## 4. What the Mac II does with FC=0

Mac II's bus interface, like most real M68K systems, only decodes the
*defined* function codes (1, 2, 5, 6, 7) and the few specific FC=7
cycle subtypes. When it sees a cycle with FC=0:

- No address decoder claims it
- No device asserts `/DSACK` to acknowledge the cycle
- The bus times out
- `/BERR` is asserted
- CPU takes the **bus error exception** (vector 2)

That's what we saw: vector `00000002` for a `MOVES.L D0,(A1)` whose
destination address (in `A1`) was a perfectly valid RAM location.
The address was fine; the *function code* was the problem.

## 5. The fix in our bench

In `SingleStepTests/supervisor_bench/bench_main.c`, `build_program()`
now emits four extra instructions at the start of every test harness:

```asm
MOVEQ #5, D0          ; 5 = Supervisor Data Space
MOVEC D0, SFC         ; $4E7B 0000
MOVEC D0, DFC         ; $4E7B 0001
MOVEQ #0, D0          ; restore (we still want a clean D0 for tests)
```

With SFC = DFC = 5, every subsequent `MOVES` performs its load/store
under supervisor-data-space function codes, which the Mac II bus
happily decodes. The MOVES tests pass.

## 6. Implications for our FPGA core

This is the part that matters for `lbmactwo_MiSTer`. Our NuBus + main
bus decoders must be auditing FC2..FC0 the same way real Mac II
hardware does:

1. **FC=0 must NOT silently succeed.** If our core acknowledges FC=0
   accesses by routing them to (e.g.) RAM, programs that work on real
   hardware will *not* fault, and the divergence will only show up
   later in mysterious ways. The acceptable behaviours are: (a)
   acknowledge → bus error within a normal timeout window, or (b)
   leave the cycle unacknowledged so the bus timeout takes over.
   Either is consistent with real Mac II behaviour.

2. **FC=3 and FC=4** are the user-definable / Motorola-reserved
   encodings. Real Mac II hardware probably ignores these too; if
   our core handles them, it diverges from the reference.

3. **FC=7 (CPU space)** has its own subtypes encoded in A19..A16:
   - A19..A16 = `$F` → interrupt acknowledge (with vector level on A3..A1)
   - A19..A16 = `$2` → coprocessor access (Cp-ID in A15..A13)
   - A19..A16 = `$0` → breakpoint acknowledge

   These must be decoded correctly by our core — they aren't memory.

4. **MOVES test coverage.** Our SingleStepTests corpus has ~23
   privileged tests, several of which exercise MOVES. The corpus
   currently sets `t->preload` to the operand setup (loading D0, A1,
   etc.) but does NOT set SFC/DFC. The user-mode Mac bench skips these
   tests (they're privileged). Therefore the **supervisor harness**
   must set SFC/DFC for them. Our supervisor_bench now does this in
   `build_program()`; verilator / MAME oracle should also be checked
   to confirm they program SFC/DFC to 5 before MOVES.

## 7. Quick test: did our core get this right?

A targeted regression test for our FPGA core: at reset, supervisor
code reads SFC/DFC back as 0, executes `MOVES.L D0, (A1)` to a valid
RAM address, and expects a **bus error**. If our core completes the
write with no exception, we're more permissive than real hardware —
which means software bugs of this exact class will go undetected on
the FPGA but explode on real Mac II hardware.

A second regression: after `MOVEC #5, DFC`, the same `MOVES.L`
should succeed silently.

These two cases pin down the FC=0 behaviour and are simple to write
once the supervisor bench is fully operational.
