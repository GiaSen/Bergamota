# Migration from xnu-11215 to xnu-12377 (branch `ios26`)

Target: iOS 26.7.1 (23H30) userland, identity iPhone12,1 (N104AP, A13). Why and what was measured: `docs/IOS26_FEASIBILITY.md`.
Status: the series `xnu/patches-12377/` applies to `xnu-12377.121.6` (macOS/iOS 26.5, newest published xnu-12377 tag);
first CI builds in progress. Nothing booted.

## 1. Source, toolchain, CI

* **Tag.** `xnu-12377.121.6` (distribution-macOS `macos-265`). The 26.7.1 kernel is 12377.162.13, not published; same kind of gap as
  11215.81.4 under iOS 18.7.8.
* **Paired sources** (`macos-265` release.json), fetched by the stage scripts at pinned commits, gated on `MACOS_VERSION == 26.*`:
  libpthread-539.100.4 (`1f4f526`), hfs-715.120.4 (`124b970`). BearSSL unchanged.
* **CI** (`.github/workflows/xnu.yml`): branch `ios26` defaults to `macos_version=26.5`; 26.x runs on `macos-26` with Xcode 26.1 (the
  combination dxb's own CI uses), dxb downloads KDK 26.5 (25F71). dxb applies `patches/26.0/*.sh` (its `00_setup_coreentitlements.sh`
  needs the KDK) then `*.patch` in name order; ours are copied in with a `sweet-` prefix and a non-applying patch fails the build, as for 15.x.
  dxb's `link_kdk.patch` and `remove_applefeatures_include.patch` do not apply to 121.6 and are skipped by dxb.
* **Series layout.** `xnu/patches-11215/` stays (iOS 18 kernel, `develop` still builds it). `xnu/patches-12377/` has the same file names
  and numbers, one diff per file, regenerated from a per-patch commit series (`git diff C~1 C`); applying it from scratch onto
  12377.121.6 + dxb 26.0 + staged sources reproduces that tree exactly (checked).

## 2. What changed in the port

164 of the 197 patches applied unchanged. The others:

| Patch | 12377 change | Port |
| --- | --- | --- |
| 0003 fb serial console | `serial_init` moved the defaults/`serial-device` lookup into `get_serial_device_phandle()` | `fbcon_probe()` before that call |
| 0004 machine config | machine list gained T6041/T6050/T8142; `pexpert/arm64` export list reorganised | `SWEET` added to the new lists; `SWEET.h` in `PRIVATE_KERNELFILES` |
| 0009 SoC-only exports | `Private.Tightbeam.exports` is gone in 12377 | that file dropped from the patch; the same symbol lines removed from `Private.arm64.exports`/`Private.exports` |
| 0010, 0012 early console marks | context drift in `arm_init`/`arm_vm_init` (KASAN block moved) | re-placed by hand |
| 0013 kmem RNG without corecrypto | `vm_kern.c` no longer uses `crypto_random_uniform`; the per-CPU corecrypto RNG moved to `vm_map_store.c` (guard objects) | same SplitMix64 generator, now in `vm_map_store.c` (`vm_map_store_crypto_init`, `vmgo_chunk_select_random_slot`) |
| 0014 HMAC PRNG | `write_random` now hashes with SHA-512 | SHA-256 special case dropped: SHA-512 is served by BearSSL (0033) |
| 0016, 0018, 0035, 0038, 0123 | `iokit/conf/files.arm64` context | lines appended |
| 0039 coredump default off | file guard is now `CONFIG_COREDUMP \|\| CONFIG_UCOREDUMP` | include placed after it |
| 0043 crash log | `proc_prepareexit` context (Apple fixed the `\|\|` -> `&&` EXC_CRASH test) | re-anchored |
| 0065, 0082, 0131, 0135, 0141, 0153, 0170, 0191 | context drift only | hunks re-anchored on unique neighbouring lines and reviewed (0135 `#if HAS_APPLE_PAC` balance checked) |

Compile-level API drift is found by the CI build; fixes go into the patch that owns the file, or a new `0235+` patch.

## 3. Open items

* The local build path (sccache, `BOUND_CHECKS=0`) is not recorded in the repo; the Mac has Xcode 27.1 and no KDK 26.5.
* `tools/mkadt.py` needs the N104AP tree (`research/ios26/n104ap.adt`) as identity source; patch 0059 identity strings for iPhone12,1.
* Renegade root for the 26.7.1 OTA (`tools/renegade`), then first boot.
