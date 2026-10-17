//! Says what the core is, checks that startup set up the sections, then
//! echoes what you type. Ctrl-A x leaves; typing `q` exits with status 0.

#![no_std]
#![no_main]

use core::ptr::addr_of;

use heliodor_bsp::{entry, exit, getc, print, println, riscv};
use riscv::register::{marchid, mimpid, misa, mvendorid};

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
