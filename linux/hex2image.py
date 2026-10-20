"""Takes the kernel Image out of one of heliodor's DRAM images.

heliodor's test/hex/linux_dram_*.hex hold the kernel and then the device
tree, one little-endian 32-bit word per line. The Image header says how long
the kernel is (image_size, with its .bss).

The core starts at the kernel's first word, in M-mode. So the first 8 bytes
become a jump to the firmware, and the original 8 bytes go to <Image>.head
for the firmware to put back.

    python3 -I hex2image.py <linux_dram.hex> <Image> <kernel base> <firmware base>
"""

import struct
import sys

src, dst = sys.argv[1], sys.argv[2]
kernel, firmware = int(sys.argv[3], 0), int(sys.argv[4], 0)
data = bytearray()
with open(src) as f:
    for line in f:
        data += struct.pack("<I", int(line, 16))
if data[0x38:0x3C] != b"RSC\x05":
    sys.exit(f"{src}: no RISC-V Image header")
(image_size,) = struct.unpack_from("<Q", data, 16)
image = data[:image_size]

offset = firmware - kernel
if offset % 0x1000 or not 0 < offset < 1 << 31:
    sys.exit("the firmware must be 4 KB aligned, above the kernel and within 2 GB")
auipc_t0 = (offset & 0xFFFFF000) | (5 << 7) | 0x17  # auipc t0, offset >> 12
jalr_t0 = (5 << 15) | 0x67                           # jalr x0, 0(t0)
with open(dst + ".head", "wb") as f:
    f.write(image[:8])
struct.pack_into("<II", image, 0, auipc_t0, jalr_t0)
with open(dst, "wb") as f:
    f.write(image)
print(f"{dst}: {image_size} bytes")
