# Builds riscv-tests' isa tests for this board, into build/isa.
#
# The tests are riscv-tests' own; only the link (link.ld) and one mapping of
# the v environment (vm.c.patch) change, so the host can read tohost while the
# core runs. RISCV_TESTS is a riscv-tests checkout with its env submodule.

-include ../local.mk
CROSS       ?= riscv64-unknown-elf-
RISCV_TESTS ?= ../../riscv-tests

all: build/isa/.done

build/isa/.done: link.ld vm.c.patch
	rm -rf build
	mkdir -p build/src build/isa
	cp -r $(RISCV_TESTS)/env $(RISCV_TESTS)/isa build/src/
	cp link.ld build/src/env/p/link.ld
	cp link.ld build/src/env/v/link.ld
	patch -d build/src/env -p1 < vm.c.patch
	$(MAKE) -C build/isa -f ../src/isa/Makefile src_dir=../src/isa XLEN=64 RISCV_PREFIX=$(CROSS)
	touch $@

clean:
	rm -rf build

.PHONY: all clean
