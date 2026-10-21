# make -C linux    builds linux.elf: Linux with busybox on heliodor, console
#                  on RTT
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

.PHONY: all clean
all: linux.elf

linux.elf: fw.S image.S link.ld $(B)/Image $(B)/heliodor.dtb
	$(LINUX_CROSS)gcc -march=rv64imac_zicsr_zifencei -mabi=lp64 -nostdlib -static \
		-DDTB_ADDR=$(DTB_ADDR) -Wl,--defsym=DTB_ADDR=$(DTB_ADDR) \
		-T link.ld -o $@ fw.S image.S

$(B)/heliodor.dtb: heliodor.dts
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
	rm -rf linux.elf $(B)/kbuild $(B)/busybox $(B)/Image $(B)/heliodor.dtb $(B)/initramfs.list
