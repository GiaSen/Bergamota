#!/usr/bin/env python3
"""Copy the real iPhone's /product/haptics node into an Apple Device Tree that has a /product node without it.
  adt-haptics.py IN.adt OUT.adt [--from research/ios26/n104ap.adt]
MobileGestalt reads DeviceSupportsClosedLoopHaptics from /product/haptics "closed-loop": with it iOS plays the system's
vibrations and feedbacks as waveforms on the audio HAL's "Actuator" device (SweetSpeaker.driver), without it it looks
for an old vibration motor in IOKit (found by HakiOS, xnuloader/mkidentity.py; docs/FORKS_SURVEY.md G9). The node's
properties are copied as they are, except those iBoot fills in from syscfg (flagged: controller-coeff-cal) and the
phandle, which gets a new value. tools/mkadt.py copies the same node when it builds an ADT; this is for ADTs already
built (dipper-n104-2x-wlan-gpu.adt has been through adt-gpufw.py). The source tree is an Apple artifact: keep it and
the output out of git.
"""
import argparse
import os
import struct
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import adt  # noqa: E402

N104 = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'research', 'ios26', 'n104ap.adt')


def name(n):
    return dict((k, v) for k, f, v in n.props).get('name', b'').rstrip(b'\0').decode()


def child(n, want):
    return next((c for c in n.children if name(c) == want), None)


def phandles(n, out):
    for k, f, v in n.props:
        if k == 'AAPL,phandle' and len(v) == 4:
            out.add(struct.unpack('<I', v)[0])
    for c in n.children:
        phandles(c, out)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('inp')
    ap.add_argument('out')
    ap.add_argument('--from', dest='src', default=N104)
    a = ap.parse_args()
    root, _ = adt.parse(adt.load(a.inp))
    src, _ = adt.parse(adt.load(a.src))
    product, sproduct = child(root, 'product'), child(src, 'product')
    if product is None or sproduct is None:
        sys.exit('no /product node in %s' % (a.inp if product is None else a.src))
    shap = child(sproduct, 'haptics')
    if shap is None:
        sys.exit('%s: no /product/haptics' % a.src)
    old = child(product, 'haptics')
    if old is not None:
        product.children.remove(old)
    ph = max(phandles(root, set()) | {0}) + 1
    n = adt.Node()
    n.props = [(k, 0, v) for k, f, v in shap.props if not f and k != 'AAPL,phandle']
    n.props.append(('AAPL,phandle', 0, struct.pack('<I', ph)))
    n.children = []
    product.children.append(n)
    open(a.out, 'wb').write(adt.serialize(root))
    print('%s: /product/haptics (%s) from %s, phandle %#x%s' % (a.out, ', '.join(k for k, f, v in n.props if k not in ('name', 'AAPL,phandle')),
          os.path.basename(a.src), ph, ', replacing the old one' if old is not None else ''))


if __name__ == '__main__':
    main()
