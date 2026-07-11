#!/bin/bash
# Assemble berr_rte_test.s into a 512KB ROM image loadable via --rom.
# Reset vectors are the first 8 bytes; code is linked at $A00000 (ROM base).
set -e
cd "$(dirname "$0")"
AS=m68k-elf-as; LD=m68k-elf-ld; OC=m68k-elf-objcopy
$AS -m68030 berr_rte_test.s -o berr_rte_test.o
$LD -Ttext=0xA00000 --entry=_entry -nostdlib berr_rte_test.o -o berr_rte_test.elf 2>/dev/null
$OC -O binary berr_rte_test.elf berr_rte_test.bin
# pad to 512 KB (0x80000) to match a real boot ROM image size
python3 - <<'PY'
data=open('berr_rte_test.bin','rb').read()
img=data + b'\x00'*(0x80000-len(data))
open('berr_rte_test.rom','wb').write(img[:0x80000])
print(f"rom: {len(img[:0x80000])} bytes, code {len(data)} bytes")
PY
echo "=== disasm of the image ==="
python3 - <<'PY'
import capstone
d=open('berr_rte_test.bin','rb').read()
md=capstone.Cs(capstone.CS_ARCH_M68K, capstone.CS_MODE_M68K_030)
# first 8 bytes are vectors; disasm from offset 8 at runtime $A00008
import struct
sp,pc=struct.unpack('>II',d[0:8]); print(f"[vec] SP={sp:08X} PC={pc:08X}")
for i in md.disasm(d[8:], 0xA00008):
    print(f"{i.address:06X}: {i.mnemonic:8s} {i.op_str}")
PY
