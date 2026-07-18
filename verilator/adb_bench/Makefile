# Standalone adb_device bench — seconds per run, no boot required.
VERILATOR ?= verilator
TOP = tb_adb

all: obj_dir/V$(TOP)

obj_dir/V$(TOP): tb_adb.sv ../../rtl/adb_device.sv sim_adb_main.cpp
	$(VERILATOR) -cc --exe --build -j 4 \
	  +define+SIMULATION=1 \
	  -Wno-WIDTH -Wno-CASEINCOMPLETE -Wno-UNUSED -Wno-UNDRIVEN \
	  -I../../rtl \
	  tb_adb.sv ../../rtl/adb_device.sv sim_adb_main.cpp \
	  -o V$(TOP)

run: obj_dir/V$(TOP)
	./obj_dir/V$(TOP)

clean:
	rm -rf obj_dir
