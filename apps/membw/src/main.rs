//! Memory bandwidth, in bytes per core cycle (mcycle).
//!
//! 1. Copy, Scale, Add and Triad on three arrays of doubles, 4 MB each (32
//!    times the L2): the four kernels of the STREAM benchmark, written again
//!    here, counted the same way (bytes the kernel reads and writes) and
//!    best of three. Twice: arrays back to back, and one line apart.
//! 2. Loads only, against the size of the working set: the steps are the L1
//!    D-cache, the L2 and DRAM.
//! 3. Stores only, the same way.
//!
//! The core runs in M-mode with no address translation, so the TLB plays no
//! part. The loops are unrolled by hand, eight words a round, so the loop
//! itself costs little next to the memory.

#![no_std]
#![no_main]

use core::hint::black_box;
use core::ptr::{read_volatile, write_volatile};

use heliodor_bsp::{entry, exit, println, riscv};
use riscv::register::mcycle;

/// Cached DRAM past the program's 32 MB: nothing else uses it.
const BUF: usize = 0x8400_0000;

const KB: usize = 1024;
const MB: usize = 1024 * KB;

/// Doubles in each STREAM array.
const N: usize = 4 * MB / 8;
const TIMES: usize = 3;
const SCALAR: f64 = 3.0;

const SIZES: &[usize] = &[
    4 * KB,
    8 * KB,
    16 * KB,
    32 * KB,
    64 * KB,
    128 * KB,
    256 * KB,
    MB,
    4 * MB,
    16 * MB,
];

/// The core clock on the VCU118, for MB/s.
const MHZ: u64 = 20;

/// Array `k`, `gap` bytes past the end of the one before it. With no gap
/// the same element of each array falls in the same cache set.
fn array(k: usize, gap: usize) -> *mut f64 {
    (BUF + k * (N * 8 + gap)) as *mut f64
}

/// Runs `f` and returns the cycles it took.
fn timed(f: impl FnOnce()) -> u64 {
    let t0 = mcycle::read64();
    f();
    mcycle::read64() - t0
}

/// Applies `f` to every index, eight at a time. `N` is a multiple of 8.
#[inline(always)]
fn each8(n: usize, mut f: impl FnMut(usize)) {
    let mut i = 0;
    while i < n {
        f(i);
        f(i + 1);
        f(i + 2);
        f(i + 3);
        f(i + 4);
        f(i + 5);
        f(i + 6);
        f(i + 7);
        i += 8;
    }
}

#[inline(never)]
fn copy(a: *const f64, c: *mut f64) {
    each8(N, |i| unsafe { *c.add(i) = *a.add(i) });
}

#[inline(never)]
fn scale(c: *const f64, b: *mut f64) {
    each8(N, |i| unsafe { *b.add(i) = SCALAR * *c.add(i) });
}

#[inline(never)]
fn add(a: *const f64, b: *const f64, c: *mut f64) {
    each8(N, |i| unsafe { *c.add(i) = *a.add(i) + *b.add(i) });
}

#[inline(never)]
fn triad(b: *const f64, c: *const f64, a: *mut f64) {
    each8(N, |i| unsafe { *a.add(i) = *b.add(i) + SCALAR * *c.add(i) });
}

/// Sums `words` 64-bit words from `p`, in eight sums that do not depend on
/// each other.
#[inline(never)]
fn read(p: *const u64, words: usize) -> u64 {
    let mut s = [0u64; 8];
    let mut i = 0;
    while i < words {
        unsafe {
            s[0] = s[0].wrapping_add(read_volatile(p.add(i)));
            s[1] = s[1].wrapping_add(read_volatile(p.add(i + 1)));
            s[2] = s[2].wrapping_add(read_volatile(p.add(i + 2)));
            s[3] = s[3].wrapping_add(read_volatile(p.add(i + 3)));
            s[4] = s[4].wrapping_add(read_volatile(p.add(i + 4)));
            s[5] = s[5].wrapping_add(read_volatile(p.add(i + 5)));
            s[6] = s[6].wrapping_add(read_volatile(p.add(i + 6)));
            s[7] = s[7].wrapping_add(read_volatile(p.add(i + 7)));
        }
        i += 8;
    }
    s.iter().fold(0, |a, &b| a.wrapping_add(b))
}

/// Stores `v` to `words` 64-bit words from `p`.
#[inline(never)]
fn write(p: *mut u64, words: usize, v: u64) {
    let mut i = 0;
    while i < words {
        unsafe {
            write_volatile(p.add(i), v);
            write_volatile(p.add(i + 1), v);
            write_volatile(p.add(i + 2), v);
            write_volatile(p.add(i + 3), v);
            write_volatile(p.add(i + 4), v);
            write_volatile(p.add(i + 5), v);
            write_volatile(p.add(i + 6), v);
            write_volatile(p.add(i + 7), v);
        }
        i += 8;
    }
}

/// One row: a label, bytes per cycle and MB/s at the VCU118's clock.
fn show(label: &str, bytes: u64, cycles: u64) {
    let bpc = bytes * 100 / cycles;
    let mbs = bytes * MHZ / cycles;
    println!("{:>10} {:>5}.{:02} {:>8}", label, bpc / 100, bpc % 100, mbs);
}

/// A size in its largest whole unit, as a label.
fn size_label(bytes: usize, buf: &mut [u8; 8]) -> &str {
    let (mut v, unit) = if bytes.is_multiple_of(MB) {
        (bytes / MB, b'M')
    } else {
        (bytes / KB, b'K')
    };
    let mut n = buf.len();
    n -= 1;
    buf[n] = unit;
    loop {
        n -= 1;
        buf[n] = b'0' + (v % 10) as u8;
        v /= 10;
        if v == 0 {
            break;
        }
    }
    core::str::from_utf8(&buf[n..]).unwrap_or("?")
}

/// The values STREAM expects in each array after `TIMES` rounds.
fn expected() -> (f64, f64, f64) {
    let (mut a, mut b, mut c) = (1.0, 2.0, 0.0);
    for _ in 0..TIMES {
        c = a;
        b = SCALAR * c;
        c = a + b;
        a = b + SCALAR * c;
    }
    (a, b, c)
}

fn stream(gap: usize) {
    let (a, b, c) = (array(0, gap), array(1, gap), array(2, gap));
    each8(N, |i| unsafe {
        *a.add(i) = 1.0;
        *b.add(i) = 2.0;
        *c.add(i) = 0.0;
    });

    let mut best = [u64::MAX; 4];
    for _ in 0..TIMES {
        let t = [
            timed(|| copy(a, c)),
            timed(|| scale(c, b)),
            timed(|| add(a, b, c)),
            timed(|| triad(b, c, a)),
        ];
        for (b, t) in best.iter_mut().zip(t) {
            *b = (*b).min(t);
        }
    }

    let words = N as u64 * 8;
    show("Copy", 2 * words, best[0]);
    show("Scale", 2 * words, best[1]);
    show("Add", 3 * words, best[2]);
    show("Triad", 3 * words, best[3]);

    let (ea, eb, ec) = expected();
    for i in 0..N {
        let got = unsafe { (*a.add(i), *b.add(i), *c.add(i)) };
        if got != (ea, eb, ec) {
            println!("wrong result at {i}: {got:?}, expected {:?}", (ea, eb, ec));
            exit(1);
        }
    }
}

#[entry]
fn main() -> ! {
    println!("membw: bandwidth, bytes per cycle, and MB/s at {MHZ} MHz");

    println!();
    println!("1. STREAM kernels over 3 x 4M, best of {TIMES}");
    for gap in [0, 64] {
        println!("gap between the arrays: {gap} bytes");
        println!("{:>10} {:>8} {:>8}", "kernel", "B/cycle", "MB/s");
        stream(gap);
    }

    let p = BUF as *mut u64;
    let mut label = [0u8; 8];

    println!();
    println!("2. loads only");
    println!("{:>10} {:>8} {:>8}", "size", "B/cycle", "MB/s");
    for &size in SIZES {
        let words = size / 8;
        // At least 1 MB read, and at least twice over, after a pass to warm up.
        let passes = (MB / size).max(2);
        black_box(read(p, words));
        let cycles = timed(|| {
            for _ in 0..passes {
                black_box(read(p, words));
            }
        });
        show(size_label(size, &mut label), (size * passes) as u64, cycles);
    }

    println!();
    println!("3. stores only");
    println!("{:>10} {:>8} {:>8}", "size", "B/cycle", "MB/s");
    for &size in SIZES {
        let words = size / 8;
        let passes = (MB / size).max(2);
        write(p, words, 0);
        let cycles = timed(|| {
            for k in 0..passes {
                write(p, words, k as u64);
            }
        });
        show(size_label(size, &mut label), (size * passes) as u64, cycles);
    }

    println!();
    println!("membw: done");
    exit(0)
}
