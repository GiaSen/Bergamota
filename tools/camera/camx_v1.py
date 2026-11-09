#!/usr/bin/env python3
"""Reader for old CamX sensor module files ("ParameterParser V1.1.0", e.g. the Mi 8's
/vendor/lib/camera/com.qti.sensormodule.imx363.bin). Reads the file as data; prints what it finds and can write the
register sequence of one mode as a small binary blob for the kernel's kern.sweet_cam_seq (xnu 3077+).

The module files are the phone vendor's: take them from your own vendor partition and keep them and anything made from
them out of git (NOTES "CAMERA" bullets).

Layout, as read here (little endian, packed):
  0x98: (entry table offset, entry count); entries of (id, offset, size)
  entry 0: symbol records of 64 bytes {id, name[32], kind, w1, w2, w3, a, b}: kind 1 = a top-level structure at pool
           offset b; kind 0 = the data of a pointer field (an array) at pool offset b, found by its symbol id
  entry 1: the pool (the packed structures, then the arrays they point to)
  register setting (40 bytes): slaveAddrExists, slaveAddrID, registerAddr, registerDataCount, registerDataID,
           regAddrType (1 byte, 2 word), regDataType, operation (0 write, else see the file), delayUsExists, delayUsID
  resolution (mode) record (112 bytes): +0x04 stream configuration count, +0x08 its id, +0x0c line length (pixel
           clocks), +0x10 frame length (lines), +0x14/+0x18 minimum horizontal/vertical blanking, +0x1c output pixel
           clock (Hz), +0x20/+0x24 horizontal/vertical binning, +0x28 frame rate (double), +0x30 4 in every mode
           here (taken as the lane count), +0x44 integration info id, +0x48 register setting count, +0x4c its id
  stream configuration (32 bytes): virtual channel, data type, x, y, width, height, bit width, type (1 image, 2 PDAF)

  python3 -I tools/camera/camx_v1.py MODULE.bin                      # summary: modes, init and other settings
  python3 -I tools/camera/camx_v1.py MODULE.bin --dump               # every register setting too
  python3 -I tools/camera/camx_v1.py MODULE.bin --seq MODE out.bin   # init + mode MODE as a kernel sequence

Sequence blob (8-byte records, little endian): u16 register, u8 op, u8 0, u32 value; op 0 = write 8 bits, 1 = write
16 bits, 2 = wait value microseconds. The kernel starts streaming (0x0100 = 1) itself.
"""
import argparse
import struct
import sys

REG_SIZE = 40
MODE_SIZE = 112
STREAM_SIZE = 32


class Module:
    def __init__(self, path):
        self.d = open(path, 'rb').read()
        toff, tcnt = struct.unpack_from('<2I', self.d, 0x98)
        ents = [struct.unpack_from('<3I', self.d, toff + 12 * i) for i in range(tcnt)]
        symoff, symsize = ents[0][1], ents[0][2]
        self.pool = ents[1][1]
        self.pool_size = ents[1][2]
        self.syms = {}       # id -> (name, kind, pool offset)
        self.order = []
        for at in range(symoff, symoff + symsize - 63, 64):
            sid = struct.unpack_from('<I', self.d, at)[0]
            name = self.d[at + 4:at + 36].split(b'\0')[0].decode('latin1')
            kind, _w1, _w2, _w3, _a, b = struct.unpack_from('<6I', self.d, at + 36)
            self.syms[sid] = (name, kind, b)
            self.order.append(sid)

    def u32(self, off):
        return struct.unpack_from('<I', self.d, self.pool + off)[0]

    def at(self, sid):
        return self.syms[sid][2]

    def top(self, name):
        for sid in self.order:
            n, k, b = self.syms[sid]
            if k == 1 and n == name:
                return b
        return None

    def regs(self, count, sid):
        """a register setting list -> [(addr, [data...], addr_type, data_type, op, delay_us)]"""
        out = []
        base = self.at(sid)
        for i in range(count):
            w = struct.unpack_from('<10I', self.d, self.pool + base + REG_SIZE * i)
            _sae, _said, addr, dcnt, did, at, dt, op, due, duid = w
            data = [self.u32(self.at(did) + 4 * k) for k in range(dcnt)] if dcnt else []
            delay = self.u32(self.at(duid)) if due and duid in self.syms else 0   # S5K3M3: a delay flag with no symbol (id 0)
            out.append((addr, data, at, dt, op, delay))
        return out

    def modes(self):
        """the resolution records: found as the array of the kind-0 symbol named resolutionData"""
        rid = next(s for s in self.order if self.syms[s][0] == 'resolutionData')
        info = self.at(rid) - 12          # resolutionInfo: (?, count, id)
        _x, count, sid = struct.unpack_from('<3I', self.d, self.pool + info)
        if sid != rid:
            raise SystemExit('resolutionInfo does not point at resolutionData (%d != %d)' % (sid, rid))
        out = []
        for i in range(count):
            o = self.pool + self.at(rid) + MODE_SIZE * i
            m = {
                'index': i,
                'line_length': struct.unpack_from('<I', self.d, o + 0x0c)[0],
                'frame_length': struct.unpack_from('<I', self.d, o + 0x10)[0],
                'min_hblank': struct.unpack_from('<I', self.d, o + 0x14)[0],
                'min_vblank': struct.unpack_from('<I', self.d, o + 0x18)[0],
                'output_pixel_clock': struct.unpack_from('<I', self.d, o + 0x1c)[0],
                'binning': struct.unpack_from('<2I', self.d, o + 0x20),
                'fps': struct.unpack_from('<d', self.d, o + 0x28)[0],
                'lanes': struct.unpack_from('<I', self.d, o + 0x30)[0],
            }
            scount, ssid = struct.unpack_from('<2I', self.d, o + 0x04)
            m['streams'] = []
            for k in range(scount):
                vc, dt, x, y, w, h, bits, typ = struct.unpack_from('<8I', self.d, self.pool + self.at(ssid) + STREAM_SIZE * k)
                m['streams'].append({'vc': vc, 'dt': dt, 'x': x, 'y': y, 'width': w, 'height': h, 'bits': bits, 'type': typ})
            rcount, rsid = struct.unpack_from('<2I', self.d, o + 0x48)
            m['regs'] = self.regs(rcount, rsid)
            out.append(m)
        return out

    def setting_lists(self):
        """every (count, id) pair in the pool that points at a 'regSetting' symbol: [(pool offset of the pair, count, id)]"""
        reg_ids = {s for s in self.order if self.syms[s][0] == 'regSetting'}
        found = []
        for off in range(0, self.pool_size - 8):
            cnt, sid = struct.unpack_from('<2I', self.d, self.pool + off)
            if sid in reg_ids and 0 < cnt < 4096:
                try:
                    self.regs(cnt, sid)
                except (KeyError, struct.error):
                    continue        # a (count, id) look-alike whose data does not resolve (S5K3M3 file)
                found.append((off, cnt, sid))
        return found


def fmt_regs(regs, limit=None):
    lines = []
    for i, (addr, data, at, dt, op, delay) in enumerate(regs):
        if limit is not None and i >= limit:
            lines.append('    ... %d more' % (len(regs) - limit))
            break
        vals = ' '.join('%#x' % v for v in data)
        lines.append('    %#06x = %s%s%s' % (addr, vals, '' if op == 0 else ' (op %d)' % op,
                                            ' wait %d us' % delay if delay else ''))
    return '\n'.join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('module')
    ap.add_argument('--dump', action='store_true')
    ap.add_argument('--seq', nargs=2, metavar=('MODE', 'OUT'))
    a = ap.parse_args()
    m = Module(a.module)
    modes = m.modes()
    mode_ids = set()
    for md in modes:
        img = [s for s in md['streams'] if s['type'] == 1]
        s = img[0] if img else md['streams'][0]
        per_lane = md['output_pixel_clock'] * s['bits'] / md['lanes'] if md['lanes'] else 0
        print('mode %d: %dx%d dt %#x %d bits, %.2f fps, %d lanes, binning %dx%d, line %d x frame %d, output pixel clock %d'
              ' (x bits / lanes = %.3f Gb/s a lane), %d register writes, %d streams' % (
                  md['index'], s['width'], s['height'], s['dt'], s['bits'], md['fps'], md['lanes'], md['binning'][0],
                  md['binning'][1], md['line_length'], md['frame_length'], md['output_pixel_clock'], per_lane / 1e9,
                  len(md['regs']), len(md['streams'])))
        for st in md['streams']:
            print('    stream vc %d dt %#x %dx%d at %d,%d %d bits type %d' % (st['vc'], st['dt'], st['width'], st['height'],
                                                                         st['x'], st['y'], st['bits'], st['type']))
        if a.dump:
            print(fmt_regs(md['regs']))
    rid = next(s for s in m.order if m.syms[s][0] == 'resolutionData')
    for off, cnt, sid in m.setting_lists():
        regs = m.regs(cnt, sid)
        first = regs[0] if regs else None
        print('settings at pool %#x: %d writes (symbol %d)%s' % (off, cnt, sid,
              '' if not first else ', first %#06x = %s' % (first[0], ' '.join('%#x' % v for v in first[1]))))
        if a.dump or cnt <= 4:
            print(fmt_regs(regs, None if a.dump else 4))
    if a.seq:
        idx = int(a.seq[0])
        init = None
        for off, cnt, sid in m.setting_lists():
            if m.syms[sid - 1][0] == 'initSettings' or (sid - 1 in m.syms and m.syms[sid - 1][0] == 'initSettings'):
                init = m.regs(cnt, sid)
        if init is None:
            sys.exit('no initSettings found')
        out = bytearray()
        for addr, data, at, dt, op, delay in init + modes[idx]['regs']:
            if addr == 0x0100 and op == 0:
                continue        # mode_select (stream on/off) is the kernel's: its sequence loader refuses it
            if op != 0:
                sys.exit('register %#x: operation %d not handled' % (addr, op))
            if at != 2 or dt not in (1, 2):
                sys.exit('register %#x: address type %d / data type %d not handled' % (addr, at, dt))
            for k, v in enumerate(data):
                out += struct.pack('<HBBI', addr + k * dt, 0 if dt == 1 else 1, 0, v)
            if delay:
                out += struct.pack('<HBBI', 0, 2, 0, delay)
        open(a.seq[1], 'wb').write(out)
        print('sequence: %d init + %d mode %d writes -> %s (%d records)' % (len(init), len(modes[idx]['regs']), idx, a.seq[1],
                                                                       len(out) // 8))
    _ = rid


if __name__ == '__main__':
    main()
