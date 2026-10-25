# renegade-rs

Renegade in Rust: the stages that turn an Apple IPSW into a PAC-stripped HFS+ root image for the Poco F1,
ported from the Python Renegade in [`tools/renegade`](../renegade) one stage at a time. The Python tools stay
the reference (and keep working) until the Rust port covers everything; every ported stage is tested against
them on the same inputs.

The library reads through a `ReadAt` trait and writes through `std::io::Write`, with no file system access
of its own, so the same code is the native CLI and, compiled to `wasm32-unknown-unknown`, the patcher of
the web flasher (`apps/web`, phase 3).

## Ported (the stages the iOS 26 port marked stable)

| Python | Rust | Status |
| --- | --- | --- |
| `img2simg.py` | `sparse::img2simg`, `renegade-rs img2simg RAW OUT [--block N]` | byte-identical output |
| `simg2img.py` | `sparse::simg2img`, `renegade-rs simg2img IN OUT` | identical image (holes for zeros) |
| `hfsx.py` (sparse reader, HFS+/HFSX catalog, hard links, symlinks, extents overflow) | `sparse::Sparse`, `hfs::Volume`, `renegade-rs hfs SIMG ls\|cat\|get\|getdir\|stat\|find\|dsc` | identical output |
| `pacstrip.py` (rewrite, `--scan`, `-v`, `--dylinker`) | `pacstrip::strip`, `renegade-rs strip` | byte-identical files, identical output |
| `fixupcheck.py` (directory or `.simg`) | `fixups::check_bytes`, `renegade-rs fixupcheck` | identical output |
| `hfsroot_owners.py` (owner/mode pass on an image) | `hfsedit::apply_owners`, `renegade-rs owners IMAGE [--map] [--default-root]` | byte-identical image |
| `hfs_trim.py` | `hfsedit::free_runs`, `renegade-rs trim IMAGE` | byte-identical image |
| owners.tsv (`write_map` / `load_map` of mkroot-full.py) | `hfsedit::format_map` / `parse_map` | same text |
| `newfs_hfs -s` + mount + `ditto` + `hfsroot_owners.py` (no Python writer) | `hfswrite::build`, `renegade-rs mkhfs DIR IMG`, `rebuild SIMG IMG --prefix P` | fsck_hfs clean, mounts, same tree, same owners as the Python way |
| `plistlib.load` / `dump(FMT_BINARY / FMT_XML)` | `plist::parse`, `to_binary`, `to_xml`, `renegade-rs plist IN OUT [--fmt xml]` | byte-identical on 426 plists of the iOS 26 root (852 dumps, incl. launchd.plist's shared containers) and 300 random ones |
| `root_tweaks18.py`: launchd, quiet, containers, launchservices, event_timing, usbnet, netcfg, sweetreboot, sweetmetrics, audio, activation, prefs, iosroot_dirs, staged apps, the bluetoothd environment, add_job | `tweaks::run` on a folder (`DirFs`, `renegade-rs tweaks DIR`) or on the root build's tree (`TreeFs`) | same files, modes, recorded owners and printed lines as root_tweaks18.py |
| `pacstrip.py --sign` (`codesign -f -s - -i ID -o OPTS --entitlements E` on macOS; the bundle sealed when the file is its main executable) | `codesign::resign` / `sign`, `bundle::code_resources`, `renegade-rs strip --sign`, `sign FILE [--info] [--resources]` | byte-identical to codesign: all 3,222 Mach-Os pacstrip.py re-signed in the iOS 26 root (`renegade-rs resign-check`), 2,368 bundle seals; thin, fat, kext, hardened-runtime, entitlements, bundles in the tests |
| copy-stage layout fixes, tweaks, owner map (+ the tweaks' owners as OWNER_EXTRA), macho stage (strip + re-sign, bundles sealed), seal, img2simg --consume | `renegade-rs root DIR OUT.simg --build B --version V [--no-macho]` | tweaked files identical to root_tweaks18.py's, Mach-Os and CodeResources identical to pacstrip.py --sign's, fsck_hfs clean |

Not ported yet: ldid signing (pacstrip.py `--sign` on Linux), the tweaks that install prebuilt tools
with host steps (ssh: dropbear + host-generated keys; the BlueTool stub, hcitest and firmware; PosterBoard +
sweetfp via addlc.py; bgmtl; bglrender; the first-boot job; sweetprefs), the console bring-up job, the
jailbreak stage, IPSW/AEA extraction and the APFS volumes (the root build starts from an extracted folder),
the shared-cache stage (`pacstrip_cache.py`, still changing on the `ios26` branch: `--stubs`),
`simg_putfile.py`, and the boot images (`mkboot-full.sh`). Reference for the port: branch `ios26` at `6a66010`.

### Ad-hoc signing

`codesign` reproduced without codesign, so the root builds on Linux and in the browser with the bytes the macOS
build gets: one SHA-256 CodeDirectory (0x20400; 0x20500 with the hardened runtime, carrying the SDK version;
0x20100 for kexts), 16 KiB pages, the exec segment from `__TEXT`, special slots for Info.plist (the bundle's or
the embedded `__info_plist` section), the empty requirement set, CodeResources and both entitlement forms (XML,
and CoreEntitlements DER), an empty CMS wrapper. Details that took matching against codesign:

- The space reserved is codesign's estimate rounded: `roundup16(length + 88 − header + 8)`, the estimate counting
  a 0x20400 header whatever the version; the padding keeps the bytes the file had there.
- pacstrip.py reads the old entitlements back through `codesign -d --entitlements - --xml`, which prints the
  CoreEntitlements view as compact XML (keys sorted, `<dict></dict>`, `&quot;`/`&apos;`); that text is what the
  new signature holds (`codesign::codesign_xml`).
- A bundle's main executable is CFBundleExecutable, or without that key the file named after the folder minus
  its extension. Its CodeResources follows the iOS rules (SHA-1 `files`, SHA-256 `files2`, `.lproj` optional,
  locversion and `.DS_Store` omitted, nested bundles hashed as plain files) in CoreFoundation's XML layout.
- Apple's own untouched ad-hoc signatures (4 KiB pages) are left alone, as the Python build leaves every file
  pacstrip does not change.

The root build seals bundles deepest first. The Python stage signs in a process pool, so a bundle can be sealed
before its nested code is re-signed: 68 bundles of the iOS 26 root carry stale hashes of their app extensions,
which the Rust build does not reproduce.

### The HFSX writer

`hfswrite` writes a case-sensitive, unjournaled volume in one pass: the catalog B-tree (leaf and index nodes,
HFSX binary key order, HFS+ name decomposition), empty extents-overflow and attributes B-trees, the allocation
bitmap, both volume headers, folder counts, and hard links as xnu writes them (an `iNode<N>` file in the private
directory with the first link's CNID in `reserved1`, link records carrying the chain in their owner/group
fields and the private directory's creation date). No extended attributes: the only ones in a ditto-built root
are the Mac's `com.apple.provenance` (451,713 of them on the iOS 26 root, nothing iOS reads). Checked by
`fsck_hfs` and by mounting on macOS; rebuilt `/usr` (3,008 entries, 135 hard-link groups) and `/Applications`
(40,973 entries, a 4,149-node catalog) of the real iOS 26 root come out fsck-clean with every file's owner,
mode, size and SHA-256 and every hard-link group identical.

Differences from the Python on purpose:

- `pacstrip.py --subtype arm64` raises `struct.error` on arm64e files (the subtype 0x81000002 is read as a
  signed int and the masked value no longer fits); `renegade-rs strip --subtype arm64` writes
  `subtype & 0xff000000` (the capability byte kept, the subtype ALL).
- A FILL chunk's 32-bit pattern keeps its phase relative to the chunk start when the sparse reader is read
  at an offset that is not a multiple of 4 (`hfsx.py` restarts the pattern at the read offset). Zero fills,
  the only kind img2simg writes, are unaffected.
- Hard links with conflicting owner-map entries: hfsroot_owners.py applies every link's entry to the shared
  iNode in catalog order (the last one wins, and a defaulted link resets the owner but not the mode); the Rust
  root build gives the iNode the entry of a mapped link. In a real build every link of a file has the same
  entry (one lstat of the IPSW volume), so the results agree.

## Build and test

```sh
cargo build --release                                  # target/release/renegade-rs
cargo build --release --lib --target wasm32-unknown-unknown
cargo test --release                                   # needs python3: compares with ../renegade on the same inputs
python3 tests/fixtures/make.py                         # (macOS) rebuild the fixtures: hdiutil + clang, our own content only
```

The tests compare, on generated images and on the fixtures (small HFS+ and HFSX volumes, arm64e binaries
compiled from `tests/fixtures/pac.s`, `fix.c`, `exe.c`, a hand-built Mach-O with a data-in-code entry):
img2simg bytes, simg2img images and random reads, every `hfs` command on both volumes (including hard links,
relative and absolute symlinks, NFC/NFD names), pacstrip scan and rewrite bytes and verbose lines,
`--dylinker`, 200,000 random instruction words classified by `pacstrip.rewrite_word`, fixupcheck on a
directory (with a deliberately broken chain) and on the image, and (macOS) `strip --sign` against
`pacstrip.py --sign` on linker-signed, codesign-signed (entitlements, hardened runtime, long identifier) and fat
binaries and on bundles with and without CFBundleExecutable. No Apple file is committed.

`renegade-rs resign-check ROOT.simg` re-signs every codesign-signed Mach-O of a Python-built root and reports
the ones that do not come out identical.
