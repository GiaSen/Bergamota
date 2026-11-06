#!/usr/bin/env python3
"""sbdis.py SPLIT_DYLIB MAP '-[Class sel]'...: disassemble ObjC methods of a dylib split out of the shared cache (ipsw macho
disass --force), printing branches, calls and loads, with objc_msgSend stubs and method calls named from MAP (objcmap.py)."""
import sys, re, subprocess, bisect
F = sys.argv[1]; mapf = sys.argv[2]; names = sys.argv[3:]
imps = []; stubs = {}
for l in open(mapf):
    a, n = l.split(' ', 1); a = int(a, 16); n = n.strip()
    (stubs.__setitem__(a, n[5:]) if n.startswith('stub:') else imps.append((a, n)))
imps.sort(); keys = [a for a, _ in imps]
for want in names:
    for i, (a, n) in enumerate(imps):
        if n == want:
            end = imps[i + 1][0]
            cnt = (end - a) // 4
            out = subprocess.run(['ipsw', 'macho', 'disass', F, '--vaddr', hex(a), '--count', str(cnt), '--no-color', '--force'],
                                 capture_output=True, text=True).stdout
            print('=====', n, hex(a), cnt, 'instructions')
            for l in out.splitlines():
                b = re.search(r'\bbl?\s+(0x[0-9a-f]+)', l)
                extra = ''
                if b:
                    t = int(b.group(1), 16)
                    if t in stubs: extra = ' -> ' + stubs[t]
                    else:
                        j = bisect.bisect_right(keys, t) - 1
                        if j >= 0 and imps[j][0] == t: extra = ' -> ' + imps[j][1]
                if re.search(r'bl?\s|cbz|cbnz|tbz|tbnz|b\.|ldr\s+[wx]\d+, \[x19|mov\s+w2|"|ret$', l):
                    print(l[:100] + extra)
