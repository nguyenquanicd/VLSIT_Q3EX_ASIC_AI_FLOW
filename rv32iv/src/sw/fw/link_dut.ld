/* DUT firmware: reset PC = 0, IMEM 32 KB at 0x0000_0000 */
OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY
{
  IMEM (rx) : ORIGIN = 0x00000000, LENGTH = 32K
}
SECTIONS
{
  .text : {
    *(.text.init)
    *(.text .text.*)
    *(.rodata .rodata.*)
    *(.data .data.*)
  } > IMEM
  /DISCARD/ : { *(.comment) *(.riscv.attributes) *(.note*) }
}
