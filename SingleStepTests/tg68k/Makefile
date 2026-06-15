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
           -Wno-INITIALDLY -Wno-SYNCASYNCNET -Wno-ALWNEVER

# Per CLAUDE.md: verilator uses the ghdl-generated .v sources + the SV pkg.
# The standalone TG68KdotC_Kernel.v (from convert_to_verilog.sh) bundles the
# kernel + ALU + PMMU as self-contained modules, so it is the only RTL needed.
V_SRC = \
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
