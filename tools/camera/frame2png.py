#!/usr/bin/env python3
"""A kern.sweet_cam_frame dump to PNG, no dependencies.

  ssh root@192.168.7.2 /var/root/camframe > frame.bin      # tools/camera/camframe.c, built as in its header
  python3 tools/camera/frame2png.py frame.bin out.png                 # C3: RAW8 Bayer 640x480 (the test pattern)
  python3 tools/camera/frame2png.py frame.bin out.png --raw10 --size 1920x1080 --black 64 --wb
                                                                       # C4: MIPI RAW10 from the IMX363 (mode 2)
Options: --raw (greyscale bytes, RAW8 only), --slot N (RAW8 dumps with several frames), --order RGGB|BGGR|GRBG|GBRG.
Colour: one RGB pixel per 2x2 Bayer cell (G = mean of the two greens). RAW8 is drawn 2x2 so the size stays; RAW10 is
written at half size, black level subtracted, scaled so the 99th percentile of green is white, gamma 2.2, and with --wb
grey-world white balance (red and blue means scaled to green's).
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


def unpack_raw10(data, w, h):
    """MIPI RAW10: 4 pixels in 5 bytes (4 high bytes, then the 4 low 2-bit pairs); lines w * 5 / 4 bytes"""
    stride = w * 5 // 4
    if len(data) < stride * h:
        raise SystemExit('dump too short for %dx%d RAW10 (%d < %d bytes)' % (w, h, len(data), stride * h))
    rows = []
    for y in range(h):
        r = data[y * stride:(y + 1) * stride]
        line = []
        for o in range(0, stride, 5):
            lo = r[o + 4]
            line += [(r[o] << 2) | (lo & 3), (r[o + 1] << 2) | ((lo >> 2) & 3), (r[o + 2] << 2) | ((lo >> 4) & 3),
                     (r[o + 3] << 2) | ((lo >> 6) & 3)]
        rows.append(line)
    return rows


def raw10_png(a, data, w, h):
    px = unpack_raw10(data, w, h)
    pos = {c: i for i, c in enumerate(a.order)}
    greens = [i for i, c in enumerate(a.order) if c == 'G']
    cells = []                                                  # (R, G, B) per 2x2 cell, black level off
    for y in range(0, h - 1, 2):
        r0, r1 = px[y], px[y + 1]
        line = []
        for x in range(0, w - 1, 2):
            cell = (r0[x], r0[x + 1], r1[x], r1[x + 1])
            cell = [max(0, v - a.black) for v in cell]
            line.append((cell[pos['R']], (cell[greens[0]] + cell[greens[1]]) / 2, cell[pos['B']]))
        cells.append(line)
    gains = [1.0, 1.0, 1.0]
    if a.wb:
        means = [sum(c[i] for line in cells for c in line) / (len(cells) * len(cells[0])) for i in range(3)]
        gains = [means[1] / means[0] if means[0] else 1.0, 1.0, means[1] / means[2] if means[2] else 1.0]
    gs = sorted(c[1] for line in cells[::4] for c in line[::4])
    white = max(1.0, gs[int(len(gs) * 0.99)])
    rows = []
    for line in cells:
        out = bytearray()
        for c in line:
            for i in range(3):
                v = min(1.0, c[i] * gains[i] / white)
                out.append(int(255 * v ** (1 / 2.2) + 0.5))
        rows.append(bytes(out))
    png(a.dst, len(cells[0]), len(cells), rows, True)
    print('RAW10 %dx%d: black %d, white (green p99) %.0f, gains R %.2f B %.2f -> %s (%dx%d)' % (
        w, h, a.black, white, gains[0], gains[2], a.dst, len(cells[0]), len(cells)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('src')
    ap.add_argument('dst')
    ap.add_argument('--raw', action='store_true')
    ap.add_argument('--raw10', action='store_true')
    ap.add_argument('--size', default=None)
    ap.add_argument('--slot', type=int, default=0)
    ap.add_argument('--black', type=int, default=64)
    ap.add_argument('--wb', action='store_true')
    ap.add_argument('--order', default='RGGB', choices=['RGGB', 'BGGR', 'GRBG', 'GBRG'])
    a = ap.parse_args()
    w, h = (int(v) for v in (a.size or ('1920x1080' if a.raw10 else '640x480')).split('x'))
    data = open(a.src, 'rb').read()
    if a.raw10:
        raw10_png(a, data, w, h)
        return
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
