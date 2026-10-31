#!/usr/bin/env python3
"""The UI paths a finger takes, one number per scene: what reached the panel, and what the frames cost.

  tools/dipper-scenes.py [ROUNDS, default 3] [SCENE ...]

Fingers go through the real touch path (kern.sweet_touch_drag: panel pixels x1,y1,x2,y2,ms). For each scene: new rows of
kern.sweet_fb_trace (shown frames, gaps) and new bgmtl.log lines of backboardd (encode, GPU wait, draws, texture pool).
Screenshots of the last round land in research/shots/scene-NAME.png: look at them, a missed gesture measures an idle screen.
"""
import os, re, statistics, subprocess, sys

SSH = ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', 'root@192.168.7.2']


def drag(x1, y1, x2, y2, ms):
    return f'/var/root/sweetsys kern.sweet_touch_drag={x1},{y1},{x2},{y2},{ms} >/dev/null'


HOME = 'sweettouch home; sleep 1.2'
TO_HOME = 'sweettouch home; sleep 1.5; sweettouch home; sleep 1.2'
LOCKED = 'sweettouch lock; sleep 1.5; sweettouch home; sleep 2'
CC_OPEN = drag(1000, 8, 1000, 1300, 350)
SCENES = [
    # name, set-up, action, seconds to watch
    ('unlock', LOCKED, drag(540, 2230, 540, 700, 300), 1.6),
    ('cc-open', TO_HOME, CC_OPEN, 1.5),
    ('cc-scroll', '', drag(540, 1900, 540, 600, 400), 1.4),
    ('cc-scroll-back', '', drag(540, 600, 540, 1900, 400), 1.4),
    ('cc-close', '', 'sweettouch home', 1.5),
    ('page-flick', TO_HOME, drag(980, 1100, 100, 1100, 250), 1.2),
    ('page-flick-back', '', drag(100, 1100, 980, 1100, 250), 1.2),
    ('spotlight', TO_HOME, drag(540, 900, 540, 1500, 300), 1.3),
    ('spotlight-close', '', 'sweettouch home', 1.3),
    ('app-open', TO_HOME, 'sweettouch tap 143 557', 2.0),
    ('list-flick', '', drag(540, 1800, 540, 500, 200), 1.6),
    ('list-flick-back', '', drag(540, 500, 540, 1800, 200), 1.6),
    ('app-close', '', drag(540, 2235, 540, 1000, 250), 1.5),
    ('switcher', TO_HOME, drag(540, 2235, 540, 1400, 600), 1.5),
    ('switcher-close', '', 'sweettouch home', 1.5),
]
TRACE = '/var/root/sweetsys kern.sweet_fb_trace'
LOG = '/private/var/tmp/bgmtl.log'


def phone(script):
    return subprocess.run(SSH + ['sh -s'], input=script, capture_output=True, text=True).stdout


def trace_rows(text):
    rows = []
    for line in text.split('\n'):
        f = line.split()
        if len(f) == 7 and f[0].isdigit():
            rows.append([int(x) for x in f])
    return rows


def analyse(rows, log):
    gaps, scan = [], []
    for a, b in zip(rows, rows[1:]):
        dt = (b[1] - a[1]) / 1000
        if dt <= 200:
            gaps.append(dt)
        if a[2]:
            scan.append(a[2])
    ms = sum(gaps)
    out = {'swaps': len(gaps), 'ms': ms}
    if not gaps or ms < 30:
        return out
    scan.sort()
    sg = [(b - a) / 1000 for a, b in zip(scan, scan[1:]) if b - a < 200000]
    out.update(fps=len(gaps) * 1000 / ms, shown=len(sg) * 1000 / sum(sg) if sg else 0, worst=max(sg) if sg else 0,
               over25=sum(1 for g in sg if g > 25), over50=sum(1 for g in sg if g > 50))
    enc, wait, draws, miss = [], [], [], []
    for l in log:
        m = re.search(r'\[\d+\] perf: ([\d.]+) cbuf/s, ([\d.]+) draws/cbuf; per second: encode (\d+) ms, submit (\d+) ms, gpu wait (\d+)', l)
        if m and float(m.group(1)) > 5:
            n = float(m.group(1))
            draws.append(float(m.group(2)))
            enc.append(int(m.group(3)) / n)
            wait.append(int(m.group(5)) / n)
        m = re.search(r'texpool: (\d+) hits, (\d+) misses', l)
        if m:
            miss.append(int(m.group(2)))
    if enc:
        out.update(enc=statistics.mean(enc), wait=statistics.mean(wait), draws=statistics.mean(draws))
    if miss:
        out['miss'] = sum(miss)
    return out


def main():
    args = sys.argv[1:]
    rounds = int(args[0]) if args and args[0].isdigit() else 3
    only = [a for a in args if not a.isdigit()]
    res = {}
    for r in range(rounds):
        for name, setup, action, secs in SCENES:
            if only and not any(name.startswith(o) for o in only):
                continue
            shot = f'sweetshot /tmp/scene-{name}.png >/dev/null' if r == rounds - 1 else ':'
            out = phone(f'''{setup}
n=$(wc -l < {LOG}); {TRACE} | grep -E "^[0-9]" | tail -1 | cut -d" " -f1 > /tmp/t0
{action}
sleep {secs}
{shot}
sleep 0.2
echo "@@T0 $(cat /tmp/t0)"; {TRACE}; echo @@LOG; tail -n +$((n+1)) {LOG} | grep -E "perf:|texpool:" ''')
            m = re.search(r'@@T0 (\d+)', out)
            t0 = int(m.group(1)) if m else 0
            body, _, lg = out.partition('@@LOG')
            rows = [x for x in trace_rows(body) if x[0] >= t0]
            res.setdefault(name, []).append(analyse(rows, lg.split('\n')))
            if r == rounds - 1:
                png = subprocess.run(SSH + [f'cat /tmp/scene-{name}.png'], capture_output=True).stdout
                os.makedirs('research/shots', exist_ok=True)
                open(f'research/shots/scene-{name}.png', 'wb').write(png)
    print(f'{"scene":<16}{"swaps":>6}{"shown fps":>10}{"rendered":>9}{"worst ms":>9}{">25ms":>6}{">50ms":>6}{"encode":>8}{"gpu":>7}{"draws":>7}{"misses":>7}')
    for name, _, _, _ in SCENES:
        for i, o in enumerate(res.get(name, [])):
            if 'fps' not in o:
                print(f'{name:<16}{o["swaps"]:>6}  (no animation)')
                continue
            print(f'{name if i == 0 else "":<16}{o["swaps"]:>6}{o["shown"]:>10.1f}{o["fps"]:>9.1f}{o["worst"]:>9.0f}{o["over25"]:>6}{o["over50"]:>6}'
                  f'{o.get("enc", 0):>8.1f}{o.get("wait", 0):>7.1f}{o.get("draws", 0):>7.0f}{o.get("miss", 0):>7}')


if __name__ == '__main__':
    main()
