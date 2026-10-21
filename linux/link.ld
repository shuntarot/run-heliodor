/* One ELF for `hio cpu boot`: the firmware, the kernel, the device tree and
 * the RTT console, each at the address fw.S expects. */
OUTPUT_ARCH(riscv)
ENTRY(_start)

SECTIONS
{
  . = 0x80000000;
  .text   : { *(.text.start) *(.text .text.*) }
  .rodata : { *(.rodata .rodata.*) }
  .bss    : { *(.bss .bss.*) }

  . = 0x80200000;
  .kernel : { KEEP(*(.kernel)) }

  . = DTB_ADDR;
  .dtb : { KEEP(*(.dtb)) }

  /* Past the 32 MB the core caches. */
  . = 0x82000000;
  .console : { *(.console) }
}
