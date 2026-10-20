# make -C linux    builds linux.elf: Linux 5.15 on heliodor, console on RTT
#
# The kernel is the one heliodor's own tests boot, taken out of its DRAM
# image. Run it with `hio --regs hns/vcu118/regs.json cpu boot linux/linux.elf`.
-include ../local.mk
CROSS      ?= riscv64-unknown-elf-
HELIODOR   ?= ../../heliodor
KERNEL_HEX ?= $(HELIODOR)/test/hex/linux_dram_real.hex
DTB_ADDR   := 0x81e00000
FW_BASE    := 0x81f00000

linux.elf: fw.S image.S link.ld Image heliodor.dtb Makefile
	$(CROSS)gcc -march=rv64imac_zicsr_zifencei -mabi=lp64 -nostdlib -static \
		-DDTB_ADDR=$(DTB_ADDR) -Wl,--defsym=DTB_ADDR=$(DTB_ADDR) -Wl,--defsym=FW_BASE=$(FW_BASE) \
		-T link.ld -o $@ fw.S image.S

Image: $(KERNEL_HEX) hex2image.py
	python3 -I hex2image.py $< $@ 0x80000000 $(FW_BASE)

heliodor.dtb: heliodor.dts
	dtc -I dts -O dtb -o $@ $<

clean:
	rm -f linux.elf Image Image.head heliodor.dtb
