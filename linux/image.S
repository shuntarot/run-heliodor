/* The kernel and the device tree, as they are put in memory. */
    .section .kernel, "a"
    .incbin "Image"
    .section .dtb, "a"
    .incbin "heliodor.dtb"
