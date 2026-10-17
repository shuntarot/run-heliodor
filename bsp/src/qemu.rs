//! QEMU's `virt` machine (`cargo run-emu`): the console is its 16550 UART, and
//! the exit status goes to its test device, which ends QEMU with it.

use core::ptr::{read_volatile, write_volatile};

const UART: usize = 0x1000_0000;
/// Receive and transmit holding registers.
const RBR: *mut u8 = UART as *mut u8;
const THR: *mut u8 = UART as *mut u8;
/// Line status: a byte has arrived, and there is room to send one.
const LSR: *const u8 = (UART + 5) as *const u8;
const LSR_DATA: u8 = 0x01;
const LSR_EMPTY: u8 = 0x20;

/// `sifive_test`: 0x5555 ends QEMU with 0; `(code << 16) | 0x3333` with `code`.
const TEST: *mut u32 = 0x0010_0000 as *mut u32;

pub(crate) fn init() {}

pub(crate) fn puts(s: &str) {
    for byte in s.bytes() {
        // QEMU leaves the terminal raw, where a bare LF does not return the
        // carriage. `hio cpu console` adds the CR itself.
        if byte == b'\n' {
            putc(b'\r');
        }
        putc(byte);
    }
}

fn putc(byte: u8) {
    // SAFETY: the 16550 of `virt`; nothing else drives it.
    unsafe {
        while read_volatile(LSR) & LSR_EMPTY == 0 {}
        write_volatile(THR, byte);
    }
}

pub(crate) fn getc() -> Option<u8> {
    // SAFETY: as in `putc`.
    unsafe { (read_volatile(LSR) & LSR_DATA != 0).then(|| read_volatile(RBR)) }
}

pub(crate) fn exit(code: u8) {
    let value = match code {
        0 => 0x5555,
        _ => (u32::from(code) << 16) | 0x3333,
    };
    // SAFETY: the test device of `virt`. QEMU stops on this write.
    unsafe { write_volatile(TEST, value) }
}
