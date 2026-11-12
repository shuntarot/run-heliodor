//! Says what the core is, checks that startup set up the sections, times a
//! small loop with the cycle and instruction counters, then echoes what you
//! type. Ctrl-A x leaves; typing `q` exits with status 0.

#![no_std]
#![no_main]

use core::hint::black_box;
use core::ptr::addr_of;

use heliodor_bsp::{entry, exit, getc, print, println, riscv};
use riscv::register::{marchid, mcycle, mimpid, minstret, misa, mvendorid};

/// Loops of `work` that are timed.
const LOOPS: u64 = 1000;

/// Two chains that do not depend on each other, so an out-of-order core can
/// run them side by side.
fn work(n: u64) -> u64 {
    let (mut a, mut b) = (0u64, 1u64);
    for k in 0..n {
        let k = black_box(k);
        a = a.wrapping_add(k);
        b = b.wrapping_mul(3) ^ k;
    }
    a ^ b
}

/// In .rodata: neither copied nor cleared.
static RODATA: u32 = 0xaaaa_5555;
/// In .data: copied from its load address.
static mut DATA: u32 = 0x1234_5678;
/// In .bss: cleared.
static mut BSS: u32 = 0;

#[entry]
fn main() -> ! {
    println!("heliodor console");

    let isa = misa::read();
    print!("  misa      {:#018x} ", isa.bits());
    for ext in 'A'..='Z' {
        if isa.has_extension(ext) {
            print!("{ext}");
        }
    }
    println!();
    println!("  mvendorid {:#018x}", mvendorid::read().bits());
    println!("  marchid   {:#018x}", marchid::read().bits());
    println!("  mimpid    {:#018x}", mimpid::read().bits());

    // SAFETY: one hart and no interrupts, so nothing else touches them.
    let (data, bss) = unsafe {
        (
            addr_of!(DATA).read_volatile(),
            addr_of!(BSS).read_volatile(),
        )
    };
    let ok = RODATA == 0xaaaa_5555 && data == 0x1234_5678 && bss == 0;
    println!(
        "  sections  .rodata {RODATA:#010x} .data {data:#010x} .bss {bss:#010x} -> {}",
        if ok { "ok" } else { "WRONG" }
    );

    // The first run fills the caches; the second is timed.
    black_box(work(LOOPS));
    let (c0, i0) = (mcycle::read(), minstret::read());
    black_box(work(LOOPS));
    let (c1, i1) = (mcycle::read(), minstret::read());
    let (cycles, insns) = (c1.wrapping_sub(c0), i1.wrapping_sub(i0));
    let ipc = insns * 100 / cycles.max(1);
    println!(
        "  {LOOPS} loops  {cycles} cycles, {insns} instructions, IPC {}.{:02}",
        ipc / 100,
        ipc % 100
    );

    println!("type something; q exits");
    loop {
        if let Some(key) = getc() {
            if key == b'q' {
                println!();
                exit(if ok { 0 } else { 1 })
            }
            print!("{}", key as char);
        }
    }
}
