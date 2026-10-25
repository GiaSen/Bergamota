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

Not ported yet: `pacstrip.py --sign` (ad-hoc re-signing goes through codesign/ldid; the Rust CLI refuses
`--sign`), IPSW/AEA extraction, the shared-cache stage (`pacstrip_cache.py`, still changing on the `ios26`
branch: `--stubs`), the HFS+ writer and root build (`mkroot-full.py`, `root_tweaks18.py`), `simg_putfile.py`,
and the boot images (`mkboot-full.sh`). Reference for the port: branch `ios26` at `6a66010`.

Differences from the Python on purpose:

- `pacstrip.py --subtype arm64` raises `struct.error` on arm64e files (the subtype 0x81000002 is read as a
  signed int and the masked value no longer fits); `renegade-rs strip --subtype arm64` writes
  `subtype & 0xff000000` (the capability byte kept, the subtype ALL).
- A FILL chunk's 32-bit pattern keeps its phase relative to the chunk start when the sparse reader is read
  at an offset that is not a multiple of 4 (`hfsx.py` restarts the pattern at the read offset). Zero fills,
  the only kind img2simg writes, are unaffected.

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
