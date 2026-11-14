//! Load latency through the memory system, in core cycles (mcycle).
//!
//! Every test is a pointer chase: each load reads the address of the next,
//! so no two loads overlap and the time per load is its latency. One pointer
//! sits in each 64-byte line. The core runs in M-mode with no address
//! translation, so the TLB plays no part.
//!
//! 1. Latency against the size of the working set, lines in random order:
//!    the steps are the L1 D-cache, the L2 and DRAM.
//! 2. The same, lines in address order: shows a prefetcher or DRAM page
//!    hits, if there are any.
//! 3. k lines that fall in one set (a stride of one way): latency jumps when
//!    k passes the number of ways.
//! 4. Several chases that do not depend on each other, side by side: how
//!    many misses the core keeps in flight.
//! 5. Loads from DRAM the core does not cache.

#![no_std]
#![no_main]

use core::ptr::{read_volatile, write_volatile};

use heliodor_bsp::{entry, exit, println, riscv};
use riscv::register::mcycle;

const LINE: usize = 64;
/// Cached DRAM past the program's 32 MB: nothing else uses it.
const BUF: usize = 0x8400_0000;
/// DRAM the core does not cache, past the RTT console.
const UNCACHED: usize = 0x8380_0000;

const KB: usize = 1024;
const MB: usize = 1024 * KB;

const SIZES: &[usize] = &[
    KB,
    2 * KB,
    4 * KB,
    8 * KB,
    12 * KB,
    14 * KB,
    16 * KB,
    20 * KB,
    24 * KB,
    32 * KB,
    48 * KB,
    64 * KB,
    96 * KB,
    112 * KB,
    128 * KB,
    144 * KB,
    160 * KB,
    176 * KB,
    192 * KB,
    256 * KB,
    512 * KB,
    MB,
    2 * MB,
    4 * MB,
    8 * MB,
    16 * MB,
];

/// xorshift64: a fixed seed, so every run chases the same order.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.0 = x;
        x
    }
}

fn line(base: usize, i: usize, stride: usize) -> *mut usize {
    (base + i * stride) as *mut usize
}

/// Links `n` lines at `base`, `stride` bytes apart, into one cycle: line i
/// holds the index of the line after it, then its address. Random order is
/// Sattolo's shuffle, which turns the identity into a single cycle (started
/// from anything else, it can split into several).
fn link(base: usize, n: usize, stride: usize, random: bool, rng: &mut Rng) -> usize {
    unsafe {
        for i in 0..n {
            let next = if random { i } else { (i + 1) % n };
            write_volatile(line(base, i, stride), next);
        }
        if random {
            for i in (1..n).rev() {
                let j = (rng.next() % i as u64) as usize;
                let a = read_volatile(line(base, i, stride));
                let b = read_volatile(line(base, j, stride));
                write_volatile(line(base, i, stride), b);
                write_volatile(line(base, j, stride), a);
            }
        }
        for i in 0..n {
            let next = read_volatile(line(base, i, stride));
            write_volatile(line(base, i, stride), base + next * stride);
        }
    }
    base
}

/// Follows the chain for `8 * rounds` loads and returns the cycles taken and
/// where it stopped.
#[inline(never)]
fn chase(mut p: usize, rounds: usize) -> (u64, usize) {
    let t0 = mcycle::read64();
    for _ in 0..rounds {
        unsafe {
            p = read_volatile(p as *const usize);
            p = read_volatile(p as *const usize);
            p = read_volatile(p as *const usize);
            p = read_volatile(p as *const usize);
            p = read_volatile(p as *const usize);
            p = read_volatile(p as *const usize);
            p = read_volatile(p as *const usize);
            p = read_volatile(p as *const usize);
        }
    }
    (mcycle::read64() - t0, p)
}

/// Chases side by side, one pointer each, for `4 * rounds` loads each.
/// Returns the cycles taken. The pointers stay in registers: through an
/// array they would go through the stack between loads.
macro_rules! chase_side_by_side {
    ($name:ident, $($p:ident),+) => {
        #[inline(never)]
        fn $name($(mut $p: usize,)+ rounds: usize) -> u64 {
            let t0 = mcycle::read64();
            for _ in 0..rounds {
                unsafe {
                    $($p = read_volatile($p as *const usize);)+
                    $($p = read_volatile($p as *const usize);)+
                    $($p = read_volatile($p as *const usize);)+
                    $($p = read_volatile($p as *const usize);)+
                }
            }
            let t = mcycle::read64() - t0;
            core::hint::black_box(($($p,)+));
            t
        }
    };
}

chase_side_by_side!(chase1, a);
chase_side_by_side!(chase2, a, b);
chase_side_by_side!(chase3, a, b, c);
chase_side_by_side!(chase4, a, b, c, d);

/// Cycles per load, in hundredths.
fn per_load(cycles: u64, loads: usize) -> u64 {
    cycles * 100 / loads as u64
}

/// One row: a size (or a count when `unit` is empty) and cycles per load.
fn show(v: usize, unit: &str, cycles: u64, loads: usize) {
    let c = per_load(cycles, loads);
    println!("{:>8}{:<2} {:>5}.{:02}", v, unit, c / 100, c % 100);
}

/// A size in its largest whole unit.
fn split(bytes: usize) -> (usize, &'static str) {
    if bytes.is_multiple_of(MB) {
        (bytes / MB, "M")
    } else if bytes.is_multiple_of(KB) {
        (bytes / KB, "K")
    } else {
        (bytes, "B")
    }
}

fn show_size(bytes: usize, cycles: u64, loads: usize) {
    let (v, unit) = split(bytes);
    show(v, unit, cycles, loads);
}

/// The chain from `start` must come back to it after exactly `n` loads, and
/// stay inside the buffer: a shorter loop would fit in a cache and read as
/// a faster memory.
fn check_cycle(start: usize, n: usize) {
    let mut p = start;
    for step in 1..=n {
        p = unsafe { read_volatile(p as *const usize) };
        if p < BUF || p >= BUF + n * LINE || !p.is_multiple_of(LINE) {
            println!("bad chain: step {step} of {n} reads {p:#x}");
            exit(1);
        }
        if p == start && step != n {
            println!("bad chain: back at the start after {step} of {n}");
            exit(1);
        }
    }
    if p != start {
        println!("bad chain: not back at the start after {n}");
        exit(1);
    }
}

/// Latency per load over `size` bytes of lines: one pass to warm up, then
/// at least two passes and 16384 loads, timed.
fn by_size(size: usize, random: bool, rng: &mut Rng) -> (u64, usize) {
    let n = size / LINE;
    let p = link(BUF, n, LINE, random, rng);
    check_cycle(p, n);
    let (_, p) = chase(p, n.div_ceil(8));
    let rounds = (2 * n).max(16384) / 8;
    let (cycles, _) = chase(p, rounds);
    (cycles, rounds * 8)
}

#[entry]
fn main() -> ! {
    let mut rng = Rng(0x9e37_79b9_7f4a_7c15);

    println!("memlat: load latency, cycles per load (mcycle)");

    println!();
    println!("1. working set, lines in random order");
    println!("{:>10} {:>8}", "size", "cycles");
    for &size in SIZES {
        let (cycles, loads) = by_size(size, true, &mut rng);
        show_size(size, cycles, loads);
    }

    println!();
    println!("2. working set, lines in address order");
    println!("{:>10} {:>8}", "size", "cycles");
    for &size in &[8 * KB, 64 * KB, MB, 16 * MB] {
        let (cycles, loads) = by_size(size, false, &mut rng);
        show_size(size, cycles, loads);
    }

    println!();
    println!("3. k lines in one set, `stride` bytes apart");
    for &stride in &[4 * KB, 32 * KB] {
        let (v, unit) = split(stride);
        println!("stride {}{}", v, unit);
        println!("{:>10} {:>8}", "k", "cycles");
        for k in 1..=8 {
            let p = link(BUF, k, stride, false, &mut rng);
            let (_, p) = chase(p, 64);
            let (cycles, _) = chase(p, 2048);
            show(k, "", cycles, 2048 * 8);
        }
    }

    println!();
    println!("4. independent chases side by side over 16M, cycles per load");
    println!("{:>10} {:>8}", "chases", "cycles");
    {
        let n = 16 * MB / LINE;
        let p0 = link(BUF, n, LINE, true, &mut rng);
        // Start points a quarter of the cycle apart, so the chases never meet.
        let mut starts = [p0; 4];
        let mut p = p0;
        for (s, start) in starts.iter_mut().enumerate() {
            if s > 0 {
                let (_, q) = chase(p, n / 4 / 8);
                p = q;
            }
            *start = p;
        }
        let rounds = 4096;
        let [a, b, c, d] = starts;
        show(1, "", chase1(a, rounds), rounds * 4);
        show(2, "", chase2(a, b, rounds), rounds * 4 * 2);
        show(3, "", chase3(a, b, c, rounds), rounds * 4 * 3);
        show(4, "", chase4(a, b, c, d, rounds), rounds * 4 * 4);
    }

    println!();
    println!("5. DRAM the core does not cache");
    println!("{:>10} {:>8}", "lines", "cycles");
    {
        let p = link(UNCACHED, 64, LINE, true, &mut rng);
        let (cycles, _) = chase(p, 512);
        show(64, "", cycles, 512 * 8);
    }

    println!();
    println!("memlat: done");
    exit(0)
}
