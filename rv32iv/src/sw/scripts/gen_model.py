#!/usr/bin/env python3
"""gen_model.py -- weights, test images and bit-exact golden results of the MNIST MLP (784 -> 128 ReLU -> 10).

Writes into --work:
  model_cfg.h       layout offsets, requantisation shifts, image count (included by the firmware sources)
  dmem_static.bin   [W1 | b1 | W2 | b2] padded to the image offset (DMEM image, starts at DMEM_BASE)
  images.bin        NIMG x 784 INT8 pixels
  golden_exp.hex    expected results, 11 words per image: label, logit[0..9] (two's complement hex words)
and into --prog-dir:
  mnist.layout      key=value layout (IMG_ADDR, LOGIT_ADDR, ...)       (the firmware ".layout" file of the spec)
  mnist.plusargs    the plusargs of TC-056/TC-057 for these files

Network arithmetic (spec section 9, REQ-FUNC-006/007/008):
  layer 1: acc = sum(x*w) + b1 (INT32), ReLU, vnclip 32->16 by SHIFT1, vnclip 16->8 by SHIFT2 (round-to-nearest-up,
           saturating), stored as INT8
  layer 2: logit = sum(y*w) + b2 (INT32), label = first maximum (strict >).

Data: no trained weights are delivered with the project, so by default a deterministic synthetic network and
synthetic digit-like images are generated (fixed seed). A real export can be used with --model <file.npz> holding
w1 (128,784) int8, b1 (128) int32, w2 (10,128) int8, b2 (10) int32, images (N,784) int8 and optionally
shift1, shift2 (numpy is needed for that option only).
"""
import argparse
import os
import random
import struct
import sys
from operator import mul

N_IN, N_HID, N_OUT = 784, 128, 10
OFF_SPK_IMGS = 0x20000          # image array of the Spike model build (relative to its DMEM base)
DMEM_BASE = 0x10000000


def align16(v):
    return (v + 15) & ~15


def clip(v, lo, hi):
    return lo if v < lo else (hi if v > hi else v)


def s32(v):
    v &= 0xFFFFFFFF
    return v - (1 << 32) if v & 0x80000000 else v


def rnu_shift(v, s):
    """arithmetic shift right with round-to-nearest-up (vxrm = 0)"""
    if s == 0:
        return v
    return (v >> s) + ((v >> (s - 1)) & 1)


def nclip(v, s, bits):
    return clip(rnu_shift(v, s), -(1 << (bits - 1)), (1 << (bits - 1)) - 1)


def make_image(rng):
    """synthetic digit-like image: strokes of intensity 255/160 on a 0 background, INT8 = pixel - 128"""
    px = [0] * (N_IN)
    for _ in range(rng.randint(2, 4)):
        x0, y0 = rng.uniform(5, 22), rng.uniform(5, 22)
        x1, y1 = rng.uniform(5, 22), rng.uniform(5, 22)
        n = 40
        for k in range(n + 1):
            t = k / n
            cx = int(round(x0 + (x1 - x0) * t))
            cy = int(round(y0 + (y1 - y0) * t))
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    xx, yy = cx + dx, cy + dy
                    if 0 <= xx < 28 and 0 <= yy < 28:
                        v = 255 if (dx == 0 and dy == 0) else 160
                        if px[yy * 28 + xx] < v:
                            px[yy * 28 + xx] = v
    for _ in range(rng.randint(0, 6)):
        px[rng.randrange(N_IN)] = rng.randint(30, 255)
    return [p - 128 for p in px]


def synthetic(nimg, seed):
    rng = random.Random(seed)

    def wgen():
        if rng.random() < 1.0 / 64:
            return -128
        return clip(int(round(rng.gauss(0, 24))), -128, 127)

    w1 = [[wgen() for _ in range(N_IN)] for _ in range(N_HID)]
    b1 = [int(rng.gauss(0, 3000)) for _ in range(N_HID)]
    w2 = [[wgen() for _ in range(N_HID)] for _ in range(N_OUT)]
    b2 = [int(rng.gauss(0, 500)) for _ in range(N_OUT)]
    imgs = [make_image(rng) for _ in range(nimg)]
    if nimg >= 2:
        imgs[nimg - 2] = [-128] * N_IN          # extreme inputs: -128 x -128 products
        imgs[nimg - 1] = [127] * N_IN
    return w1, b1, w2, b2, imgs, None, None


def from_npz(path):
    import numpy as np
    d = np.load(path)
    w1 = [[int(v) for v in row] for row in d["w1"]]
    b1 = [int(v) for v in d["b1"]]
    w2 = [[int(v) for v in row] for row in d["w2"]]
    b2 = [int(v) for v in d["b2"]]
    imgs = [[int(v) for v in row] for row in d["images"]]
    s1 = int(d["shift1"]) if "shift1" in d.files else None
    s2 = int(d["shift2"]) if "shift2" in d.files else None
    return w1, b1, w2, b2, imgs, s1, s2


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--work", required=True)
    ap.add_argument("--prog-dir", required=True)
    ap.add_argument("--nimg", type=int, default=100)
    ap.add_argument("--seed", type=int, default=20240607)
    ap.add_argument("--model", default="")
    a = ap.parse_args()

    if a.model:
        w1, b1, w2, b2, imgs, s1, s2 = from_npz(a.model)
    else:
        w1, b1, w2, b2, imgs, s1, s2 = synthetic(a.nimg, a.seed)
    nimg = len(imgs)
    assert nimg <= 100 and all(len(i) == N_IN for i in imgs), "at most 100 images of 784 pixels (TC-056 buffer)"

    # ---- layer 1 (INT32 accumulators); pick the requantisation shifts from the data when not given
    pre = []
    for x in imgs:
        pre.append([s32(sum(map(mul, w1[j], x)) + b1[j]) for j in range(N_HID)])
    if s1 is None or s2 is None:
        vals = sorted(max(v, 0) for row in pre for v in row)
        p95 = vals[int(0.95 * (len(vals) - 1))]
        t = 0
        while (p95 >> t) > 100 and t < 18:
            t += 1
        t = max(t, 2)
        s2 = min(t, 3)
        s1 = t - s2
    assert 0 <= s1 <= 31 and 0 <= s2 <= 15

    exp = []
    for i in range(nimg):
        y = [nclip(nclip(max(v, 0), s1, 16), s2, 8) for v in pre[i]]
        logits = [s32(sum(map(mul, w2[j], y)) + b2[j]) for j in range(N_OUT)]
        best = 0
        for j in range(1, N_OUT):
            if logits[j] > logits[best]:
                best = j
        exp.append([best] + logits)

    # ---- layout
    off_w1 = 0
    off_b1 = off_w1 + N_HID * N_IN
    off_w2 = off_b1 + N_HID * 4
    off_b2 = off_w2 + N_OUT * N_HID
    off_img = align16(off_b2 + N_OUT * 4)
    off_act1 = off_img + align16(N_IN)
    off_logit = off_act1 + N_HID
    assert off_w1 % 16 == 0 and off_b1 % 16 == 0 and off_w2 % 16 == 0 and off_b2 % 16 == 0
    assert off_logit % 4 == 0 and off_logit + 48 < 0x40000 - 64

    static = bytearray()
    for row in w1:
        static += bytes(v & 0xFF for v in row)
    static += struct.pack("<%di" % N_HID, *b1)
    for row in w2:
        static += bytes(v & 0xFF for v in row)
    static += struct.pack("<%di" % N_OUT, *b2)
    static += bytes(off_img - len(static))
    assert len(static) == off_img

    os.makedirs(a.work, exist_ok=True)
    os.makedirs(a.prog_dir, exist_ok=True)
    with open(os.path.join(a.work, "model_cfg.h"), "w") as f:
        f.write("/* generated by gen_model.py */\n#ifndef MODEL_CFG_H\n#define MODEL_CFG_H\n")
        for k, v in (("N_IN", N_IN), ("N_HID", N_HID), ("N_OUT", N_OUT), ("NIMG", nimg),
                     ("SHIFT1", s1), ("SHIFT2", s2)):
            f.write("#define %s %d\n" % (k, v))
        for k, v in (("OFF_W1", off_w1), ("OFF_B1", off_b1), ("OFF_W2", off_w2), ("OFF_B2", off_b2),
                     ("OFF_IMG", off_img), ("OFF_ACT1", off_act1), ("OFF_LOGIT", off_logit),
                     ("OFF_SPK_IMGS", OFF_SPK_IMGS)):
            f.write("#define %s 0x%X\n" % (k, v))
        f.write("#endif\n")
    with open(os.path.join(a.work, "dmem_static.bin"), "wb") as f:
        f.write(static)
    with open(os.path.join(a.work, "images.bin"), "wb") as f:
        for x in imgs:
            f.write(bytes(v & 0xFF for v in x))
    with open(os.path.join(a.work, "golden_exp.hex"), "w") as f:
        for e in exp:
            for v in e:
                f.write("%08x\n" % (v & 0xFFFFFFFF))

    prog = os.path.abspath(a.prog_dir)
    img_addr = DMEM_BASE + off_img
    log_addr = DMEM_BASE + off_logit
    with open(os.path.join(prog, "mnist.layout"), "w") as f:
        f.write("# MNIST firmware data layout (byte offsets from DMEM_BASE = 0x10000000)\n")
        for k, v in (("W1", off_w1), ("B1", off_b1), ("W2", off_w2), ("B2", off_b2), ("IMG", off_img),
                     ("ACT1", off_act1), ("LOGIT", off_logit)):
            f.write("OFF_%s=%08x\n" % (k, v))
        f.write("IMG_ADDR=%08x\nLOGIT_ADDR=%08x\n" % (img_addr, log_addr))
        f.write("SHIFT1=%d\nSHIFT2=%d\nNIMG=%d\nBAUD=1736\n" % (s1, s2, nimg))
        f.write("DMEM_WORDS=%d\n" % (off_img // 4))
    with open(os.path.join(prog, "mnist.plusargs"), "w") as f:
        f.write("+FW_HEX=%s +DMEM_HEX=%s +IMG_HEX=%s +EXP_HEX=%s +IMG_ADDR=%08x +LOGIT_ADDR=%08x "
                "+DMEM_WORDS=%d +NIMG=%d +BAUD=1736\n" % (
                    os.path.join(prog, "mnist_fw.hex"), os.path.join(prog, "mnist_dmem.hex"),
                    os.path.join(prog, "mnist_img.hex"), os.path.join(prog, "mnist_exp.hex"),
                    img_addr, log_addr, off_img // 4, nimg))

    print("gen_model: %d images, shift1=%d shift2=%d, labels %s" % (
        nimg, s1, s2, sorted(set(e[0] for e in exp))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
