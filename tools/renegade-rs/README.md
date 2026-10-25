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
| copy-stage layout fixes, owner map, macho stage (strip), seal, img2simg --consume | `renegade-rs root DIR OUT.simg --unsigned` | stripped Mach-Os identical to pacstrip.py; no re-signing yet |

Not ported yet: `pacstrip.py --sign` (ad-hoc re-signing goes through codesign/ldid; the Rust CLI refuses
`--sign`, and `renegade-rs root` needs `--unsigned` until it can sign), the tweaks stage (`root_tweaks18.py`),
the jailbreak stage, IPSW/AEA extraction and the APFS volumes (the root build starts from an extracted folder),
the shared-cache stage (`pacstrip_cache.py`, still changing on the `ios26` branch: `--stubs`),
`simg_putfile.py`, and the boot images (`mkboot-full.sh`). Reference for the port: branch `ios26` at `6a66010`.

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
`--dylinker`, 200,000 random instruction words classified by `pacstrip.rewrite_word`, and fixupcheck on a
directory (with a deliberately broken chain) and on the image. No Apple file is committed.
