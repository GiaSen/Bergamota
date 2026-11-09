#!/usr/bin/env python3
"""Set the presented display size (/arm-io/disp0 canvas-width/canvas-height) of an Apple Device Tree already built.
  adt-canvas.py IN.adt OUT.adt --points WxH [--scale 2]
The kernel (SweetFramebuffer.cpp) presents that canvas to iOS and its display scaler maps it onto the panel; touches are
mapped back with the same transform (SweetHID.cpp). A canvas with the panel's own aspect fills the panel without bars
or distortion: the Mi 8's 1080x2248 panel is 414x862 points at @2x (828x1724, 1.3043x on both axes), where the
iPhone 11's 414x896 left a ~20 px black band at each side (2026-11-09). Not the default: iOS has no status bar layout for
a 414x862 screen and moved its icons into the notch; the default stretches the 414x896 canvas instead (sweetfb_scale=2,
tools/dipper-mkboot.sh). The source tree is an Apple artifact: keep it and the output out of git.
"""
import argparse
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import adt  # noqa: E402


def child(n, want):
    return next((c for c in n.children if c.name == want), None)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('inp')
    ap.add_argument('out')
    ap.add_argument('--points', required=True, help='WxH in points')
    ap.add_argument('--scale', type=int, default=2)
    a = ap.parse_args()
    w, h = (int(v) for v in a.points.lower().split('x'))
    cw, ch = w * a.scale, h * a.scale
    root, _ = adt.parse(adt.load(a.inp))
    armio = child(root, 'arm-io')
    disp = child(armio, 'disp0') if armio is not None else None
    if disp is None:
        sys.exit('%s: no /arm-io/disp0' % a.inp)
    old = {k: v for k, f, v in disp.props if k in ('canvas-width', 'canvas-height')}
    disp.props = [(k, f, struct.pack('<I', cw) if k == 'canvas-width' else struct.pack('<I', ch) if k == 'canvas-height' else v)
                  for k, f, v in disp.props]
    if 'canvas-width' not in old:
        disp.props.append(('canvas-width', 0, struct.pack('<I', cw)))
    if 'canvas-height' not in old:
        disp.props.append(('canvas-height', 0, struct.pack('<I', ch)))
    open(a.out, 'wb').write(adt.serialize(root))
    was = 'x'.join(str(struct.unpack('<I', old[k])[0]) if k in old else '?' for k in ('canvas-width', 'canvas-height'))
    print('%s: /arm-io/disp0 canvas %dx%d (%s at @%d; was %s)' % (a.out, cw, ch, a.points, a.scale, was))


if __name__ == '__main__':
    main()
