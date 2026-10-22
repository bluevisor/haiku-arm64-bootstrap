#!/usr/bin/env python3
"""ppm2png.py IN.ppm [OUT.png]: convert a P6 pixmap (from tools/haiku-grab.cpp) to PNG, stdlib only."""
import struct
import sys
import zlib

src = sys.argv[1]
dst = sys.argv[2] if len(sys.argv) > 2 else src.rsplit(".", 1)[0] + ".png"
data = open(src, "rb").read()
magic, dims, _maxval, pixels = data.split(b"\n", 3)
assert magic == b"P6"
w, h = map(int, dims.split())
raw = b"".join(b"\x00" + pixels[y * w * 3:(y + 1) * w * 3] for y in range(h))


def chunk(kind, body):
    return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)


png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))
open(dst, "wb").write(png)
print(f"{dst}: {w}x{h}")
