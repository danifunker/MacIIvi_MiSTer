# iotest — disk I/O timing bench (1B..4MB on .hda, 1B..128KB on .dsk).
#
# Two payload binaries:
#   payload_iotest_hda.bin  — SCSI variant, 12 sizes (1B .. 4MB)
#   payload_iotest_dsk.bin  — Floppy variant,  8 sizes (1B .. 128KB)
#
# Layout assumptions, all owned by ../common/make/common.mk:
#   CC/AS/LD/OBJCOPY    — Retro68 toolchain
#   COMMON              — path to preboot/common (defaults to ../common)
#   PAYLOAD_LD          — linker script for the payload
#   BOOT_STUB_LD        — linker script for the boot block
#   BOOT_STUB_SRC       — canonical SCSI boot block (PAYLDOFF-patchable)
#   DISPLAY_SRC         — active paint kernel (1bpp by default)

include ../common/make/common.mk

BUILD := build

# IOTEST_MODE: which phases of each size test to run.
#   read       — read /Read_<label> only; no write+verify
#   full       — read, then write + readback-verify (default)
# Read-only mode is for isolating SCSI read-path bugs without the
# additional complexity of write+verify. Switch via `make IOTEST_MODE=full`.
IOTEST_MODE ?= read

ifeq ($(IOTEST_MODE),read)
    CFLAGS += -DIOTEST_READ_ONLY
else ifneq ($(IOTEST_MODE),full)
    $(error Unknown IOTEST_MODE=$(IOTEST_MODE); use 'read' or 'full')
endif

COMMON_RUNTIME := $(COMMON)/runtime
COMMON_DISPLAY := $(COMMON)/display

# ---- Object lists ---------------------------------------------------
COMMON_OBJS := $(BUILD)/jsonl_writer.o \
               $(BUILD)/freestanding.o \
               $(BUILD)/eject.o \
               $(BUILD)/display.o

HDA_C_OBJS  := $(BUILD)/diskio_main.hda.o $(BUILD)/sizes.hda.o $(BUILD)/timing.hda.o $(BUILD)/drive_enum.o
DSK_C_OBJS  := $(BUILD)/diskio_main.dsk.o $(BUILD)/sizes.dsk.o $(BUILD)/timing.dsk.o $(BUILD)/drive_enum.o

ENTRY_OBJ   := $(BUILD)/payload_entry.o
EXC_OBJ     := $(BUILD)/exc_handlers.o
BOOT_OBJ    := $(BUILD)/boot_stub.o
BOOT_BIN    := $(BUILD)/boot_stub.bin

HDA_OBJS    := $(ENTRY_OBJ) $(EXC_OBJ) $(HDA_C_OBJS) $(COMMON_OBJS)
DSK_OBJS    := $(ENTRY_OBJ) $(EXC_OBJ) $(DSK_C_OBJS) $(COMMON_OBJS)

.PHONY: all hda dsk clean
all: hda dsk
hda: $(BUILD)/payload_iotest_hda.bin $(BOOT_BIN)
dsk: $(BUILD)/payload_iotest_dsk.bin $(BOOT_BIN)

$(BUILD):
	mkdir -p $@

# ---- Boot stub ------------------------------------------------------
$(BOOT_OBJ): $(BOOT_STUB_SRC) | $(BUILD)
	$(AS) $(ASFLAGS) -o $@ $<
$(BUILD)/boot_stub.elf: $(BOOT_OBJ) $(BOOT_STUB_LD)
	$(LD) $(LDFLAGS) -T $(BOOT_STUB_LD) -o $@ $<
$(BOOT_BIN): $(BUILD)/boot_stub.elf
	$(OBJCOPY) -O binary $< $@

# ---- Payload entry + exception handlers -----------------------------
$(ENTRY_OBJ): payload_entry.s | $(BUILD)
	$(AS) $(ASFLAGS) -o $@ $<
$(EXC_OBJ): exc_handlers.s | $(BUILD)
	$(AS) $(ASFLAGS) -o $@ $<

# ---- IOTest C sources (per variant) ---------------------------------
$(BUILD)/diskio_main.hda.o: diskio_main.c sizes.h timing.h | $(BUILD)
	$(CC) $(CFLAGS) -DIOTEST_VARIANT_HDA -c -o $@ $<
$(BUILD)/sizes.hda.o: sizes.c sizes.h | $(BUILD)
	$(CC) $(CFLAGS) -DIOTEST_VARIANT_HDA -c -o $@ $<
$(BUILD)/timing.hda.o: timing.c timing.h | $(BUILD)
	$(CC) $(CFLAGS) -DIOTEST_VARIANT_HDA -c -o $@ $<

$(BUILD)/diskio_main.dsk.o: diskio_main.c sizes.h timing.h | $(BUILD)
	$(CC) $(CFLAGS) -DIOTEST_VARIANT_DSK -c -o $@ $<

$(BUILD)/drive_enum.o: drive_enum.c drive_enum.h | $(BUILD)
	$(CC) $(CFLAGS) -c -o $@ $<
$(BUILD)/sizes.dsk.o: sizes.c sizes.h | $(BUILD)
	$(CC) $(CFLAGS) -DIOTEST_VARIANT_DSK -c -o $@ $<
$(BUILD)/timing.dsk.o: timing.c timing.h | $(BUILD)
	$(CC) $(CFLAGS) -DIOTEST_VARIANT_DSK -c -o $@ $<

# ---- Shared runtime + display objects -------------------------------
$(BUILD)/jsonl_writer.o: $(COMMON_RUNTIME)/jsonl_writer.c $(COMMON_RUNTIME)/jsonl_writer.h | $(BUILD)
	$(CC) $(CFLAGS) -c -o $@ $<
$(BUILD)/freestanding.o: $(COMMON_RUNTIME)/freestanding.c | $(BUILD)
	$(CC) $(CFLAGS) -c -o $@ $<
$(BUILD)/eject.o: $(COMMON_RUNTIME)/eject.c $(COMMON_RUNTIME)/eject.h | $(BUILD)
	$(CC) $(CFLAGS) -c -o $@ $<
$(BUILD)/display.o: $(DISPLAY_SRC) | $(BUILD)
	$(CC) $(CFLAGS) -c -o $@ $<

# ---- Link both payload variants -------------------------------------
$(BUILD)/payload_iotest_hda.elf: $(HDA_OBJS) $(PAYLOAD_LD)
	$(LD) $(LDFLAGS) -T $(PAYLOAD_LD) -o $@ $(HDA_OBJS)
$(BUILD)/payload_iotest_hda.bin: $(BUILD)/payload_iotest_hda.elf
	$(OBJCOPY) -O binary $< $@

$(BUILD)/payload_iotest_dsk.elf: $(DSK_OBJS) $(PAYLOAD_LD)
	$(LD) $(LDFLAGS) -T $(PAYLOAD_LD) -o $@ $(DSK_OBJS)
$(BUILD)/payload_iotest_dsk.bin: $(BUILD)/payload_iotest_dsk.elf
	$(OBJCOPY) -O binary $< $@

clean:
	rm -rf $(BUILD)
