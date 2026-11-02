/*
 * spike_data.S -- data image of the Spike model build (not used by the DUT build).
 *   .dmem : static weights/biases (same bytes as the DMEM image), padding, then NIMG test images
 *   .sig  : signature area, 11 words per image: label, logit[0..9]  (expected-result format of the testbench)
 */
#include "model_cfg.h"

    .section .dmem, "aw", @progbits
    .balign 16
    .incbin "dmem_static.bin"
    .skip   OFF_SPK_IMGS - OFF_IMG
    .incbin "images.bin"

    .section .sig, "aw", @progbits
    .balign 16
    .globl begin_signature
begin_signature:
    .skip   44 * NIMG
    .globl end_signature
end_signature:
    .balign 16
