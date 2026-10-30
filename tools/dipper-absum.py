#!/usr/bin/env python3
"""Summary of one tools/dipper-abtest.sh run: dipper-absum.py DIR NAME.

backboardd's frames (bgmtl.perf `frames:` lines) over the UI test, windows at the idle trickle (<= 12 fps) apart; the framebuffer's
counters from the kernel log; CPU seconds per process between the two `ps` listings.
"""
import re, sys

d, name = sys.argv[1], sys.argv[2]
base = f'{d}/{name}'


def cpu_table(path):
    t = {}
    for line in open(path, errors='replace').read().splitlines()[1:]:
        m = re.match(r'\s*(\d+)\s+(\d+):(\d+)\.(\d+)\s+(.*)', line)
        if m:
            t[int(m[1])] = (int(m[2]) * 60 + int(m[3]) + int(m[4]) / 100, m[5].split('/')[-1])
    return t


log = open(f'{base}.bgmtl.log', errors='replace').read().splitlines()
ps0, ps1 = cpu_table(f'{base}.ps0'), cpu_table(f'{base}.ps1')

# backboardd = the pid whose line says so
bb = next((m[1] for l in log if (m := re.match(r'\[(\d+)\] backboardd:', l))), None)
frames = []
for l in log:
    m = re.match(r'\[(\d+)\] frames: ([\d.]+) fps while animating \((\d+) intervals, (\d+) ms\); intervals <=17 ms (\d+), <=25 (\d+), <=34 (\d+), <=100 (\d+)', l)
    if m and m[1] == bb:
        frames.append((float(m[2]), int(m[3]), int(m[4]), *map(int, m.groups()[4:])))


def line(rows, label):
    if not rows:
        return f'{label}: no windows'
    n, ms = sum(r[1] for r in rows), sum(r[2] for r in rows)
    h = [sum(r[i] for r in rows) for i in range(3, 7)]
    tot = max(sum(h), 1)
    s = sorted(r[0] for r in rows)
    return (f'{label}: {len(rows)} windows, {n * 1000 / max(ms, 1):.1f} fps overall, median {s[len(s) // 2]:.1f}; '
            f'intervals <=17 ms {100 * h[0] / tot:.0f}%, <=25 {100 * h[1] / tot:.0f}%, <=34 {100 * h[2] / tot:.0f}%, <=100 {100 * h[3] / tot:.0f}%')


# the frames lines before the UI test belong to start-up: the same number of windows is not comparable, so all of them count only when
# the run has no split; a run is one boot and one test, start-up is short against 180 s
print(f'== {name}')
print(line(frames, 'all windows'))
print(line([r for r in frames if r[0] > 12], 'animating (> 12 fps)'))

k = open(f'{base}.klog', errors='replace').read()
st = re.findall(r'SWEET FB: stats sweet_fb v1 mode=(\w+) hz=(\d+).*?swaps_s=([\d.]+).*?zc_s=([\d.]+).*?copy_s=([\d.]+)', k)
if st:
    active = [s for s in st if float(s[2]) > 5]
    mean = lambda i: sum(float(s[i]) for s in active) / max(len(active), 1)
    print(f'FB: mode={st[-1][0]} hz={st[-1][1]}; active samples {len(active)}: swaps/s {mean(2):.1f}, zero-copy/s {mean(3):.1f}, copies/s {mean(4):.1f}')
for tag in ('scan_gpu', 'scan_gpu_copies', 'scan_gpu_fallbacks'):
    m = re.findall(rf'\b{tag}=(\d+)', k)
    if m:
        print(f'{tag}={m[-1]}', end=' ')
print()
faults = k.count('SMMU CB1 FAULT')
print(f'GPU faults {faults}, recoveries {k.count("RECOVERY ")}, did-not-finish {k.count("did not finish")}, CRASH lines {len(re.findall(r"^CRASH \S+ reason", k, re.M))}')
for c in (0, 1):
    v = [int(x) for x in re.findall(rf'gov cluster{c} load (\d+)%', k)]
    if v:
        tail = v[-20:]
        print(f'cluster{c} load last {len(tail)} samples: mean {sum(tail) / len(tail):.0f}%')

dt = {}
for pid, (t1, comm) in ps1.items():
    t0 = ps0.get(pid, (0, comm))[0]
    if t1 - t0 > 0:
        dt[comm] = dt.get(comm, 0) + t1 - t0
print(f'CPU seconds during the test, total {sum(dt.values()):.1f}:')
for comm, t in sorted(dt.items(), key=lambda x: -x[1])[:14]:
    print(f'  {t:7.1f}  {comm}')
