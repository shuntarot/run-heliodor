# run-heliodor

Runs the [heliodor](https://github.com/dalance/heliodor) RISC-V core (RV64GC,
out of order) in the Veryl simulator or on a Xilinx VCU118 with
[veryl-harness](https://github.com/shuntarot/uharness). The core fetches,
loads and stores through one memory, which the host fills before the core
starts.

Only the core is used, not the heliodor SoC: `rtl/heliodor_top.veryl` serves
its memory port from the harness's `dram` over AXI4 and adds the CLINT.

## Requirements

- Veryl, with `veryl-harness` and `hio` from veryl-harness
- [shuntarot/heliodor](https://github.com/shuntarot/heliodor) cloned beside
  this directory (`../heliodor`); it is not published, so it is a path
  dependency
- Vivado and a VCU118 on USB, for the board
- Rust through rustup, for the firmware (`rust-toolchain.toml` picks the target)
- `riscv64-unknown-elf-gcc`, for `asm/smoke.S`
- `qemu-system-riscv64`, to run the firmware without the simulator
- For Linux: `riscv64-unknown-linux-gnu-gcc`, `dtc` and `curl`

## Run

```bash
veryl harness gen --target sim
veryl harness sim          # builds, then waits for hio; leave it running
hio run bringup.hio        # in another terminal
```

`bringup.hio` loads `asm/smoke.elf` (`make -C asm`), runs it, and reads back
what it wrote. The expected values are in its comments.

On the VCU118, generate into another directory and point `hio` at it:

```bash
veryl harness gen --target xilinx/vcu118 -o hns/vcu118
make -C hns/vcu118/syn
hio --regs hns/vcu118/regs.json program
hio --regs hns/vcu118/regs.json run bringup.hio
```

The core is cut down to fit one FPGA (no vector unit, a 512-entry BTB) and
runs at 20 MHz; the same core runs in the simulator. A build takes about
3 hours.

Firmware in Rust runs with cargo. `hio cpu boot` loads it, connects to its RTT
console, and exits with its status; Ctrl-A x leaves. If `veryl harness gen`
wrote somewhere other than `hns/` (`--out-dir`), change the path of
`HIO_REGS` under `[env]` in `.cargo/config.toml` to match.

```bash
cargo run -p hello
cargo run -p console
cargo run-emu -p console   # the same on QEMU's virt machine
```

riscv-tests' `isa` tests run one by one through `hio cpu boot`, each ending
with its pass or failure code (a test that hangs times out after 60 s):

```bash
scripts/riscv-tests.sh <riscv-tests>/share/riscv-tests/isa          # the suites this core runs
scripts/riscv-tests.sh -o results.txt <isa dir> 'rv64ui-p-*'   # or name them
```

## Linux

`linux/` builds Linux 6.6 with a busybox shell, and boots it with its
console on RTT. It downloads the sources into `linux/build/` (checked by
sha256); `linux/fw.S` is a small SBI firmware that puts the console on RTT.

```bash
make -C linux
hio --regs hns/vcu118/regs.json cpu boot linux/linux.elf
```

The shell is on the console; `exit` powers off. Some commands (`ls`) still
crash: a core bug, not fixed yet.

## Memory

| Address | |
|---|---|
| `0x8000_0000` | DRAM (`mem`), the reset PC. The core caches the first 32 MB |
| `0x8200_0000` | the same DRAM, past the cached part: the RTT console lives here |
| `0x0200_0000` | CLINT |

The D-cache writes back, so the host does not see what the core stores in the
first 32 MB until the line leaves the cache (`fence.i` writes back all of it,
`cbo.clean` one line). Anything the host reads while the program runs goes
past it; `bsp/memory.x` puts the `.console` section there.

## Size

LUT and FF counts, block RAM in 36 Kb blocks, after place and route. The
core is the DUT alone; the design adds the harness and the board's memory
controller.

| Target | Clock | Core LUT / FF / BRAM / DSP | Design LUT / FF / BRAM / DSP |
|---|---|---|---|
| `xilinx/vcu118` | 20 MHz | 378,002 / 151,055 / 0 / 82 | 399,199 / 173,141 / 25.5 / 85 |

## Files

| | |
|---|---|
| `rtl/heliodor_top.veryl` | the DUT: heliodor's core with its memory port on AXI4, and the CLINT |
| `Harness.toml` | where each port goes |
| `vivado.tcl` | synthesis directives (`[vivado] tcl`) |
| `asm/smoke.S` | the test program (`make -C asm`) |
| `bsp/` | startup, console (RTT, or the UART on QEMU) and exit for the firmware |
| `apps/` | the firmware: `hello`, `console` |
| `linux/` | Linux and busybox, built and packed with the SBI firmware (`make -C linux`) |

Put paths for your machine in `local.mk` (`CROSS`, `LINUX_CROSS`).

## License

MIT (`LICENSE`).
