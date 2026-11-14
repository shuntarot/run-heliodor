//! What it costs a core in M-mode to control a system through registers, in
//! core cycles (mcycle): register loads and stores, a polling loop, CSRs,
//! fences, traps and an interrupt. Also whether a register access, a CSR or a
//! fence stops cache misses around it from overlapping.
//!
//! Each test runs a block of instructions many times and prints the cycles
//! per block, or per instruction where the block repeats one. Independent
//! accesses that take as long each as dependent ones do not overlap.
//!
//! The program builds for RV32 and RV64. To move it to another core, change
//! the board section below: the bsp and the addresses.

#![no_std]
#![no_main]

use core::arch::{asm, global_asm};
use core::ptr::{read_volatile, write_volatile};

// --- The board ---------------------------------------------------------------

use heliodor_bsp::{entry, exit, println, riscv};

/// The CLINT: registers inside the SoC, next to the core.
const CLINT: usize = 0x0200_0000;
/// Hart 0's msip: 32 bits, bit 0 raises the machine software interrupt.
const MSIP: usize = CLINT;
/// Hart 0's mtimecmp. It resets to all ones, and the tests write all ones,
/// so the timer interrupt never comes.
const MTIMECMP: usize = CLINT + 0x4000;
/// mtime, read only.
const MTIME: usize = CLINT + 0xbff8;
/// DRAM the core does not cache: a register behind the SoC's bus.
const UNCACHED: usize = 0x8380_0000;
/// Cached DRAM the program does not use, 16 MB of it, for cache misses.
const BUF: usize = 0x8400_0000;
const BUF_SIZE: usize = 16 * 1024 * 1024;

// ------------------------------------------------------------------------------

use riscv::register::mcycle;

// --- Word-sized loads and stores, for RV32 and RV64 ---------------------------

#[cfg(target_pointer_width = "64")]
macro_rules! lx {
    () => {
        "ld"
    };
}
#[cfg(target_pointer_width = "64")]
macro_rules! sx {
    () => {
        "sd"
    };
}
#[cfg(target_pointer_width = "32")]
macro_rules! lx {
    () => {
        "lw"
    };
}
#[cfg(target_pointer_width = "32")]
macro_rules! sx {
    () => {
        "sw"
    };
}

/// Eight copies of one instruction.
macro_rules! x8 {
    ($i:expr) => {
        concat!($i, "\n", $i, "\n", $i, "\n", $i, "\n", $i, "\n", $i, "\n", $i, "\n", $i)
    };
}

const ROUNDS: usize = 1000;

fn show(label: &str, cycles: u64, per_round: usize) {
    let c = cycles * 100 / (ROUNDS * per_round) as u64;
    println!("  {:<46} {:>5}.{:02}", label, c / 100, c % 100);
}

macro_rules! time_block {
    ($($body:tt)*) => {{
        let t0 = mcycle::read64();
        for _ in 0..ROUNDS {
            #[allow(unused_unsafe)]
            unsafe { $($body)* }
        }
        mcycle::read64() - t0
    }};
}

// --- Traps --------------------------------------------------------------------

// A vectored trap table for the trap tests, with handlers that touch no
// memory and only the registers the tests give them:
// - ecall: steps over the ecall. Uses t6.
// - machine software interrupt: puts mcycle in t6, counts itself in t5, and
//   clears msip, whose address is in t4.
// Any other trap goes to the handler the program had before.
global_asm!(
    ".section .text.issue_traps, \"ax\"",
    ".balign 256",
    // Vectored mode puts each entry 4 bytes apart: no compressed jumps.
    ".option push",
    ".option norvc",
    "issue_vector:",
    "    j issue_ecall",
    "    j issue_other",
    "    j issue_other",
    "    j issue_msi",
    "    j issue_other",
    "    j issue_other",
    "    j issue_other",
    "    j issue_other",
    "    j issue_other",
    "    j issue_other",
    "    j issue_other",
    "    j issue_other",
    ".option pop",
    "issue_ecall:",
    "    csrr t6, mepc",
    "    addi t6, t6, 4",
    "    csrw mepc, t6",
    "    mret",
    "issue_msi:",
    "    csrr t6, mcycle",
    "    addi t5, t5, 1",
    "    sw zero, 0(t4)",
    "    mret",
    "issue_other:",
    "    la t6, {old}",
    concat!("    ", lx!(), " t6, 0(t6)"),
    "    csrw mtvec, t6",
    "    jr t6",
    old = sym OLD_MTVEC,
);

extern "C" {
    static issue_vector: u8;
}

/// mtvec before the trap tests (direct mode: the handler's address).
static mut OLD_MTVEC: usize = 0;

/// Runs `f` with the trap table above in mtvec.
fn with_traps(f: impl FnOnce()) {
    unsafe {
        let old: usize;
        asm!("csrr {}, mtvec", out(reg) old);
        OLD_MTVEC = old;
        asm!("csrw mtvec, {}", in(reg) &issue_vector as *const u8 as usize | 1);
        f();
        asm!("csrw mtvec, {}", in(reg) old);
    }
}

// --- Cache misses ---------------------------------------------------------------

/// A random cycle through the lines of `BUF` (Sattolo's shuffle), each line
/// holding the address of the next.
fn link() {
    let n = BUF_SIZE / 64;
    let at = |i: usize| (BUF + i * 64) as *mut usize;
    let mut x = 0x9e37_79b9u32;
    unsafe {
        for i in 0..n {
            write_volatile(at(i), i);
        }
        for i in (1..n).rev() {
            x ^= x << 13;
            x ^= x >> 17;
            x ^= x << 5;
            let j = x as usize % i;
            let (a, b) = (read_volatile(at(i)), read_volatile(at(j)));
            write_volatile(at(i), b);
            write_volatile(at(j), a);
        }
        for i in 0..n {
            write_volatile(at(i), BUF + read_volatile(at(i)) * 64);
        }
    }
}

#[entry]
fn main() -> ! {
    println!("issue: cycles per instruction, or per block");

    // A chain in uncached DRAM that points back to its start.
    unsafe {
        for i in 0..8 {
            write_volatile((UNCACHED + i * 64) as *mut usize, UNCACHED);
        }
    }

    println!();
    println!("1. register loads");
    let mut p = UNCACHED;
    show(
        "uncached DRAM, dependent",
        time_block! {
            asm!(x8!(concat!(lx!(), " {p}, 0({p})")), p = inout(reg) p, options(nostack, readonly));
        },
        8,
    );
    show(
        "uncached DRAM, independent",
        time_block! {
            asm!(
                concat!(lx!(), " {a}, 0({p})"), concat!(lx!(), " {b}, 64({p})"),
                concat!(lx!(), " {a}, 128({p})"), concat!(lx!(), " {b}, 192({p})"),
                concat!(lx!(), " {a}, 256({p})"), concat!(lx!(), " {b}, 320({p})"),
                concat!(lx!(), " {a}, 384({p})"), concat!(lx!(), " {b}, 448({p})"),
                p = in(reg) UNCACHED, a = out(reg) _, b = out(reg) _, options(nostack, readonly),
            );
        },
        8,
    );
    show(
        "CLINT mtime, independent",
        time_block! {
            asm!(
                concat!(lx!(), " {a}, 0({p})"), concat!(lx!(), " {b}, 0({p})"),
                concat!(lx!(), " {a}, 0({p})"), concat!(lx!(), " {b}, 0({p})"),
                concat!(lx!(), " {a}, 0({p})"), concat!(lx!(), " {b}, 0({p})"),
                concat!(lx!(), " {a}, 0({p})"), concat!(lx!(), " {b}, 0({p})"),
                p = in(reg) MTIME, a = out(reg) _, b = out(reg) _, options(nostack, readonly),
            );
        },
        8,
    );
    show(
        "CLINT msip polled: load, branch",
        time_block! {
            asm!(
                x8!("lw {t}, 0({p})\n bnez {t}, 2f"),
                "2:",
                p = in(reg) MSIP, t = out(reg) _, options(nostack, readonly),
            );
        },
        8,
    );

    println!();
    println!("2. register stores");
    show(
        "uncached DRAM",
        time_block! {
            asm!(
                concat!(sx!(), " {v}, 512({p})"), concat!(sx!(), " {v}, 576({p})"),
                concat!(sx!(), " {v}, 640({p})"), concat!(sx!(), " {v}, 704({p})"),
                concat!(sx!(), " {v}, 768({p})"), concat!(sx!(), " {v}, 832({p})"),
                concat!(sx!(), " {v}, 896({p})"), concat!(sx!(), " {v}, 960({p})"),
                p = in(reg) UNCACHED, v = in(reg) 0, options(nostack),
            );
        },
        8,
    );
    show(
        "CLINT mtimecmp",
        time_block! {
            asm!(x8!(concat!(sx!(), " {v}, 0({p})")), p = in(reg) MTIMECMP, v = in(reg) usize::MAX,
                 options(nostack));
        },
        8,
    );
    show(
        "uncached DRAM, store then load the word",
        time_block! {
            asm!(concat!(sx!(), " {v}, 512({p})"), concat!(lx!(), " {v}, 512({p})"),
                 p = in(reg) UNCACHED, v = inout(reg) 0usize => _, options(nostack));
        },
        1,
    );
    show(
        "CLINT mtimecmp, load, or, store",
        time_block! {
            asm!(concat!(lx!(), " {v}, 0({p})"), "or {v}, {v}, {m}", concat!(sx!(), " {v}, 0({p})"),
                 p = in(reg) MTIMECMP, m = in(reg) usize::MAX, v = out(reg) _, options(nostack));
        },
        1,
    );

    println!();
    println!("3. CSRs");
    show(
        "mscratch read",
        time_block! {
            asm!(x8!("csrr {a}, mscratch"), a = out(reg) _, options(nostack, nomem));
        },
        8,
    );
    show(
        "mcycle read",
        time_block! {
            asm!(x8!("csrr {a}, mcycle"), a = out(reg) _, options(nostack, nomem));
        },
        8,
    );
    show(
        "mscratch write",
        time_block! {
            asm!(x8!("csrw mscratch, {v}"), v = in(reg) 0, options(nostack, nomem));
        },
        8,
    );
    show(
        "mscratch write, then read",
        time_block! {
            asm!("csrw mscratch, {v}", "csrr {v}, mscratch", v = inout(reg) 0usize => _,
                 options(nostack, nomem));
        },
        1,
    );
    show(
        "mstatus.MIE clear, then set",
        time_block! {
            asm!("csrci mstatus, 8", "csrsi mstatus, 8", options(nostack, nomem));
        },
        1,
    );
    clear_mstatus_mie();
    // 32 adds in two chains, with a CSR access in the middle or not.
    macro_rules! adds {
        ($label:expr, $csr:expr $(, $($op:tt)*)?) => {
            show(
                $label,
                time_block! {
                    asm!(x8!("addi {a}, {a}, 1\n addi {b}, {b}, 1"), $csr,
                         x8!("addi {a}, {a}, 1\n addi {b}, {b}, 1"),
                         a = out(reg) _, b = out(reg) _ $(, $($op)*)?, options(nostack, nomem));
                },
                1,
            )
        };
    }
    adds!("32 adds alone", "");
    adds!("32 adds with a mscratch read", "csrr {e}, mscratch", e = out(reg) _);
    adds!("32 adds with a mscratch write", "csrw mscratch, {a}");

    println!();
    println!("4. fences");
    show(
        "fence",
        time_block! { asm!(x8!("fence"), options(nostack)); },
        8,
    );
    show(
        "fence iorw, iorw",
        time_block! { asm!(x8!("fence iorw, iorw"), options(nostack)); },
        8,
    );
    show(
        "fence.i",
        time_block! { asm!(x8!("fence.i"), options(nostack)); },
        8,
    );
    show(
        "CLINT mtimecmp store, then fence",
        time_block! {
            asm!(concat!(sx!(), " {v}, 0({p})"), "fence", p = in(reg) MTIMECMP, v = in(reg) usize::MAX,
                 options(nostack));
        },
        1,
    );

    println!();
    println!("5. traps");
    let mut ecall = 0;
    let (mut entry, mut total, mut again) = (0u64, 0u64, 0usize);
    with_traps(|| {
        ecall = time_block! { asm!(x8!("ecall"), out("t6") _, options(nostack)); };
        unsafe {
            asm!("csrsi mie, 8", "csrsi mstatus, 8", options(nostack, nomem));
        }
        for _ in 0..ROUNDS {
            let (t0, t1, t2, n): (usize, usize, usize, usize);
            unsafe {
                asm!(
                    "li t6, 0",
                    "li t5, 0",
                    "csrr {t0}, mcycle",
                    "sw {one}, 0(t4)",
                    "1: beqz t6, 1b",
                    "csrr {t2}, mcycle",
                    t0 = out(reg) t0, t2 = out(reg) t2, one = in(reg) 1,
                    in("t4") MSIP, out("t5") n, out("t6") t1, options(nostack),
                );
            }
            entry += t1.wrapping_sub(t0) as u64;
            total += t2.wrapping_sub(t0) as u64;
            again += n - 1;
        }
        clear_mstatus_mie();
        unsafe {
            asm!("csrci mie, 8", options(nostack, nomem));
        }
    });
    show("ecall to a handler that steps over it, and back", ecall, 8);
    show("msip store, to the handler's first instruction", entry, 1);
    show("msip store, through the handler, and back", total, 1);
    if again > 0 {
        // msip was still set at mret, so the handler ran again.
        println!("  the handler ran {again} more times than interrupts were raised");
    }
    let back_to_back = time_block! {
        asm!("csrr {a}, mcycle", "csrr {b}, mcycle", a = out(reg) _, b = out(reg) _, options(nostack, nomem));
    };
    show("(two mcycle reads, which both counts include)", back_to_back, 1);

    // Cache misses around each kind of access: the second of two chases
    // through DRAM overlaps the first unless what is between them stops it.
    println!();
    println!("6. two DRAM chases side by side, per pair of loads");
    link();
    let (mut a, mut b) = (BUF, BUF);
    for _ in 0..BUF_SIZE / 64 / 2 {
        b = unsafe { read_volatile(b as *const usize) };
    }
    macro_rules! pair {
        ($label:expr, $between:expr $(, $($op:tt)*)?) => {
            show(
                $label,
                time_block! {
                    asm!(concat!(lx!(), " {a}, 0({a})"), $between, concat!(lx!(), " {b}, 0({b})"),
                         a = inout(reg) a, b = inout(reg) b $(, $($op)*)?, options(nostack));
                },
                1,
            )
        };
    }
    pair!("alone", "");
    pair!("with a mscratch read between", "csrr {t}, mscratch", t = out(reg) _);
    pair!("with a mscratch write between", "csrw mscratch, {a}");
    pair!("with a CLINT mtime load between", concat!(lx!(), " {t}, 0({u})"),
          u = in(reg) MTIME, t = out(reg) _);
    pair!("with an uncached load between", concat!(lx!(), " {t}, 0({u})"),
          u = in(reg) UNCACHED, t = out(reg) _);
    pair!("with a CLINT store between", concat!(sx!(), " {m}, 0({c})"),
          c = in(reg) MTIMECMP, m = in(reg) usize::MAX);
    pair!("with an uncached store between", concat!(sx!(), " {a}, 512({u})"), u = in(reg) UNCACHED);
    pair!("with a fence between", "fence");
    show(
        "one chase, for comparison",
        time_block! {
            asm!(concat!(lx!(), " {a}, 0({a})"), a = inout(reg) a, options(nostack, readonly));
        },
        1,
    );

    println!();
    println!("issue: done");
    exit(0)
}

fn clear_mstatus_mie() {
    unsafe {
        asm!("csrci mstatus, 8", options(nostack, nomem));
    }
}
