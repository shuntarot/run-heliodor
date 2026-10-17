//! The smallest program: one line on the console, then exit status 0.

#![no_std]
#![no_main]

use heliodor_bsp::{entry, exit, println};

#[entry]
fn main() -> ! {
    println!("hello from heliodor");
    exit(0)
}
