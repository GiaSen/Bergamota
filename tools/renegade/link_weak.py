#!/usr/bin/env python3
"""link_weak.py BIN DYLIB OUT: copy of a system binary that weak-links one more dylib, re-signed ad hoc the way
root_tweaks18.chlorophyll_link does it (same identifier, CS flags and entitlements; addlc.py --weak --make-room).
Refuses when the identity, flags or entitlements would change, or when BIN already links DYLIB.
The by-hand install of the backboardd orientation shim on the phone (2026-11-06, NOTES "SENSORS") was made with it; in an
image, `RENEGADE_ORIENT=1 renegade update` does the same (root_tweaks18.orient, through the same weak_link_file)."""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from root_tweaks18 import macho_has_dylib, weak_link_file

if len(sys.argv) != 4:
    sys.exit(__doc__)
src, dylib, out = sys.argv[1:]
if macho_has_dylib(src, dylib):
    sys.exit('%s already links %s' % (src, dylib))
ident, ents = weak_link_file(src, dylib, out, 'link_weak')
os.chmod(out, 0o755)
print('%s: weak-links %s (re-signed ad hoc as %s, flags %#x, %d entitlements)' % (out, dylib, ident[0], ident[2], len(ents)))
