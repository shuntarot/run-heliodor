# make -C linux    builds linux.elf (one hart, the VCU118) and linux-smp4.elf
#                  (four harts, the fp1): Linux with busybox on heliodor,
#                  console on RTT
# make -C linux run-emu    linux-smp4.elf's on QEMU, with four harts
#
# It downloads Linux and busybox into build/ (checked by sha256), builds
# both, and puts them in one ELF with the firmware and the device tree. Run
# it with `hio --regs hns/vcu118/regs.json cpu boot linux/linux.elf`.
#
# LINUX_CROSS is a riscv64 Linux toolchain (glibc), for busybox and the
# kernel; set it in local.mk.
-include ../local.mk
LINUX_CROSS ?= riscv64-unknown-linux-gnu-
JOBS  ?= $(shell nproc)

LINUX_VER   := 6.6.159
LINUX_SHA   := 7206727244da5d85f4a03758d29e1c0673f2f01877793f494c0f3638c46b8fa5
LINUX_URL   := https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$(LINUX_VER).tar.xz
BUSYBOX_VER := 1.37.0
BUSYBOX_SHA := 3311dff32e746499f4df0d5df04d7eb396382d7e108bb9250e7b519b837043a4
BUSYBOX_URL := https://busybox.net/downloads/busybox-$(BUSYBOX_VER).tar.bz2

# Where fw.S puts the device tree: in memory, past the kernel.
DTB_ADDR := 0x81e00000

B       := $(abspath build)
# The version string names who built it; keep this machine out of it.
KMAKE   = $(MAKE) -C $(LINUX) O=$(B)/kbuild ARCH=riscv CROSS_COMPILE=$(LINUX_CROSS) \
          KBUILD_BUILD_USER=build KBUILD_BUILD_HOST=run-heliodor
LINUX   := $(B)/linux-$(LINUX_VER)
BUSYBOX := $(B)/busybox-$(BUSYBOX_VER)

QEMU ?= qemu-system-riscv64

.PHONY: all clean run-emu
all: linux.elf linux-smp4.elf

# The firmware, the kernel and a device tree in one ELF. NHARTS is how many
# harts the firmware serves; the device tree names the same.
ELF = $(LINUX_CROSS)gcc -march=rv64imac_zicsr_zifencei -mabi=lp64 -nostdlib -static \
	-DDTB_ADDR=$(DTB_ADDR) -Wl,--defsym=DTB_ADDR=$(DTB_ADDR) \
	-DDTB_FILE='"$(B)/$(2).dtb"' -DNHARTS=$(1) $(3) -T link.ld -o $@ fw.S image.S

# The VCU118: one hart at 20 MHz.
linux.elf: fw.S image.S link.ld $(B)/Image $(B)/heliodor.dtb
	$(call ELF,1,heliodor)

# Four harts at 10 MHz: the fp1.
linux-smp4.elf: fw.S image.S link.ld $(B)/Image $(B)/heliodor-smp4.dtb
	$(call ELF,4,heliodor-smp4)

# linux-smp4.elf's, on QEMU's `virt` machine with four harts: the console is its
# UART, and the exit status ends QEMU. Ctrl-A x leaves.
linux-qemu.elf: fw.S image.S link.ld $(B)/Image $(B)/heliodor-smp4.dtb
	$(call ELF,4,heliodor-smp4,-DQEMU)

run-emu: linux-qemu.elf
	$(QEMU) -machine virt -smp 4 -m 2G -nographic -bios none -kernel $<

$(B)/%.dtb: %.dts
	mkdir -p $(B)
	dtc -I dts -O dtb -o $@ $<

# ---- downloads, checked before they are used ----
$(B)/dl/%:
	mkdir -p $(@D)
	curl -sSfL -o $@.part $(URL)
	echo "$(SHA)  $@.part" | sha256sum -c --quiet
	mv $@.part $@
$(B)/dl/linux-$(LINUX_VER).tar.xz: URL := $(LINUX_URL)
$(B)/dl/linux-$(LINUX_VER).tar.xz: SHA := $(LINUX_SHA)
$(B)/dl/busybox-$(BUSYBOX_VER).tar.bz2: URL := $(BUSYBOX_URL)
$(B)/dl/busybox-$(BUSYBOX_VER).tar.bz2: SHA := $(BUSYBOX_SHA)

$(LINUX)/Makefile: $(B)/dl/linux-$(LINUX_VER).tar.xz
	tar xf $< -C $(B)
	touch $@
$(BUSYBOX)/Makefile: $(B)/dl/busybox-$(BUSYBOX_VER).tar.bz2
	tar xf $< -C $(B)
	touch $@

# ---- busybox ----
$(B)/busybox/busybox: $(BUSYBOX)/Makefile busybox.config
	mkdir -p $(B)/busybox
	$(MAKE) -C $(BUSYBOX) O=$(B)/busybox defconfig
	sed -n 's/^\(# \)\{0,1\}\(CONFIG_[A-Z0-9_]*\).*/\2/p' busybox.config | \
		while read c; do sed -i "/^\(# \)\{0,1\}$$c[= ]/d" $(B)/busybox/.config; done
	grep '^\(# \)\{0,1\}CONFIG_' busybox.config >> $(B)/busybox/.config
	yes "" | $(MAKE) -C $(B)/busybox oldconfig > /dev/null
	$(MAKE) -C $(B)/busybox CROSS_COMPILE=$(LINUX_CROSS) -j$(JOBS)

# ---- the initramfs: busybox and init, nothing else ----
$(B)/initramfs.list: $(B)/busybox/busybox init
	printf '%s\n' \
		'dir /dev 755 0 0' 'nod /dev/console 600 0 0 c 5 1' \
		'dir /bin 755 0 0' 'dir /sbin 755 0 0' 'dir /usr 755 0 0' \
		'dir /usr/bin 755 0 0' 'dir /usr/sbin 755 0 0' \
		'dir /proc 755 0 0' 'dir /sys 755 0 0' 'dir /tmp 1777 0 0' \
		'file /bin/busybox $(B)/busybox/busybox 755 0 0' \
		'slink /bin/sh busybox 777 0 0' \
		'file /init $(abspath init) 755 0 0' > $@

# ---- the kernel ----
$(B)/Image: $(LINUX)/Makefile kernel.config $(B)/initramfs.list
	mkdir -p $(B)/kbuild
	$(KMAKE) tinyconfig
	cd $(B)/kbuild && $(LINUX)/scripts/kconfig/merge_config.sh -m .config $(abspath kernel.config)
	$(LINUX)/scripts/config --file $(B)/kbuild/.config --set-str INITRAMFS_SOURCE $(B)/initramfs.list
	$(KMAKE) olddefconfig
	$(KMAKE) -j$(JOBS) Image
	cp $(B)/kbuild/arch/riscv/boot/Image $@

clean:
	rm -rf linux.elf linux-smp4.elf linux-qemu.elf $(B)/kbuild $(B)/busybox $(B)/Image $(B)/*.dtb $(B)/initramfs.list
