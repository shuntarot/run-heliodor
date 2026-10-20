/* M-mode firmware that boots Linux on heliodor in the harness.
 *
 * Based on heliodor's test/linux/fw/linux_boot_fw.S (MIT, Naoya Hatta), cut
 * down to one hart. Its console is RTT, not a UART: the SBI console calls
 * write to an RTT up channel, and `hio cpu boot` shows it. The control block
 * is at 0x8200_0000, past the 32 MB the core caches, so the host and the
 * core see the same bytes.
 *
 *   0x8000_0000  the kernel Image (the reset PC: its first 8 bytes jump here)
 *   DTB_ADDR     the device tree
 *   FW_BASE      this firmware
 *   0x8200_0000  the RTT control block and buffers
 *
 * The kernel sits at 0x8000_0000, where heliodor's own tests put it.
 */

#define CLINT_MTIMECMP 0x02004000
#define KERNEL_ENTRY   0x80000000
#ifndef DTB_ADDR
#error "define DTB_ADDR"
#endif

#define SBI_EXT_BASE   0x10
#define SBI_EXT_TIME   0x54494D45
#define SBI_EXT_IPI    0x735049
#define SBI_EXT_RFENCE 0x52464E43
#define SBI_EXT_SRST   0x53525354
#define SBI_EXT_DBCN   0x4442434E

/* The firmware's own call, from s_trap. */
#define EID_S_TRAP     0x0A000001

#define MIP_SSIP 0x2
#define MIP_STIP 0x20
#define MIE_MTIE 0x80

/* RTT control block, as rtt-target lays it out on a 64-bit target: every
 * field is 8 bytes. */
#define RTT_CH_BUF   8
#define RTT_CH_SIZE  16
#define RTT_CH_WR    24
#define RTT_CH_RD    32
#define RTT_UP0      32
#define RTT_UP1      80
#define RTT_DOWN0    128
#define RTT_BYTES    176

    .section .text.start, "ax"
    .global _start
_start:
    csrw mie, zero

    /* Set up the RTT control block from its template. `hio cpu boot` clears
     * the block after loading, so that a stale one is not taken for live.
     * The id goes last: the host waits for it. */
    la   t0, rtt_template
    la   t1, _SEGGER_RTT
    li   t2, 16
1:  add  t3, t0, t2
    ld   t4, 0(t3)
    add  t3, t1, t2
    sd   t4, 0(t3)
    addi t2, t2, 8
    li   t3, RTT_BYTES
    bltu t2, t3, 1b
    fence w, w
    ld   t4, 0(t0)
    sd   t4, 0(t1)
    ld   t4, 8(t0)
    sd   t4, 8(t1)
    fence w, w

    la   s0, msg_boot
    jal  puts

    /* The reset PC is the kernel's first word, which was patched to jump
     * here. Put the kernel's own first 8 bytes back, and make the fetch see
     * them. */
    li   t0, KERNEL_ENTRY
    la   t1, kernel_head
    lw   t2, 0(t1)
    sw   t2, 0(t0)
    lw   t2, 4(t1)
    sw   t2, 4(t0)
    fence.i
    la   t0, trap
    csrw mtvec, t0
    la   t0, trap_stack_top
    csrw mscratch, t0

    /* S-mode may read time, cycle and instret. */
    li   t0, 7
    csrw mcounteren, t0

    /* Misaligned access, illegal instruction, breakpoint, ecall from U and
     * page faults go to S-mode. */
    li   t0, (1 << 2) | (1 << 3) | (1 << 4) | (1 << 6) | (1 << 8) | (1 << 12) | (1 << 13) | (1 << 15)
    csrw medeleg, t0
    /* Supervisor software, timer and external interrupts go to S-mode. */
    li   t0, 0x222
    csrw mideleg, t0

    li   t0, CLINT_MTIMECMP
    li   t1, -1
    sd   t1, 0(t0)
    li   t0, MIE_MTIE
    csrw mie, t0

    /* mret to S-mode at the kernel: MPP=S, MPIE, SPIE, SIE. */
    li   t0, (1 << 11) | (1 << 7) | (1 << 5) | (1 << 1)
    csrw mstatus, t0
    /* Until the kernel sets its own, an S-mode trap comes to s_trap. */
    la   t0, s_trap
    csrw stvec, t0
    li   t0, KERNEL_ENTRY
    csrw mepc, t0
    li   a0, 0
    li   a1, DTB_ADDR
    mret

/* ---- Trap entry ---------------------------------------------------------
 * The handler runs on its own stack. It keeps ra, t0-t6, s0 and s1 of the
 * caller; an SBI call returns only a0 and a1. */
    .balign 4
trap:
    csrrw sp, mscratch, sp
    addi sp, sp, -80
    sd   ra, 0(sp)
    sd   t0, 8(sp)
    sd   t1, 16(sp)
    sd   t2, 24(sp)
    sd   t3, 32(sp)
    sd   t4, 40(sp)
    sd   t5, 48(sp)
    sd   t6, 56(sp)
    sd   s0, 64(sp)
    sd   s1, 72(sp)

    csrr t0, mcause
    bltz t0, irq
    li   t1, 9
    beq  t0, t1, ecall
    j    unexpected

irq:
    slli t0, t0, 1
    srli t0, t0, 1
    li   t1, 7
    bne  t0, t1, trap_return
    /* Machine timer: pass it to S-mode, and mask it until the next
     * set_timer. */
    li   t0, MIP_STIP
    csrs mip, t0
    li   t0, MIE_MTIE
    csrc mie, t0
    j    trap_return

/* ---- SBI ---------------------------------------------------------------- */
ecall:
    csrr t0, mepc
    addi t0, t0, 4
    csrw mepc, t0

    li   t0, 0x00
    beq  a7, t0, set_timer
    li   t0, 0x01
    beq  a7, t0, legacy_putchar
    li   t0, 0x02
    beq  a7, t0, legacy_getchar
    li   t0, 0x08
    beq  a7, t0, shutdown
    /* Legacy clear_ipi, send_ipi and remote fences: one hart, nothing to
     * do but succeed. */
    li   t0, 0x03
    bltu a7, t0, 1f
    li   t0, 0x07
    bleu a7, t0, ok
1:
    li   t0, SBI_EXT_BASE
    beq  a7, t0, base
    li   t0, SBI_EXT_TIME
    beq  a7, t0, set_timer
    li   t0, SBI_EXT_IPI
    beq  a7, t0, ipi
    li   t0, SBI_EXT_RFENCE
    beq  a7, t0, rfence
    li   t0, SBI_EXT_SRST
    beq  a7, t0, srst
    li   t0, SBI_EXT_DBCN
    beq  a7, t0, dbcn
    li   t0, EID_S_TRAP
    beq  a7, t0, s_trap_report
not_supported:
    li   a0, -2
    li   a1, 0
    j    trap_return

ok:
    li   a0, 0
    li   a1, 0
    j    trap_return

set_timer:
    li   t0, CLINT_MTIMECMP
    sd   a0, 0(t0)
    li   t0, MIP_STIP
    csrc mip, t0
    li   t0, MIE_MTIE
    csrs mie, t0
    j    ok

legacy_putchar:
    mv   t6, a0
    jal  putc
    j    ok

legacy_getchar:
    jal  getc
    mv   a0, t6
    li   a1, 0
    j    trap_return

base:
    li   t0, 0
    beq  a6, t0, 1f
    li   t0, 3
    beq  a6, t0, 2f
    li   t0, 4
    beq  a6, t0, 3f
    li   t0, 5
    beq  a6, t0, 4f
    li   t0, 6
    beq  a6, t0, 5f
    /* get_impl_id and get_impl_version: an unknown implementation. */
    li   a0, 0
    li   a1, 0
    j    trap_return
1:  /* get_spec_version: 2.0 */
    li   a0, 0
    li   a1, 0x02000000
    j    trap_return
2:  /* probe_extension */
    mv   t1, a0
    li   a0, 0
    li   a1, 1
    li   t0, SBI_EXT_TIME
    beq  t1, t0, trap_return
    li   t0, SBI_EXT_IPI
    beq  t1, t0, trap_return
    li   t0, SBI_EXT_RFENCE
    beq  t1, t0, trap_return
    li   t0, SBI_EXT_SRST
    beq  t1, t0, trap_return
    li   t0, SBI_EXT_DBCN
    beq  t1, t0, trap_return
    li   a1, 0
    j    trap_return
3:  li   a0, 0
    csrr a1, mvendorid
    j    trap_return
4:  li   a0, 0
    csrr a1, marchid
    j    trap_return
5:  li   a0, 0
    csrr a1, mimpid
    j    trap_return

/* send_ipi(hart_mask, hart_mask_base): hart 0 is the only one. */
ipi:
    li   t0, -1
    beq  a1, t0, 1f
    bnez a1, ok
    andi t0, a0, 1
    beqz t0, ok
1:  li   t0, MIP_SSIP
    csrs mip, t0
    j    ok

/* Remote fences: this hart is the only one, so do them here. */
rfence:
    bnez a6, 1f
    fence.i
    j    ok
1:  sfence.vma
    j    ok

/* system_reset(type, reason): the reason is the exit status. */
srst:
    mv   s0, a1
    j    finish
shutdown:
    li   s0, 0
    j    finish

dbcn:
    li   t0, 0
    beq  a6, t0, dbcn_write
    li   t0, 1
    beq  a6, t0, dbcn_write_byte
    li   t0, 2
    beq  a6, t0, dbcn_read
    j    not_supported
dbcn_write:
    /* a0 bytes from the physical address a1 */
    mv   s0, a1
    add  s1, a1, a0
1:  beq  s0, s1, 2f
    lbu  t6, 0(s0)
    jal  putc
    addi s0, s0, 1
    j    1b
2:  mv   a1, a0
    li   a0, 0
    j    trap_return
dbcn_write_byte:
    mv   t6, a0
    jal  putc
    j    ok
dbcn_read:
    /* up to a0 bytes to the physical address a1 */
    mv   s0, a1
    add  s1, a1, a0
1:  beq  s0, s1, 2f
    jal  getc
    bltz t6, 2f
    sb   t6, 0(s0)
    addi s0, s0, 1
    j    1b
2:  sub  a1, s0, a1
    li   a0, 0
    j    trap_return

trap_return:
    ld   ra, 0(sp)
    ld   t0, 8(sp)
    ld   t1, 16(sp)
    ld   t2, 24(sp)
    ld   t3, 32(sp)
    ld   t4, 40(sp)
    ld   t5, 48(sp)
    ld   t6, 56(sp)
    ld   s0, 64(sp)
    ld   s1, 72(sp)
    addi sp, sp, 80
    csrrw sp, mscratch, sp
    mret

/* A trap the firmware does not expect: print where, and stop with status
 * 255. */
unexpected:
    la   s0, msg_trap
    jal  puts
    csrr s0, mcause
    jal  puthex
    la   s0, msg_epc
    jal  puts
    csrr s0, mepc
    jal  puthex
    la   s0, msg_tval
    jal  puts
    csrr s0, mtval
    jal  puthex
    li   t6, '\n'
    jal  putc
    li   s0, 255
finish:
    /* The low byte of s0 goes to the `hio-exit` channel. */
    la   t0, _SEGGER_RTT + RTT_UP1
    mv   t6, s0
    jal  rtt_put
1:  wfi
    j    1b

/* An S-mode trap before the kernel has a handler: print it, and stop with
 * status 254. */
s_trap_report:
    la   s0, msg_strap
    jal  puts
    csrr s0, scause
    jal  puthex
    la   s0, msg_epc
    jal  puts
    csrr s0, sepc
    jal  puthex
    la   s0, msg_tval
    jal  puts
    csrr s0, stval
    jal  puthex
    li   t6, '\n'
    jal  putc
    li   s0, 254
    j    finish

    .balign 4
s_trap:
    li   a7, EID_S_TRAP
    ecall
1:  j    1b

/* ---- RTT ----------------------------------------------------------------
 * putc: write t6 to the terminal. It waits while the buffer is full, so
 * nothing is lost while the host drains it. Uses t0-t5. */
putc:
    la   t0, _SEGGER_RTT + RTT_UP0
rtt_put:
    ld   t1, RTT_CH_WR(t0)
    addi t2, t1, 1
    ld   t3, RTT_CH_SIZE(t0)
    bltu t2, t3, 1f
    li   t2, 0
1:  ld   t4, RTT_CH_RD(t0)
    beq  t2, t4, 1b
    ld   t5, RTT_CH_BUF(t0)
    add  t5, t5, t1
    sb   t6, 0(t5)
    fence w, w
    sd   t2, RTT_CH_WR(t0)
    ret

/* getc: a key from the host in t6, or -1 if there is none. Uses t0-t5. */
getc:
    la   t0, _SEGGER_RTT + RTT_DOWN0
    ld   t1, RTT_CH_RD(t0)
    ld   t2, RTT_CH_WR(t0)
    li   t6, -1
    beq  t1, t2, 1f
    ld   t5, RTT_CH_BUF(t0)
    add  t5, t5, t1
    lbu  t6, 0(t5)
    addi t1, t1, 1
    ld   t3, RTT_CH_SIZE(t0)
    bltu t1, t3, 2f
    li   t1, 0
2:  fence r, w
    sd   t1, RTT_CH_RD(t0)
1:  ret

/* puts: the string at s0. puthex: s0 in hex. Both use s0, s1 and ra. */
puts:
    mv   s1, ra
1:  lbu  t6, 0(s0)
    beqz t6, 2f
    jal  putc
    addi s0, s0, 1
    j    1b
2:  jr   s1

puthex:
    addi sp, sp, -8
    sd   ra, 0(sp)
    li   s1, 60
1:  srl  t6, s0, s1
    andi t6, t6, 15
    addi t6, t6, '0'
    li   t0, '9'
    bleu t6, t0, 2f
    addi t6, t6, 'a' - '0' - 10
2:  jal  putc
    addi s1, s1, -4
    bgez s1, 1b
    ld   ra, 0(sp)
    addi sp, sp, 8
    ret

    .section .rodata
kernel_head:
    .incbin "Image.head"
msg_boot: .asciz "fw: starting the kernel\n"
msg_trap: .asciz "\nfw: unexpected trap, mcause 0x"
msg_strap: .asciz "\nfw: S-mode trap before the kernel's handler, scause 0x"
msg_epc:  .asciz " mepc 0x"
msg_tval: .asciz " mtval 0x"

    .section .bss
    .balign 16
trap_stack:
    .skip 4096
trap_stack_top:

/* ---- The RTT control block ----------------------------------------------
 * The template is copied to _SEGGER_RTT at boot. */
    .section .rodata
    .balign 8
rtt_template:
    .ascii "SEGGER RTT"
    .skip 6
    .dword 2, 1
    .dword name_term, buf_up0, 4096, 0, 0, 2   /* up 0: block if full */
    .dword name_exit, buf_up1, 16, 0, 0, 2     /* up 1: the exit status */
    .dword name_term, buf_down0, 64, 0, 0, 0   /* down 0: keys */

    .section .console, "aw"
    .balign 8
    .global _SEGGER_RTT
    .type _SEGGER_RTT, @object
_SEGGER_RTT:
    .skip RTT_BYTES
    .size _SEGGER_RTT, . - _SEGGER_RTT
name_term: .asciz "Terminal"
name_exit: .asciz "hio-exit"
    .balign 8
buf_up0:   .skip 4096
buf_up1:   .skip 16
buf_down0: .skip 64
