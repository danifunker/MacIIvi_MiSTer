/* Boot block: flat layout, max 1024 bytes, no relocation. */
ENTRY(_start)
SECTIONS
{
  . = 0;
  .text : {
    *(.text)
    *(.text.*)
    *(.rodata)
    *(.rodata.*)
  }
  /DISCARD/ : { *(.data) *(.bss) *(.comment) *(.note*) *(.eh_frame*) }
  _bb_end = .;
  ASSERT(_bb_end <= 1024, "boot block exceeds 1024 bytes")
}
