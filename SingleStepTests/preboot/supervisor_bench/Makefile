# Macintosh IIvi / LC II supervisor bench — boot-block + freestanding
# payload variants. (Inherited from the Mac II project; the boot path
# and 1 bpp paint kernel are machine-independent enough to carry over.)
#
# Targets:
#   make all           — boot_stub + payload skeleton (compatibility)
#   make scsi          — SCSI-bootable skeleton (boot_stub_scsi + payload_scsi)
#   make cpu_scsi      — CPU test bench, SCSI, 1 bpp paint (production)
#   make minimal       — minimal-bringup boot stub
#   make probe         — display polarity probe (was: m2hires_probe)
#   make calibrate     — display stride calibration (was: m2hires_calibrate)
#   make strides       — multi-stride bracket display (was: m2hires_v3)
#   make cpu_scsi_8bpp — 8 bpp paint CPU bench (was: cpu_scsi_m2hires).
#                        DEFERRED — needs depth-switch init code.
#
# The 1 bpp paint kernel ($(COMMON)/display/display_1bpp.c) works on
# Toby, m2hires, and mdc824 in their power-on 1 bpp default. 8 bpp
# requires writing the TFB / Bt453 / Apple Display Card init registers
# first — that work is not yet present, so the _8bpp targets won't
# render correctly on hardware today and are kept around as scaffolding.

include ../common/make/common.mk

BUILD := build

COMMON_RUNTIME := $(COMMON)/runtime
COMMON_DISPLAY := $(COMMON)/display
COMMON_OLD     := $(COMMON)/display/old
COMMON_DIAGS   := $(COMMON)/display/diagnostics
COMMON_BOOT    := $(COMMON)/boot

SIZE := $(PREFIX)size

.PHONY: all clean scsi cpu_scsi cpu minimal probe calibrate strides cpu_scsi_8bpp sizes
all: $(BUILD)/boot_stub_floppy.bin $(BUILD)/payload.bin sizes
scsi:        $(BUILD)/boot_stub_scsi.bin $(BUILD)/payload_scsi.bin
cpu_scsi:    $(BUILD)/boot_stub_scsi.bin $(BUILD)/payload_cpu_scsi.bin
# Consolidated CPU bench (full corpus) on the PAYLDOFF-patchable boot
# stub so the same payload boots from either a floppy (.dsk) or a SCSI
# disk (.hda) — build_dsk.sh / build_hda.sh place /Payload anywhere and
# patch the offset, rather than relying on the fixed 0x51600 layout.
cpu:         $(BUILD)/boot_stub_patch.bin $(BUILD)/payload_cpu_scsi.bin
# PMMU bench (gen/pmmu_tests.h + pmmu_bench_main.c): supervisor-mode
# 68030 PMMU correctness tests for the Macintosh LC II / IIvi.
#   pmmu       — hw-safe rows only (translation never enabled)
#   pmmu_full  — every row, incl. live translation + deliberate faults.
#                Boot only after the safe image runs clean.
# *_auto variants use runtime ScrnRow stride detection (one image works
# on mdc824 + LC II V8 + IIvi VASP displays); the plain variants paint
# at the fixed 80-byte mdc824 stride.
pmmu:           $(BUILD)/boot_stub_patch.bin $(BUILD)/payload_pmmu_scsi.bin
pmmu_auto:      $(BUILD)/boot_stub_patch.bin $(BUILD)/payload_pmmu_scsi_auto.bin
pmmu_full:      $(BUILD)/boot_stub_patch.bin $(BUILD)/payload_pmmu_full_scsi.bin
pmmu_full_auto: $(BUILD)/boot_stub_patch.bin $(BUILD)/payload_pmmu_full_scsi_auto.bin
cpu_auto:       $(BUILD)/boot_stub_patch.bin $(BUILD)/payload_cpu_scsi_auto.bin
# Everything the prebuilt images need, in one shot:
prebuilt_payloads: cpu cpu_auto pmmu pmmu_auto pmmu_full pmmu_full_auto
.PHONY: pmmu pmmu_auto pmmu_full pmmu_full_auto cpu_auto prebuilt_payloads
minimal:     $(BUILD)/boot_stub_minimal.bin
probe:       $(BUILD)/boot_stub_probe.bin
calibrate:   $(BUILD)/boot_stub_calibrate.bin
strides:     $(BUILD)/boot_stub_strides.bin
cpu_scsi_8bpp: $(BUILD)/boot_stub_scsi_8bpp.bin $(BUILD)/payload_cpu_scsi_8bpp.bin

$(BUILD):
	mkdir -p $@

# ---------- Shared runtime objects (from preboot/common) ----------
$(BUILD)/jsonl_writer.o: $(COMMON_RUNTIME)/jsonl_writer.c | $(BUILD)
	$(CC) $(CFLAGS) -c -o $@ $<
$(BUILD)/freestanding.o: $(COMMON_RUNTIME)/freestanding.c | $(BUILD)
	$(CC) $(CFLAGS) -c -o $@ $<
$(BUILD)/eject.o: $(COMMON_RUNTIME)/eject.c $(COMMON_RUNTIME)/eject.h | $(BUILD)
	$(CC) $(CFLAGS) -c -o $@ $<
$(BUILD)/recovery.o: $(COMMON_RUNTIME)/recovery.s | $(BUILD)
	$(AS) $(ASFLAGS) -o $@ $<
$(BUILD)/exception_handlers.o: $(COMMON_RUNTIME)/exception_handlers.s | $(BUILD)
	$(AS) $(ASFLAGS) -o $@ $<

# ---------- 1 bpp display kernel (canonical for current hardware) ----------
$(BUILD)/font_ascii.o: $(COMMON_DISPLAY)/display_1bpp.c | $(BUILD)
	$(CC) $(CFLAGS) -c -o $@ $<

# ---------- Bench-local sources ----------
$(BUILD)/payload_entry.o: payload_entry.s | $(BUILD)
	$(AS) $(ASFLAGS) -o $@ $<
$(BUILD)/payload_entry_cpu.o: payload_entry_cpu.s | $(BUILD)
	$(AS) $(ASFLAGS) -o $@ $<
$(BUILD)/payload_entry_scsi.o: payload_entry_scsi.s | $(BUILD)
	$(AS) $(ASFLAGS) -o $@ $<
$(BUILD)/variant_cpu_scsi.o: variant_cpu_scsi.s | $(BUILD)
	$(AS) $(ASFLAGS) -o $@ $<
$(BUILD)/bench_main.o: bench_main.c | $(BUILD)
	$(CC) $(CFLAGS) -c -o $@ $<

# ---------- PMMU bench objects ----------
# recovery with the translation-off guard at recovery_core entry.
$(BUILD)/recovery_pmmu.o: $(COMMON_RUNTIME)/recovery.s | $(BUILD)
	$(AS) $(ASFLAGS) --defsym PMMU_RECOVERY=1 -o $@ $<
$(BUILD)/pmmu_bench_main.o: pmmu_bench_main.c ../../gen/pmmu_tests.h | $(BUILD)
	$(CC) $(CFLAGS) -c -o $@ $<
$(BUILD)/pmmu_bench_main_full.o: pmmu_bench_main.c ../../gen/pmmu_tests.h | $(BUILD)
	$(CC) $(CFLAGS) -DPMMU_FULL -c -o $@ $<
# Display kernel with runtime ScrnRow stride detection (see common.mk
# VIDEO_VARIANT=auto). Built explicitly here so one make run can link
# both the fixed-stride and auto payloads.
$(BUILD)/font_ascii_auto.o: $(COMMON_DISPLAY)/display_1bpp.c | $(BUILD)
	$(CC) $(CFLAGS) -DROW_BYTES_AUTO -c -o $@ $<
# MAME-verification harness build: full corpus, results accumulated in
# RAM (no _Write), Lua-injected at frame 1. Never shipped on images.
$(BUILD)/pmmu_bench_main_harness.o: pmmu_bench_main.c ../../gen/pmmu_tests.h | $(BUILD)
	$(CC) $(CFLAGS) -DPMMU_FULL -DPMMU_MAME_HARNESS -c -o $@ $<
PMMU_HARNESS_OBJS := $(BUILD)/payload_entry_cpu.o \
                     $(BUILD)/variant_cpu_scsi.o \
                     $(BUILD)/freestanding.o \
                     $(BUILD)/eject.o \
                     $(BUILD)/recovery_pmmu.o \
                     $(BUILD)/pmmu_bench_main_harness.o \
                     $(BUILD)/font_ascii.o
$(BUILD)/payload_pmmu_harness.elf: $(PMMU_HARNESS_OBJS) $(PAYLOAD_LD)
	$(LD) $(LDFLAGS) -T $(PAYLOAD_LD) -o $@ $(PMMU_HARNESS_OBJS)
pmmu_harness: $(BUILD)/payload_pmmu_harness.bin
.PHONY: pmmu_harness

# ---------- Boot blocks (production + diagnostic) ----------
# Production: lives in preboot/common/boot/. Floppy (non-SCSI) variant
# was 'boot_stub.s'; renamed to clarify it's the floppy version.
$(BUILD)/boot_stub_floppy.o:  $(COMMON_BOOT)/boot_stub_floppy.s | $(BUILD)
	$(AS) $(ASFLAGS) -o $@ $<
# supervisor_bench's historical SCSI boot block hardcoded /Payload at
# offset 0x51600; the newer PAYLDOFF-patchable one is in $(COMMON_BOOT)/boot_stub_scsi.s
# (and used by iotest). Until supervisor_bench migrates to that, we
# keep the older fixed-offset version available.
$(BUILD)/boot_stub_scsi.o:    $(COMMON_BOOT)/boot_stub_scsi_fixed_offset.s | $(BUILD)
	$(AS) $(ASFLAGS) -o $@ $<
# PAYLDOFF-patchable SCSI boot stub (same one iotest uses): /Payload
# offset is a patched marker, not hardcoded, so the build script can
# place the payload wherever the HFS allocator puts it.
$(BUILD)/boot_stub_patch.o:   $(COMMON_BOOT)/boot_stub_scsi.s | $(BUILD)
	$(AS) $(ASFLAGS) -o $@ $<
# Diagnostic stubs (was: boot_stub_m2hires_{probe,calibrate,v3}.s)
$(BUILD)/boot_stub_minimal.o:    $(COMMON_DIAGS)/boot_stub_minimal.s | $(BUILD)
	$(AS) $(ASFLAGS) -o $@ $<
$(BUILD)/boot_stub_probe.o:      $(COMMON_DIAGS)/boot_stub_probe.s | $(BUILD)
	$(AS) $(ASFLAGS) -o $@ $<
$(BUILD)/boot_stub_calibrate.o:  $(COMMON_DIAGS)/boot_stub_calibrate.s | $(BUILD)
	$(AS) $(ASFLAGS) -o $@ $<
$(BUILD)/boot_stub_strides.o:    $(COMMON_DIAGS)/boot_stub_strides.s | $(BUILD)
	$(AS) $(ASFLAGS) -o $@ $<

# ---------- 8 bpp kept as scaffolding (preboot/common/display/old) ----------
$(BUILD)/boot_stub_scsi_8bpp.o:        $(COMMON_OLD)/boot_stub_scsi_m2hires.s | $(BUILD)
	$(AS) $(ASFLAGS) -o $@ $<
$(BUILD)/payload_entry_cpu_8bpp.o:     $(COMMON_OLD)/payload_entry_cpu_m2hires.s | $(BUILD)
	$(AS) $(ASFLAGS) -o $@ $<
$(BUILD)/font_ascii_8bpp.o:            $(COMMON_OLD)/font_ascii_m2hires.c | $(BUILD)
	$(CC) $(CFLAGS) -c -o $@ $<

# ---------- Linker rules ----------
%.elf:
	$(LD) $(LDFLAGS) -T $(BOOT_STUB_LD) -o $@ $^
%.bin: %.elf
	$(OBJCOPY) -O binary $< $@

# Boot-stub ELFs (one rule per stub since stems differ).
$(BUILD)/boot_stub_floppy.elf:    $(BUILD)/boot_stub_floppy.o    $(BOOT_STUB_LD) ; $(LD) $(LDFLAGS) -T $(BOOT_STUB_LD) -o $@ $<
$(BUILD)/boot_stub_scsi.elf:      $(BUILD)/boot_stub_scsi.o      $(BOOT_STUB_LD) ; $(LD) $(LDFLAGS) -T $(BOOT_STUB_LD) -o $@ $<
$(BUILD)/boot_stub_patch.elf:     $(BUILD)/boot_stub_patch.o     $(BOOT_STUB_LD) ; $(LD) $(LDFLAGS) -T $(BOOT_STUB_LD) -o $@ $<
$(BUILD)/boot_stub_minimal.elf:   $(BUILD)/boot_stub_minimal.o   $(BOOT_STUB_LD) ; $(LD) $(LDFLAGS) -T $(BOOT_STUB_LD) -o $@ $<
$(BUILD)/boot_stub_probe.elf:     $(BUILD)/boot_stub_probe.o     $(BOOT_STUB_LD) ; $(LD) $(LDFLAGS) -T $(BOOT_STUB_LD) -o $@ $<
$(BUILD)/boot_stub_calibrate.elf: $(BUILD)/boot_stub_calibrate.o $(BOOT_STUB_LD) ; $(LD) $(LDFLAGS) -T $(BOOT_STUB_LD) -o $@ $<
$(BUILD)/boot_stub_strides.elf:   $(BUILD)/boot_stub_strides.o   $(BOOT_STUB_LD) ; $(LD) $(LDFLAGS) -T $(BOOT_STUB_LD) -o $@ $<
$(BUILD)/boot_stub_scsi_8bpp.elf: $(BUILD)/boot_stub_scsi_8bpp.o $(BOOT_STUB_LD) ; $(LD) $(LDFLAGS) -T $(BOOT_STUB_LD) -o $@ $<

# ---------- Payload variants ----------
PAYLOAD_OBJS := $(BUILD)/payload_entry.o $(BUILD)/exception_handlers.o \
                $(BUILD)/bench_main.o    $(BUILD)/jsonl_writer.o \
                $(BUILD)/eject.o
$(BUILD)/payload.elf: $(PAYLOAD_OBJS) $(PAYLOAD_LD)
	$(LD) $(LDFLAGS) -T $(PAYLOAD_LD) -o $@ $(PAYLOAD_OBJS)

SCSI_OBJS := $(BUILD)/payload_entry_scsi.o
$(BUILD)/payload_scsi.elf: $(SCSI_OBJS) $(PAYLOAD_LD)
	$(LD) $(LDFLAGS) -T $(PAYLOAD_LD) -o $@ $(SCSI_OBJS)

CPU_SCSI_OBJS := $(BUILD)/payload_entry_cpu.o \
                 $(BUILD)/variant_cpu_scsi.o \
                 $(BUILD)/bench_main.o \
                 $(BUILD)/jsonl_writer.o \
                 $(BUILD)/freestanding.o \
                 $(BUILD)/eject.o \
                 $(BUILD)/font_ascii.o \
                 $(BUILD)/recovery.o
$(BUILD)/payload_cpu_scsi.elf: $(CPU_SCSI_OBJS) $(PAYLOAD_LD)
	$(LD) $(LDFLAGS) -T $(PAYLOAD_LD) -o $@ $(CPU_SCSI_OBJS)

# CPU bench, auto-stride display.
CPU_SCSI_AUTO_OBJS := $(BUILD)/payload_entry_cpu.o \
                      $(BUILD)/variant_cpu_scsi.o \
                      $(BUILD)/bench_main.o \
                      $(BUILD)/jsonl_writer.o \
                      $(BUILD)/freestanding.o \
                      $(BUILD)/eject.o \
                      $(BUILD)/font_ascii_auto.o \
                      $(BUILD)/recovery.o
$(BUILD)/payload_cpu_scsi_auto.elf: $(CPU_SCSI_AUTO_OBJS) $(PAYLOAD_LD)
	$(LD) $(LDFLAGS) -T $(PAYLOAD_LD) -o $@ $(CPU_SCSI_AUTO_OBJS)

# PMMU bench payloads: {safe,full} x {fixed-80,auto} display.
PMMU_BASE_OBJS := $(BUILD)/payload_entry_cpu.o \
                  $(BUILD)/variant_cpu_scsi.o \
                  $(BUILD)/jsonl_writer.o \
                  $(BUILD)/freestanding.o \
                  $(BUILD)/eject.o \
                  $(BUILD)/recovery_pmmu.o
$(BUILD)/payload_pmmu_scsi.elf: $(PMMU_BASE_OBJS) $(BUILD)/pmmu_bench_main.o $(BUILD)/font_ascii.o $(PAYLOAD_LD)
	$(LD) $(LDFLAGS) -T $(PAYLOAD_LD) -o $@ $(PMMU_BASE_OBJS) $(BUILD)/pmmu_bench_main.o $(BUILD)/font_ascii.o
$(BUILD)/payload_pmmu_scsi_auto.elf: $(PMMU_BASE_OBJS) $(BUILD)/pmmu_bench_main.o $(BUILD)/font_ascii_auto.o $(PAYLOAD_LD)
	$(LD) $(LDFLAGS) -T $(PAYLOAD_LD) -o $@ $(PMMU_BASE_OBJS) $(BUILD)/pmmu_bench_main.o $(BUILD)/font_ascii_auto.o
$(BUILD)/payload_pmmu_full_scsi.elf: $(PMMU_BASE_OBJS) $(BUILD)/pmmu_bench_main_full.o $(BUILD)/font_ascii.o $(PAYLOAD_LD)
	$(LD) $(LDFLAGS) -T $(PAYLOAD_LD) -o $@ $(PMMU_BASE_OBJS) $(BUILD)/pmmu_bench_main_full.o $(BUILD)/font_ascii.o
$(BUILD)/payload_pmmu_full_scsi_auto.elf: $(PMMU_BASE_OBJS) $(BUILD)/pmmu_bench_main_full.o $(BUILD)/font_ascii_auto.o $(PAYLOAD_LD)
	$(LD) $(LDFLAGS) -T $(PAYLOAD_LD) -o $@ $(PMMU_BASE_OBJS) $(BUILD)/pmmu_bench_main_full.o $(BUILD)/font_ascii_auto.o

CPU_SCSI_8BPP_OBJS := $(BUILD)/payload_entry_cpu_8bpp.o \
                      $(BUILD)/variant_cpu_scsi.o \
                      $(BUILD)/bench_main.o \
                      $(BUILD)/jsonl_writer.o \
                      $(BUILD)/freestanding.o \
                      $(BUILD)/eject.o \
                      $(BUILD)/font_ascii_8bpp.o \
                      $(BUILD)/recovery.o
$(BUILD)/payload_cpu_scsi_8bpp.elf: $(CPU_SCSI_8BPP_OBJS) $(PAYLOAD_LD)
	$(LD) $(LDFLAGS) -T $(PAYLOAD_LD) -o $@ $(CPU_SCSI_8BPP_OBJS)

# Generic ELF→.bin rule for payloads (boot stubs have explicit rules above).
$(BUILD)/payload%.bin: $(BUILD)/payload%.elf
	$(OBJCOPY) -O binary $< $@

sizes: $(BUILD)/boot_stub_floppy.bin $(BUILD)/payload.bin
	@echo "--- sizes ---"
	@wc -c $(BUILD)/boot_stub_floppy.bin $(BUILD)/payload.bin

clean:
	rm -rf $(BUILD)
