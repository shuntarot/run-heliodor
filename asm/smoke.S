// Smoke test for heliodor on the harness. The program is in `mem` from
// 0x8000_0000. The core caches the first 32 MB, and the host cannot see a
// cached line while the core runs, so the program works in cached memory at
// 0x8000_1000 and writes what it found to the DRAM that is not cached. The
// results are dwords at 0x8200_0100:
//   +0x00: 0x21534e48 ("HNS!")
//   +0x08: misa
//   +0x10: mhartid (0)
//   +0x18: a dword loaded from .rodata (0x0123456789abcdef)
//   +0x20: 1234 * 5678 / 7 (0xf45f6)
//   +0x28: eight byte stores, loaded back as one dword (0x8877665544332211)
//   +0x30: a store read back by the very next load (0x12345678)
//   +0x38: 40, then amoadd.d of 2, loaded back (0x2a)
//   +0x40: counter, incremented forever
//   +0x48: a dword stored at 0x8200_0000 and loaded back
//          (0xfeedfacecafebeef); the byte 0x5a is stored at 0x8200_0009
#define SCRATCH  0x80001000
#define RESULT   0x82000100
#define UNCACHED 0x82000000

.section .text.start, "ax", @progbits
.globl _start
_start:
  li   t0, RESULT
  li   t4, SCRATCH
  li   t1, 0x21534e48
  sd   t1, 0x00(t0)
  csrr t1, misa
  sd   t1, 0x08(t0)
  csrr t1, mhartid
  sd   t1, 0x10(t0)
  la   t2, pattern
  ld   t1, 0(t2)
  sd   t1, 0x18(t0)
  li   t1, 1234
  li   t2, 5678
  mul  t1, t1, t2
  li   t2, 7
  divu t1, t1, t2
  sd   t1, 0x20(t0)
  li   t1, 0x11
  sb   t1, 0x28(t4)
  li   t1, 0x22
  sb   t1, 0x29(t4)
  li   t1, 0x33
  sb   t1, 0x2a(t4)
  li   t1, 0x44
  sb   t1, 0x2b(t4)
  li   t1, 0x55
  sb   t1, 0x2c(t4)
  li   t1, 0x66
  sb   t1, 0x2d(t4)
  li   t1, 0x77
  sb   t1, 0x2e(t4)
  li   t1, 0x88
  sb   t1, 0x2f(t4)
  ld   t1, 0x28(t4)
  sd   t1, 0x28(t0)
  li   t1, 0x12345678
  sd   t1, 0x30(t4)
  ld   t2, 0x30(t4)
  sd   t2, 0x30(t0)
  li   t1, 40
  sd   t1, 0x38(t4)
  li   t1, 2
  addi t3, t4, 0x38
  amoadd.d zero, t1, (t3)
  ld   t1, 0x38(t4)
  sd   t1, 0x38(t0)
  li   t3, UNCACHED
  li   t1, 0xfeedfacecafebeef
  sd   t1, 0(t3)
  li   t1, 0x5a
  sb   t1, 9(t3)
  ld   t2, 0(t3)
  sd   t2, 0x48(t0)
  li   t1, 0
1:
  addi t1, t1, 1
  sd   t1, 0x40(t0)
  j    1b

.section .rodata
.balign 8
pattern:
  .dword 0x0123456789abcdef
