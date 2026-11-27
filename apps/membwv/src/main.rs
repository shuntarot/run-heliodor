//! Memory bandwidth with the vector unit (RVV 1.0), in bytes per core cycle
//! (mcycle): `membw`'s tests again, with vector loads and stores of 64-bit
//! elements.
//!
//! 1. Loads only against the size of the working set, at LMUL 1 (16 bytes
//!    a load) and LMUL 4 (64 bytes, one line).
//! 2. Stores only, the same way.
//! 3. Copy, Scale, Add and Triad on three arrays of doubles, 4 MB each, at
//!    LMUL 4, best of three; arrays back to back, and one line apart.
//!
//! `membw` is the scalar code the other cores run; this one is for cores
//! with V. The kernels are inline assembly, so the compiler needs no V
//! target feature. Triad multiplies and adds in two steps, as the scalar
//! kernel does.

#![no_std]
#![no_main]

use core::arch::asm;
use core::hint::black_box;

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

/// Turns the vector unit on: mstatus.VS = Initial.
fn vector_on() {
    unsafe { asm!("csrs mstatus, {0}", in(reg) 1usize << 9) };
}

/// VLENB, bytes in one vector register.
fn vlenb() -> usize {
    let v: usize;
    unsafe {
        asm!(".option push", ".option arch, +v", "csrr {0}, vlenb", ".option pop",
             out(reg) v)
    };
    v
}

/// Runs `f` and returns the cycles it took.
fn timed(f: impl FnOnce()) -> u64 {
    let t0 = mcycle::read64();
    f();
    mcycle::read64() - t0
}

/// Sums `words` 64-bit words from `p` into a vector of sums. `$lmul` is m1
/// or m4, `$acc` and `$x` vector registers aligned to it.
macro_rules! vload {
    ($name:ident, $lmul:literal) => {
        #[inline(never)]
        fn $name(p: *const u64, words: usize) -> u64 {
            let s: u64;
            unsafe {
                asm!(
                    ".option push",
                    ".option arch, +v",
                    concat!("vsetvli t0, zero, e64, ", $lmul, ", ta, ma"),
                    "vmv.v.i v8, 0",
                    "2:",
                    concat!("vsetvli t0, {n}, e64, ", $lmul, ", ta, ma"),
                    "vle64.v v16, ({p})",
                    "vadd.vv v8, v8, v16",
                    "sub {n}, {n}, t0",
                    "slli t0, t0, 3",
                    "add {p}, {p}, t0",
                    "bnez {n}, 2b",
                    // Sum the lanes so the loads are used.
                    concat!("vsetvli t0, zero, e64, ", $lmul, ", ta, ma"),
                    "vmv.s.x v24, zero",
                    "vredsum.vs v24, v8, v24",
                    "vmv.x.s {s}, v24",
                    ".option pop",
                    p = inout(reg) p => _,
                    n = inout(reg) words => _,
                    s = out(reg) s,
                    out("t0") _,
                    out("v8") _, out("v9") _, out("v10") _, out("v11") _,
                    out("v16") _, out("v17") _, out("v18") _, out("v19") _,
                    out("v24") _,
                    options(nostack),
                );
            }
            s
        }
    };
}

macro_rules! vstore {
    ($name:ident, $lmul:literal) => {
        #[inline(never)]
        fn $name(p: *mut u64, words: usize, v: u64) {
            unsafe {
                asm!(
                    ".option push",
                    ".option arch, +v",
                    concat!("vsetvli t0, zero, e64, ", $lmul, ", ta, ma"),
                    "vmv.v.x v8, {v}",
                    "2:",
                    concat!("vsetvli t0, {n}, e64, ", $lmul, ", ta, ma"),
                    "vse64.v v8, ({p})",
                    "sub {n}, {n}, t0",
                    "slli t0, t0, 3",
                    "add {p}, {p}, t0",
                    "bnez {n}, 2b",
                    ".option pop",
                    p = inout(reg) p => _,
                    n = inout(reg) words => _,
                    v = in(reg) v,
                    out("t0") _,
                    out("v8") _, out("v9") _, out("v10") _, out("v11") _,
                    options(nostack),
                );
            }
        }
    };
}

vload!(vload_m1, "m1");
vload!(vload_m4, "m4");
vstore!(vstore_m1, "m1");
vstore!(vstore_m4, "m4");

/// The STREAM kernels at LMUL 4. `n` doubles; a, b and c as in STREAM.
#[inline(never)]
fn vcopy(a: *const f64, c: *mut f64, n: usize) {
    unsafe {
        asm!(
            ".option push", ".option arch, +v",
            "2:",
            "vsetvli t0, {n}, e64, m4, ta, ma",
            "vle64.v v8, ({a})",
            "vse64.v v8, ({c})",
            "sub {n}, {n}, t0",
            "slli t0, t0, 3",
            "add {a}, {a}, t0",
            "add {c}, {c}, t0",
            "bnez {n}, 2b",
            ".option pop",
            a = inout(reg) a => _, c = inout(reg) c => _, n = inout(reg) n => _,
            out("t0") _, out("v8") _, out("v9") _, out("v10") _, out("v11") _,
            options(nostack),
        );
    }
}

#[inline(never)]
fn vscale(c: *const f64, b: *mut f64, n: usize) {
    unsafe {
        asm!(
            ".option push", ".option arch, +v",
            "2:",
            "vsetvli t0, {n}, e64, m4, ta, ma",
            "vle64.v v8, ({c})",
            "vfmul.vf v8, v8, {s}",
            "vse64.v v8, ({b})",
            "sub {n}, {n}, t0",
            "slli t0, t0, 3",
            "add {c}, {c}, t0",
            "add {b}, {b}, t0",
            "bnez {n}, 2b",
            ".option pop",
            c = inout(reg) c => _, b = inout(reg) b => _, n = inout(reg) n => _,
            s = in(freg) SCALAR,
            out("t0") _, out("v8") _, out("v9") _, out("v10") _, out("v11") _,
            options(nostack),
        );
    }
}

#[inline(never)]
fn vadd(a: *const f64, b: *const f64, c: *mut f64, n: usize) {
    unsafe {
        asm!(
            ".option push", ".option arch, +v",
            "2:",
            "vsetvli t0, {n}, e64, m4, ta, ma",
            "vle64.v v8, ({a})",
            "vle64.v v12, ({b})",
            "vfadd.vv v8, v8, v12",
            "vse64.v v8, ({c})",
            "sub {n}, {n}, t0",
            "slli t0, t0, 3",
            "add {a}, {a}, t0",
            "add {b}, {b}, t0",
            "add {c}, {c}, t0",
            "bnez {n}, 2b",
            ".option pop",
            a = inout(reg) a => _, b = inout(reg) b => _, c = inout(reg) c => _,
            n = inout(reg) n => _,
            out("t0") _,
            out("v8") _, out("v9") _, out("v10") _, out("v11") _,
            out("v12") _, out("v13") _, out("v14") _, out("v15") _,
            options(nostack),
        );
    }
}

#[inline(never)]
fn vtriad(b: *const f64, c: *const f64, a: *mut f64, n: usize) {
    unsafe {
        asm!(
            ".option push", ".option arch, +v",
            "2:",
            "vsetvli t0, {n}, e64, m4, ta, ma",
            "vle64.v v8, ({b})",
            "vle64.v v12, ({c})",
            "vfmul.vf v12, v12, {s}",
            "vfadd.vv v8, v8, v12",
            "vse64.v v8, ({a})",
            "sub {n}, {n}, t0",
            "slli t0, t0, 3",
            "add {b}, {b}, t0",
            "add {c}, {c}, t0",
            "add {a}, {a}, t0",
            "bnez {n}, 2b",
            ".option pop",
            b = inout(reg) b => _, c = inout(reg) c => _, a = inout(reg) a => _,
            n = inout(reg) n => _,
            s = in(freg) SCALAR,
            out("t0") _,
            out("v8") _, out("v9") _, out("v10") _, out("v11") _,
            out("v12") _, out("v13") _, out("v14") _, out("v15") _,
            options(nostack),
        );
    }
}

/// Array `k`, `gap` bytes past the end of the one before it.
fn array(k: usize, gap: usize) -> *mut f64 {
    (BUF + k * (N * 8 + gap)) as *mut f64
}

/// One row: a label, bytes per cycle and MB/s at the VCU118's clock.
fn show(label: &str, bytes: u64, cycles: u64) {
    let bpc = bytes * 100 / cycles;
    let mbs = bytes * MHZ / cycles;
    println!("{:>10} {:>5}.{:02} {:>8}", label, bpc / 100, bpc % 100, mbs);
}

/// Two values on one row, bytes per cycle each.
fn show2(label: &str, bytes: u64, c1: u64, c4: u64) {
    let (x, y) = (bytes * 100 / c1, bytes * 100 / c4);
    println!("{:>10} {:>5}.{:02} {:>5}.{:02}", label, x / 100, x % 100, y / 100, y % 100);
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
    for i in 0..N {
        unsafe {
            *a.add(i) = 1.0;
            *b.add(i) = 2.0;
            *c.add(i) = 0.0;
        }
    }

    let mut best = [u64::MAX; 4];
    for _ in 0..TIMES {
        let t = [
            timed(|| vcopy(a, c, N)),
            timed(|| vscale(c, b, N)),
            timed(|| vadd(a, b, c, N)),
            timed(|| vtriad(b, c, a, N)),
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
    vector_on();
    println!("membwv: bandwidth with vector loads and stores, bytes per cycle");
    println!("VLENB {} (VLEN {} bits)", vlenb(), vlenb() * 8);

    let p = BUF as *mut u64;
    let mut label = [0u8; 8];

    println!();
    println!("1. vector loads only, B/cycle");
    println!("{:>10} {:>8} {:>8}", "size", "LMUL 1", "LMUL 4");
    for &size in SIZES {
        let words = size / 8;
        // At least 1 MB read, and at least twice over, after a pass to warm up.
        let passes = (MB / size).max(2);
        let sum = vload_m1(p, words);
        // The words must add up as a scalar loop sees them.
        let mut want = 0u64;
        for i in 0..words {
            want = want.wrapping_add(unsafe { p.add(i).read_volatile() });
        }
        if sum != want {
            println!("wrong sum over {size} bytes: {sum:#x}, expected {want:#x}");
            exit(1);
        }
        let c1 = timed(|| {
            for _ in 0..passes {
                black_box(vload_m1(p, words));
            }
        });
        black_box(vload_m4(p, words));
        let c4 = timed(|| {
            for _ in 0..passes {
                black_box(vload_m4(p, words));
            }
        });
        show2(size_label(size, &mut label), (size * passes) as u64, c1, c4);
    }

    println!();
    println!("2. vector stores only, B/cycle");
    println!("{:>10} {:>8} {:>8}", "size", "LMUL 1", "LMUL 4");
    for &size in SIZES {
        let words = size / 8;
        let passes = (MB / size).max(2);
        vstore_m1(p, words, 0);
        let c1 = timed(|| {
            for k in 0..passes {
                vstore_m1(p, words, k as u64);
            }
        });
        vstore_m4(p, words, 0);
        let c4 = timed(|| {
            for k in 0..passes {
                vstore_m4(p, words, k as u64);
            }
        });
        for i in [0, words / 2, words - 1] {
            let v = unsafe { p.add(i).read_volatile() };
            if v != (passes - 1) as u64 {
                println!("wrong store at word {i} of {size} bytes: {v}");
                exit(1);
            }
        }
        show2(size_label(size, &mut label), (size * passes) as u64, c1, c4);
    }

    println!();
    println!("3. STREAM kernels over 3 x 4M, vector LMUL 4, best of {TIMES}");
    for gap in [0, 64] {
        println!("gap between the arrays: {gap} bytes");
        println!("{:>10} {:>8} {:>8}", "kernel", "B/cycle", "MB/s");
        stream(gap);
    }

    println!();
    println!("membwv: done");
    exit(0)
}
