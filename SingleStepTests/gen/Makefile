# Test corpus generator.
#
# Links against the standalone Musashi checkout at MUSASHI_DIR (override on
# the command line if it lives elsewhere). Musashi must be built first so
# m68kops.c/h are generated:
#
#     make -C $(MUSASHI_DIR)
#     make            # build the generator
#     ./gen ../tg68k/corpus 0xC0FFEE01

MUSASHI_DIR ?= $(HOME)/repos/Musashi

CC      = gcc
CFLAGS  = -O2 -g -Wall -Wno-unused-parameter -I$(MUSASHI_DIR)

# Musashi object files (built by `make -C $(MUSASHI_DIR)`)
MUSASHI_OBJS = \
  $(MUSASHI_DIR)/m68kcpu.o \
  $(MUSASHI_DIR)/m68kops.o \
  $(MUSASHI_DIR)/m68kdasm.o \
  $(MUSASHI_DIR)/softfloat/softfloat.o

all: gen

# Force Musashi to be built first if its .o files are missing.
$(MUSASHI_OBJS):
	$(MAKE) -C $(MUSASHI_DIR)

gen: gen.c $(MUSASHI_OBJS)
	$(CC) $(CFLAGS) -o $@ gen.c $(MUSASHI_OBJS) -lm

clean:
	rm -f gen

.PHONY: all clean
