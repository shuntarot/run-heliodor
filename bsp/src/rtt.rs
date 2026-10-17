//! The RTT channels: up 0 and down 0 are the terminal, and up 1 named
//! `hio-exit` carries the exit status to `hio cpu boot`.
//!
//! The control block and the buffers go to `.console`, which the core does
//! not cache. In cached memory the host would see nothing until a line left
//! the D-cache, and a line written back would undo what the host wrote.

use core::cell::RefCell;

use critical_section::Mutex;
use rtt_target::{rtt_init, ChannelMode, DownChannel, UpChannel};

static TERM: Mutex<RefCell<Option<UpChannel>>> = Mutex::new(RefCell::new(None));
static EXIT: Mutex<RefCell<Option<UpChannel>>> = Mutex::new(RefCell::new(None));
static KEYS: Mutex<RefCell<Option<DownChannel>>> = Mutex::new(RefCell::new(None));

pub(crate) fn init() {
    let channels = rtt_init! {
        up: {
            0: {
                size: 4096,
                // Wait for the host rather than lose output. `hio` drains it
                // while the console is open; without one the core stalls.
                mode: ChannelMode::BlockIfFull,
                name: "Terminal",
                section: ".console"
            }
            1: {
                size: 16,
                mode: ChannelMode::BlockIfFull,
                name: "hio-exit",
                section: ".console"
            }
        }
        down: {
            0: {
                size: 64,
                name: "Terminal",
                section: ".console"
            }
        }
        section_cb: ".console"
    };
    critical_section::with(|cs| {
        TERM.borrow(cs).replace(Some(channels.up.0));
        EXIT.borrow(cs).replace(Some(channels.up.1));
        KEYS.borrow(cs).replace(Some(channels.down.0));
    });
}

pub(crate) fn puts(s: &str) {
    critical_section::with(|cs| {
        if let Some(up) = TERM.borrow(cs).borrow_mut().as_mut() {
            up.write(s.as_bytes());
        }
    });
}

pub(crate) fn getc() -> Option<u8> {
    critical_section::with(|cs| {
        let mut keys = KEYS.borrow(cs).borrow_mut();
        let mut byte = [0u8; 1];
        (keys.as_mut()?.read(&mut byte) == 1).then_some(byte[0])
    })
}

pub(crate) fn exit(code: u8) {
    critical_section::with(|cs| {
        if let Some(up) = EXIT.borrow(cs).borrow_mut().as_mut() {
            up.write(&[code]);
        }
    });
}
