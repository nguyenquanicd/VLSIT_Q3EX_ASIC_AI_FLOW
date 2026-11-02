#!/usr/bin/env python3
"""check_spike.py <spike.sig> <golden_exp.hex> <out_exp.hex>
Compares the Spike signature dump (word per line: label, logit[0..9] per image) with the Python golden model and
writes the expected-result file of the testbench (the Spike result, bit-identical to the golden one)."""
import sys


def words(path):
    out = []
    for line in open(path):
        line = line.strip()
        if line and not line.startswith("#"):
            out.append(int(line, 16) & 0xFFFFFFFF)
    return out


def main():
    if len(sys.argv) != 4:
        sys.exit("usage: check_spike.py spike.sig golden_exp.hex out_exp.hex")
    sig = words(sys.argv[1])
    gold = words(sys.argv[2])
    if len(sig) != len(gold):
        sys.exit("check_spike: signature has %d words, golden model %d" % (len(sig), len(gold)))
    bad = [i for i in range(len(gold)) if sig[i] != gold[i]]
    if bad:
        i = bad[0]
        sys.exit("check_spike: %d words differ from the golden model; first: image %d word %d spike=%08x golden=%08x"
                 % (len(bad), i // 11, i % 11, sig[i], gold[i]))
    with open(sys.argv[3], "w") as f:
        for w in sig:
            f.write("%08x\n" % w)
    print("check_spike: Spike and golden model agree on %d images" % (len(gold) // 11))


if __name__ == "__main__":
    main()
