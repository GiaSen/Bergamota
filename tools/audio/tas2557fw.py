#!/usr/bin/env python3
"""TI TAS2557 firmware (the Mi 8's /vendor/firmware/tas2557_uCDSP_*.bin): list it, or flatten one program +
configuration into the register writes the amp needs, as TI's driver (tas2557-core.c) plays them.

  tas2557fw.py FW.bin                              programs, configurations, PLLs, calibrations
  tas2557fw.py FW.bin --flat PROGRAM CONFIG OUT    the writes for that pair, as 'book page reg value' lines (and
                                                   'delay_us N'), in the order tas2557_set_program() sends them

The firmware is Xiaomi's/TI's and stays out of git; this only reads it.

Format (fw_parse_*): big-endian. Header: magic '5552', size, checksum, PPC version, FW version, driver version,
timestamp, 64-byte DDC name, description (NUL-terminated), device family (0), device (2 = TAS2557 dual mono).
Then PLLs, programs, configurations, calibrations; each has a 64-byte name and a NUL-terminated description. A data
item is a list of blocks: type (4), [4 checksum bytes if driver version >= 0x200], command count (4), commands
(4 bytes each).
"""
import argparse
import struct
import sys

CRCCHK, CONFDEV, MTPLLSRC, CFGDEV_NONCRC = 0x200, 0x300, 0x400, 0x101
UDELAY, MDELAY = 0xfffffffe, 0xfffffffd
BLOCK_NAMES = {0x00: 'PLL', 0x0d: 'PGM_ALL', 0x01: 'PGM_DEV_A', 0x08: 'PGM_DEV_B', 0x03: 'CFG_COEFF_DEV_A',
               0x0a: 'CFG_COEFF_DEV_B', 0x04: 'CFG_PRE_DEV_A', 0x0b: 'CFG_PRE_DEV_B', 0x05: 'CFG_POST',
               0x06: 'CFG_POST_POWER'}
APP_MODES = {0: 'ROM1', 1: 'ROM2', 2: 'TUNING', 3: 'ROM1_96KHZ', 4: 'ROM2_96KHZ', 5: 'RAM'}


class R:
    def __init__(self, b):
        self.b, self.p = b, 0

    def u8(self):
        v = self.b[self.p]
        self.p += 1
        return v

    def u16(self):
        v = struct.unpack_from('>H', self.b, self.p)[0]
        self.p += 2
        return v

    def u32(self):
        v = struct.unpack_from('>I', self.b, self.p)[0]
        self.p += 4
        return v

    def name(self):
        v = self.b[self.p:self.p + 64].split(b'\0')[0].decode('latin-1')
        self.p += 64
        return v

    def cstr(self):
        e = self.b.index(b'\0', self.p)
        v = self.b[self.p:e].decode('latin-1')
        self.p = e + 1
        return v


def block(r, drv):
    t = r.u32()
    chk = (r.u8(), r.u8(), r.u8(), r.u8()) if drv >= CRCCHK else None
    n = r.u32()
    data = r.b[r.p:r.p + 4 * n]
    r.p += 4 * n
    return {'type': t, 'chk': chk, 'data': data}


def data(r, drv):
    d = {'name': r.name(), 'desc': r.cstr()}
    d['blocks'] = [block(r, drv) for _ in range(r.u16())]
    return d


def parse(b):
    r = R(b)
    assert b[:4] == b'5552', 'not a TAS2557 firmware (magic)'
    r.p = 4
    h = dict(zip(('size', 'checksum', 'ppc', 'fw', 'driver', 'time'), (r.u32() for _ in range(6))))
    h['ddc'], h['desc'] = r.name(), r.cstr()
    h['family'], h['device'] = r.u32(), r.u32()
    assert h['family'] == 0 and h['device'] == 2, 'not a TAS2557 dual-mono firmware'
    drv = h['driver']
    plls = []
    for _ in range(r.u16()):
        plls.append({'name': r.name(), 'desc': r.cstr(), 'block': block(r, drv)})
    progs = []
    for _ in range(r.u16()):
        p = {'name': r.name(), 'desc': r.cstr(), 'mode': r.u8(), 'boost': r.u16()}
        p['data'] = data(r, drv)
        progs.append(p)
    cfgs = []
    for _ in range(r.u16()):
        c = {'name': r.name(), 'desc': r.cstr()}
        c['devices'] = r.u16() if drv >= CONFDEV or (CFGDEV_NONCRC <= drv < CRCCHK) else 1
        c['program'], c['pll'], c['rate'] = r.u8(), r.u8(), r.u32()
        if drv >= MTPLLSRC:
            c['pllsrc'], c['pllsrc_rate'] = r.u8(), r.u32()
        c['data'] = data(r, drv)
        cfgs.append(c)
    cals = []
    if r.p < len(b):
        for _ in range(r.u16()):
            c = {'name': r.name(), 'desc': r.cstr(), 'program': r.u8(), 'config': r.u8()}
            c['data'] = data(r, drv)
            cals.append(c)
    return h, plls, progs, cfgs, cals


def commands(blk):
    """tas2557_load_block: 4-byte commands [book? page reg value]; see the driver for the burst form"""
    d = blk['data']
    i, out = 0, []
    n = len(d) // 4
    while i < n:
        w = d[4 * i:4 * i + 4]
        if w[2] == 0x85:        # burst: w[0] book, w[1] page, w[3] first reg; count in the next word's ... (see load_block)
            out.append(('burst?', w.hex()))
        out.append(tuple(w))
        i += 1
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('fw')
    ap.add_argument('--flat', nargs=3, metavar=('PROGRAM', 'CONFIG', 'OUT'))
    a = ap.parse_args()
    b = open(a.fw, 'rb').read()
    h, plls, progs, cfgs, cals = parse(b)
    print(f"size {h['size']} (file {len(b)}), PPC {h['ppc']:#x}, FW {h['fw']:#x}, driver {h['driver']:#x}, "
          f"DDC '{h['ddc']}'")
    for i, p in enumerate(plls):
        print(f"PLL {i}: '{p['name']}' {BLOCK_NAMES.get(p['block']['type'], hex(p['block']['type']))} "
              f"{len(p['block']['data']) // 4} commands")
    for i, p in enumerate(progs):
        bl = ', '.join(f"{BLOCK_NAMES.get(x['type'], hex(x['type']))}:{len(x['data']) // 4}" for x in p['data']['blocks'])
        print(f"program {i}: '{p['name']}' mode {APP_MODES.get(p['mode'], p['mode'])} boost {p['boost']}: {bl}")
    for i, c in enumerate(cfgs):
        bl = ', '.join(f"{BLOCK_NAMES.get(x['type'], hex(x['type']))}:{len(x['data']) // 4}" for x in c['data']['blocks'])
        extra = f", pll src {c['pllsrc']} at {c['pllsrc_rate']} Hz" if 'pllsrc' in c else ''
        print(f"config {i}: '{c['name']}' program {c['program']} PLL {c['pll']} {c['rate']} Hz{extra}: {bl}")
    for i, c in enumerate(cals):
        print(f"calibration {i}: '{c['name']}' program {c['program']} config {c['config']}")
    if a.flat:
        sys.exit('--flat: not written yet')


if __name__ == '__main__':
    main()
