# Amiga 68030+PMMU test floppies — payload builds.
# See ../../../AMIGA_TESTBENCH.md. Shares bench_main.c /
# pmmu_bench_main.c / recovery.s / display_1bpp.c / jsonl_writer.c with
# the Mac preboot bench; only the platform layer here is Amiga-specific.

include ../common/make/common.mk

BUILD := build
SB    := ../supervisor_bench
COMMON_RUNTIME := $(COMMON)/runtime
COMMON_DISPLAY := $(COMMON)/display

# Amiga payloads paint a fixed 80-byte-stride bitplane we own, through
# the external-framebuffer hook; the JsonlWriter uses the trackdisk
# backend.
ACFLAGS := $(CFLAGS) -DDISPLAY_FB_EXTERN -DJW_BACKEND_EXTERN
PAYLOAD_AMIGA_LD := payload_amiga.ld

all: payloads
payloads: $(BUILD)/bootblock.bin \
          $(BUILD)/payload_cpu_amiga.bin \
          $(BUILD)/payload_pmmu_amiga.bin \
          $(BUILD)/payload_pmmu_full_amiga.bin
.PHONY: all payloads clean

$(BUILD):
	mkdir -p $@

# ---------- bootblock (flat 1024 bytes; checksum patched later) ------
$(BUILD)/bootblock.o: bootblock.s | $(BUILD)
	$(AS) $(ASFLAGS) -o $@ $<
$(BUILD)/bootblock.elf: $(BUILD)/bootblock.o
	$(LD) $(LDFLAGS) -Ttext=0 -o $@ $<
$(BUILD)/bootblock.bin: $(BUILD)/bootblock.elf
	$(OBJCOPY) -O binary $< $@

# ---------- platform objects -----------------------------------------
$(BUILD)/payload_entry_amiga.o: payload_entry_amiga.s | $(BUILD)
	$(AS) $(ASFLAGS) -o $@ $<
$(BUILD)/jsonl_trackdisk.o: jsonl_trackdisk.c | $(BUILD)
	$(CC) $(ACFLAGS) -c -o $@ $<
$(BUILD)/amiga_gate.o: amiga_gate.c | $(BUILD)
	$(CC) $(ACFLAGS) -c -o $@ $<
$(BUILD)/eject_amiga.o: eject_amiga.c | $(BUILD)
	$(CC) $(ACFLAGS) -c -o $@ $<

# ---------- shared objects, Amiga-flavored ---------------------------
$(BUILD)/jsonl_writer.o: $(COMMON_RUNTIME)/jsonl_writer.c | $(BUILD)
	$(CC) $(ACFLAGS) -c -o $@ $<
$(BUILD)/freestanding.o: $(COMMON_RUNTIME)/freestanding.c | $(BUILD)
	$(CC) $(ACFLAGS) -c -o $@ $<
$(BUILD)/font_ascii.o: $(COMMON_DISPLAY)/display_1bpp.c | $(BUILD)
	$(CC) $(ACFLAGS) -c -o $@ $<
$(BUILD)/recovery.o: $(COMMON_RUNTIME)/recovery.s | $(BUILD)
	$(AS) $(ASFLAGS) --defsym NO_SCRNBASE_DOT=1 -o $@ $<
$(BUILD)/recovery_pmmu.o: $(COMMON_RUNTIME)/recovery.s | $(BUILD)
	$(AS) $(ASFLAGS) --defsym NO_SCRNBASE_DOT=1 --defsym PMMU_RECOVERY=1 -o $@ $<
$(BUILD)/bench_main.o: $(SB)/bench_main.c ../../gen/cpu_tests.h | $(BUILD)
	$(CC) $(ACFLAGS) -I$(SB) -c -o $@ $<
$(BUILD)/pmmu_bench_main.o: $(SB)/pmmu_bench_main.c ../../gen/pmmu_tests.h | $(BUILD)
	$(CC) $(ACFLAGS) -I$(SB) -c -o $@ $<
$(BUILD)/pmmu_bench_main_full.o: $(SB)/pmmu_bench_main.c ../../gen/pmmu_tests.h | $(BUILD)
	$(CC) $(ACFLAGS) -I$(SB) -DPMMU_FULL -c -o $@ $<

# ---------- payloads ---------------------------------------------------
AMIGA_BASE_OBJS := $(BUILD)/payload_entry_amiga.o \
                   $(BUILD)/jsonl_trackdisk.o \
                   $(BUILD)/amiga_gate.o \
                   $(BUILD)/eject_amiga.o \
                   $(BUILD)/jsonl_writer.o \
                   $(BUILD)/freestanding.o \
                   $(BUILD)/font_ascii.o

$(BUILD)/payload_cpu_amiga.elf: $(AMIGA_BASE_OBJS) $(BUILD)/bench_main.o $(BUILD)/recovery.o $(PAYLOAD_AMIGA_LD)
	$(LD) $(LDFLAGS) -T $(PAYLOAD_AMIGA_LD) -o $@ $(AMIGA_BASE_OBJS) $(BUILD)/bench_main.o $(BUILD)/recovery.o
$(BUILD)/payload_pmmu_amiga.elf: $(AMIGA_BASE_OBJS) $(BUILD)/pmmu_bench_main.o $(BUILD)/recovery_pmmu.o $(PAYLOAD_AMIGA_LD)
	$(LD) $(LDFLAGS) -T $(PAYLOAD_AMIGA_LD) -o $@ $(AMIGA_BASE_OBJS) $(BUILD)/pmmu_bench_main.o $(BUILD)/recovery_pmmu.o
$(BUILD)/payload_pmmu_full_amiga.elf: $(AMIGA_BASE_OBJS) $(BUILD)/pmmu_bench_main_full.o $(BUILD)/recovery_pmmu.o $(PAYLOAD_AMIGA_LD)
	$(LD) $(LDFLAGS) -T $(PAYLOAD_AMIGA_LD) -o $@ $(AMIGA_BASE_OBJS) $(BUILD)/pmmu_bench_main_full.o $(BUILD)/recovery_pmmu.o

$(BUILD)/payload%.bin: $(BUILD)/payload%.elf
	$(OBJCOPY) -O binary $< $@

clean:
	rm -rf $(BUILD)
