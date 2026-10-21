/* The kernel and the device tree, as they are put in memory. */
    .section .kernel, "a"
    .incbin "build/Image"
    .section .dtb, "a"
    .incbin "build/heliodor.dtb"
