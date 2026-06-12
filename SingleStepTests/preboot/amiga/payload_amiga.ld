/* Payload: flat binary, loaded by the Amiga bootblock at $00080000.
 * .text must come first so offset 0 of the binary == _payload_start. */
ENTRY(_payload_start)
SECTIONS
{
  . = 0x00080000;
  .text : {
    *(.text._payload_start)
    *(.text)
    *(.text.*)
    *(.rodata)
    *(.rodata.*)
  }
  .data : ALIGN(4) {
    *(.data)
    *(.data.*)
  }
  _payload_end_data = .;
  .bss (NOLOAD) : ALIGN(4) {
    *(.bss)
    *(.bss.*)
    *(COMMON)
  }
  _payload_bss_end = .;
  /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
