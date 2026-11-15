# Firmware and tests

## Firmware

Programs in Rust, under `apps/`. `hio cpu boot` loads one, connects to its
RTT console, and exits with its status; Ctrl-A x leaves. If `veryl harness
gen` wrote somewhere other than `hns/`, change `HIO_REGS` under `[env]` in
`.cargo/config.toml` to match.

```bash
cargo run -p hello
cargo run -p console
cargo run-emu -p console   # the same on QEMU's virt machine
cargo run --release -p memlat
cargo run --release -p membw
cargo run --release -p issue
```

| App | What it does |
|---|---|
| `hello` | prints one line and exits |
| `console` | prints the core's ID and counters, then echoes what you type |
| `memlat` | measures load latency |
| `membw` | measures bandwidth |
| `issue` | measures what controlling the system through registers costs |

## memlat

Load latency by pointer chasing, in core cycles: one pointer in each 64-byte
line, so no two loads overlap. It runs in M-mode, without the TLB, in about
10 s. With one hart (`Harness.toml`, 20 MHz) and with four (smp4,
`Harness.smp4.toml`, 10 MHz), where the program runs on hart 0:

| Where the line is | 1 hart | smp4 |
|---|---|---|
| L1 D-cache (up to 16 KB) | 5 | 5 |
| L2 (up to 128 KB) | 21 | 19 |
| DRAM | 37.7 | 40.6 |
| DRAM the core does not cache | 36.1 | 36.9 |
| DRAM, two to four chases side by side | 32.6 | 32.5 |

- Lines one way apart show 4 ways in both caches.
- Lines in address order are no faster than lines in random order.

## membw

Bandwidth in bytes per core cycle, in M-mode, in about 6 s. First the four
kernels of the STREAM benchmark on three arrays of 4 MB, counted as STREAM
counts them, then loads alone and stores alone against the size of the
working set. The program prints MB/s at 20 MHz, the clock of one hart.

| Kernel | 1 hart, back to back | 1 hart, one line apart | smp4, back to back | smp4, one line apart |
|---|---|---|---|---|
| Copy | 3.92 | 3.83 | 3.94 | 3.93 |
| Scale | 3.84 | 3.83 | 3.26 | 2.64 |
| Add | 2.36 | 2.20 | 2.36 | 2.78 |
| Triad | 1.98 | 2.91 | 2.01 | 2.95 |

| Working set | Loads, 1 hart | Loads, smp4 | Stores, 1 hart | Stores, smp4 |
|---|---|---|---|---|
| L1 D-cache (16 KB) | 5.3 | 5.4 | 4.3 | 7.0 |
| L2 (32–128 KB) | 3.9 | 3.95 | 4.3 | 4.5–5.5 |
| DRAM (256 KB and up) | 2.0 | 2.0 | 4.2 | 4.2 |

- Loads from DRAM come at one line per 32 cycles, as two side-by-side
  chases do in `memlat`.
- Stores to DRAM keep 4.2 B/cycle: they write whole lines, which go to
  DRAM without being read first.
- With the arrays back to back, the same element of each falls in the same
  cache set, and Triad drops by a third.

## issue

What it costs the core in M-mode to control a system through registers, in
core cycles, and whether those accesses let cache misses around them
overlap. The source builds for RV32 too, to run the same tests on other
cores.

| Access | 1 hart | smp4 |
|---|---|---|
| CLINT load (`mtime`) | 14 | 14 |
| CLINT poll: load, branch | 15.3 | 15.3 |
| CLINT store (`mtimecmp`) | 11 | 11 |
| CLINT load, or, store | 28 | 28 |
| Uncached DRAM load, dependent / independent | 36.1 / 32.2 | 36.9 / 32.5 |
| Uncached DRAM store | 17 | 17 |
| CSR read / write | 4.1 / 13.8 | 4.1 / 13.8 |
| `fence` / `fence.i` | 1.1 / 63–68 | 1.1 / 68 |
| `ecall` to a handler and back | 42.6 | 42.6 |
| `msip` store to the interrupt handler | 28–32 | 28 |
| `msip` store, the handler, and back | 57–60 | 57 |

The last two include two `mcycle` reads, 9 cycles together. Where a
range is given, it moved by that much when the code moved.

- Register loads and stores run one at a time, after every older
  instruction, and a store waits for its response.
- A CSR write holds up the instructions after it: 32 adds take 17 cycles
  alone, 21 with a CSR read among them, and 34 with a CSR write.
- Of what can sit between two DRAM misses, only an uncached load and a
  `fence` keep the second from starting before the first ends; a CLINT
  access or a CSR access does not.

## riscv-tests

riscv-tests' `isa` tests run one by one through `hio cpu boot`. Each ends
with its pass or failure code, and a test that hangs times out after 60 s.
They are built here, with `tohost` moved to memory the core does not cache:

```bash
make -C riscv-tests RISCV_TESTS=<riscv-tests checkout>
scripts/riscv-tests.sh riscv-tests/build/isa                    # the suites this core runs
scripts/riscv-tests.sh -o results.txt riscv-tests/build/isa 'rv64ui-p-*'   # or name them
```
