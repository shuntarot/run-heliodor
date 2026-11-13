/* M-mode firmware that boots Linux on heliodor in the harness.
 *
 * Based on heliodor's test/linux/fw/linux_boot_fw.S (MIT, Naoya Hatta). Its
 * console is RTT, not a UART: the SBI console calls write to an RTT up
 * channel, and `hio cpu boot` shows it. The control block is at 0x8200_0000,
 * past the 32 MB the core caches, so the host and the core see the same
 * bytes. Built with -DQEMU, it runs on QEMU's `virt` machine instead: the
 * console is its UART, and the exit status ends QEMU.
 *
 *   0x8000_0000  this firmware (the reset PC)
 *   0x8020_0000  the kernel Image
 *   DTB_ADDR     the device tree
 *   0x8200_0000  the RTT control block and buffers
 *
 * NHARTS harts (default 1) all start here. Hart 0 starts the kernel; the
 * others wait in M-mode until the kernel starts them with the SBI HSM
 * extension. IPIs and remote fences go through the CLINT's msip.
 */

#ifndef DTB_ADDR
#error "define DTB_ADDR"
#endif
#ifndef NHARTS
#define NHARTS 1
#endif

#define CLINT_MSIP     0x02000000
#define CLINT_MTIMECMP 0x02004000
#define KERNEL_ENTRY   0x80200000

#define SBI_EXT_BASE   0x10
#define SBI_EXT_TIME   0x54494D45
#define SBI_EXT_IPI    0x735049
#define SBI_EXT_RFENCE 0x52464E43
#define SBI_EXT_HSM    0x48534D
#define SBI_EXT_SRST   0x53525354
#define SBI_EXT_DBCN   0x4442434E

#define SBI_ERR_NOT_SUPPORTED     -2
#define SBI_ERR_INVALID_PARAM     -3
#define SBI_ERR_ALREADY_AVAILABLE -6

/* The firmware's own call, from s_trap. */
#define EID_S_TRAP     0x0A000001

#define MIP_SSIP 0x2
#define MIP_STIP 0x20
#define MIE_MSIE 0x8
#define MIE_MTIE 0x80

/* Each hart's trap stack. */
#define STACK_BYTES 4096

/* Each hart's state, HART_BYTES apart from hart_data. */
#define HART_BYTES   64
#define HART_STATE   0    /* HSM state */
#define HART_ADDR    8    /* where hart_start sends it */
#define HART_OPAQUE  16   /* and its a1 there */
#define HART_FENCE   24   /* nonzero: run fence.i and sfence.vma */
#define HART_SSIP    32   /* nonzero: raise its supervisor software interrupt */

#define HSM_STARTED       0
#define HSM_STOPPED       1
#define HSM_START_PENDING 2

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

/* QEMU virt: the 16550 UART, and the test device that ends QEMU. */
#define UART_BASE    0x10000000
#define QEMU_TEST    0x00100000

/* reg = this hart's entry in hart_data. */
.macro hart_ptr reg, tmp
    csrr \reg, mhartid
    slli \reg, \reg, 6
    la   \tmp, hart_data
    add  \reg, \reg, \tmp
.endm

/* reg = the entry of hart `id`. */
.macro hart_ptr_of reg, id, tmp
    slli \reg, \id, 6
    la   \tmp, hart_data
    add  \reg, \reg, \tmp
.endm

/* The console is shared: one hart prints at a time. Uses t0-t2. */
.macro console_lock
    la   t0, console_mutex
    li   t1, 1
99: amoswap.w.aq t2, t1, (t0)
    bnez t2, 99b
.endm

.macro console_unlock
    la   t0, console_mutex
    amoswap.w.rl zero, zero, (t0)
.endm

    .section .text.start, "ax"
    .global _start
_start:
    csrw mie, zero
    csrr s11, mhartid
    li   t0, NHARTS
    bgeu s11, t0, idle

    la   t0, trap
    csrw mtvec, t0
    /* The top of this hart's trap stack. */
    addi t1, s11, 1
    li   t2, STACK_BYTES
    mul  t1, t1, t2
    la   t0, trap_stacks
    add  t0, t0, t1
    csrw mscratch, t0

    /* S-mode and U-mode may read time, cycle and instret. Linux does not
     * set scounteren itself (only its SBI PMU driver would), and the vDSO
     * reads time from U-mode: without this, gettimeofday is an illegal
     * instruction. */
    li   t0, 7
    csrw mcounteren, t0
    csrw scounteren, t0

    /* Misaligned access, illegal instruction, breakpoint, ecall from U and
     * page faults go to S-mode. */
    li   t0, (1 << 2) | (1 << 3) | (1 << 4) | (1 << 6) | (1 << 8) | (1 << 12) | (1 << 13) | (1 << 15)
    csrw medeleg, t0
    /* Supervisor software, timer and external interrupts go to S-mode. */
    li   t0, 0x222
    csrw mideleg, t0

    slli t1, s11, 3
    li   t0, CLINT_MTIMECMP
    add  t0, t0, t1
    li   t1, -1
    sd   t1, 0(t0)

    /* Until the kernel sets its own, an S-mode trap comes to s_trap. */
    la   t0, s_trap
    csrw stvec, t0

#ifdef QEMU
    /* QEMU has PMP, and denies S-mode everything until an entry allows
     * it. heliodor has none. */
    li   t0, -1
    csrw pmpaddr0, t0
    li   t0, 0x1f
    csrw pmpcfg0, t0
#endif

    bnez s11, park

#ifndef QEMU
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
#endif

    la   s0, msg_boot
    jal  puts

    li   t0, MIE_MTIE | MIE_MSIE
    csrw mie, t0
    /* mret to S-mode at the kernel: MPP=S, MPIE, SPIE, SIE. */
    li   t0, (1 << 11) | (1 << 7) | (1 << 5) | (1 << 1)
    csrw mstatus, t0
    li   t0, KERNEL_ENTRY
    csrw mepc, t0
    li   a0, 0
    li   a1, DTB_ADDR
    mret

/* A hart past NHARTS: the device tree does not name it. */
idle:
    wfi
    j    idle

/* ---- A hart the kernel has not started ----------------------------------
 * It waits with interrupts off; msip only wakes it. hart_start sets its
 * state to START_PENDING, then msip. A remote fence is served here too, so
 * a sender never waits on a parked hart. */
park:
    csrci mstatus, 0x8
    li   t0, MIE_MSIE
    csrw mie, t0
1:  wfi
    csrr t0, mhartid
    slli t0, t0, 2
    li   t1, CLINT_MSIP
    add  t1, t1, t0
    sw   zero, 0(t1)
    fence
    hart_ptr t3, t1
    addi t2, t3, HART_FENCE
    amoswap.d t0, zero, (t2)
    beqz t0, 2f
    fence.i
    sfence.vma
2:  ld   t0, HART_STATE(t3)
    li   t1, HSM_START_PENDING
    bne  t0, t1, 1b

    /* Start: S-mode at the address, a0 = hartid, a1 = opaque, the MMU
     * off and S-mode interrupts off. */
    fence r, rw
    ld   t0, HART_ADDR(t3)
    csrw mepc, t0
    ld   a1, HART_OPAQUE(t3)
    li   t0, HSM_STARTED
    sd   t0, HART_STATE(t3)
    li   t0, (1 << 11)
    csrw mstatus, t0
    csrw satp, zero
    sfence.vma
    fence.i
    li   t0, MIE_MTIE | MIE_MSIE
    csrw mie, t0
    csrr a0, mhartid
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
    li   t1, 3
    beq  t0, t1, msip_irq
    li   t1, 7
    bne  t0, t1, trap_return
    /* Machine timer: pass it to S-mode, and mask it until the next
     * set_timer. */
    li   t0, MIP_STIP
    csrs mip, t0
    li   t0, MIE_MTIE
    csrc mie, t0
    j    trap_return

/* Machine software interrupt: another hart wants a fence here, an IPI for
 * S-mode, or both. */
msip_irq:
    csrr t0, mhartid
    slli t0, t0, 2
    li   t1, CLINT_MSIP
    add  t1, t1, t0
    sw   zero, 0(t1)
    fence
    hart_ptr t3, t1
    addi t2, t3, HART_FENCE
    amoswap.d t0, zero, (t2)
    beqz t0, 1f
    fence.i
    sfence.vma
1:  addi t2, t3, HART_SSIP
    amoswap.d t0, zero, (t2)
    beqz t0, trap_return
    li   t0, MIP_SSIP
    csrs mip, t0
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
    /* Legacy clear_ipi, send_ipi and remote fences. Linux uses the
     * extensions below instead, since the firmware reports SBI 2.0. */
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
    li   t0, SBI_EXT_HSM
    beq  a7, t0, hsm
    li   t0, SBI_EXT_SRST
    beq  a7, t0, srst
    li   t0, SBI_EXT_DBCN
    beq  a7, t0, dbcn
    li   t0, EID_S_TRAP
    beq  a7, t0, s_trap_report
not_supported:
    li   a0, SBI_ERR_NOT_SUPPORTED
    li   a1, 0
    j    trap_return

invalid_param:
    li   a0, SBI_ERR_INVALID_PARAM
    li   a1, 0
    j    trap_return

ok:
    li   a0, 0
    li   a1, 0
    j    trap_return

set_timer:
    csrr t1, mhartid
    slli t1, t1, 3
    li   t0, CLINT_MTIMECMP
    add  t0, t0, t1
    sd   a0, 0(t0)
    li   t0, MIP_STIP
    csrc mip, t0
    li   t0, MIE_MTIE
    csrs mie, t0
    j    ok

legacy_putchar:
    console_lock
    mv   t6, a0
    jal  putc
    console_unlock
    j    ok

legacy_getchar:
    console_lock
    jal  getc
    console_unlock
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
    li   t0, SBI_EXT_HSM
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

/* s0 = the harts named by hart_mask a0 and hart_mask_base a1, one bit
 * each. A base of -1 names every hart. Goes to invalid_param past the
 * last hart. */
hart_mask:
    li   t0, -1
    bne  a1, t0, 1f
    li   s0, (1 << NHARTS) - 1
    ret
1:  li   t0, NHARTS
    bgeu a1, t0, invalid_param
    sll  s0, a0, a1
    li   t0, (1 << NHARTS) - 1
    and  s0, s0, t0
    ret

/* send_ipi(hart_mask, hart_mask_base) */
ipi:
    jal  hart_mask
    li   s1, 0
1:  srl  t0, s0, s1
    andi t0, t0, 1
    beqz t0, 2f
    hart_ptr_of t3, s1, t1
    li   t0, 1
    sd   t0, HART_SSIP(t3)
    fence
    slli t0, s1, 2
    li   t1, CLINT_MSIP
    add  t1, t1, t0
    li   t0, 1
    sw   t0, 0(t1)
2:  addi s1, s1, 1
    li   t0, NHARTS
    bltu s1, t0, 1b
    j    ok

/* remote_fence_i, remote_sfence_vma and remote_sfence_vma_asid, each
 * (hart_mask, hart_mask_base, ...). Every target runs fence.i and a whole
 * sfence.vma, and the call returns once all of them have. */
rfence:
    li   t0, 2
    bgtu a6, t0, not_supported
    jal  hart_mask
    csrr t5, mhartid
    /* Ask each target but this hart. */
    li   s1, 0
1:  srl  t0, s0, s1
    andi t0, t0, 1
    beqz t0, 2f
    beq  s1, t5, 2f
    hart_ptr_of t3, s1, t1
    li   t0, 1
    sd   t0, HART_FENCE(t3)
    fence
    slli t0, s1, 2
    li   t1, CLINT_MSIP
    add  t1, t1, t0
    li   t0, 1
    sw   t0, 0(t1)
2:  addi s1, s1, 1
    li   t0, NHARTS
    bltu s1, t0, 1b
    /* This hart's own. */
    fence.i
    sfence.vma
    /* Wait for each. A hart that asks this one at the same time waits in
     * here too, so serve its request while waiting. */
    li   s1, 0
3:  srl  t0, s0, s1
    andi t0, t0, 1
    beqz t0, 5f
    beq  s1, t5, 5f
    hart_ptr_of t3, s1, t1
4:  hart_ptr t4, t1
    addi t2, t4, HART_FENCE
    amoswap.d t0, zero, (t2)
    beqz t0, 6f
    fence.i
    sfence.vma
6:  ld   t0, HART_FENCE(t3)
    bnez t0, 4b
5:  addi s1, s1, 1
    li   t0, NHARTS
    bltu s1, t0, 3b
    fence
    j    ok

hsm:
    li   t0, 0
    beq  a6, t0, hart_start
    li   t0, 1
    beq  a6, t0, hart_stop
    li   t0, 2
    beq  a6, t0, hart_status
    j    not_supported

/* hart_start(hartid, start_addr, opaque) */
hart_start:
    li   t0, NHARTS
    bgeu a0, t0, invalid_param
    hart_ptr_of t3, a0, t1
    ld   t0, HART_STATE(t3)
    li   t1, HSM_STOPPED
    beq  t0, t1, 1f
    li   a0, SBI_ERR_ALREADY_AVAILABLE
    li   a1, 0
    j    trap_return
1:  sd   a1, HART_ADDR(t3)
    sd   a2, HART_OPAQUE(t3)
    fence w, w
    li   t0, HSM_START_PENDING
    sd   t0, HART_STATE(t3)
    fence
    slli t0, a0, 2
    li   t1, CLINT_MSIP
    add  t1, t1, t0
    li   t0, 1
    sw   t0, 0(t1)
    j    ok

/* hart_stop(): back to park, with the trap stack as it was. */
hart_stop:
    hart_ptr t3, t1
    li   t0, HSM_STOPPED
    sd   t0, HART_STATE(t3)
    addi sp, sp, 80
    csrw mscratch, sp
    j    park

/* hart_get_status(hartid) */
hart_status:
    li   t0, NHARTS
    bgeu a0, t0, invalid_param
    hart_ptr_of t3, a0, t1
    ld   a1, HART_STATE(t3)
    li   a0, 0
    j    trap_return

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
    console_lock
    mv   s0, a1
    add  s1, a1, a0
1:  beq  s0, s1, 2f
    lbu  t6, 0(s0)
    jal  putc
    addi s0, s0, 1
    j    1b
2:  console_unlock
    mv   a1, a0
    li   a0, 0
    j    trap_return
dbcn_write_byte:
    console_lock
    mv   t6, a0
    jal  putc
    console_unlock
    j    ok
dbcn_read:
    /* up to a0 bytes to the physical address a1 */
    console_lock
    mv   s0, a1
    add  s1, a1, a0
1:  beq  s0, s1, 2f
    jal  getc
    bltz t6, 2f
    sb   t6, 0(s0)
    addi s0, s0, 1
    j    1b
2:  console_unlock
    sub  a1, s0, a1
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
 * 255. The console stays locked: the system is stopping. */
unexpected:
    console_lock
    la   s0, msg_trap
    jal  puts
    csrr s0, mhartid
    jal  puthex
    la   s0, msg_cause
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
    j    1f
finish:
    console_lock
1:
#ifdef QEMU
    /* QEMU's test device: 0x5555 passes, (status << 16) | 0x3333 fails. */
    li   t0, QEMU_TEST
    li   t1, 0x5555
    andi s0, s0, 0xff
    beqz s0, 2f
    slli t1, s0, 16
    li   t2, 0x3333
    or   t1, t1, t2
2:  sw   t1, 0(t0)
#else
    /* The low byte of s0 goes to the `hio-exit` channel. */
    la   t0, _SEGGER_RTT + RTT_UP1
    mv   t6, s0
    jal  rtt_put
#endif
3:  wfi
    j    3b

/* An S-mode trap before the kernel has a handler: print it, and stop with
 * status 254. */
s_trap_report:
    console_lock
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
    j    1b

    .balign 4
s_trap:
    li   a7, EID_S_TRAP
    ecall
1:  j    1b

#ifdef QEMU
/* ---- UART ---------------------------------------------------------------
 * putc: write t6. getc: a key in t6, or -1 if there is none. Use t0-t1. */
putc:
    li   t0, UART_BASE
1:  lbu  t1, 5(t0)
    andi t1, t1, 0x20
    beqz t1, 1b
    sb   t6, 0(t0)
    ret

getc:
    li   t0, UART_BASE
    li   t6, -1
    lbu  t1, 5(t0)
    andi t1, t1, 1
    beqz t1, 1f
    lbu  t6, 0(t0)
1:  ret
#else
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
#endif

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
msg_boot:  .asciz "fw: starting the kernel\n"
msg_trap:  .asciz "\nfw: unexpected trap on hart 0x"
msg_cause: .asciz " mcause 0x"
msg_strap: .asciz "\nfw: S-mode trap before the kernel's handler, scause 0x"
msg_epc:   .asciz " mepc 0x"
msg_tval:  .asciz " mtval 0x"

/* Initialised, not .bss: `hio cpu boot` zero-fills only the .bss that
 * follows file bytes. Hart 0 is running; the others are stopped. */
    .section .data
    .balign 64
hart_data:
    .dword HSM_STARTED, 0, 0, 0, 0, 0, 0, 0
    .rept NHARTS - 1
    .dword HSM_STOPPED, 0, 0, 0, 0, 0, 0, 0
    .endr
console_mutex:
    .word 0

    .section .bss
    .balign 16
trap_stacks:
    .skip STACK_BYTES * NHARTS

#ifndef QEMU
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
#endif
