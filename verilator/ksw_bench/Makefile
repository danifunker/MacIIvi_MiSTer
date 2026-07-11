V       = verilator
TOP     = --top-module ksw_top
RTL     = ../../rtl
V_DEFINE = +define+SIMULATION=1 \
           --timescale-override 1ps/1ps \
           -Wno-TIMESCALEMOD -Wno-fatal \
           -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-IMPLICIT \
           -Wno-PINMISSING -Wno-UNUSEDSIGNAL -Wno-UNOPTFLAT \
           -Wno-CASEINCOMPLETE -Wno-UNSIGNED -Wno-CMPCONST \
           -Wno-LATCH -Wno-UNDRIVEN -Wno-MISINDENT -Wno-COMBDLY \
           -Wno-INITIALDLY -Wno-SYNCASYNCNET -Wno-BLKANDNBLK

V_SRC = ksw_top.v $(RTL)/tg68k/TG68KdotC_Kernel.v
C_SRC = ksw_bench.cpp
V_OPT = --x-assign fast --x-initial fast --noassert
EXE   = ./obj_dir/Vksw_top

all: $(EXE)

obj_dir/Vksw_top.cpp: $(V_SRC) Makefile
	$V -cc $(V_OPT) -exe --Mdir ./obj_dir $(V_DEFINE) $(TOP) $(V_SRC) $(C_SRC)

$(EXE): obj_dir/Vksw_top.cpp $(C_SRC)
	cd obj_dir && $(MAKE) -f Vksw_top.mk OBJCACHE=

run: $(EXE)
	$(EXE)

clean:
	rm -rf obj_dir

.PHONY: all run clean
