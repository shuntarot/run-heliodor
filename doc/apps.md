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
```

| App | What it does |
|---|---|
| `hello` | prints one line and exits |
| `console` | prints the core's ID and counters, then echoes what you type |
| `memlat` | measures load latency |
| `membw` | measures bandwidth |

## memlat

Load latency by pointer chasing, in core cycles: one pointer in each 64-byte
line, so no two loads overlap. It runs in M-mode, without the TLB, in about
10 s. On the VCU118 at 20 MHz:

| Where the line is | Cycles per load |
|---|---|
| L1 D-cache (up to 16 KB) | 5 |
| L2 (up to 128 KB) | 21 |
| DRAM | 37.7 |
| DRAM the core does not cache | 36.1 |

- Lines one way apart show 4 ways in both caches.
- Lines in address order are no faster than lines in random order.
- Two chases side by side bring a DRAM load down only to 32.6 cycles.

## membw

Bandwidth in bytes per core cycle, in M-mode, in about 6 s. First the four
kernels of the STREAM benchmark on three arrays of 4 MB, counted as STREAM
counts them, then loads alone and stores alone against the size of the
working set. On the VCU118 at 20 MHz (1 B/cycle is 20 MB/s):

| Kernel | Arrays back to back | Arrays one line apart |
|---|---|---|
| Copy | 3.92 | 3.83 |
| Scale | 3.84 | 3.83 |
| Add | 2.36 | 2.20 |
| Triad | 1.98 | 2.91 |

| Working set | Loads | Stores |
|---|---|---|
| L1 D-cache (16 KB) | 5.3 | 4.3 |
| L2 (32–128 KB) | 3.9 | 4.3 |
| DRAM (256 KB and up) | 2.0 | 4.2 |

- Loads from DRAM come at one line per 32 cycles, as two side-by-side
  chases do in `memlat`.
- Stores keep their speed all the way to DRAM: they write whole lines,
  which go to DRAM without being read first.
- With the arrays back to back, the same element of each falls in the same
  cache set, and Triad drops by a third.

## riscv-tests

riscv-tests' `isa` tests run one by one through `hio cpu boot`. Each ends
with its pass or failure code, and a test that hangs times out after 60 s.
They are built here, with `tohost` moved to memory the core does not cache:

```bash
make -C riscv-tests RISCV_TESTS=<riscv-tests checkout>
scripts/riscv-tests.sh riscv-tests/build/isa                    # the suites this core runs
scripts/riscv-tests.sh -o results.txt riscv-tests/build/isa 'rv64ui-p-*'   # or name them
```
