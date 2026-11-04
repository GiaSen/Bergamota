#!/usr/bin/env python3
"""Renegade: the audio stack's host clock, for a counter that is not Apple's 24 MHz one.

  timebase_cache.py CACHE_DIR [--hz 19200000] [--scan]          the dyld shared cache, in place (main + sub-caches)
  timebase_cache.py --file MACHO [--hz 19200000] [--scan]       one thin Mach-O (re-sign it after: pacstrip.py --sign)

iOS 26's CoreAudio and the libraries around it hard-code the host clock of Apple's chips: AudioGetHostClockFrequency()
returns the constant 24e6, host time <-> seconds conversions multiply by 1/24e6, and a few functions build 24000000 as
an immediate. The Mi 8's counter runs at 19.2 MHz (mach_timebase_info 625/12).

Used by the root build since 2026-11-04 (root_tweaks18.speaker, with RENEGADE_AMP_FW): a real output device
(SweetSpeaker.driver) clocked by mach_absolute_time at 400 ticks per frame read to the HAL, which computes 500 from the
24 MHz constant, as "host time is not consecutive": it re-anchored and overloaded about every 0.4 s and the sound broke up.
With the null device alone (2026-11-03) an A/B showed no difference, which is why it was not used before.

Inside the images listed in IMAGES only (cache) or the given file:
  * 8-byte doubles 24e6 and 1/24e6 in the non-executable __TEXT sections -> HZ and 1/HZ,
  * movz Rn,#0x3600 + movk Rn,#0x16e,lsl #16 (24000000) within 4 instructions of each other in __text -> HZ, same
    register, same two words (HZ must fit 32 bits),
then the cache files' page hashes are recomputed (pacstrip_cache.fix_signature). Values already equal to HZ are
counted as done: running it twice changes nothing. Other cache images holding the constants are reported, not touched.
"""
import argparse
import mmap
import os
import struct
import sys
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pacstrip  # noqa: E402
import pacstrip_cache as pc  # noqa: E402

APPLE_HZ = 24000000
# The audio stack: what audiomxd, mediaplaybackd and the apps' audio sessions run. Path substrings of cache images.
IMAGES = (
    '/CoreAudio.framework/CoreAudio', '/AudioToolbox.framework/AudioToolbox', '/AudioToolboxCore.framework/AudioToolboxCore',
    '/caulk.framework/caulk', '/AVFAudio.framework/AVFAudio', '/AudioToolbox.framework/libAudioDSP.dylib',
    '/AudioToolbox.framework/libEmbeddedSystemAUs.dylib', '/libAudioDSPCore.dylib', '/AudioDSPGraph.framework/AudioDSPGraph',
    '/VoiceProcessor.framework/VoiceProcessor', '/PHASE.framework/PHASE', '/CoreHaptics.framework/CoreHaptics',
    '/CoreMIDI.framework/CoreMIDI',
)


def sections(buf, off, translate):
    """[(segname, sectname, flags, start, end)] of the Mach-O header at buf[off]; translate(addr, size) -> (buf, start)"""
    magic, _, _, _, ncmds, _ = struct.unpack_from('<IiiIII', buf, off)
    assert magic == pacstrip.MH_MAGIC_64, 'not a 64-bit Mach-O'
    p, out = off + 32, []
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', buf, p)
        if cmd == pc.LC_SEGMENT_64:
            segname = bytes(buf[p + 8:p + 24]).split(b'\0')[0].decode()
            for i in range(struct.unpack_from('<I', buf, p + 64)[0]):
                so = p + 72 + 80 * i
                sectname = bytes(buf[so:so + 16]).split(b'\0')[0].decode()
                saddr, ssize, soff = struct.unpack_from('<QQI', buf, so + 32)
                flags = struct.unpack_from('<I', buf, so + 64)[0]
                if segname == '__TEXT' and ssize:
                    t = translate(saddr, ssize, soff)
                    if t:
                        out.append((segname, sectname, flags) + t)
        p += size
    return out


def patch_ranges(secs, hz, scan, stats):
    """Rewrite the constants in the given sections; returns {(buf, 4k page)} of changed bytes."""
    old_d = (struct.pack('<d', float(APPLE_HZ)), struct.pack('<d', 1.0 / APPLE_HZ))
    new_d = (struct.pack('<d', float(hz)), struct.pack('<d', 1.0 / hz))
    changed = set()
    for segname, sectname, flags, buf, start, end in secs:
        code = flags & (pacstrip.S_ATTR_PURE_INSTRUCTIONS | pacstrip.S_ATTR_SOME_INSTRUCTIONS)
        if not code:
            for o in range((start + 7) & ~7, end - 7, 8):
                v = bytes(buf[o:o + 8])
                for k in (0, 1):
                    if v == old_d[k]:
                        stats['double ' + ('hz' if k == 0 else '1/hz')] += 1
                        if not scan:
                            buf[o:o + 8] = new_d[k]
                            changed.add((id(buf), o >> 12))
                    elif v == new_d[k] and hz != APPLE_HZ:
                        stats['double done'] += 1
            continue
        if sectname != '__text':
            continue
        words = struct.unpack_from(f'<{(end - start) // 4}I', buf, start)
        for i, w in enumerate(words):
            # movk Rd, #imm16, lsl #16 (32 or 64 bit)
            if (w & 0x7fe00000) != 0x72a00000:
                continue
            hi = (w >> 5) & 0xffff
            if hi not in (APPLE_HZ >> 16, hz >> 16):
                continue
            rd = w & 31
            for j in range(max(0, i - 4), min(len(words), i + 5)):
                w2 = words[j]
                # movz Rd, #imm16 (lsl 0), same width and register
                if (w2 & 0x7fe00000) == 0x52800000 and (w2 & 31) == rd and (w2 >> 31) == (w >> 31):
                    lo = (w2 >> 5) & 0xffff
                    if (hi << 16 | lo) == APPLE_HZ:
                        stats['immediate'] += 1
                        if not scan:
                            nw = (w & ~(0xffff << 5)) | ((hz >> 16) << 5)
                            nw2 = (w2 & ~(0xffff << 5)) | ((hz & 0xffff) << 5)
                            struct.pack_into('<I', buf, start + 4 * i, nw)
                            struct.pack_into('<I', buf, start + 4 * j, nw2)
                            changed.add((id(buf), (start + 4 * i) >> 12))
                            changed.add((id(buf), (start + 4 * j) >> 12))
                    elif (hi << 16 | lo) == hz and hz != APPLE_HZ:
                        stats['immediate done'] += 1
                    break
    return changed


def do_cache(d, hz, scan):
    cache = pc.Cache(d)
    files = {}
    for fn in cache.files:          # writable maps of the same files, for the rewrite
        f = open(os.path.join(d, fn), 'rb' if scan else 'r+b')
        files[fn] = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ if scan else mmap.ACCESS_WRITE)
    by_id = {id(b): fn for fn, b in files.items()}
    changed = defaultdict(set)
    total = defaultdict(int)
    others = []
    for addr, path in cache.images():
        t = cache.translate(addr, 32)
        if not t:
            continue

        def tr(saddr, ssize, soff):
            t2 = cache.translate(saddr, ssize)
            return (files[t2[0]], t2[1], t2[1] + ssize) if t2 else None

        fn, off, _ = t
        stats = defaultdict(int)
        secs = sections(files[fn], off, tr)
        if any(s in path for s in IMAGES):
            for b, page in patch_ranges(secs, hz, scan, stats):
                changed[by_id[b]].add(page)
            if stats:
                print(f'{path}: ' + ', '.join(f'{k} {v}' for k, v in sorted(stats.items())))
                for k, v in stats.items():
                    total[k] += v
        else:
            patch_ranges(secs, hz, True, stats)
            if stats.get('double hz') or stats.get('double 1/hz') or stats.get('immediate'):
                others.append(path)
    for b in files.values():
        if not scan:
            b.flush()
        b.close()
    for fn, pages in sorted(changed.items()):
        n, note = pc.fix_signature(os.path.join(d, fn), pages)
        print(f'{fn}: {len(pages)} pages changed, {n} page hashes recomputed ({note})')
    print('total: ' + (', '.join(f'{k} {v}' for k, v in sorted(total.items())) or 'nothing'))
    if others:
        print(f'not touched, also hold the constants ({len(others)}): ' + ', '.join(os.path.basename(p) for p in others))


def do_file(path, hz, scan):
    f = open(path, 'rb' if scan else 'r+b')
    b = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ if scan else mmap.ACCESS_WRITE)
    stats = defaultdict(int)
    secs = sections(b, 0, lambda saddr, ssize, soff: (b, soff, soff + ssize))
    patch_ranges(secs, hz, scan, stats)
    if not scan:
        b.flush()
    b.close()
    print(f'{path}: ' + (', '.join(f'{k} {v}' for k, v in sorted(stats.items())) or 'nothing'))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('cache_dir', nargs='?')
    ap.add_argument('--file', help='a thin Mach-O instead of the cache')
    ap.add_argument('--hz', type=int, default=19200000, help='the counter frequency (mach_timebase_info: 1e9 * denom / numer)')
    ap.add_argument('--scan', action='store_true', help='report only')
    a = ap.parse_args()
    assert 0 < a.hz < 1 << 32
    if a.file:
        do_file(a.file, a.hz, a.scan)
    elif a.cache_dir:
        do_cache(a.cache_dir, a.hz, a.scan)
    else:
        ap.error('CACHE_DIR or --file')


if __name__ == '__main__':
    main()
