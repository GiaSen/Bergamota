#!/usr/bin/env python3
"""TI TAS2557 firmware (the Mi 8's /vendor/firmware/tas2557_uCDSP_*.bin): list it, or flatten one program +
configuration into the register writes the amp needs, as TI's driver (tas2557-core.c) plays them.

  tas2557fw.py FW.bin                                   programs, configurations, PLLs, calibrations
  tas2557fw.py FW.bin --script id OUT                   reset, chip id (B0P0R3) and safe guard (R37, 0x5a)
  tas2557fw.py FW.bin --script load OUT PROGRAM CONFIG  tas2557_set_program(): resets, defaults, program, PLL, coefficients
  tas2557fw.py FW.bin --script on OUT GAIN              tas2557_enable(true): startup, unmute, DAC gain (0..15)
  tas2557fw.py FW.bin --script off OUT                  tas2557_enable(false): the shutdown sequence
  tas2557fw.py FW.bin --script status OUT               reads: flags, power, gain, mute, id

A script is what kern.sweet_audio_i2c plays (bsd/dev/dipper_audio.c; tools/sweetnet/sweeti2c on the phone): 01 addr n
data (write), 02 addr reg n (read), 03 level (reset pin), 04 ms (2 bytes), 05 addr reg mask value (read-modify-write).

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


ADDR = 0x4c
# tas2557-core.c tables, as (book, page, reg, value) or ('us', N)
DEFAULT = [(0, 0, 21, 0x05), (0, 0, 45, 0x21), (0, 0, 46, 0x21), (0, 0, 37, 0x5a)]
IRQ_CONFIG = [(0, 1, 106, 0x71), (0, 1, 108, 0x11), (0, 1, 109, 0x11), (0, 1, 110, 0x11), (0, 1, 111, 0x01),
              (0, 1, 64, 0x07), (0, 1, 114, 0x80)]
STARTUP = [(0, 1, 77, 0x15), (0, 1, 61, 0x01), (0, 1, 62, 0x01), (0, 0, 5, 0xa0), (0, 0, 5, 0xa3), (0, 0, 4, 0xf8),
           ('us', 2000), (0, 0, 44, 0x2b)]
UNMUTE = [(0, 0, 7, 0x00), (100, 0, 7, 0x00)]
SHUTDOWN = [(0, 0, 44, 0x00), (100, 0, 7, 0x01), ('us', 10000), (0, 0, 7, 0x03), (0, 0, 4, 0x60), ('us', 2000),
            (0, 0, 5, 0x00), (0, 0, 4, 0x00), (0, 1, 61, 0x00), (0, 1, 62, 0x00), (0, 1, 77, 0x00)]


class Script:
    """the ops, with TI's book/page switching (tas2557_change_book_page): page 0 reg 127 = book, reg 0 = page"""

    def __init__(self):
        self.b = bytearray()
        self.book = self.page = None
        self.notes = []

    def bp(self, book, page):
        if self.book != book:
            self.raw_write(0, [0])
            self.raw_write(127, [book])
            self.book, self.page = book, 0
            if page:
                self.raw_write(0, [page])
                self.page = page
        elif self.page != page:
            self.raw_write(0, [page])
            self.page = page

    def raw_write(self, reg, data):
        assert len(data) < 255
        self.b += bytes([1, ADDR, 1 + len(data), reg]) + bytes(data)

    def write(self, book, page, reg, data):
        self.bp(book, page)
        self.raw_write(reg, data if isinstance(data, (list, bytes, bytearray)) else [data])

    def read(self, book, page, reg, n=1, what=''):
        self.bp(book, page)
        self.b += bytes([2, ADDR, reg, n])
        self.notes.append(f'{what or f"B{book}P{page}R{reg}"} ({n})')

    def update(self, book, page, reg, mask, value):
        self.bp(book, page)
        self.b += bytes([5, ADDR, reg, mask, value])

    def reset_pin(self, level):
        self.b += bytes([3, 1 if level else 0])

    def sleep_ms(self, ms):
        ms = max(1, int(ms))
        self.b += bytes([4, ms & 0xff, ms >> 8])

    def table(self, rows):
        for r in rows:
            if r[0] == 'us':
                self.sleep_ms((r[1] + 999) // 1000)
            else:
                self.write(*r)

    def hw_reset(self):
        """tas2557_hw_reset: low 5 ms, high 2 ms; the book/page cache is gone"""
        self.reset_pin(0)
        self.sleep_ms(5)
        self.reset_pin(1)
        self.sleep_ms(2)
        self.book = self.page = None

    def block(self, blk, label):
        """tas2557_load_block: 4-byte commands book page reg value; reg 0x81 = sleep (book << 8 | page) ms;
        reg 0x85 = burst of (book << 8 | page) bytes to the register in the next command, data from its 4th byte"""
        d = blk['data']
        if blk['chk'] and blk['chk'][0]:
            self.write(0, 0, 33, 1)                     # TAS2557_CRC_RESET_REG
        n, i = len(d) // 4, 0
        while i < n:
            w = d[4 * i:4 * i + 4]
            i += 1
            if w[2] <= 0x7f:
                self.write(w[0], w[1], w[2], w[3])
            elif w[2] == 0x81:
                self.sleep_ms((w[0] << 8) | w[1])
            elif w[2] == 0x85:
                length = (w[0] << 8) | w[1]
                nxt = d[4 * i:]
                book, page, reg = nxt[0], nxt[1], nxt[2]
                data = nxt[3:3 + length] if length > 1 else nxt[3:4]
                for k in range(0, len(data), 240):      # one I2C write each, the register auto-increments
                    self.write(book, page, reg + k, data[k:k + 240])
                i += 1 + (((length - 2) // 4) + 1 if length >= 2 else 0)
            else:
                raise ValueError(f'{label}: unknown command {w.hex()}')
        if blk['chk'] and blk['chk'][0]:
            self.read(0, 0, 32, 1, f'{label} PRAM checksum, firmware says {blk["chk"][1]:#04x}')


def script(kind, fw, args):
    h, plls, progs, cfgs, cals = fw
    s = Script()
    if kind == 'id':
        s.hw_reset()
        s.write(0, 0, 1, 1)                             # TAS2557_SW_RESET_REG
        s.book = s.page = None
        s.sleep_ms(1)
        s.read(0, 0, 3, 1, 'PGID (0xa0 = PG2.1, 0x80 = PG1.0)')
        s.read(0, 0, 37, 1, 'safe guard (0x5a after defaults only)')
    elif kind == 'load':
        prog, cfg = int(args[0]), int(args[1])
        p, c = progs[prog], cfgs[cfg]
        assert c['program'] == prog, f'configuration {cfg} is for program {c["program"]}'
        s.hw_reset()
        s.write(0, 0, 1, 1)
        s.book = s.page = None
        s.sleep_ms(1)
        s.table(DEFAULT)                                # tas2557_load_default
        s.table(IRQ_CONFIG)                             # load_platdata: configIRQ (ti,irq-gpio is set)
        s.update(0, 1, 1, 0x18, 0 << 3)                 # set_bit_rate(16): ASI1_DAC_FORMAT
        s.update(0, 1, 1, 0x01, 0x01)                   # DOUT tri-state for extra BCLKs
        for blk in p['data']['blocks']:
            if blk['type'] == 0x01:                     # PGM_DEV_A
                s.block(blk, f'program {prog}')
        s.read(0, 0, 6, 1, 'SPK_CTRL after the program (DAC gain in bits 6:3)')
        s.block(plls[c['pll']]['block'], f'PLL {c["pll"]}')
        for t in (0x04, 0x03):                          # CFG_PRE_DEV_A, then CFG_COEFF_DEV_A
            for blk in c['data']['blocks']:
                if blk['type'] == t:
                    s.block(blk, f'config {cfg} {BLOCK_NAMES[t]}')
        s.read(0, 0, 37, 1, 'safe guard (0x5a)')
    elif kind == 'on':
        gain = int(args[0])
        assert 0 <= gain <= 15
        s.read(0, 0, 104, 1, 'FLAGS_1 (cleared by the read)')
        s.read(0, 0, 108, 1, 'FLAGS_2')
        s.table(STARTUP)
        s.update(0, 0, 6, 0x78, gain << 3)              # tas2557_set_DAC_gain
        s.table(UNMUTE)
        s.read(0, 0, 4, 2, 'POWER_CTRL1/2')
        s.read(0, 0, 6, 1, 'SPK_CTRL')
    elif kind == 'off':
        s.table(SHUTDOWN)
        s.read(0, 0, 4, 2, 'POWER_CTRL1/2')
    elif kind == 'status':
        s.read(0, 0, 3, 1, 'PGID')
        s.read(0, 0, 4, 2, 'POWER_CTRL1/2')
        s.read(0, 0, 6, 2, 'SPK_CTRL, MUTE')
        s.read(0, 0, 37, 1, 'safe guard')
        s.read(0, 0, 104, 1, 'FLAGS_1')
        s.read(0, 0, 108, 1, 'FLAGS_2')
        s.read(0, 1, 1, 1, 'ASI1_DAC_FORMAT')
    else:
        raise SystemExit(f'unknown script {kind}')
    return s


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('fw')
    ap.add_argument('--script', nargs='+', metavar=('KIND OUT', 'ARG'))
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
    if a.script:
        kind, out, args = a.script[0], a.script[1], a.script[2:]
        sc = script(kind, (h, plls, progs, cfgs, cals), args)
        open(out, 'wb').write(sc.b)
        print(f'{out}: {len(sc.b)} bytes; reads, in order: ' + '; '.join(sc.notes))


if __name__ == '__main__':
    main()
