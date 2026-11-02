#!/usr/bin/env python3
"""bin2hex.py <in.bin> <out.hex> [max_words] -- little-endian 32-bit words, one 8-digit hex word per line
(the format $readmemh of the testbench expects). The input is zero-padded to a whole word."""
import struct
import sys


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: bin2hex.py in.bin out.hex [max_words]")
    data = open(sys.argv[1], "rb").read()
    data += bytes((-len(data)) % 4)
    words = struct.unpack("<%dI" % (len(data) // 4), data)
    if len(sys.argv) > 3 and len(words) > int(sys.argv[3]):
        sys.exit("bin2hex: %s has %d words, limit %s" % (sys.argv[1], len(words), sys.argv[3]))
    with open(sys.argv[2], "w") as f:
        for w in words:
            f.write("%08x\n" % w)


if __name__ == "__main__":
    main()
