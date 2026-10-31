#!/usr/bin/env python3
"""Build the kernel on this Mac from an xnu.yml artifact, without Actions, a KDK or Xcode 26.

  xnu-offline-build.py BUILDTREE LIBDISPATCH_SRC OUT [-jN] [--relink] [FILTER ...]

BUILDTREE       extracted xnu-buildtree artifact of a good run (build/xnu.obj, xnu/, fakeroot/, sdk-kernel-platform/),
                with later patches applied to BUILDTREE/xnu by hand (`patch -p1`)
LIBDISPATCH_SRC extracted libdispatch source, the tag xnu.yml's log names (firehose_buffer.c: -lfirehose_kernel)
OUT             the stripped kernel, for tools/dipper-mkboot.sh

Every object in the artifact's compile_commands.json is compiled with this Mac's clang and the same flags, in place
(artifact objects are excluded from the tree), then the log's link line and strip run. No CTF and no dSYM: nothing at boot
needs them. Only stale objects are recompiled, so after an edit under BUILDTREE/xnu a rerun takes seconds.
A source whose headers changed is not detected: delete its object, or pass FILTER strings to force sources that contain them.
New source files need their entry added to compile_commands.json and link.filelist by hand.
"""
import concurrent.futures as cf, json, os, re, shlex, subprocess, sys

CI_DXB = '/Users/runner/work/Bergamota/Bergamota/dxb'
CI_SDK = re.compile(r'/Applications/Xcode[^ /]*\.app/Contents/Developer/Platforms/MacOSX\.platform/Developer/SDKs/MacOSX[0-9.]*\.sdk')
CI_SDK_PLATFORM = re.compile(CI_SDK.pattern + r'/+System/Library/Frameworks/Kernel\.framework/Versions/A/PrivateHeaders/platform')
# -fexperimental-bounds-safety: unknown to Xcode 27's driver; the CI build has BOUND_CHECKS=0, its annotations compile away
DROP = {'-g', '-MD', '-MMD', '-MP', '-gline-tables-only', '-fexperimental-bounds-safety'}
DROP_WITH_ARG = {'-MF', '-MT', '-MJ'}


def xcrun(*a):
    return subprocess.run(['xcrun', *a], capture_output=True, text=True, check=True).stdout.strip()


class Build:
    def __init__(self, bt):
        self.bt = os.path.abspath(bt)
        self.sdk = xcrun('--sdk', 'macosx', '--show-sdk-path')
        self.clang = xcrun('-f', 'clang')
        self.obj = os.path.join(self.bt, 'build/xnu.obj/DEVELOPMENT_ARM64_SWEET')
        # Xcode 27's SDK has no TrustCache/API.h
        self.extra = ['-I', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'xnu-offline-stubs')]

    def path(self, a):
        a = CI_SDK_PLATFORM.sub(os.path.join(self.bt, 'sdk-kernel-platform/platform'), a)
        a = CI_SDK.sub(self.sdk, a)
        return a.replace(CI_DXB, self.bt)

    def entry(self, e):
        args, skip = [], False
        for a in e['arguments'][1:]:
            if skip:
                skip = False
            elif a in DROP:
                pass
            elif a in DROP_WITH_ARG:
                skip = True
            else:
                args.append(self.path(a))
        cc = self.clang + ('++' if os.path.basename(e['arguments'][0]) == 'clang++' else '')
        # an Xcode newer than the tree's: new diagnostics must not stop an old tree
        return [cc, *args, '-Wno-error', '-w', *self.extra], self.path(e['directory'])

    def stale(self, e, force):
        cwd = self.path(e['directory'])
        out = os.path.join(cwd, e['output'])
        src = self.path(e['file'])
        src = src if os.path.isabs(src) else os.path.join(cwd, src)
        if any(f in src for f in force):
            return True
        return not os.path.exists(out) or os.path.getmtime(out) < os.path.getmtime(src)


def compile_one(b, e):
    cmd, cwd = b.entry(e)
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    return e['file'], p.returncode, p.stderr


def firehose(b, src):
    """libfirehose_kernel.a, what CI builds with xcodebuild (libfirehose_kernel.xcconfig)."""
    out = os.path.join(b.bt, 'fakeroot/usr/local/lib/kernel')
    os.makedirs(out, exist_ok=True)
    lib = os.path.join(out, 'libfirehose_kernel.a')
    if os.path.exists(lib):
        return lib
    hdr = os.path.join(b.bt, 'build/xnu.obj/EXPORT_HDRS')
    o = os.path.join(out, 'firehose_buffer.o')
    inc = [src, src + '/src', src + '/private', src + '/os', os.path.join(b.bt, 'sdk-kernel-platform'),
           hdr + '/bsd', hdr + '/osfmk', hdr + '/libkern', hdr + '/iokit', hdr + '/pexpert',
           b.bt + '/fakeroot/usr/local/include', b.bt + '/fakeroot/usr/local/include/os', b.bt + '/fakeroot/usr/local/include/firehose']
    cmd = [b.clang, '-x', 'c', '-arch', 'arm64', '-std=gnu11', '-O2', '-mkernel', '-nostdlibinc', '-w', '-DKERNEL=1', '-DDISPATCH_USE_DTRACE=0',
           '-DKERNEL_PRIVATE', '-DPRIVATE', '-D__ARM64__', '-DARM64_BOARD_CONFIG_SWEET', '-D__WORDSIZE=64', '-mmacos-version-min=26.1', '-isysroot', b.sdk,
           *sum((['-I', i] for i in inc), []), '-idirafter', b.sdk + '/System/Library/Frameworks/Kernel.framework/Headers',
           '-idirafter', b.sdk + '/usr/include', '-c', src + '/src/firehose/firehose_buffer.c', '-o', o]
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode:
        sys.exit('firehose_buffer.c:\n' + p.stderr[:3000])
    subprocess.run([xcrun('-f', 'libtool'), '-static', '-o', lib, o], check=True, capture_output=True)
    return lib


def link(b, log, out):
    line = None
    for l in open(log, errors='replace'):
        if 'kernel.development.sweet.unstripped.noctf' in l and '-filelist link.filelist' in l:
            line = l.strip()
            break
    if not line:
        sys.exit('no link line in ' + log)
    words = shlex.split(line)
    words = words[words.index(next(w for w in words if w.endswith('clang++'))):]
    words[0] = b.clang + '++'
    new = [b.path(w) for w in words]
    new = [w for w in new if not w.startswith('-L/Library/Developer/KDKs')]
    new = [w for i, w in enumerate(new) if not w.startswith('-mmacosx-version-min') or True]
    # link.filelist holds the runner's paths
    fl = os.path.join(b.obj, 'link.filelist')
    local = os.path.join(b.obj, 'link.local.filelist')
    with open(fl) as f, open(local, 'w') as g:
        for l in f:
            g.write(b.path(l))
    new[new.index('link.filelist')] = local
    p = subprocess.run(new + ['-Wl,-w'], cwd=b.obj, capture_output=True, text=True)
    err = '\n'.join(l for l in p.stderr.split('\n') if 'warning' not in l)
    if p.returncode:
        sys.exit('link failed:\n' + err[:6000])
    unstripped = os.path.join(b.obj, 'kernel.development.sweet.unstripped.noctf')
    subprocess.run([xcrun('-f', 'strip'), '-S', unstripped, '-o', out], check=True, capture_output=True)
    print('kernel', out, os.path.getsize(out))


def main():
    args = sys.argv[1:]
    jobs = next((int(a[2:]) for a in args if a.startswith('-j')), 8)
    relink = '--relink' in args
    pos = [a for a in args if not a.startswith('-')]
    if len(pos) < 3:
        sys.exit(__doc__)
    b = Build(pos[0])
    force = pos[3:]
    db = json.load(open(os.path.join(b.obj, 'compile_commands.json')))
    for extra in ('lastkerneldataconst', 'lastkernelconstructor', 'nonlto'):
        db.append(json.JSONDecoder().raw_decode(open(os.path.join(b.obj, extra + '.o.json')).read())[0])
    # clang records an assembler source's preprocessing step, with a temporary as the output
    for e in db:
        if e['output'].startswith('/var/folders/'):
            o = os.path.splitext(os.path.basename(e['file']))[0] + '.o'
            e['arguments'] = [o if a == e['output'] else a for a in e['arguments']]
            e['output'] = o
    todo = [] if relink else [e for e in db if b.stale(e, force)]
    print(f'{len(db)} objects, {len(todo)} to compile, {jobs} jobs', flush=True)
    bad = 0
    with cf.ThreadPoolExecutor(jobs) as ex:
        for n, (f, rc, err) in enumerate(ex.map(lambda e: compile_one(b, e), todo), 1):
            if rc:
                bad += 1
                print('FAILED', f, '\n', err[:1500], flush=True)
            if n % 100 == 0:
                print(n, 'done', bad, 'failed', flush=True)
    if bad:
        sys.exit(f'{bad} objects failed')
    v = os.path.join(b.obj, 'version.o')
    if not os.path.exists(v):
        t = next(e for e in db if e['output'] == 'nonlto.o')
        e = dict(t, file=os.path.join(b.obj, 'version.c'), output='version.o')
        e['arguments'] = [e['file'] if a.endswith('nonlto.c') else 'version.o' if a == 'nonlto.o' else a for a in t['arguments']]
        f, rc, err = compile_one(b, e)
        if rc:
            sys.exit('version.c:\n' + err[:2000])
    firehose(b, os.path.abspath(pos[1]))
    link(b, os.path.join(b.bt, 'build.log'), os.path.abspath(pos[2]))


if __name__ == '__main__':
    main()
