#!/usr/bin/env python3
"""What reaches the panel, from kern.sweet_fb_trace (the last 128 swaps; `sweetsys kern.sweet_fb_trace` on the phone).

  ssh root@192.168.7.2 /var/root/sweetsys kern.sweet_fb_trace | tools/dipper-fbtrace.py

backboardd's `frames:` line counts rendered frames, not shown ones: this one prints both, and the time from a swap to its
scan-out. Only swaps less than 50 ms apart count, so a pause between animations does not read as a low frame rate.
"""
import sys

rows = []
for line in sys.stdin:
    f = line.split()
    if len(f) == 7 and f[0].isdigit():
        rows.append([int(x) for x in f])
if len(rows) < 2:
    sys.exit("no trace")

busy, shown, late = 0.0, 0, []
swaps = 0
for a, b in zip(rows, rows[1:]):
    dt = (b[1] - a[1]) / 1000
    if dt > 50:
        continue
    busy += dt
    swaps += 1
    if a[2]:
        shown += 1
        late.append((a[2] - a[1]) / 1000)
if not busy:
    sys.exit("no animation in the trace")
late.sort()
print(f"{swaps} swaps in {busy:.0f} ms of animation: rendered {swaps * 1000 / busy:.1f} fps, "
      f"shown {shown * 1000 / busy:.1f} fps ({100 * shown / swaps:.0f}% of the frames)")
if late:
    print(f"swap to scan-out: median {late[len(late) // 2]:.1f} ms, worst {late[-1]:.1f} ms")
