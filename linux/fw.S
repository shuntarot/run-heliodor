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
 *
 * Built with -DEMULATE_TIME, it serves a core that has no `time` CSR (such
 * as Rocket): reading it traps to M-mode, and the firmware answers with the
 * CLINT's mtime. Any other illegal instruction goes on to S-mode as if it
 * had been delegated. The core must put the instruction in mtval.
 *
 * Built with -DEMULATE_MISALIGNED, it does in M-mode the loads and stores
 * the core traps on for a misaligned address (Rocket does): Linux expects
 * the firmware to, and does not do them itself in S-mode.
 *
 * Built with -DPMP, it lets S-mode and U-mode reach all memory through PMP
 * entry 0, for a core that has PMP.
 */

#ifndef DTB_ADDR
#error "define DTB_ADDR"
#endif
#ifndef NHARTS
#define NHARTS 1
#endif

#define CLINT_MSIP     0x02000000
#define CLINT_MTIMECMP 0x02004000
#define CLINT_MTIME    0x0200BFF8
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

/* The exceptions medeleg leaves here, for the firmware to emulate. */
#ifdef EMULATE_TIME
#define MEDELEG_ILLEGAL     0
#else
#define MEDELEG_ILLEGAL     (1 << 2)
#endif
#ifdef EMULATE_MISALIGNED
#define MEDELEG_MISALIGNED  0
#else
#define MEDELEG_MISALIGNED  ((1 << 4) | (1 << 6))
#endif

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
     * page faults go to S-mode. With EMULATE_TIME, illegal instructions come
     * here first (illegal_insn); with EMULATE_MISALIGNED, misaligned loads
     * and stores (misaligned). */
    li   t0, MEDELEG_ILLEGAL | MEDELEG_MISALIGNED | (1 << 3) | (1 << 8) | (1 << 12) | (1 << 13) | (1 << 15)
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

#if defined(QEMU) || defined(PMP)
    /* A core with PMP (QEMU, Rocket; -DPMP) denies S-mode everything
     * until an entry allows it. heliodor has none. */
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
#ifdef EMULATE_TIME
    li   t1, 2
    beq  t0, t1, illegal_insn
#endif
#ifdef EMULATE_MISALIGNED
    li   t1, 4
    beq  t0, t1, misaligned
    li   t1, 6
    beq  t0, t1, misaligned
#endif
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

#ifdef EMULATE_TIME
/* ---- Illegal instruction ------------------------------------------------
 * `csrrs rd, time, x0` (rdtime) gets mtime in rd. Anything else goes to
 * S-mode. */
illegal_insn:
    csrr t0, mtval
    li   t1, 0xFFFFF07F
    and  t2, t0, t1
    li   t1, 0xC0102073
    bne  t2, t1, redirect
    li   t1, CLINT_MTIME
    ld   t3, 0(t1)
    csrr t1, mepc
    addi t1, t1, 4
    csrw mepc, t1
    /* Jump to the entry of rd: two instructions each. */
    srli t0, t0, 7
    andi t0, t0, 31
    slli t0, t0, 3
    la   t1, rd_table
    add  t1, t1, t0
    jr   t1
#endif

#ifdef EMULATE_MISALIGNED
/* ---- Misaligned load and store -----------------------------------------
 * A load or store that trapped for its misaligned address is done here a
 * byte at a time, through the translation of the mode that trapped (MPRV);
 * the instruction is read the same way, at mepc. A fault on the way goes to
 * S-mode as it would have from that access (ma_fault). Atomics and anything
 * else go to S-mode as they are.
 *
 *   s0  mepc         s1  mstatus at the trap
 *   t4  instruction  t5  bytes | MA_SIGNED | MA_FP    t6  register
 *   t0  address      t3  the value; t1, t2 scratch */
#define MSTATUS_MPRV (1 << 17)
#define MSTATUS_MXR  (1 << 19)
#define MA_SIGNED    16
#define MA_FP        32
misaligned:
    csrr s1, mstatus
    srli t1, s1, 11
    andi t1, t1, 3
    li   t2, 3
    beq  t1, t2, unexpected
    csrr s0, mepc
    la   t1, ma_fault
    csrw mtvec, t1
    /* The instruction, in halves: mepc may be 2 bytes from a page end. */
    li   t1, MSTATUS_MPRV | MSTATUS_MXR
    csrs mstatus, t1
    lhu  t4, 0(s0)
    andi t2, t4, 3
    li   t3, 3
    bne  t2, t3, 1f
    lhu  t2, 2(s0)
    slli t2, t2, 16
    or   t4, t4, t2
1:  csrc mstatus, t1

    andi t1, t4, 3
    li   t2, 3
    bne  t1, t2, ma_compressed
    /* 32 bits: t1 = funct3, t2 = opcode */
    srli t1, t4, 12
    andi t1, t1, 7
    andi t2, t4, 0x7f
    li   t3, 0x03
    beq  t2, t3, ma_int
    li   t3, 0x23
    beq  t2, t3, ma_int
    li   t3, 0x07
    beq  t2, t3, ma_fp
    li   t3, 0x27
    beq  t2, t3, ma_fp
    j    ma_give_up
ma_int:
    /* lh lw ld lhu lwu, sh sw sd: 1 << funct3[1:0] bytes, signed below 4 */
    andi t3, t1, 3
    beqz t3, ma_give_up
    li   t5, 1
    sll  t5, t5, t3
    li   t3, 4
    bgeu t1, t3, ma_32
    ori  t5, t5, MA_SIGNED
    j    ma_32
ma_fp:
    /* flw fld, fsw fsd: funct3 2 and 3 (the others are vector) */
    li   t3, 2
    bltu t1, t3, ma_give_up
    li   t3, 3
    bgtu t1, t3, ma_give_up
    li   t5, 1
    sll  t5, t5, t1
    ori  t5, t5, MA_FP
ma_32:
    li   t3, 0x20               /* the store bit of the opcode */
    and  t3, t4, t3
    bnez t3, 1f
    srli t6, t4, 7              /* rd */
    andi t6, t6, 31
    j    ma_load
1:  srli t6, t4, 20             /* rs2 */
    andi t6, t6, 31
    j    ma_store

ma_compressed:
    /* quadrant 0: c.fld c.lw c.ld, c.fsd c.sw c.sd with rd'/rs2' in [4:2];
     * quadrant 2: the same off sp, rd in [11:7], rs2 in [6:2].
     * funct3[1:0]: 1 fld/fsd, 2 lw/sw, 3 ld/sd; funct3[2]: store. */
    srli t2, t4, 13
    andi t2, t2, 7
    andi t3, t2, 3
    beqz t3, ma_give_up
    li   t5, 8
    li   t0, 2
    bne  t3, t0, 1f
    li   t5, 4 | MA_SIGNED
1:  li   t0, 1
    bne  t3, t0, 1f
    ori  t5, t5, MA_FP
1:  beqz t1, ma_q0
    li   t0, 2
    bne  t1, t0, ma_give_up
    andi t0, t2, 4
    bnez t0, 1f
    srli t6, t4, 7
    andi t6, t6, 31
    j    ma_load
1:  srli t6, t4, 2
    andi t6, t6, 31
    j    ma_store
ma_q0:
    srli t6, t4, 2
    andi t6, t6, 7
    addi t6, t6, 8
    andi t0, t2, 4
    bnez t0, ma_store

ma_load:
    csrr t0, mtval
    li   t1, MSTATUS_MPRV
    csrs mstatus, t1
    andi t1, t5, 15
    li   t3, 0
1:  addi t1, t1, -1
    add  t2, t0, t1
    lbu  t2, 0(t2)
    slli t3, t3, 8
    or   t3, t3, t2
    bnez t1, 1b
    li   t1, MSTATUS_MPRV
    csrc mstatus, t1
    andi t1, t5, MA_SIGNED
    beqz t1, 1f
    andi t1, t5, 15
    slli t1, t1, 3
    li   t2, 64
    sub  t1, t2, t1
    sll  t3, t3, t1
    sra  t3, t3, t1
1:  jal  ma_done
    /* to the register: rd_table, or fw_table / fd_table */
    slli t1, t6, 3
    la   t0, rd_table
    andi t2, t5, MA_FP
    beqz t2, 1f
    la   t0, fd_table
    andi t2, t5, 4
    beqz t2, 1f
    la   t0, fw_table
1:  add  t0, t0, t1
    jr   t0

ma_store:
    /* the value from the register: rs_table, or fsw_table / fsd_table */
    slli t1, t6, 3
    la   t0, rs_table
    andi t2, t5, MA_FP
    beqz t2, 1f
    la   t0, fsd_table
    andi t2, t5, 4
    beqz t2, 1f
    la   t0, fsw_table
1:  add  t0, t0, t1
    jalr t0
    csrr t0, mtval
    andi t1, t5, 15
    add  t1, t0, t1
    li   t2, MSTATUS_MPRV
    csrs mstatus, t2
1:  sb   t3, 0(t0)
    srli t3, t3, 8
    addi t0, t0, 1
    bne  t0, t1, 1b
    li   t2, MSTATUS_MPRV
    csrc mstatus, t2
    jal  ma_done
    j    trap_return

/* Done: the usual trap vector again, and mepc past the instruction. */
ma_done:
    la   t1, trap
    csrw mtvec, t1
    addi t1, s0, 2
    andi t2, t4, 3
    xori t2, t2, 3
    bnez t2, 1f
    addi t1, t1, 2
1:  csrw mepc, t1
    ret

ma_give_up:
    la   t1, trap
    csrw mtvec, t1
    j    redirect

/* An access of the emulation faulted (a trap from M-mode, so mepc, mcause
 * and mstatus are new): put back the trap being emulated, with this fault's
 * cause and address, and hand that to S-mode. */
    .balign 4
ma_fault:
    csrr t0, mcause
    csrr t1, mtval
    la   t2, trap
    csrw mtvec, t2
    csrw mstatus, s1
    csrw mepc, s0
    csrw mcause, t0
    csrw mtval, t1
    j    redirect

/* Read register n into t3, and return to ra. */
    .option push
    .option norvc
rs_table:
    li   t3, 0;        ret              /* x0 */
    ld   t3, 0(sp);    ret              /* ra */
    csrr t3, mscratch; ret              /* sp */
    mv   t3, gp;       ret
    mv   t3, tp;       ret
    ld   t3, 8(sp);    ret              /* t0 */
    ld   t3, 16(sp);   ret              /* t1 */
    ld   t3, 24(sp);   ret              /* t2 */
    ld   t3, 64(sp);   ret              /* s0 */
    ld   t3, 72(sp);   ret              /* s1 */
    mv   t3, a0;       ret
    mv   t3, a1;       ret
    mv   t3, a2;       ret
    mv   t3, a3;       ret
    mv   t3, a4;       ret
    mv   t3, a5;       ret
    mv   t3, a6;       ret
    mv   t3, a7;       ret
    mv   t3, s2;       ret
    mv   t3, s3;       ret
    mv   t3, s4;       ret
    mv   t3, s5;       ret
    mv   t3, s6;       ret
    mv   t3, s7;       ret
    mv   t3, s8;       ret
    mv   t3, s9;       ret
    mv   t3, s10;      ret
    mv   t3, s11;      ret
    ld   t3, 32(sp);   ret              /* t3 */
    ld   t3, 40(sp);   ret              /* t4 */
    ld   t3, 48(sp);   ret              /* t5 */
    ld   t3, 56(sp);   ret              /* t6 */

/* The same for the FP registers: write fN from t3 (single, double), read
 * t3 from fN (single, double). */
    .option arch, +d
fw_table:
    .irp n, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    fmv.w.x f\n, t3;   j trap_return
    .endr
fd_table:
    .irp n, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    fmv.d.x f\n, t3;   j trap_return
    .endr
fsw_table:
    .irp n, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    fmv.x.w t3, f\n;   ret
    .endr
fsd_table:
    .irp n, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    fmv.x.d t3, f\n;   ret
    .endr
    .option pop
#endif

#if defined(EMULATE_TIME) || defined(EMULATE_MISALIGNED)
/* Write t3 to register n. Registers the trap entry saved are written in
 * their slots, so trap_return loads them; sp is in mscratch. */
    .option push
    .option norvc
rd_table:
    nop;               j trap_return    /* x0 */
    sd   t3, 0(sp);    j trap_return    /* ra */
    csrw mscratch, t3; j trap_return    /* sp */
    mv   gp, t3;       j trap_return
    mv   tp, t3;       j trap_return
    sd   t3, 8(sp);    j trap_return    /* t0 */
    sd   t3, 16(sp);   j trap_return    /* t1 */
    sd   t3, 24(sp);   j trap_return    /* t2 */
    sd   t3, 64(sp);   j trap_return    /* s0 */
    sd   t3, 72(sp);   j trap_return    /* s1 */
    mv   a0, t3;       j trap_return
    mv   a1, t3;       j trap_return
    mv   a2, t3;       j trap_return
    mv   a3, t3;       j trap_return
    mv   a4, t3;       j trap_return
    mv   a5, t3;       j trap_return
    mv   a6, t3;       j trap_return
    mv   a7, t3;       j trap_return
    mv   s2, t3;       j trap_return
    mv   s3, t3;       j trap_return
    mv   s4, t3;       j trap_return
    mv   s5, t3;       j trap_return
    mv   s6, t3;       j trap_return
    mv   s7, t3;       j trap_return
    mv   s8, t3;       j trap_return
    mv   s9, t3;       j trap_return
    mv   s10, t3;      j trap_return
    mv   s11, t3;      j trap_return
    sd   t3, 32(sp);   j trap_return    /* t3 */
    sd   t3, 40(sp);   j trap_return    /* t4 */
    sd   t3, 48(sp);   j trap_return    /* t5 */
    sd   t3, 56(sp);   j trap_return    /* t6 */
    .option pop

/* Hand the trap to S-mode, as a delegated one would go: sepc, scause and
 * stval from the M-mode ones, SPP from MPP, SPIE from SIE, SIE off, and on
 * to stvec in S-mode. A trap from M-mode itself is unexpected. */
redirect:
    csrr t0, mstatus
    srli t1, t0, 11
    andi t1, t1, 3
    li   t2, 3
    beq  t1, t2, unexpected
    li   t2, ~((1 << 8) | (1 << 5) | (1 << 1) | (3 << 11))
    and  t3, t0, t2
    beqz t1, 1f
    li   t2, 1 << 8
    or   t3, t3, t2
1:  andi t2, t0, 1 << 1
    slli t2, t2, 4
    or   t3, t3, t2
    li   t2, 1 << 11
    or   t3, t3, t2
    csrw mstatus, t3
    csrr t0, mepc
    csrw sepc, t0
    csrr t0, mcause
    csrw scause, t0
    csrr t0, mtval
    csrw stval, t0
    csrr t0, stvec
    andi t0, t0, -4
    csrw mepc, t0
    j    trap_return
#endif

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
