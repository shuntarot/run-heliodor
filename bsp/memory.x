/* heliodor on run-heliodor's harness. `mem` is DRAM from 0x8000_0000, the
 * reset PC. The core caches only its first 32 MB, which hold the program.
 * The RTT console goes past them, to 0x8200_0000, so the host sees what the
 * core writes there at once, and the core sees what the host writes. */

MEMORY
{
  RAM     (rwx) : ORIGIN = 0x80000000, LENGTH = 32M
  CONSOLE (rw)  : ORIGIN = 0x82000000, LENGTH = 64K
}

REGION_ALIAS("REGION_TEXT",   RAM);
REGION_ALIAS("REGION_RODATA", RAM);
REGION_ALIAS("REGION_DATA",   RAM);
REGION_ALIAS("REGION_BSS",    RAM);
REGION_ALIAS("REGION_HEAP",   RAM);
REGION_ALIAS("REGION_STACK",  RAM);

_max_hart_id     = 0;
_hart_stack_size = 64K;
_heap_size       = 0;

SECTIONS
{
  /* Set up at run time by rtt_init!: nothing is loaded or zeroed here.
   * After .bss, it would move __ebss and the startup would zero 32 MB. */
  .console (NOLOAD) : ALIGN(64)
  {
    *(.console .console.*);
  } > CONSOLE
}
INSERT AFTER .uninit;
