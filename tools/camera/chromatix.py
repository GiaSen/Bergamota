#!/usr/bin/env python3
"""The colour tuning of a camera out of its Qualcomm tuning file, for sweetcam.

  python3 -I tools/camera/chromatix.py TUNED.bin            # list what is there
  python3 -I tools/camera/chromatix.py TUNED.bin OUT.ctun   # and write it for sweetcam

TUNED.bin is the phone's own `com.qti.tuned.<maker>_<sensor>.bin` (vendor partition /lib/camera; vendor data: never in
git, nor what this makes of it). It is a "QTI Chromatix Header" file in the older CamX layout ("ParameterParser
V1.1.0", or naming no parser, "Chromatix"), laid out as the sensors' module files are (tools/camera/camx_v1.py): a table
of 0x40-byte symbols { id, name[32], kind, three words, offset into the pool, size } and the pool. Taken from it:

  cc13  (the colour matrix): per scene brightness (lux index, Qualcomm's: higher is darker) and colour temperature range
        a 3x3 matrix from the white-balanced sensor colours to linear sRGB, rows R, G, B (each row sums to 1)
  lsc34 (lens shading): per brightness and colour temperature range a gain for each of R, Gr, Gb, B at the 17 x 13
        points of a grid laid over the sensor (corners on its corners, rows from the top)
  refPtV1 (the white balance's reference lights): ten lights, each as the sensor sees a grey under it (R/G, B/G),
        from 10000 K to a candle; each given the colour temperature its tables are picked by
  expTables / expKneeEntries (the auto exposure's table): its first knee is where the lux index counts from, e.g.
        gain 1.00 at 0.042 ms = index 0; every index is 3 % more exposure (the other knees say so: 10 ms = 185)

How these modules are laid out (the led_idx -> aec -> cct tree, the 24-byte brightness records, the reference lights'
order and colour temperatures) is as HakiOS's tools/camtuning.py documents it (MIT, oosexgang/hakios-xnu-kernel; the
OnePlus 6T port kiwiiiii-eth/hakios-fajita, 2026-11-16, docs/FORKS_SURVEY.md H1). This is our own reader of that layout.

OUT.ctun, little-endian, counts as 32-bit words: "SWCTUN01"; the colour matrix tree { regions; per region: lux index
from, to (floats), ranges; per range: CCT from, to, 9 floats }; the lens shading tree, the same with 4 x 17 x 13 floats
per range (R, Gr, Gb, B grids); the reference lights { count; each R/G, B/G, CCT }; one float, the exposure of lux
index 0 in microseconds x gain (0: not in the file).
"""
import struct
import sys

GRID_W, GRID_H = 17, 13
GRID = GRID_W * GRID_H
# the colour temperature each of the ten reference lights picks its tables by: 10000 K, D75, D65, D50, cool white,
# TL84, U30 (3000 K without a filament's infrared, so a white LED's: TL84's tables), A, horizon, candle
REFERENCE_CCTS = (10000, 7500, 6500, 5000, 4150, 4000, 3800, 2850, 2300, 1900)


def symbols(data):
    if not data.startswith(b'QTI Chromatix Header'):
        raise SystemExit('chromatix.py: not a Chromatix tuning file')
    count, first = struct.unpack_from('<2I', data, 0x9c)
    if not (2 <= count <= 8 and first == 0):
        raise SystemExit('chromatix.py: not the V1.1.0 layout (entry count %d)' % count)
    entries = [struct.unpack_from('<3I', data, 0xa0 + 12 * i) for i in range(count)]
    table, pool = entries[0][1], entries[1][1]
    out = {}
    for at in range(table, pool - 0x3f, 0x40):
        sid = struct.unpack_from('<I', data, at)[0]
        name = data[at + 4:at + 0x24].split(b'\0')[0].decode('latin1')
        off, size = struct.unpack_from('<2i', data, at + 0x38)
        out[sid] = (name, data[pool + off:pool + off + size] if size > 0 else b'')
    return out


def tree(syms, led, floats):
    """[(lux from, lux to, [(cct from, cct to, values)])] of the no-flash branch of one led_idx record"""
    nolight = next((e for e in struct.iter_unpack('<3I', led[:len(led) // 12 * 12]) if e[0] == 0), None)
    if nolight is None:
        return []
    _, regions, sid = nolight
    out = []
    for i in range(regions):
        lux_from, lux_to, _a, _b, n, cct_sid = struct.unpack_from('<4f2I', syms[sid][1], 24 * i)
        cct = syms[cct_sid][1]
        size = len(cct) // n if n else 0
        ranges = []
        for j in range(n):
            v = struct.unpack_from('<%df' % (2 + floats), cct, size * j)
            ranges.append((v[0], v[1], v[2:]))
        out.append((lux_from, lux_to, ranges))
    return out


def module(syms, name, floats):
    """the module's first tree that changes something (a file may begin with an identity one, for modes leaving it out)"""
    trees = [tree(syms, v, floats) for n, v in syms.values() if n == 'mod_%s_led_idx_data' % name]
    trees = [t for t in trees if t]
    if not trees:
        raise SystemExit('chromatix.py: no %s in the file' % name)
    plain = (1, 0, 0, 0, 1, 0, 0, 0, 1) if floats == 9 else (1,) * floats
    return next((t for t in trees if any(tuple(round(x, 4) for x in v) != plain for _, _, r in t for _, _, v in r)), trees[0])


def references(syms):
    v = next((v for n, v in syms.values() if n == 'refPtV1'), None)
    if not v:
        return []
    f = struct.unpack('<%df' % (len(v) // 4), v[:len(v) // 4 * 4])
    points = [(f[i], f[i + 1]) for i in range(6, len(f) - 1, 2) if f[i] > 0 and f[i + 1] > 0]
    return [(rg, bg, cct) for (rg, bg), cct in zip(points, REFERENCE_CCTS)] if len(points) == len(REFERENCE_CCTS) else []


def exposure_zero(syms):
    """microseconds x gain of the first exposure table's knee with index 0 (0.0: none)"""
    for sid in sorted(syms):
        name, v = syms[sid]
        if name != 'expTables' or len(v) < 16:
            continue
        _factor, knees, knee_sid, _pct = struct.unpack_from('<fIIf', v)
        knee = syms.get(knee_sid, ('', b''))[1]
        if knees and len(knee) >= 20:
            gain, ns, _priority, index = struct.unpack_from('<fQIf', knee)
            if index == 0 and gain > 0 and ns > 0:
                return gain * ns / 1000.0
        break
    return 0.0


def main():
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    syms = symbols(open(sys.argv[1], 'rb').read())
    ccm = module(syms, 'cc13', 9)
    lsc = module(syms, 'lsc34', 4 * GRID)
    refs = references(syms)
    zero = exposure_zero(syms)
    for lux_from, lux_to, ranges in ccm:
        for cct_from, cct_to, v in ranges:
            print('colour matrix  lux index %4.0f-%-4.0f CCT %5.0f-%-5.0f %s' % (lux_from, lux_to, cct_from, cct_to,
                                                                            ' '.join('%6.3f' % x for x in v)))
    for lux_from, lux_to, ranges in lsc:
        for cct_from, cct_to, v in ranges:
            corners = [v[c * GRID + k] for c in range(4) for k in (0, GRID_W - 1, GRID - GRID_W, GRID - 1)]
            centre = [v[c * GRID + (GRID_H // 2) * GRID_W + GRID_W // 2] for c in range(4)]
            print('lens shading   lux index %4.0f-%-4.0f CCT %5.0f-%-5.0f corners R %.2f..%.2f B %.2f..%.2f, centre %s' % (
                lux_from, lux_to, cct_from, cct_to, min(corners[0:4]), max(corners[0:4]), min(corners[12:16]),
                max(corners[12:16]), ' '.join('%.2f' % x for x in centre)))
    for rg, bg, cct in refs:
        print('reference light R/G %.3f B/G %.3f, its tables those of %.0f K' % (rg, bg, cct))
    print('lux index 0 is %.1f us x gain' % zero if zero else 'no exposure table: lux index 0 not known')
    if len(sys.argv) == 3:
        out = bytearray(b'SWCTUN01')
        for t in (ccm, lsc):
            out += struct.pack('<I', len(t))
            for lux_from, lux_to, ranges in t:
                out += struct.pack('<2fI', lux_from, lux_to, len(ranges))
                for cct_from, cct_to, v in ranges:
                    out += struct.pack('<2f%df' % len(v), cct_from, cct_to, *v)
        out += struct.pack('<I', len(refs))
        for ref in refs:
            out += struct.pack('<3f', *ref)
        out += struct.pack('<f', zero)
        open(sys.argv[2], 'wb').write(out)
        print('%s: %d bytes' % (sys.argv[2], len(out)))


if __name__ == '__main__':
    main()
