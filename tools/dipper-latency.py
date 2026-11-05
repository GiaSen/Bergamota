#!/usr/bin/env python3
"""Finger-to-screen latency on the Mi 8, from the kernel's own clocks (xnu 3053).

  tools/dipper-latency.py drag [N]     N synthetic drags (kern.sweet_touch_drag) on whatever is on screen, each after a
                                       quiet second; the list or page under the finger must scroll
  tools/dipper-latency.py watch [SEC]  wait SEC seconds (default 20) while someone uses the phone, then measure every touch
                                       that started on a still screen

kern.sweet_touch_trace lists the touch events as SweetHIDTouch hands them to backboardd (absolute us); kern.sweet_fb_trace
lists the last 128 swaps (backboardd's frame handed over) and scans (copied to the panel memory, which the panel shows at
its next refresh, up to 16.7 ms later), relative to base_us. A touch that comes after at least QUIET ms without a swap
gets the first swap after it as its answer: from the touch-down, and from the first move (a scroll view starts moving
only once the finger has moved). Not counted: the touch IC's own scan and the driver's poll before the event (a few ms),
and the panel's scan-out after the copy. Read-only on the phone.
"""
import re
import statistics
import subprocess
import sys
import time

SSH = ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', 'root@192.168.7.2']
QUIET_MS = 300


def phone(cmd):
    return subprocess.run(SSH + [cmd], capture_output=True, text=True).stdout


def traces():
    out = phone('/var/root/sweetsys kern.sweet_fb_trace; echo @@; /var/root/sweetsys kern.sweet_touch_trace')
    fb, _, tt = out.partition('@@')
    m = re.search(r'base_us=(\d+)', fb)
    if not m:
        sys.exit('no base_us in kern.sweet_fb_trace: the kernel needs patch 3053')
    base = int(m.group(1))
    swaps = []
    for line in fb.split('\n'):
        f = line.split()
        if len(f) == 7 and f[0].isdigit():
            sw, sc = int(f[1]), int(f[2])
            swaps.append((base + sw, base + sc if sc else 0))
    touches = []
    for line in tt.split('\n'):
        f = line.split()
        if len(f) == 3 and f[0].isdigit():
            touches.append((int(f[0]), f[1], int(f[2])))
    return sorted(swaps), touches


def measure(swaps, touches, since_us=0):
    res = []
    for i, (t, kind, finger) in enumerate(touches):
        if kind != 'd' or t < since_us:
            continue
        before = [s for s, _ in swaps if s < t]
        if not swaps or swaps[0][0] > t - QUIET_MS * 1000:
            continue                    # the trace does not reach back far enough to know the screen was still
        if before and t - before[-1] < QUIET_MS * 1000:
            continue                    # something was already moving
        mv = next((tm for tm, k, fg in touches[i + 1:] if fg == finger and k in 'mu'), None)
        after = [(s, sc) for s, sc in swaps if s > t]
        if not after:
            continue
        s, sc = after[0]
        row = {'down_swap': (s - t) / 1000, 'down_scan': (sc - t) / 1000 if sc else None}
        if mv is not None and mv < s:
            row['move_swap'] = (s - mv) / 1000
            row['move_scan'] = (sc - mv) / 1000 if sc else None
        res.append(row)
    return res


def summary(rows):
    if not rows:
        print('no touch started on a still screen')
        return
    for key, what in (('down_swap', 'touch-down -> swap'), ('down_scan', 'touch-down -> scan'),
                      ('move_swap', 'first move -> swap'), ('move_scan', 'first move -> scan')):
        v = [r[key] for r in rows if r.get(key) is not None]
        if v:
            print('%-20s n=%2d  median %6.1f ms  min %6.1f  max %6.1f   (%s)' % (what, len(v), statistics.median(v), min(v),
                  max(v), ' '.join('%.0f' % x for x in v)))
    print('add: the panel shows a scanned frame at its next refresh (0-16.7 ms), and the IC + poll before the event')


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else 'watch'
    if mode == 'drag':
        n = int(sys.argv[2]) if len(sys.argv) > 2 else 8
        rows = []
        for k in range(n):
            time.sleep(1.2)
            phone('/var/root/sweetsys kern.sweet_touch_drag=540,%d,540,%d,200 >/dev/null' % ((1500, 700) if k % 2 == 0 else (700, 1500)))
            time.sleep(0.8)
            swaps, touches = traces()
            got = measure(swaps, touches, since_us=touches[-1][0] - 2000000 if touches else 0)
            rows += got[-1:]
        summary(rows)
    elif mode == 'watch':
        # the frame trace holds 128 swaps (~2 s of scrolling): read both traces every 0.7 s and merge them
        secs = int(sys.argv[2]) if len(sys.argv) > 2 else 20
        allsw, allt = {}, {}
        end = time.time() + secs
        while time.time() < end:
            sw, tt = traces()
            for s_, sc in sw:
                allsw[s_] = max(sc, allsw.get(s_, 0))
            for t in tt:
                allt[t] = 1
            time.sleep(0.7)
        summary(measure(sorted(allsw.items()), sorted(allt)))
    else:
        sys.exit(__doc__)


if __name__ == '__main__':
    main()
