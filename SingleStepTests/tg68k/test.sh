#!/bin/bash
# Runs every test file in the corpus dir against the built bench.
# Usage: ./test.sh                  # uses default $TARGET_DIR
#        ./test.sh /path/to/corpus  # override

set -u
TARGET_DIR="${1:-./680x0/68000/v1}"
PROGRAM="./obj_dir/Vtg68k_tests"

if [ ! -d "$TARGET_DIR" ]; then
    echo "Corpus dir '$TARGET_DIR' not found."
    echo "Hint: git clone https://github.com/SingleStepTests/680x0"
    exit 1
fi
if [ ! -x "$PROGRAM" ]; then
    echo "Bench not built: run 'make' first."
    exit 1
fi

find "$TARGET_DIR" -type f -name '*.json' | sort | while read -r file; do
    echo "Processing: $file"
    "$PROGRAM" "$file" || exit 1
done
