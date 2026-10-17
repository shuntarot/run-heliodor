//! Board support for heliodor under veryl-harness.
//!
//! An application depends on this crate and nothing else:
//!
//! ```ignore
//! #![no_std]
//! #![no_main]
//!
//! use heliodor_bsp::{entry, exit, println};
//!
//! #[entry]
//! fn main() -> ! {
//!     println!("hello");
//!     exit(0)
//! }
//! ```
//!
//! Under the harness the console is SEGGER RTT in uncached DRAM, which the
//! host reads through the harness window (`hio cpu boot` / `hio cpu console`). With the
//! `qemu` feature (`cargo run-emu`) it is the UART of QEMU's `virt` machine.
//! Either is up before `main`.

#![no_std]

pub use riscv;
pub use riscv_rt::entry;

#[cfg(feature = "qemu")]
mod qemu;
#[cfg(not(feature = "qemu"))]
mod rtt;

#[cfg(feature = "qemu")]
use qemu as console;
#[cfg(not(feature = "qemu"))]
use rtt as console;

/// Backend of `print!`. Not meant to be called directly.
#[doc(hidden)]
pub fn _print(args: core::fmt::Arguments) {
    use core::fmt::Write;
    let _ = Console.write_fmt(args);
}

struct Console;

impl core::fmt::Write for Console {
    fn write_str(&mut self, s: &str) -> core::fmt::Result {
        console::puts(s);
        Ok(())
    }
}

/// Reads one byte the host typed, or `None`. Never blocks.
pub fn getc() -> Option<u8> {
    console::getc()
}

/// Ends the program with `code`. `hio cpu boot` and QEMU exit with the same
/// status.
pub fn exit(code: u8) -> ! {
    console::exit(code);
    loop {
        riscv::asm::wfi();
    }
}

/// Sets the console up before `main`, so a panic in setup still has one.
#[riscv_rt::post_init]
unsafe fn post_init(_hartid: usize) {
    console::init();
}

#[macro_export]
macro_rules! print {
    ($($arg:tt)*) => {
        $crate::_print(core::format_args!($($arg)*))
    };
}

#[macro_export]
macro_rules! println {
    ()            => { $crate::print!("\n") };
    ($($arg:tt)*) => { $crate::print!("{}\n", core::format_args!($($arg)*)) };
}

/// Any exception without its own handler: show where, then stop with 102.
#[export_name = "ExceptionHandler"]
fn exception_handler(trap_frame: &riscv_rt::TrapFrame) -> ! {
    use riscv::register::{mcause, mepc, mtval};
    println!();
    println!("*** exception ***");
    println!("  mcause {:#018x}", mcause::read().bits());
    println!("  mepc   {:#018x}", mepc::read());
    println!("  mtval  {:#018x}", mtval::read());
    println!("  ra     {:#018x}", trap_frame.ra);
    exit(102)
}

/// A panic stops with 101, as a panicking Rust program does.
#[panic_handler]
fn panic(info: &core::panic::PanicInfo) -> ! {
    println!();
    println!("*** panic ***");
    println!("{info}");
    exit(101)
}
