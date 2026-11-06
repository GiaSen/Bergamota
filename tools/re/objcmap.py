#!/usr/bin/env python3
"""objcmap.py SPLIT_DYLIB DSC_DIR: IMP -> '-[Class sel]' for a dylib split out of the shared cache (relative method lists),
and objc stub -> selector. Writes SPLIT_DYLIB-derived maps to stdout as 'addr name' lines."""
import sys, struct
sys.path.insert(0, __import__('os').path.dirname(__file__))
from dsc import DSC, BASE
path, dscdir = sys.argv[1], sys.argv[2]
SELBASE = 0x1fa27fde0   # iOS 26.6.2 23G90 iPhone12,1: solved from SBCoverSheetPresentationManager's list
d = DSC(dscdir)
data = open(path, 'rb').read()
ncmds = struct.unpack_from('<I', data, 16)[0]; off = 32; secs = {}
for _ in range(ncmds):
    cmd, size = struct.unpack_from('<II', data, off)
    if cmd == 0x19:
        n = struct.unpack_from('<I', data, off + 64)[0]
        for k in range(n):
            so = off + 72 + k * 80
            sect = data[so:so + 16].rstrip(b'\0').decode(); seg = data[so + 16:so + 32].rstrip(b'\0').decode()
            a, sz, fo = struct.unpack_from('<QQI', data, so + 32); secs[(seg, sect)] = (a, sz, fo)
    off += size
def sec(name):
    for (seg, s), v in secs.items():
        if s == name: return v
out = []
def methods(ml, cname, meta):
    if not ml: return
    hdr = d.read(ml, 8)
    if not hdr: return
    es, cnt = struct.unpack('<II', hdr)
    rel = es & 0x80000000; size = es & 0xfffc
    for i in range(min(cnt, 5000)):
        e = ml + 8 + i * size
        if rel:
            no, to, io = struct.unpack('<iii', d.read(e, 12))
            if es & 0x40000000:
                name = d.cstr(SELBASE + no, 120)      # selector offsets from the cache's selector base
            else:
                name = d.cstr(d.ptr(e + no))
            imp = e + 8 + io
        else:
            nm, ty, imp = struct.unpack('<QQQ', d.read(e, 24))
            name = d.cstr((nm & 0xfffffffff) + BASE); imp = (imp & 0xfffffffff) + BASE
        out.append((imp, '%s[%s %s]' % ('+' if meta else '-', cname, name)))
def ro_of(cls):
    data_ptr = d.ptr(cls + 32)
    return data_ptr & ~7 if data_ptr else None
def do_class(cls):
    ro = ro_of(cls)
    if not ro: return
    name = d.cstr(d.ptr(ro + 24)) or '?'
    methods(d.ptr(ro + 32) if d.read(ro + 32, 8) and struct.unpack('<Q', d.read(ro + 32, 8))[0] else None, name, False)
    meta = d.ptr(cls)
    if meta:
        mro = ro_of(meta)
        if mro and struct.unpack('<Q', d.read(mro + 32, 8))[0]:
            methods(d.ptr(mro + 32), name, True)
cl = sec('__objc_classlist')
if cl:
    a, sz, fo = cl
    for i in range(0, sz, 8):
        do_class(d.ptr(a + i))
cat = sec('__objc_catlist')
if cat:
    a, sz, fo = cat
    for i in range(0, sz, 8):
        c = d.ptr(a + i)
        cname = d.cstr(d.ptr(c)) or '?'
        for off_, meta in ((16, False), (24, True)):
            raw = struct.unpack('<Q', d.read(c + off_, 8))[0]
            if raw: methods(d.ptr(c + off_), cname + '(cat)', meta)
stubs = sec('__objc_stubs')
if stubs:
    a, sz, fo = stubs
    for s in range(a, a + sz, 32):
        i0, i1 = struct.unpack('<II', d.read(s, 8))
        if i0 & 0x9f000000 != 0x90000000: continue
        immlo = (i0 >> 29) & 3; immhi = (i0 >> 5) & 0x7ffff
        imm = ((immhi << 2) | immlo) << 12
        if imm & (1 << 32): imm -= 1 << 33
        page = (s & ~0xfff) + imm
        selref = page + ((i1 >> 10) & 0xfff) * 8
        out.append((s, 'stub:' + str(d.cstr(d.ptr(selref)))))
for imp, n in sorted(out):
    print('%x %s' % (imp, n))
