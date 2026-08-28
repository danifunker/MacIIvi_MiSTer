#!/bin/bash
# Lint both ethernet configurations of sim.v against the Makefile's V_SRC list.
cd "$(dirname "$0")" || exit 1
SRCS=$(awk '/^V_SRC = /{f=1;next} f{gsub(/\\/,"");gsub(/\t/,"");gsub(/\$\(RTL\)/,"../rtl");if($0==""){f=0;next} if($0!~/tg68k_debug/) print}' Makefile)
echo "files: $(echo "$SRCS" | wc -l)"
for DEF in "" "-DDISABLE_ETHERNET"; do
	echo "=== lint ${DEF:-default} ==="
	# shellcheck disable=SC2086
	verilator --lint-only -Wno-fatal --timescale 1ns/1ps -I../rtl $DEF $SRCS --top-module emu 2>&1 | grep -E "%Error" | head -8
	echo "rc-note: errors above (none = clean)"
done
echo LINTBOTH-DONE
