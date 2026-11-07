#!/usr/bin/env python3
"""Set MobileGestalt answers through the cache's CacheExtra overrides.

  mg-override.py IN.plist OUT.plist QUESTION=VALUE [QUESTION=VALUE ...]

IN is the phone's /private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/
Caches/com.apple.MobileGestalt.plist. A CacheExtra entry, keyed by base64(md5("MGCopyAnswer" + question))[:22],
answers MGCopyAnswer(question) in place of the computed value (NOTES.md: the arm64e fix for Control Center).
VALUE: 1/0/true/false (a boolean), an integer, or text. QUESTION=- removes the override.
"""
import base64, hashlib, plistlib, sys


def key(question):
    return base64.b64encode(hashlib.md5(('MGCopyAnswer' + question).encode()).digest()).decode()[:22]


def value(text):
    low = text.lower()
    if low in ('1', 'true', 'yes'):
        return True
    if low in ('0', 'false', 'no'):
        return False
    try:
        return int(text, 0)
    except ValueError:
        return text


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    src, dst = sys.argv[1], sys.argv[2]
    with open(src, 'rb') as f:
        mg = plistlib.load(f)
    extra = mg.setdefault('CacheExtra', {})
    for arg in sys.argv[3:]:
        q, _, v = arg.partition('=')
        k = key(q)
        if v == '-':
            extra.pop(k, None)
            print(f'{q} ({k}): override removed')
        else:
            extra[k] = value(v)
            print(f'{q} ({k}) = {extra[k]!r}')
    with open(dst, 'wb') as f:
        plistlib.dump(mg, f, fmt=plistlib.FMT_BINARY)


if __name__ == '__main__':
    main()
