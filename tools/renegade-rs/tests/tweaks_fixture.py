#!/usr/bin/env python3
"""A synthetic iOS root for the tweaks comparison (our own content only), and the Python side of the comparison.

  tweaks_fixture.py make ROOT TOOLS            build the root and two fake tool binaries
  tweaks_fixture.py run ROOT TOOLS [--quiet]   root_tweaks18.py's functions (base() + auto() order, the ported ones)
"""
import datetime, os, plistlib, sys

HERE = os.path.dirname(os.path.abspath(__file__))
RENEGADE = os.path.normpath(os.path.join(HERE, '..', '..', 'renegade'))


def w(root, rel, data, mode=0o644):
    p = os.path.join(root, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, 'wb') as f:
        f.write(data)
    os.chmod(p, mode)


def make(root, tools):
    shared = {'SuccessfulExit': False, 'Crashed': True}          # one object in two jobs: a shared ref in the bplist
    jobs = {
        '/System/Library/LaunchDaemons/com.apple.foo.plist': {'Label': 'com.apple.foo', '_PanicOnCrash': True, 'KeepAlive': shared,
                                                              'ProgramArguments': ['/usr/libexec/foo', '-v'], 'Nice': -5, 'Big': 1 << 40},
        '/System/Library/LaunchDaemons/com.apple.bar.plist': {'Label': 'com.apple.bar', 'KeepAlive': shared, 'Ratio': 0.25, 'Zero': 0.0},
        '/System/Library/LaunchDaemons/com.apple.CommCenter.plist': {'Label': 'com.apple.CommCenter', '_PanicOnCrash': True},
        '/System/Library/LaunchDaemons/com.apple.vmd.plist': {'Label': 'com.apple.voicemail.vmd'},
        '/System/Library/LaunchDaemons/com.apple.bluetoothd.plist': {'Label': 'com.apple.bluetoothd',
                                                                     'EnvironmentVariables': {'BT_DEVICE_ADDRESS': '00:11:22:33:44:55', 'X': 'y'}},
        '/System/Library/LaunchDaemons/com.apple.security.cryptexd.plist': {'Label': 'com.apple.security.cryptexd'},
        '/System/Library/LaunchDaemons/com.apple.replicatord.plist': {'Label': 'com.apple.replicatord', 'Data': b'\x00\x01binary',
                                                                      'When': datetime.datetime(2025, 3, 4, 5, 6, 7)},
    }
    launchd = {'LaunchDaemons': jobs, 'Agents': {'vmd': {'Label': 'com.apple.voicemail.vmd'}, 'other': {'Label': 'x'}},
               'Version': 3, 'Name': 'café ☃'}
    w(root, 'System/Library/xpc/launchd.plist', plistlib.dumps(launchd, fmt=plistlib.FMT_BINARY))
    w(root, 'System/Library/LaunchDaemons/com.apple.CommCenter-noncellular.plist', plistlib.dumps(
        {'Label': 'com.apple.CommCenter', '_LimitLoadFromDeviceTree': {'a': 1}, '_PanicOnCrash': True, 'MachServices': {'com.apple.commcenter': True}},
        fmt=plistlib.FMT_BINARY))
    for k in ('Default', 'Touch'):
        w(root, f'System/Library/EventTimingProfiles/N841.{k}.plist', plistlib.dumps({'Profile': k}, fmt=plistlib.FMT_BINARY))
    w(root, 'System/Library/Frameworks/MediaToolbox.framework/A/SubServerConfiguration.plist', plistlib.dumps(
        {'StartRecorderServer': True, 'Servers': [{'Name': 'a & <b>', 'Weight': 1e20, 'Tiny': 1.5e-7, 'Blob': bytes(range(120))}],
         'Empty': {}, 'None': [], 'Date': datetime.datetime(2001, 1, 1)}, fmt=plistlib.FMT_XML))
    w(root, 'Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin/Contents/Info.plist', b'plugin')
    w(root, 'private/var/containers/Data/System/AAA/.com.apple.mobile_container_manager.metadata.plist',
      plistlib.dumps({'MCMMetadataIdentifier': 'com.apple.other'}, fmt=plistlib.FMT_BINARY))
    w(root, 'private/var/containers/Data/System/BBB/.com.apple.mobile_container_manager.metadata.plist',
      plistlib.dumps({'MCMMetadataIdentifier': 'com.apple.mobileactivationd'}, fmt=plistlib.FMT_BINARY))
    w(root, 'private/var/mobile/Containers/Data/InternalDaemon/X1/Library/Caches/com.apple.LaunchServices-1234.csstore', b'db')
    w(root, 'private/var/mobile/Containers/Data/InternalDaemon/X1/Library/Caches/keep.me', b'keep')
    w(root, 'private/var/mobile/Library/Preferences/com.apple.springboard.plist',
      plistlib.dumps({'Existing': 'yes', 'BKNoWatchdogs': False}, fmt=plistlib.FMT_BINARY), 0o600)
    w(root, 'private/var/preferences/SystemConfiguration/preferences.plist', plistlib.dumps(
        {'CurrentSet': '/Sets/1111', 'Sets': {'1111': {'UserDefinedName': 'Mine', 'Network': {'Global': {'IPv4': {'ServiceOrder': ['old']}}}}},
         'NetworkServices': {'old': {'UserDefinedName': 'Wi-Fi'}}}, fmt=plistlib.FMT_BINARY))
    w(root, 'Applications/Preferences.app/Preferences', b'settings', 0o755)
    for app in ('Zed.app', 'Alpha.app'):
        w(root, f'private/var/staged_system_apps/{app}/Contents/Info.plist', app.encode())
    w(root, 'private/var/staged_system_apps/README', b'not an app')
    w(root, 'usr/local/share/renegade/register-apps', b'Old.app\n')
    w(tools, 'sweetnetcfg', b'\xcf\xfa\xed\xfe fake netcfg', 0o755)
    w(tools, 'sweetreboot', b'\xcf\xfa\xed\xfe fake reboot', 0o700)


def run(root, tools, quiet):
    sys.path.insert(0, RENEGADE)
    import root_tweaks18 as rt
    rt.BUILD, rt.VERSION = '22H352', '18.7.8'
    rt.NETCFG = os.path.join(tools, 'sweetnetcfg')
    rt.REBOOT_TOOL = os.path.join(tools, 'sweetreboot')
    rt.BLUETOOL_STUB = '/nonexistent/bluetool-stub'
    rt.SWEETNET_DIRS = []
    rec = rt.OwnerRecorder()
    rec.install()
    rt.launchd(root)
    if quiet:
        rt.quiet(root)
    rt.containers(root)
    rt.launchservices(root)
    rt.event_timing(root)          # develop: N841 -> D22 (the ios18 case)
    rt.usbnet(root)
    rt.netcfg(root)
    rt.sweetreboot(root)
    rt.audio(root)
    rt.activation(root)
    rt.prefs(root)
    rt.iosroot_dirs(root)
    rt.staged_apps(root)
    rt.bluetooth(root)
    for p, (u, g) in sorted(rec.owners.items()):
        print(f'OWNER {os.path.relpath(p, root)} {u} {g}')


if __name__ == '__main__':
    if sys.argv[1] == 'make':
        make(sys.argv[2], sys.argv[3])
    else:
        run(sys.argv[2], sys.argv[3], '--quiet' in sys.argv)
