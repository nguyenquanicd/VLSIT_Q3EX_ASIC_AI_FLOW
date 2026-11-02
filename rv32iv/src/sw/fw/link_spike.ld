/* Spike model build: code at the default DRAM base, "DMEM" at +1 MB, signature behind the images */
OUTPUT_ARCH(riscv)
ENTRY(_start)
SECTIONS
{
  . = 0x80000000;
  .text : {
    *(.text.init)
    *(.text .text.*)
    *(.rodata .rodata.*)
  }
  . = ALIGN(0x1000);
  .tohost : { *(.tohost) }
  . = 0x80100000;
  .dmem : { *(.dmem) }
  . = ALIGN(16);
  .sig : { *(.sig) }
}
