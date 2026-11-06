#!/usr/bin/env python3
"""xref.py MACHO STRING...: code addresses that load each string (or its CFString) with ADRP+ADD, in a thin arm64(e) Mach-O:
an executable (pointers: low 36 bits + 0x100000000) or a dylib split out of the shared cache by `ipsw dyld split`
(pointers: low 36 bits + the cache base 0x180000000). Used for locationd/backboardd/SpringBoard (NOTES, sensors 2026-11-06)."""
import sys, struct, subprocess, re
path = sys.argv[1]; needles = sys.argv[2:]
data = open(path,'rb').read()
# parse load commands for sections
ncmds = struct.unpack_from('<I', data, 16)[0]
off = 32; secs = {}
for _ in range(ncmds):
    cmd, size = struct.unpack_from('<II', data, off)
    if cmd == 0x19:
        nsect = struct.unpack_from('<I', data, off+64)[0]
        for k in range(nsect):
            so = off + 72 + k*80
            sect = data[so:so+16].rstrip(b'\0').decode(); seg = data[so+16:so+32].rstrip(b'\0').decode()
            addr, sz, fo = struct.unpack_from('<QQI', data, so+32)
            secs[(seg,sect)] = (addr, sz, fo)
    off += size
def v2o(v):
    for (seg,sect),(a,sz,fo) in secs.items():
        if a <= v < a+sz and fo: return fo + v - a
def o2v(o):
    for (seg,sect),(a,sz,fo) in secs.items():
        if fo and fo <= o < fo+sz: return a + o - fo, sect
text = secs[('__TEXT','__text')]
targets = {}
for nd in needles:
    b = nd.encode() + b'\0'
    i = data.find(b)
    while i >= 0:
        v, sect = o2v(i)
        if data[i-1:i] == b'\0':
            targets[v] = (nd, sect)
        i = data.find(b, i+1)
# cfstring entries pointing at these cstrings (ptr at +16; chained fixups: low 36 bits hold target vmaddr offset? try both)
cf = secs.get(('__DATA_CONST','__cfstring')) or secs.get(('__DATA','__cfstring')) or secs.get(('__AUTH_CONST','__cfstring'))
base = 0x100000000
if cf:
    a, sz, fo = cf
    for e in range(0, sz, 32):
        p = struct.unpack_from('<Q', data, fo+e+16)[0]
        for cand in (p, (p & 0xfffffffff) + base, (p & 0xfffffffff) + 0x180000000):
            if cand in targets:
                targets[a+e] = ('cfstring:'+targets[cand][0], '__cfstring')
print({hex(k):v for k,v in targets.items()})
# scan adrp/add pairs in __text
a, sz, fo = text
code = data[fo:fo+sz]
hits = []
for i in range(0, len(code)-8, 4):
    ins = struct.unpack_from('<I', code, i)[0]
    if ins & 0x9f000000 == 0x90000000:
        rd = ins & 31
        immlo = (ins >> 29) & 3; immhi = (ins >> 5) & 0x7ffff
        imm = ((immhi << 2) | immlo) << 12
        if imm & (1 << 32): imm -= (1 << 33)
        pc = a + i
        page = (pc & ~0xfff) + imm
        for j in (4, 8, 12):
            if i + j + 4 > len(code): break
            ins2 = struct.unpack_from('<I', code, i+j)[0]
            if ins2 & 0xffc00000 == 0x91000000 and (ins2 >> 5) & 31 == rd:
                t = page + ((ins2 >> 10) & 0xfff)
                if t in targets: hits.append((pc, targets[t][0]))
                break
for pc, nd in hits: print(hex(pc), nd)
