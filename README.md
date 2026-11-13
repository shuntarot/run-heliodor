# run-heliodor

Runs the [heliodor](https://github.com/dalance/heliodor) RISC-V core (RV64GC,
out of order) in the Veryl simulator, on a Xilinx VCU118, or with four harts
on the fp1 (a VU440 board), with
[veryl-harness](https://github.com/shuntarot/uharness). The core fetches,
loads and stores through one memory, which the host fills before the core
starts.

`rtl/heliodor_sys.veryl` is heliodor's SoC (`heliodor_soc_smp`) with harts
of the 2-wide core: their caches and the shared L2, CLINT, PLIC and Debug
Module. The SoC ends in one AXI4 master, which goes to the harness's `dram`,
and the Debug Module's DMI goes to the host (`hio cpu`). Two tops use it:

| Top | Harts | Manifest | Board |
|---|---|---|---|
| `heliodor_top` | 1 | `Harness.toml` | the simulator, the VCU118 |
| `heliodor_smp4_top` | 4 | `Harness.smp4.toml` | the fp1 |

## Address map

What a program sees, with one hart or four.

| Address | Size | Region | Backed by |
|---|---|---|---|
| `0x0000_4000` – `0x0000_5FFF` | 8 KB | Debug Module: code at `0x4000`, data at `0x5000` | the Debug Module in the SoC |
| `0x0200_0000` – `0x0200_FFFF` | 64 KB | CLINT: timer and software interrupts | registers in the SoC |
| `0x0C00_0000` – `0x0C3F_FFFF` | 4 MB | PLIC | registers in the SoC |
| `0x1000_0000` – `0x1000_0FFF` | 4 KB | UART | registers in the SoC; its output is not connected (the console is RTT) |
| `0x8000_0000` – `0x81FF_FFFF` | 32 MB | DRAM, cached: the reset PC, the program, its data | the board's DRAM |
| `0x8200_0000` – `0x83FF_FFFF` | 32 MB | DRAM, not cached: the RTT console, `tohost` | the board's DRAM |

Every other address is a hole.

The caches and the L2 write back, and nothing writes the L2 back to DRAM, so
the window does not show what the core stores in the first 32 MB while it
runs. Anything the host reads then goes past them: `bsp/memory.x` puts the
`.console` section there, and riscv-tests put `tohost` at `0x8200_1000`.
`hio cpu mem --sba` reads the cached part through the Debug Module, which
goes through the L2 and sees what the core sees.

## Requirements

- Veryl, with `veryl-harness` and `hio` from veryl-harness
- [shuntarot/heliodor](https://github.com/shuntarot/heliodor), branch `fpga`,
  cloned beside this directory
  (`git clone -b fpga https://github.com/shuntarot/heliodor ../heliodor`); it
  is not published, so it is a path dependency. The branch makes the L2, the
  cache tags and the BTB fit FPGA block RAM
- Vivado and a VCU118 on USB, for the board
- Rust through rustup, for the firmware (`rust-toolchain.toml` picks the target)
- `riscv64-unknown-elf-gcc`, for `asm/smoke.S` and riscv-tests
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
veryl harness gen --target xilinx/vcu118 --transport pcie -o hns/vcu118
make -C hns/vcu118/syn
hio --regs hns/vcu118/regs.json program
hio --regs hns/vcu118/regs.json run bringup.hio
```

The window is on JTAG and on the card's PCIe BAR. PCIe is faster, which
matters for loading Linux: add `-p` and run `hio` as root
(`sudo "$(command -v hio)" -p ...`). The machine must have found the card at
boot; `hio serve` can reprogram it without a reboot (see `hio`'s guide).

The core runs at 20 MHz, the same core as in the simulator. A build takes
about 3 hours.

### fp1

Four harts take most of a VU440, so they have their own top and manifest.
They run at 10 MHz; a build takes about 11 hours. The fp1's target
description is not public.

```bash
veryl harness gen --target pezy/fp1 --transport pcie --config Harness.smp4.toml -o hns/smp4
make -C hns/smp4/syn
hio --regs hns/smp4/regs.json program
hio --regs hns/smp4/regs.json run bringup.hio
```

`hio cpu info` counts the four harts; the rest of `hio cpu` works on hart 0.

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
with its pass or failure code (a test that hangs times out after 60 s). They
are built here, with `tohost` moved to memory the core does not cache
(`riscv-tests/`):

```bash
make -C riscv-tests RISCV_TESTS=<riscv-tests checkout>
scripts/riscv-tests.sh riscv-tests/build/isa                    # the suites this core runs
scripts/riscv-tests.sh -o results.txt riscv-tests/build/isa 'rv64ui-p-*'   # or name them
```

## Linux

`linux/` builds Linux 6.6 with a busybox shell, and boots it with its
console on RTT. It downloads the sources into `linux/build/` (checked by
sha256); `linux/fw.S` is a small SBI firmware that puts the console on RTT
and starts the other harts. One kernel serves both builds; the device tree
says how many harts there are.

```bash
make -C linux
hio --regs hns/vcu118/regs.json cpu boot linux/linux.elf        # one hart
hio --regs hns/smp4/regs.json cpu boot linux/linux-smp4.elf     # four harts, on the fp1
make -C linux run-emu                                           # linux-smp4.elf's on QEMU
```

The shell is on the console; `exit` powers off. On the fp1 the four-hart
kernel boots to the shell in about 90 s over PCIe.

## Debug

The Debug Module's DMI is the `dmi` bundle, so `hio cpu info`, `halt`,
`regs`, `step`, `resume`, `break` and the rest of `hio cpu` work on the
running core.

## Size

LUT and FF counts, block RAM in 36 Kb blocks, after place and route. The
core is the DUT alone; the design adds the harness and the board's memory
controller.

| Target | Clock | Core LUT / FF / BRAM / DSP | Design LUT / FF / BRAM / DSP |
|---|---|---|---|
| `xilinx/vcu118`, PCIe | 20 MHz | 370,431 / 144,495 / 32 / 40 | 406,101 / 182,987 / 79.5 / 43 |
| `pezy/fp1`, PCIe, four harts | 10 MHz | 1,368,208 / 555,974 / 32 / 160 | 1,407,967 / 590,487 / 66.5 / 163 |

## Files

| | |
|---|---|
| `rtl/heliodor_sys.veryl` | heliodor's SoC with N harts, its memory map, AXI4 master and DMI |
| `rtl/heliodor_top.veryl` | the DUT with one hart |
| `rtl/heliodor_smp4_top.veryl` | the DUT with four harts (the fp1) |
| `Harness.toml` | where each port goes |
| `Harness.smp4.toml` | the same for four harts, at 10 MHz |
| `vivado.tcl` | synthesis directives (`[vivado] tcl`) |
| `asm/smoke.S` | the test program (`make -C asm`) |
| `riscv-tests/` | riscv-tests' isa tests, linked for this board (`make -C riscv-tests`) |
| `bsp/` | startup, console (RTT, or the UART on QEMU) and exit for the firmware |
| `apps/` | the firmware: `hello`, `console` |
| `linux/` | Linux and busybox, built and packed with the SBI firmware: `linux.elf` for one hart, `linux-smp4.elf` for four (`make -C linux`) |

Put paths for your machine in `local.mk` (`CROSS`, `LINUX_CROSS`, `RISCV_TESTS`).

## License

MIT (`LICENSE`).
