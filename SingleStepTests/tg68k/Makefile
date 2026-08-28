# ── Bench repair notes (2026-08-07, LCII kernel import) ─────────────────────
# This bench was DOUBLY bit-rotted and could not build against any recent
# kernel. Both rots were independent of kernel contents (the identical failure
# reproduced against the previously committed kernel):
#   1. -Wno-ALWNEVER: the installed Verilator (5.020) does not define that
#      warning name and hard-errors on it. Dropped below.
#   2. No .vlt existed, so the two kernel-internal signals sim_main.cpp pokes
#      were optimized away -> "no member named" host-compile errors. Added
#      tg68k_tests.vlt (see V_SRC) marking them public_flat_rw.
# ★ tg68k_tests.vlt gotcha: its lexer rejects a LEADING comment block (syntax
#   error at the first line of prose, whatever the wording). Comments AFTER the
#   directives are fine — which is why the documentation lives here instead.
# ★ n17577_q is a GHDL-GENERATED, POSITIONAL name: it is the register behind
#   the kernel's `usp` wire, and EVERY reconvert of TG68KdotC_Kernel.vhd
#   renumbers it. After a reconvert, re-derive with
#       grep "assign usp = " ../../rtl/tg68k/TG68KdotC_Kernel.v
#   and update BOTH tg68k_tests.vlt AND the set_usp lambda in sim_main.cpp.
#   History: n15135 (bench authored) -> n16595_q -> n16619_q -> n17577_q.
V       = verilator
TOP     = --top-module tg68k_tests
RTL     = ../../rtl

SIM_INC = ../../verilator/sim
V_INC   = +incdir+$(RTL) +incdir+$(RTL)/tg68k

V_DEFINE = +define+SIMULATION=1 \
           -CFLAGS "-I.. -I$(SIM_INC) -g" \
           --timescale-override 1ps/1ps \
           -Wno-TIMESCALEMOD -Wno-fatal \
           -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-IMPLICIT \
           -Wno-PINMISSING -Wno-UNUSEDSIGNAL -Wno-UNOPTFLAT \
           -Wno-CASEINCOMPLETE -Wno-UNSIGNED -Wno-CMPCONST \
           -Wno-LATCH -Wno-UNDRIVEN -Wno-MISINDENT -Wno-COMBDLY \
           -Wno-INITIALDLY -Wno-SYNCASYNCNET
# -Wno-ALWNEVER dropped 2026-08-07: the installed Verilator (5.020) does not
# define that warning name and hard-errors on it ("Unknown warning specified"),
# so the bench could not build at all. No semantic change — the warning it
# suppressed does not exist in this version. Re-add only if a Verilator that
# defines ALWNEVER is adopted AND it fires.

# Per CLAUDE.md: verilator uses the ghdl-generated .v sources + the SV pkg.
# The standalone TG68KdotC_Kernel.v (from convert_to_verilog.sh) bundles the
# kernel + ALU + PMMU as self-contained modules, so it is the only RTL needed.
V_SRC = \
  tg68k_tests.vlt \
  tg68k_tests.v \
  $(RTL)/tg68k/TG68KdotC_Kernel.v

C_SRC = sim_main.cpp \
        $(SIM_INC)/m68kdasm.c \
        $(SIM_INC)/m68k_dasm_stubs.cpp

V_OPT = --x-assign fast --x-initial fast --noassert
EXE   = ./obj_dir/Vtg68k_tests
VOUT  = obj_dir/Vtg68k_tests.cpp

# Corpus is the in-repo MAME-derived oracle at
# SingleStepTests/results/cpu/mame_baseline_2026-05-16.json. No external
# download needed.

all: $(EXE)

$(VOUT): $(V_SRC) Makefile
	$V -cc $(V_OPT) -exe --Mdir ./obj_dir $(V_DEFINE) $(V_INC) $(TOP) \
	   $(V_SRC) $(C_SRC)

$(EXE): $(VOUT) $(C_SRC)
	cd obj_dir && $(MAKE) -f Vtg68k_tests.mk OBJCACHE=

run: $(EXE)
	$(EXE)

clean:
	rm -rf obj_dir

.PHONY: all run clean
