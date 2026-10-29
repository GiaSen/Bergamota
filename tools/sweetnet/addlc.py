#!/usr/bin/env python3
"""addlc.py [--weak] [--make-room] BIN DYLIB_PATH [OUT]: append an LC_LOAD_DYLIB to a thin Mach-O (uses the slack before __text).
--weak appends LC_LOAD_WEAK_DYLIB instead: a missing (or sweetdenypath-hidden) dylib then does not stop the process.
--make-room: when the slack is too small, drop LC_SOURCE_VERSION and an empty LC_DATA_IN_CODE (both informational; iOS 26
SpringBoard has 16 bytes of slack, as the Poco F1's hand install found).
Re-sign afterwards: codesign -f -s - --entitlements ents.plist OUT"""
import struct, sys
opts = [a for a in sys.argv[1:] if a.startswith('--')]
args = [a for a in sys.argv[1:] if not a.startswith('--')]
assert set(opts) <= {'--weak', '--make-room'}, 'unknown option: %s' % opts
src, path = args[0], args[1]
out = args[2] if len(args) > 2 else src
d = bytearray(open(src, 'rb').read())
magic, cpu, sub, ft, ncmds, scmds, flags, _ = struct.unpack_from('<8I', d, 0)
assert magic == 0xfeedfacf, 'thin 64-bit Mach-O only'
# find lowest section/segment file offset after the load commands
off, lowest, cmds = 32, 1 << 62, []
for i in range(ncmds):
    cmd, sz = struct.unpack_from('<II', d, off)
    if cmd == 0x19:  # LC_SEGMENT_64
        nsects = struct.unpack_from('<I', d, off + 64)[0]
        for s in range(nsects):
            so = off + 72 + s * 80
            soff = struct.unpack_from('<I', d, so + 48)[0]
            if soff: lowest = min(lowest, soff)
    cmds.append(bytes(d[off:off + sz]))
    off += sz
nm = path.encode() + b'\0'
cmdsz = (24 + len(nm) + 7) & ~7
end = 32 + scmds
if end + cmdsz > lowest and '--make-room' in opts:
    # LC_SOURCE_VERSION (0x2a), LC_DATA_IN_CODE (0x29) with datasize 0
    def spare(c):
        cmd = struct.unpack_from('<I', c, 0)[0]
        return cmd == 0x2a or (cmd == 0x29 and struct.unpack_from('<I', c, 12)[0] == 0)
    dropped = [c for c in cmds if spare(c)]
    cmds = [c for c in cmds if not spare(c)]
    blob = b''.join(cmds)
    d[32:end] = blob.ljust(end - 32, b'\0')
    ncmds, scmds, end = len(cmds), len(blob), 32 + len(blob)
    print('dropped %d informational load command(s) (%d bytes) for room' % (len(dropped), sum(len(c) for c in dropped)))
assert end + cmdsz <= lowest, 'no slack for a new load command (%d free, %d needed)' % (lowest - end, cmdsz)
lc_cmd = 0x80000018 if '--weak' in opts else 0xc  # LC_LOAD_WEAK_DYLIB / LC_LOAD_DYLIB
lc = struct.pack('<IIIIII', lc_cmd, cmdsz, 24, 2, 0x10000, 0x10000) + nm
d[end:end + cmdsz] = lc.ljust(cmdsz, b'\0')
struct.pack_into('<II', d, 16, ncmds + 1, scmds + cmdsz)
open(out, 'wb').write(d)
print('added', 'LC_LOAD_WEAK_DYLIB' if '--weak' in opts else 'LC_LOAD_DYLIB', path, 'to', out)
