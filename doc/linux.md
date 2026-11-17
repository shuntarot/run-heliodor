# Linux

`linux/` builds Linux 6.6 with a busybox shell, and boots it with its console
on RTT. It downloads the sources into `linux/build/` (checked by sha256).
`linux/fw.S` is a small SBI firmware: it puts the console on RTT, starts the
other harts, and ends `hio cpu boot` on a shutdown.

```bash
make -C linux
hio --regs hns/vcu118/regs.json cpu boot linux/linux.elf
make -C linux run-emu      # four harts on QEMU
```

The shell is on the console; `exit` powers off.

One kernel serves every build; the device tree says how many harts there
are and how much memory. `linux.elf` is for one hart, `linux-smp4.elf` for
four.

Built with `-DEMULATE_TIME`, the firmware serves a core with no `time` CSR,
such as Rocket: `rdtime` traps to M-mode, and the firmware answers with the
CLINT's mtime. Other illegal instructions go on to S-mode. The core must put
the instruction in mtval.
