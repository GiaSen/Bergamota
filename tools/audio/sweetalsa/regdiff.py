#!/usr/bin/env python3
"""Compare two WCD9340 register dumps ("ADDR: VAL" hex lines, as ASoC's codec_reg, wcd9xxx_core/slimslave_reg_dump
and sweetreg print them; sweetreg's "0x0b41 = 05" lines are read too).

  regdiff.py A.txt B.txt [--only LO-HI ...]   registers present in both whose values differ, then those only in one
"""
import re
import sys

LINE = re.compile(r'^\s*(?:if\s+)?(?:0x)?([0-9a-fA-F]+)\s*(?:\(written\)\s*)?[:=]\s*([0-9a-fA-F]+)')


def load(path):
    regs = {}
    for line in open(path, errors='replace'):
        m = LINE.match(line)
        if m:
            regs[int(m.group(1), 16)] = int(m.group(2), 16)
    return regs


def main():
    args = sys.argv[1:]
    ranges = []
    while '--only' in args:
        i = args.index('--only')
        lo, hi = args[i + 1].split('-')
        ranges.append((int(lo, 16), int(hi, 16)))
        del args[i:i + 2]
    if len(args) != 2:
        sys.exit(__doc__)
    a, b = load(args[0]), load(args[1])

    def keep(r):
        return not ranges or any(lo <= r <= hi for lo, hi in ranges)
    both = sorted(r for r in a if r in b and keep(r))
    diff = [r for r in both if a[r] != b[r]]
    print('%d registers in both, %d differ (%s vs %s)' % (len(both), len(diff), args[0], args[1]))
    for r in diff:
        print('  %04x: %02x  %02x' % (r, a[r], b[r]))
    only_a = [r for r in sorted(a) if r not in b and keep(r)]
    only_b = [r for r in sorted(b) if r not in a and keep(r)]
    print('only in A: %d, only in B: %d' % (len(only_a), len(only_b)))


if __name__ == '__main__':
    main()
