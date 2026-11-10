/* riscv-tests' env/p and env/v link.ld, for this board.

   tohost sits in the DRAM that is not cached (0x8200_0000 and up), so the
   host sees the result while the core's L2 still holds the cached copy.
   `hio cpu boot` zero-fills a segment only after its file bytes, so the
   QUAD in .data gives .bss file bytes to follow: the page tables of the v
   environment start zeroed. */
OUTPUT_ARCH( "riscv" )
ENTRY(_start)

SECTIONS
{
  . = 0x80000000;
  .text.init : { *(.text.init) }
  . = ALIGN(0x1000);
  .text : { *(.text) }
  . = ALIGN(0x1000);
  .data : { *(.data) QUAD(0) }
  .bss : { *(.bss) }
  _end = .;
  .tohost 0x82001000 : { *(.tohost) }
}
