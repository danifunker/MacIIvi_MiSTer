# keytest -- ADB keyboard diagnostic, floppy + SCSI hard disk.
#
# Payload is variant-agnostic (no I/O differences between floppy and
# hard disk runs), so one binary serves both image types.
#
# Produces:
#   payload_keytest.bin  -- continuous KeyMap poller

include ../common/make/common.mk

BUILD := build

COMMON_RUNTIME := $(COMMON)/runtime
COMMON_DISPLAY := $(COMMON)/display

COMMON_OBJS := $(BUILD)/freestanding.o $(BUILD)/eject.o $(BUILD)/display.o

C_OBJS  := $(BUILD)/keytest_main.o

ENTRY_OBJ   := $(BUILD)/payload_entry.o
EXC_OBJ     := $(BUILD)/exc_handlers.o
BOOT_OBJ    := $(BUILD)/boot_stub.o
BOOT_BIN    := $(BUILD)/boot_stub.bin

PAYLOAD_OBJS := $(ENTRY_OBJ) $(EXC_OBJ) $(C_OBJS) $(COMMON_OBJS)

.PHONY: all dsk hda clean
all: $(BUILD)/payload_keytest.bin $(BOOT_BIN)
dsk: all
hda: all

$(BUILD):
	mkdir -p $@

$(BOOT_OBJ): $(BOOT_STUB_SRC) | $(BUILD)
	$(AS) $(ASFLAGS) -o $@ $<
$(BUILD)/boot_stub.elf: $(BOOT_OBJ) $(BOOT_STUB_LD)
	$(LD) $(LDFLAGS) -T $(BOOT_STUB_LD) -o $@ $<
$(BOOT_BIN): $(BUILD)/boot_stub.elf
	$(OBJCOPY) -O binary $< $@

$(ENTRY_OBJ): payload_entry.s | $(BUILD)
	$(AS) $(ASFLAGS) -o $@ $<
$(EXC_OBJ): exc_handlers.s | $(BUILD)
	$(AS) $(ASFLAGS) -o $@ $<

$(BUILD)/keytest_main.o: keytest_main.c | $(BUILD)
	$(CC) $(CFLAGS) -c -o $@ $<

$(BUILD)/freestanding.o: $(COMMON_RUNTIME)/freestanding.c | $(BUILD)
	$(CC) $(CFLAGS) -c -o $@ $<
$(BUILD)/eject.o: $(COMMON_RUNTIME)/eject.c $(COMMON_RUNTIME)/eject.h | $(BUILD)
	$(CC) $(CFLAGS) -c -o $@ $<
$(BUILD)/display.o: $(DISPLAY_SRC) | $(BUILD)
	$(CC) $(CFLAGS) -c -o $@ $<

$(BUILD)/payload_keytest.elf: $(PAYLOAD_OBJS) $(PAYLOAD_LD)
	$(LD) $(LDFLAGS) -T $(PAYLOAD_LD) -o $@ $(PAYLOAD_OBJS)
$(BUILD)/payload_keytest.bin: $(BUILD)/payload_keytest.elf
	$(OBJCOPY) -O binary $< $@

clean:
	rm -rf $(BUILD)
