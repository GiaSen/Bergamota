#!/usr/bin/env python3
"""Decode a Linux msm SLIMbus NGD debug log (dynamic debug on slim-msm-ngd.c: "BAM TX buf[i]:0x..." lines) into the
messages it sent: codec register writes and reads (CHANGE_VALUE 0x68 / REQUEST_VALUE 0x60, PGD paging through
offset 0 at 0x800) and user messages to the manager (CONNECT_SINK 0x2d, DEF_ACT_CHAN 0x21, RECONFIG_NOW 0x24, ...).
  slimlog.py DMESG.txt [--reads]
"""
import re
import sys

USR = {0x2c: 'CONNECT_SRC', 0x2d: 'CONNECT_SINK', 0x2e: 'DISCONNECT_PORT', 0x21: 'DEF_ACT_CHAN', 0x23: 'REMOVE_CHAN',
       0x24: 'RECONFIG_NOW', 0x01: 'MASTER_CAPABILITY'}


def main():
    path = sys.argv[1]
    reads = '--reads' in sys.argv
    msgs, cur = [], None
    for line in open(path, errors='replace'):
        m = re.search(r'\[\s*([\d.]+)\].*BAM TX buf\[(\d+)\]:0x([0-9a-f]+)', line)
        if not m:
            continue
        t, i, w = m.group(1), int(m.group(2)), int(m.group(3), 16)
        if i == 0:
            cur = [t, [w]]
            msgs.append(cur)
        elif cur:
            cur[1].append(w)
    page = {}
    for t, ws in msgs:
        b = b''.join(x.to_bytes(4, 'little') for x in ws)
        rl, mt, mc, la = b[0] & 0x1f, b[0] >> 5, b[1], b[2]
        b = b[:rl]
        if mt == 0 and mc == 0x68:                  # CHANGE_VALUE: la, ec (2), data
            ec = b[3] | b[4] << 8
            off = (ec >> 4) & 0xfff
            data = b[5:]
            if off >= 0x800:
                o = off - 0x800
                if o == 0:
                    page[la] = data[0]
                    continue
                print('%s W la %02x  %04x = %s' % (t, la, (page.get(la, 0) << 8) | o, data.hex(' ')))
            else:
                print('%s W la %02x  if %03x = %s' % (t, la, off, data.hex(' ')))
        elif mt == 0 and mc == 0x60:                # REQUEST_VALUE: la, tid, ec (2)
            if reads:
                ec = b[4] | b[5] << 8
                off = (ec >> 4) & 0xfff
                o = off - 0x800 if off >= 0x800 else off
                print('%s R la %02x  %s%04x' % (t, la, '' if off >= 0x800 else 'if ', ((page.get(la, 0) << 8) | o)
                                                 if off >= 0x800 else off))
        elif mt == 0:
            continue
        else:
            print('%s MSG mt %d %s (0x%02x) %s' % (t, mt, USR.get(mc, '?'), mc, b[3:].hex(' ')))


if __name__ == '__main__':
    main()
