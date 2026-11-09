#!/usr/bin/env python3
"""Copy the real iPhone's /product/haptics node into an Apple Device Tree that has a /product node without it, add a
/product/camera node holding only the iPhone's "flash" property, and (--rear-camera, 2026-11-09) an /arm-io/isp node
holding only "camera-rear" = 1.
  adt-haptics.py IN.adt OUT.adt [--from research/ios26/n104ap.adt]
MobileGestalt's camera-flash comes from /product/camera "flash": with it Control Center shows the flashlight button and
FigFlashlight (cameracaptured) offers a torch (the Mi 8's: xnu 3050 + sweettorch.dylib). The iPhone's other camera
properties are left out on purpose: they describe cameras and features this phone does not have.
MobileGestalt's rear-facing-camera and still-camera come from IODeviceTree:/arm-io/isp "camera-rear" (its property names
are hashed like its keys: base64(md5("MGCopyAnswer" + name))). Without them SpringBoard hides Camera.app (SBAppTags
still-camera) and the lock screen's camera button is dimmed. The Mi 8's rear main camera works (xnu 3075+, sweetcam.dylib):
--rear-camera adds the node with that one property (no compatible: nothing matches it). --front-camera (2026-11-09, the
front S5K3T1 streams since xnu 3090) adds "camera-front" = 1 to it: MobileGestalt's front-facing-camera.
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
    ap.add_argument('--rear-camera', action='store_true', help='add /arm-io/isp "camera-rear" = 1')
    ap.add_argument('--front-camera', action='store_true', help='add /arm-io/isp "camera-front" = 1')
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
    scam = child(sproduct, 'camera')
    flash = next((v for k, f, v in scam.props if k == 'flash' and not f), None) if scam is not None else None
    if flash is None:
        sys.exit('%s: no /product/camera "flash"' % a.src)
    oldcam = child(product, 'camera')
    if oldcam is not None:
        product.children.remove(oldcam)
    cam = adt.Node()
    cam.props = [('name', 0, b'camera\0'), ('flash', 0, flash), ('AAPL,phandle', 0, struct.pack('<I', ph + 1))]
    cam.children = []
    product.children.append(cam)
    print('%s: /product/camera with only "flash" %s, phandle %#x%s' % (a.out, flash.hex(), ph + 1,
          ', replacing the old one' if oldcam is not None else ''))
    if a.rear_camera or a.front_camera:
        armio = child(root, 'arm-io')
        if armio is None:
            sys.exit('%s: no /arm-io' % a.inp)
        oldisp = child(armio, 'isp')
        if oldisp is not None:
            armio.children.remove(oldisp)
        isp = adt.Node()
        isp.props = [('name', 0, b'isp\0')] + \
            ([('camera-rear', 0, struct.pack('<I', 1))] if a.rear_camera else []) + \
            ([('camera-front', 0, struct.pack('<I', 1))] if a.front_camera else []) + \
            [('AAPL,phandle', 0, struct.pack('<I', ph + 2))]
        isp.children = []
        armio.children.append(isp)
        print('%s: /arm-io/isp with only %s, phandle %#x%s' % (a.out, ' and '.join(
              n for n, on in (('"camera-rear" 1', a.rear_camera), ('"camera-front" 1', a.front_camera)) if on), ph + 2,
              ', replacing the old one' if oldisp is not None else ''))
    open(a.out, 'wb').write(adt.serialize(root))
    print('%s: /product/haptics (%s) from %s, phandle %#x%s' % (a.out, ', '.join(k for k, f, v in n.props if k not in ('name', 'AAPL,phandle')),
          os.path.basename(a.src), ph, ', replacing the old one' if old is not None else ''))


if __name__ == '__main__':
    main()
