/*
 * mnist_fw.S -- MNIST MLP (784 -> 128 ReLU -> 10) firmware for m_soc_top (RV32I + Zmmul + Zve32x subset).
 *
 * Only instructions of the supported subset are used (no CSR instructions in the DUT build):
 *   scalar RV32I + mul-free code, vsetvli/vsetivli, vle8, vwmul.vv, vwredsum.vs, vadd.vx, vmax.vx,
 *   vnclip.wi, vmv.s.x, vmv.x.s.
 *
 * Two builds from this one source:
 *   - DUT build   : IMEM at 0x0000_0000, DMEM 0x1000_0000, MMIO 0x2000_0000 (spec section 3 / ASM-014).
 *   - SPIKE_MODEL : runs the same network (subroutine `infer`) over NIMG images on Spike (standard RVV) and
 *                   leaves label + 10 logits per image in the signature area. vwredsum.vs of the DUT reads 16-bit
 *                   source elements of a register pair at SEW = 8 (REQ-FUNC-019); Spike implements the standard
 *                   semantic (SEW-wide source), so the model build does the same reduction as two standard
 *                   SEW = 16 reductions (v2 = products 0..7, v3 = products 8..15). The result is identical.
 *
 * Data layout (see model_cfg.h, generated):  [W1 | b1 | W2 | b2 | image | act1 | logits]
 * Memory sequence (spec 11.2): clear sts.err, wait ctrl.start, clear it, busy=1, infer, result.label, done=1,
 * UART '0'+label, then spin.
 */
#include "model_cfg.h"

#ifdef SPIKE_MODEL
# define DMEM_BASE 0x80100000
# define MMIO_BASE 0x80200000
#else
# define DMEM_BASE 0x10000000
# define MMIO_BASE 0x20000000
#endif

#define CSR_CTRL    0x00
#define CSR_STS     0x04
#define CSR_RESULT  0x08
#define CSR_CYCLES  0x0C
#define CSR_UART_TX 0x10

    .section .text.init, "ax", @progbits
    .globl _start
_start:
#ifdef SPIKE_MODEL
    /* ---------------- Spike model: loop over NIMG images, no MMIO ---------------- */
    li   t0, 0x600
    csrs mstatus, t0                     /* vector unit on (Spike only) */
    li   s0, DMEM_BASE + OFF_SPK_IMGS    /* image pointer */
    la   s2, begin_signature             /* signature pointer: label, logits[10] (11 words per image) */
    li   s1, NIMG
spk_loop:
    addi s11, s2, 4
    jal  ra, infer
    sw   a0, 0(s2)
    addi s0, s0, N_IN
    addi s2, s2, 44
    addi s1, s1, -1
    bnez s1, spk_loop
    la   t0, tohost
    li   t1, 1
    sw   t1, 0(t0)
spk_end:
    j    spk_end
#else
    /* ---------------- DUT build ---------------- */
    li   sp, DMEM_BASE + 0x40000 - 16
    li   s10, MMIO_BASE
    li   t0, 4
    sw   t0, CSR_STS(s10)                /* clear sts.err (write 1) */
wait_start:
    lw   t0, CSR_CTRL(s10)
    andi t0, t0, 1
    beqz t0, wait_start                  /* wait for ctrl.start (set by i_start_req) */
    sw   zero, CSR_CTRL(s10)             /* ctrl.start = 0 */
    li   t0, 1
    sw   t0, CSR_STS(s10)                /* sts.busy = 1, sts.done = 0 */
    li   s0, DMEM_BASE + OFF_IMG
    li   s11, DMEM_BASE + OFF_LOGIT
    jal  ra, infer
    sw   a0, CSR_RESULT(s10)             /* result.label */
    li   t0, 2
    sw   t0, CSR_STS(s10)                /* sts.done = 1, sts.busy = 0 */
    addi a0, a0, 48                      /* '0' + label */
uart_wait:
    lw   t0, CSR_UART_TX(s10)
    li   t1, 0x200
    and  t0, t0, t1                      /* uart_tx.busy (bit 9) */
    bnez t0, uart_wait
    sw   a0, CSR_UART_TX(s10)            /* uart_tx.data */
    li   t1, 0x100
    or   a0, a0, t1
    sw   a0, CSR_UART_TX(s10)            /* uart_tx.send = 1 */
fw_end:
    j    fw_end
#endif

/*
 * infer: in  s0 = image pointer (784 INT8), s11 = logits pointer (10 INT32)
 *        out a0 = predicted label (argmax, first maximum wins)
 * clobbers t0-t6, a1-a6, v0-v12; no stack use.
 */
    .globl infer
infer:
    li   t6, 16                          /* AVL for e8 (VLMAX = 16 at VLEN = 128) */

    /* ---------------- layer 1: 128 neurons x 49 row steps ---------------- */
    li   a1, DMEM_BASE + OFF_W1          /* weight row pointer (advances through all of W1) */
    li   a2, DMEM_BASE + OFF_B1          /* bias pointer */
    li   a3, DMEM_BASE + OFF_ACT1        /* activation output pointer */
    li   a4, N_HID
l1_neuron:
    vsetivli x0, 1, e32, m1, tu, mu
    vmv.s.x  v8, zero                    /* accumulator = 0 */
    vsetvli  x0, t6, e8, m1, tu, mu
    mv   a5, s0
    li   a6, N_IN / 16
l1_dot:
    vle8.v   v0, (a5)
    vle8.v   v1, (a1)
    vwmul.vv v2, v0, v1                  /* 16 x INT16 products in v2/v3 */
#ifdef SPIKE_MODEL
    vsetivli x0, 8, e16, m1, tu, mu
    vwredsum.vs v8, v2, v8
    vwredsum.vs v8, v3, v8
    vsetvli  x0, t6, e8, m1, tu, mu
#else
    vwredsum.vs v8, v2, v8               /* v8[0] (INT32) += sum of the 16 products */
#endif
    addi a5, a5, 16
    addi a1, a1, 16
    addi a6, a6, -1
    bnez a6, l1_dot
    lw   t0, 0(a2)                       /* bias */
    addi a2, a2, 4
    vsetivli x0, 1, e32, m1, tu, mu
    vadd.vx  v8, v8, t0                  /* + bias */
    vmax.vx  v8, v8, zero                /* ReLU */
    vsetivli x0, 1, e16, m1, tu, mu
    vnclip.wi v10, v8, SHIFT1            /* 32 -> 16, saturate */
    vsetivli x0, 1, e8, m1, tu, mu
    vnclip.wi v12, v10, SHIFT2           /* 16 -> 8, saturate */
    vmv.x.s  t0, v12
    sb   t0, 0(a3)
    addi a3, a3, 1
    addi a4, a4, -1
    bnez a4, l1_neuron

    /* ---------------- layer 2: 10 neurons x 8 row steps, INT32 logits ---------------- */
    li   a1, DMEM_BASE + OFF_W2
    li   a2, DMEM_BASE + OFF_B2
    mv   a3, s11
    li   a4, N_OUT
l2_neuron:
    vsetivli x0, 1, e32, m1, tu, mu
    vmv.s.x  v8, zero
    vsetvli  x0, t6, e8, m1, tu, mu
    li   a5, DMEM_BASE + OFF_ACT1
    li   a6, N_HID / 16
l2_dot:
    vle8.v   v0, (a5)
    vle8.v   v1, (a1)
    vwmul.vv v2, v0, v1
#ifdef SPIKE_MODEL
    vsetivli x0, 8, e16, m1, tu, mu
    vwredsum.vs v8, v2, v8
    vwredsum.vs v8, v3, v8
    vsetvli  x0, t6, e8, m1, tu, mu
#else
    vwredsum.vs v8, v2, v8
#endif
    addi a5, a5, 16
    addi a1, a1, 16
    addi a6, a6, -1
    bnez a6, l2_dot
    lw   t0, 0(a2)
    addi a2, a2, 4
    vsetivli x0, 1, e32, m1, tu, mu
    vadd.vx  v8, v8, t0                  /* + bias */
    vmv.x.s  t0, v8
    sw   t0, 0(a3)
    addi a3, a3, 4
    addi a4, a4, -1
    bnez a4, l2_neuron

    /* ---------------- argmax over the 10 logits (signed, first maximum) ---------------- */
    lw   t1, 0(s11)                      /* current maximum */
    li   a0, 0                           /* its index */
    li   t2, 1
    li   t5, N_OUT
am_loop:
    slli t3, t2, 2
    add  t3, t3, s11
    lw   t4, 0(t3)
    bge  t1, t4, am_skip
    mv   t1, t4
    mv   a0, t2
am_skip:
    addi t2, t2, 1
    bne  t2, t5, am_loop
    ret

#ifdef SPIKE_MODEL
    .section .tohost, "aw", @progbits
    .align 6
    .globl tohost
tohost:   .dword 0
    .globl fromhost
fromhost: .dword 0
#endif
