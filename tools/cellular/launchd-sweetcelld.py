#!/usr/bin/env python3
"""Put sweetcelld in CommCenter's place in the phone's launchd.plist.

  launchd-sweetcelld.py IN.plist OUT.plist

IN is /System/Library/xpc/launchd.plist (read by launchd as booted with launchd_unsecure_cache=1). The job labelled
com.apple.CommCenter (on the Mi 8 the Wi-Fi-only com.apple.CommCenter-noncellular.plist, which launchd picked without a
baseband) is taken out; a job for /usr/local/bin/sweetcelld is put in with the two Mach services CoreTelephony's clients
use (com.apple.commcenter.coretelephony.xpc, com.apple.commcenter.xpc), as IOS-26-Hot's make-ios26-overlay.py does for
its cellulard. Nothing else changes. Undo: put the saved IN back.
"""
import plistlib, sys

# The label is CommCenter's: the jetsam limits are per label (com.apple.jetsamproperties.N104.plist gives com.apple.CommCenter
# 36 MB active / 27 MB inactive, priority 190); under a label of its own sweetcelld got the small default and was killed for
# its memory (jetsam reason 7, per-process limit) 10 s after a restart, 2026-11-07.
JOB_PATH = '/System/Library/LaunchDaemons/com.apple.CommCenter-sweetcelld.plist'
JOB = {
    'Label': 'com.apple.CommCenter',
    'ProgramArguments': ['/usr/local/bin/sweetcelld'],
    'MachServices': {
        'com.apple.commcenter.coretelephony.xpc': True,
        'com.apple.commcenter.xpc': True,
    },
    'KeepAlive': True,
    'RunAtLoad': True,
    'UserName': 'root',
    'POSIXSpawnType': 'Interactive',
    'StandardOutPath': '/private/var/sweetcell/sweetcelld.stdout',
    'StandardErrorPath': '/private/var/sweetcell/sweetcelld.stdout',
    'ThrottleInterval': 10,
}


def main():
    src, dst = sys.argv[1], sys.argv[2]
    with open(src, 'rb') as f:
        plist = plistlib.load(f)
    daemons = plist['LaunchDaemons']
    gone = [path for path, job in daemons.items() if job.get('Label') == 'com.apple.CommCenter']
    for path in gone:
        del daemons[path]
    taken = {s for job in daemons.values() for s in job.get('MachServices', {})} & set(JOB['MachServices'])
    if taken:
        sys.exit(f'another job still has {sorted(taken)}')
    daemons[JOB_PATH] = JOB
    with open(dst, 'wb') as f:
        plistlib.dump(plist, f, fmt=plistlib.FMT_BINARY)
    print(f'{dst}: removed {gone or "no CommCenter job"}, added sweetcelld as {JOB["Label"]}')


if __name__ == '__main__':
    main()
