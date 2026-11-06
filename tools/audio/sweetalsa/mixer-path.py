#!/usr/bin/env python3
"""Resolve Android audio_route mixer paths into "NAME<TAB>VALUE" lines for `sweetalsa apply`.

  mixer-path.py BASE.xml [OVERLAY.xml ...] --defaults        the top-level <ctl> values (the HAL's start state)
  mixer-path.py BASE.xml [OVERLAY.xml ...] PATH [PATH ...]   the named paths in order, nested <path> references expanded

Later files override earlier ones (a path of the same name replaces the earlier one; top-level ctls are merged).
<ctl id="N"> (one value of a multi-value control) is printed as a comment: sweetalsa sets whole controls only.
The XML files come from the phone's vendor partition and stay out of git.
"""
import sys
import xml.etree.ElementTree as ET


def main():
    files = [a for a in sys.argv[1:] if a.endswith('.xml')]
    names = [a for a in sys.argv[1:] if not a.endswith('.xml')]
    if not files or not names:
        sys.exit(__doc__)
    roots = [ET.parse(f).getroot() for f in files]
    paths = {}
    for r in roots:
        for p in r:                                  # top-level paths only (nested <path> elements are references)
            if p.tag == 'path':
                paths[p.get('name')] = p

    def emit(name, value, idx):
        if idx is not None:
            print('# %s\t%s\t(id %s)' % (name, value, idx))
        else:
            print('%s\t%s' % (name, value))

    def expand(el, depth=0):
        if depth > 20:
            sys.exit('path nesting too deep')
        for c in el:
            if c.tag == 'ctl':
                emit(c.get('name'), c.get('value'), c.get('id'))
            elif c.tag == 'path':
                ref = c.get('name')
                if ref not in paths:
                    sys.exit('unknown path reference: %s' % ref)
                expand(paths[ref], depth + 1)

    for n in names:
        if n == '--defaults':
            seen, order = {}, []
            for r in roots:
                for c in r:
                    if c.tag == 'ctl':
                        k = (c.get('name'), c.get('id'))
                        if k not in seen:
                            order.append(k)
                        seen[k] = c.get('value')
            print('# defaults (%d controls)' % len(order))
            for k in order:
                emit(k[0], seen[k], k[1])
        else:
            if n not in paths:
                sys.exit('no path: %s' % n)
            print('# path %s' % n)
            expand(paths[n])


if __name__ == '__main__':
    main()
