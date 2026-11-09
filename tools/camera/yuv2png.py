#!/usr/bin/env python3
"""An output of sweetcam's rotation self-test (tools/camera/rottest.c) to PNG, no dependencies.

  ssh root@192.168.7.2 'cat /var/root/rot.out.0' > rot0.bin
  python3 tools/camera/yuv2png.py rot0.bin rot0.png [--half]

The file: width and height (two little-endian 32-bit numbers), the Y plane, the interleaved CbCr plane at half size
(8-bit 4:2:0, full range, BT.601). --half writes every second pixel.
"""
import struct
import sys
import zlib


def main():
    src, dst = sys.argv[1], sys.argv[2]
    step = 2 if '--half' in sys.argv else 1
    d = open(src, 'rb').read()
    w, h = struct.unpack_from('<II', d, 0)
    y = d[8:8 + w * h]
    c = d[8 + w * h:]
    rows = []
    for r in range(0, h, step):
        out = bytearray()
        co = (r // 2) * w
        for x in range(0, w, step):
            yy = y[r * w + x]
            cb = c[co + (x & ~1)] - 128
            cr = c[co + (x & ~1) + 1] - 128
            for v in (yy + 1.402 * cr, yy - 0.344 * cb - 0.714 * cr, yy + 1.772 * cb):
                out.append(0 if v < 0 else 255 if v > 255 else int(v + 0.5))
        rows.append(bytes(out))

    def chunk(t, b):
        return struct.pack('>I', len(b)) + t + b + struct.pack('>I', zlib.crc32(t + b) & 0xffffffff)
    raw = b''.join(b'\x00' + r for r in rows)
    with open(dst, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', len(rows[0]) // 3, len(rows), 8, 2, 0, 0, 0)) +
                chunk(b'IDAT', zlib.compress(raw, 6)) + chunk(b'IEND', b''))
    print('%dx%d -> %s' % (w, h, dst))


if __name__ == '__main__':
    main()
