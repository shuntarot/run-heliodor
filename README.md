# run-heliodor

Runs the [heliodor](https://github.com/dalance/heliodor) RISC-V core (RV64GC,
out of order) in the Veryl simulator with
[veryl-harness](https://github.com/shuntarot/uharness). The core fetches,
loads and stores through one memory, which the host fills before the core
starts.

Only the core is used, not the heliodor SoC: `rtl/heliodor_top.veryl` serves
its memory port from the harness's `dram` over AXI4 and adds the CLINT.

## Requirements

- Veryl, with `veryl-harness` and `hio` from veryl-harness
- heliodor checked out beside this directory (`../heliodor`)
- Rust through rustup, for the firmware (`rust-toolchain.toml` picks the target)
- `riscv64-unknown-elf-gcc`, for `asm/smoke.S`
- `qemu-system-riscv64`, to run the firmware without the simulator

## Run

```bash
veryl harness gen --target sim
veryl harness sim          # builds, then waits for hio; leave it running
hio run bringup.hio        # in another terminal
```

`bringup.hio` loads `asm/smoke.elf` (`make -C asm`), runs it, and reads back
what it wrote. The expected values are in its comments.

Firmware in Rust runs with cargo. `hio cpu boot` loads it, connects to its RTT
console, and exits with its status; Ctrl-A x leaves. If `veryl harness gen`
wrote somewhere other than `hns/` (`--out-dir`), change the path of
`HIO_REGS` under `[env]` in `.cargo/config.toml` to match.

```bash
cargo run -p hello
cargo run -p console
cargo run-emu -p console   # the same on QEMU's virt machine
```

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

## Files

| | |
|---|---|
| `rtl/heliodor_top.veryl` | the DUT: heliodor's core with its memory port on AXI4, and the CLINT |
| `Harness.toml` | where each port goes |
| `asm/smoke.S` | the test program (`make -C asm`) |
| `bsp/` | startup, console (RTT, or the UART on QEMU) and exit for the firmware |
| `apps/` | the firmware: `hello`, `console` |

Put paths for your machine in `local.mk`; see `asm/Makefile`.

## License

MIT (`LICENSE`).
