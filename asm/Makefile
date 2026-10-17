-include ../local.mk
CROSS ?= riscv64-unknown-elf-

smoke.elf: smoke.S link.ld
	$(CROSS)gcc -march=rv64gc_zicbom -mabi=lp64d -nostdlib -static -T link.ld -o $@ $<

clean:
	rm -f *.elf
