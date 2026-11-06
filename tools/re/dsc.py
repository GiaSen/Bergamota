"""Minimal dyld shared cache reader: map addresses across subcaches, read strings/pointers.
Pointers in the cache: low 36 bits = offset from the cache base 0x180000000 (rebase), auth/high bits ignored."""
import glob, os, struct
BASE = 0x180000000
class DSC:
    def __init__(self, d):
        self.maps = []
        for f in sorted(glob.glob(os.path.join(d, 'dyld_shared_cache_arm64e*'))):
            if f.endswith('.map') or f.endswith('.symbols'):
                continue
            with open(f, 'rb') as fh:
                h = fh.read(0x200)
                if not h.startswith(b'dyld_v1'):
                    continue
                mo, mc = struct.unpack_from('<II', h, 0x10)
                fh.seek(mo)
                for i in range(mc):
                    a, sz, fo, mx, ini = struct.unpack('<QQQII', fh.read(32))
                    self.maps.append((a, sz, fo, f))
        self.files = {}
    def _fh(self, f):
        if f not in self.files:
            self.files[f] = open(f, 'rb')
        return self.files[f]
    def read(self, a, n):
        for ma, sz, fo, f in self.maps:
            if ma <= a < ma + sz:
                fh = self._fh(f); fh.seek(fo + a - ma); return fh.read(n)
        return None
    def ptr(self, a):
        b = self.read(a, 8)
        if not b: return None
        p = struct.unpack('<Q', b)[0]
        return (p & 0xfffffffff) + BASE
    def cstr(self, a, n=200):
        b = self.read(a, n)
        return b.split(b'\0')[0].decode(errors='replace') if b else None
    def u32(self, a):
        b = self.read(a, 4); return struct.unpack('<I', b)[0] if b else None
    def i32(self, a):
        b = self.read(a, 4); return struct.unpack('<i', b)[0] if b else None
