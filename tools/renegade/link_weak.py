#!/usr/bin/env python3
"""link_weak.py BIN DYLIB OUT: copy of a system binary that weak-links one more dylib, re-signed ad hoc the way
root_tweaks18.chlorophyll_link does it (same identifier, CS flags and entitlements; addlc.py --weak --make-room).
Refuses when the identity, flags or entitlements would change, or when BIN already links DYLIB.
Used by tools/sweetnet/sweetorient-install.sh (backboardd + /usr/local/lib/sweetorient.dylib)."""
import os, plistlib, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import pacstrip
import renegade_platform as rplat
from root_tweaks18 import ADDLC, entitlements_of, macho_has_dylib

if len(sys.argv) != 4:
    sys.exit(__doc__)
src, dylib, out = sys.argv[1:]
if macho_has_dylib(src, dylib):
    sys.exit('%s already links %s' % (src, dylib))
tmpd = tempfile.mkdtemp(prefix='link-weak-')
try:
    tmp = os.path.join(tmpd, os.path.basename(src))
    shutil.copyfile(src, tmp)
    os.chmod(tmp, 0o755)
    ents, ident = entitlements_of(tmp) or {}, pacstrip.cs_identity(tmp)
    if not ident:
        sys.exit('%s: no code signature identity' % src)
    subprocess.run([sys.executable, '-I', ADDLC, '--weak', '--make-room', tmp, dylib], check=True)
    rplat.adhoc_sign(tmp, ident[0], ident[2], plistlib.dumps(ents) if ents else None)
    new = pacstrip.cs_identity(tmp)
    if not new or new[:2] != ident[:2] or (ident[2] & ~new[2]) & ~pacstrip.CS_FLAG_IGNORED:
        sys.exit('identity or CS flags changed by the re-sign: %s -> %s' % (ident, new))
    if (entitlements_of(tmp) or {}) != ents:
        sys.exit('entitlements changed by the re-sign')
    if not macho_has_dylib(tmp, dylib):
        sys.exit('LC_LOAD_WEAK_DYLIB missing after addlc.py')
    shutil.copyfile(tmp, out)
    os.chmod(out, 0o755)
    print('%s: weak-links %s (re-signed ad hoc as %s, flags %#x, %d entitlements)' % (out, dylib, ident[0], ident[2], len(ents)))
finally:
    shutil.rmtree(tmpd, ignore_errors=True)
