#!/usr/bin/env python3
"""Raw PCM for the Mi 8's speaker tests: 48 kHz, 16-bit little-endian, stereo interleaved (what the ASM stream is
opened with), a sine with 30 ms fades so it starts and stops without a click.

  mkpcm.py OUT --freq 440 --seconds 2 --dbfs -30         one tone
  mkpcm.py OUT --freq 440 --freq 660 --seconds 1 ...     tones one after another, --seconds each

The window the DSP reads (kern.sweet_audio_pool) is 2 MiB: at most 10.9 s.
"""
import argparse
import math
import struct

RATE = 48000


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('out')
    ap.add_argument('--freq', type=float, action='append', required=True)
    ap.add_argument('--seconds', type=float, default=2.0)
    ap.add_argument('--dbfs', type=float, default=-30.0, help='peak level (0 = full scale)')
    a = ap.parse_args()
    amp = 32767 * 10 ** (a.dbfs / 20)
    n = int(RATE * a.seconds)
    fade = int(RATE * 0.03)
    out = bytearray()
    for f in a.freq:
        for i in range(n):
            g = min(1.0, i / fade, (n - 1 - i) / fade)
            v = int(round(amp * g * math.sin(2 * math.pi * f * i / RATE)))
            out += struct.pack('<hh', v, v)
    assert len(out) <= 0x200000, f'{len(out)} bytes: more than the 2 MiB window'
    open(a.out, 'wb').write(out)
    print(f'{a.out}: {len(out)} bytes, {len(out) / 4 / RATE:.2f} s, peak {a.dbfs} dBFS ({int(amp)})')


if __name__ == '__main__':
    main()
