# run-heliodor

Runs the [heliodor](https://github.com/dalance/heliodor) RISC-V core (RV64GC,
out of order) in the Veryl simulator or on a Xilinx VCU118, with
[veryl-harness](https://github.com/shuntarot/uharness). The core fetches,
loads and stores through one memory, which the host fills before the core
starts.

`rtl/heliodor_sys.veryl` is heliodor's SoC (`heliodor_soc_smp`): the 2-wide
core with its caches, the shared L2, CLINT, PLIC and Debug Module. The SoC
ends in one AXI4 master, which goes to the harness's `dram`, and the Debug
Module's DMI goes to the host, so `hio cpu` (`info`, `halt`, `regs`, `step`,
`break`, ...) works on the running core.

## Address map

| Address | Size | Region |
|---|---|---|
| `0x0000_4000` – `0x0000_5FFF` | 8 KB | Debug Module |
| `0x0200_0000` – `0x0200_FFFF` | 64 KB | CLINT |
| `0x0C00_0000` – `0x0C3F_FFFF` | 4 MB | PLIC |
| `0x1000_0000` – `0x1000_0FFF` | 4 KB | UART (not connected; the console is RTT) |
| `0x8000_0000` – `0x81FF_FFFF` | 32 MB | DRAM, cached: the reset PC, the program |
| `0x8200_0000` – `0x83FF_FFFF` | 32 MB | DRAM, not cached: the RTT console, `tohost` |
| `0x8400_0000` – `0xFFFF_FFFF` | 1984 MB | DRAM, cached |

Every other address is a hole. The caches write back and nothing writes them
back to DRAM, so what the host must see goes to the 32 MB that are not
cached. `hio cpu mem --sba` reads cached memory as the core sees it.

## Requirements

- Veryl, with `veryl-harness` and `hio` from veryl-harness
- [shuntarot/heliodor](https://github.com/shuntarot/heliodor), branch `fpga`,
  cloned beside this directory
  (`git clone -b fpga https://github.com/shuntarot/heliodor ../heliodor`).
  The branch makes the L2, the cache tags and the BTB fit FPGA block RAM
- Vivado and a VCU118, for the board
- Rust through rustup, for the firmware
- `riscv64-unknown-elf-gcc` for `asm/` and riscv-tests;
  `riscv64-unknown-linux-gnu-gcc`, `dtc` and `curl` for Linux

Put paths for your machine in `local.mk` (`CROSS`, `LINUX_CROSS`, `RISCV_TESTS`).

## Run

In the simulator:

```bash
veryl harness gen --target sim
veryl harness sim          # builds, then waits for hio; leave it running
hio run bringup.hio        # in another terminal
```

`bringup.hio` loads `asm/smoke.elf` (`make -C asm`), runs it, and reads back
what it wrote.

On the VCU118 (20 MHz; a build takes about 3 hours):

```bash
veryl harness gen --target xilinx/vcu118 --transport pcie -o hns/vcu118
make -C hns/vcu118/syn
hio --regs hns/vcu118/regs.json program
hio --regs hns/vcu118/regs.json run bringup.hio
```

The window is on JTAG and on PCIe. PCIe is faster: add `-p` and run `hio` as
root (`sudo "$(command -v hio)" -p ...`).

Firmware runs with `cargo run -p <app>`, and Linux with
`hio cpu boot linux/linux.elf`:

- [doc/apps.md](doc/apps.md): the firmware (`hello`, `console`, `memlat`)
  and riscv-tests
- [doc/linux.md](doc/linux.md): Linux

## Size

LUT and FF counts, block RAM in 36 Kb blocks, after place and route. The
core is the DUT alone; the design adds the harness and the board's memory
controller.

| Board | Clock | Core LUT / FF / BRAM / DSP | Design LUT / FF / BRAM / DSP |
|---|---|---|---|
| VCU118, PCIe | 20 MHz | 370,431 / 144,495 / 32 / 40 | 406,101 / 182,987 / 79.5 / 43 |
| VU440, PCIe, four harts | 10 MHz | 1,368,208 / 555,974 / 32 / 160 | 1,407,967 / 590,487 / 66.5 / 163 |

## Files

| | |
|---|---|
| `rtl/` | the SoC (`heliodor_sys.veryl`) and its tops, with one hart and with four |
| `Harness.toml`, `Harness.smp4.toml` | where each port goes, for one hart and for four |
| `vivado.tcl` | synthesis directives |
| `asm/` | the bring-up program |
| `riscv-tests/` | riscv-tests' isa tests, linked for this board |
| `bsp/`, `apps/` | the firmware's startup and console, and the programs |
| `linux/` | Linux, busybox and the SBI firmware |

## License

MIT (`LICENSE`).
