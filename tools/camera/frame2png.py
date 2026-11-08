#!/usr/bin/env python3
"""A kern.sweet_cam_frame dump (RAW8 Bayer, 640x480 by default) to PNG, no dependencies.

  ssh root@192.168.7.2 /var/root/camframe > frame.bin      # tools/camera/camframe.c, built as in its header
  python3 tools/camera/frame2png.py frame.bin out.png [--raw] [--size 640x480] [--slot 0] [--order RGGB]

Colour: one RGB pixel per 2x2 Bayer cell (G = mean of the two greens), drawn 2x2 so the size stays. --raw writes the
bytes as greyscale instead.
"""
import argparse
import struct
import zlib


def png(path, w, h, rows, colour):
    def chunk(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    raw = b''.join(b'\x00' + r for r in rows)
    ihdr = struct.pack('>IIBBBBB', w, h, 8, 2 if colour else 0, 0, 0, 0)
    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr) + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b''))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('src')
    ap.add_argument('dst')
    ap.add_argument('--raw', action='store_true')
    ap.add_argument('--size', default='640x480')
    ap.add_argument('--slot', type=int, default=0)
    ap.add_argument('--order', default='RGGB', choices=['RGGB', 'BGGR', 'GRBG', 'GBRG'])
    a = ap.parse_args()
    w, h = (int(v) for v in a.size.split('x'))
    data = open(a.src, 'rb').read()
    f = data[a.slot * w * h:(a.slot + 1) * w * h]
    if len(f) < w * h:
        raise SystemExit('dump too short for slot %d of %dx%d' % (a.slot, w, h))
    if a.raw:
        png(a.dst, w, h, [f[y * w:(y + 1) * w] for y in range(h)], False)
        return
    pos = {c: i for i, c in enumerate(a.order)}             # index in the 2x2 cell: 0 TL, 1 TR, 2 BL, 3 BR
    greens = [i for i, c in enumerate(a.order) if c == 'G']
    rows = []
    for y in range(0, h - 1, 2):
        r0, r1 = f[y * w:(y + 1) * w], f[(y + 1) * w:(y + 2) * w]
        line = bytearray()
        for x in range(0, w - 1, 2):
            cell = (r0[x], r0[x + 1], r1[x], r1[x + 1])
            line += bytes((cell[pos['R']], (cell[greens[0]] + cell[greens[1]]) // 2, cell[pos['B']])) * 2
        rows += [bytes(line), bytes(line)]
    png(a.dst, w - w % 2, h - h % 2, rows, True)


if __name__ == '__main__':
    main()
