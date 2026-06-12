#!/bin/bash
#
# Convert TG68K VHDL files to Verilog and generate new QIP file
#
# Usage: ./convert_to_verilog.sh [input.qip] [output.qip]
#   Defaults: TG68K.qip -> TG68K_verilog.qip

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

INPUT_QIP="${1:-TG68K.qip}"
OUTPUT_QIP="${2:-TG68K_verilog.qip}"

# GHDL parameters for TG68KdotC_Kernel synthesis
KERNEL_PARAMS="-gSR_Read=2 -gVBR_Stackframe=2 -gextAddr_Mode=2 -gMUL_Mode=2 -gDIV_Mode=2 -gBitField=2 -gBarrelShifter=2 -gMUL_Hardware=1"

# Files that need special handling
# TG68K_Pack.vhd is a package - analyzed first, not synthesized standalone
PACKAGE_FILES="TG68K_Pack.vhd"

# TG68KdotC_Kernel.vhd is the top-level kernel - must be analyzed/converted LAST
# because it depends on PMMU, FPU, Cache, ALU modules
KERNEL_FILE="TG68KdotC_Kernel.vhd"

echo "=== TG68K VHDL to Verilog Converter ==="
echo "Input QIP:  $INPUT_QIP"
echo "Output QIP: $OUTPUT_QIP"
echo ""

if [ ! -f "$INPUT_QIP" ]; then
    echo "Error: Input QIP file '$INPUT_QIP' not found"
    exit 1
fi

# Parse QIP file using grep and sed for reliable extraction
echo "Parsing $INPUT_QIP..."

# Extract VHDL files (lines containing VHDL_FILE, extract filename.vhd)
VHDL_FILES=$(grep 'VHDL_FILE' "$INPUT_QIP" | sed -n 's/.*[[:space:]]\([A-Za-z0-9_]*\.vhd\)[[:space:]].*/\1/p')

# Extract Verilog files (lines containing VERILOG_FILE, extract filename.v)
VERILOG_FILES=$(grep 'VERILOG_FILE' "$INPUT_QIP" | sed -n 's/.*[[:space:]]\([A-Za-z0-9_]*\.v\)[[:space:]].*/\1/p')

VHDL_COUNT=$(echo "$VHDL_FILES" | grep -c . || true)
VERILOG_COUNT=$(echo "$VERILOG_FILES" | grep -c . || true)

echo "Found $VHDL_COUNT VHDL files to process:"
echo "$VHDL_FILES" | while read -r f; do echo "  - $f"; done
echo ""
echo "Found $VERILOG_COUNT existing Verilog files:"
echo "$VERILOG_FILES" | while read -r f; do echo "  - $f"; done
echo ""

# Check for ghdl
if ! command -v ghdl > /dev/null 2>&1; then
    echo "Error: ghdl not found in PATH"
    echo "Please install ghdl to convert VHDL to Verilog"
    exit 1
fi

# Function to check if file is a package
is_package() {
    [ "$1" = "$PACKAGE_FILES" ]
}

# Function to check if file is the kernel (must be last)
is_kernel() {
    [ "$1" = "$KERNEL_FILE" ]
}

# Step 1: Analyze all VHDL files in dependency order
# Order: 1) Package files first, 2) All other files, 3) Kernel last
echo "=== Step 1: Analyzing VHDL files ==="

# First: analyze package files
echo "$VHDL_FILES" | while read -r vhdl_file; do
    if is_package "$vhdl_file"; then
        echo "Analyzing package: $vhdl_file"
        ghdl -a -fsynopsys -fexplicit "$vhdl_file"
    fi
done

# Second: analyze all other files (except kernel)
echo "$VHDL_FILES" | while read -r vhdl_file; do
    if ! is_package "$vhdl_file" && ! is_kernel "$vhdl_file"; then
        echo "Analyzing: $vhdl_file"
        ghdl -a -fsynopsys -fexplicit "$vhdl_file"
    fi
done

# Last: analyze kernel (depends on all other modules)
echo "$VHDL_FILES" | while read -r vhdl_file; do
    if is_kernel "$vhdl_file"; then
        echo "Analyzing kernel (last): $vhdl_file"
        ghdl -a -fsynopsys -fexplicit "$vhdl_file"
    fi
done

echo ""
echo "=== Step 2: Converting VHDL to Verilog ==="

# Convert regular files first (skip packages and kernel)
echo "$VHDL_FILES" | while read -r vhdl_file; do
    # Skip package files (they don't generate standalone modules)
    if is_package "$vhdl_file"; then
        echo "Skipping package (no standalone output): $vhdl_file"
        continue
    fi

    # Skip kernel (convert last)
    if is_kernel "$vhdl_file"; then
        continue
    fi

    # Derive entity name from filename (remove .vhd extension)
    entity_name="${vhdl_file%.vhd}"
    verilog_file="${entity_name}.v"

    echo "Converting: $vhdl_file -> $verilog_file"
    ghdl synth -fsynopsys -fexplicit --latches \
        --out=verilog "$entity_name" > "$verilog_file"
done

# Convert kernel last (with special parameters)
echo "$VHDL_FILES" | while read -r vhdl_file; do
    if is_kernel "$vhdl_file"; then
        entity_name="${vhdl_file%.vhd}"
        verilog_file="${entity_name}.v"

        echo "Converting kernel (last): $vhdl_file -> $verilog_file"
        ghdl synth -fsynopsys -fexplicit --latches \
            $KERNEL_PARAMS \
            --out=verilog "$entity_name" > "$verilog_file"
    fi
done

echo ""
echo "=== Step 3: Patching tg68k.v wrapper ==="

# The tg68k.v wrapper instantiates TG68KdotC_Kernel with parameters:
#   TG68KdotC_Kernel #(2,2,2,2,2,2,2,1, FPU_Enable) tg68k (
# Since the converted Verilog has these parameters hardcoded,
# we need to remove them from the instantiation.

WRAPPER_FILE="tg68k.v"
WRAPPER_BACKUP="tg68k.v.orig"

if [ -f "$WRAPPER_FILE" ]; then
    # Create backup if it doesn't exist
    if [ ! -f "$WRAPPER_BACKUP" ]; then
        cp "$WRAPPER_FILE" "$WRAPPER_BACKUP"
        echo "Created backup: $WRAPPER_BACKUP"
    fi

    # Pattern to match: TG68KdotC_Kernel #(...) tg68k (
    # Replace with: TG68KdotC_Kernel tg68k (
    if grep -q 'TG68KdotC_Kernel #(' "$WRAPPER_FILE"; then
        sed -i '' 's/TG68KdotC_Kernel #([^)]*)/TG68KdotC_Kernel/' "$WRAPPER_FILE"
        echo "Patched $WRAPPER_FILE: removed TG68KdotC_Kernel parameters"
    else
        echo "$WRAPPER_FILE already patched (no parameters found)"
    fi
else
    echo "Warning: $WRAPPER_FILE not found, skipping patch"
fi

echo ""
echo "=== Step 4: Generating new QIP file ==="

# Generate new QIP file
{
    echo "# TG68K Verilog QIP file"
    echo "# Auto-generated by convert_to_verilog.sh"
    echo "# Original: $INPUT_QIP"
    echo ""

    # Add existing Verilog files that were kept
    echo "$VERILOG_FILES" | while read -r v_file; do
        [ -n "$v_file" ] && echo "set_global_assignment -name VERILOG_FILE [file join \$::quartus(qip_path) $v_file ]"
    done

    # Add converted Verilog files (all VHDL except packages)
    echo "$VHDL_FILES" | while read -r vhdl_file; do
        if ! is_package "$vhdl_file"; then
            v_file="${vhdl_file%.vhd}.v"
            echo "set_global_assignment -name VERILOG_FILE [file join \$::quartus(qip_path) $v_file ]"
        fi
    done
} > "$OUTPUT_QIP"

echo "Generated: $OUTPUT_QIP"
echo ""
echo "=== Conversion Complete ==="
echo ""
echo "To restore original tg68k.v: cp $WRAPPER_BACKUP $WRAPPER_FILE"
