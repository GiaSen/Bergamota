# Migration from xnu-11215 to xnu-12377 (branch `ios26`)

Target: iOS 26.7.1 (23H30) userland, identity iPhone12,1 (N104AP, A13). Why and what was measured: `docs/IOS26_FEASIBILITY.md`.
Status (2026-10-24): `xnu/patches-12377/` (198 patches, 0001-0235) on `xnu-12377.121.6` (macOS/iOS 26.5, newest published
xnu-12377 tag) **builds and links** locally: `kernel.development.sweet`, arm64, "Darwin Kernel Version 25.5.0 ... xnu-12377.121.6"
(`tools/xnu-local-build.sh`, Xcode 27.1 + KDK 26.5). Nothing booted.

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

Compile and link fixes (CI runs 3-6 and the local build), each in the patch that owns the code:

| Patch | 12377 change | Fix |
| --- | --- | --- |
| 0004 | `SWEET.h` lacked `MPIDR_CORETYPE_ACC_M` (new M_CORE); `INTERRUPT_MASKED_DEBUG_*` gone; the closed per-SoC library `lib<SoC>.os.<config>.a` is now force-loaded for every machine config; the KDK's `libTightbeam.a` (x86_64/arm64e only) is linked and exported when found | `ACC_M` defined; `ml_interrupt_masked_debug_start/end()`; SWEET skips both libraries (its asm/pmap come from the open-source build, 0006) |
| 0006 | `files.arm64` lists `osfmk/arm64/amcc_rorgn_pv_ctrr.c`, which is not published | line commented out (PV-CTRR is for Apple VMs) |
| 0009 | 30 SPTM gen3 DART / IOMMU / `IOUnifiedAddressTranslator` exports only exist in Apple-SoC builds | removed from `Private.arm64.exports` |
| 0065 | `sysreg_restore` gone (secondaries load `TCR_EL1_BOOT`) | its cache clean dropped |
| 0066 | `vm_map_lock_read`/`vm_map_lookup_entry` replaced by the lock-context API | shared interlock + `vm_map_lookup_or_next` |
| 0131 | call before definition | prototype |
| 0148-0151 | `IO_NULL`, `io_otype`, `ip_kotype` gone (kobject types are object types) | shim in 0148, `ip_type` in 0149 |
| 0190 | `MAX_SCHED_CPUS` gone | `MAX_CPUS` |
| 0235 (new) | `ml_device_is_prod_fused()` lives in the closed `machine_routines_apple`; Tightbeam startup compiles because the KDK has its headers | SWEET definition (not prod fused, like the ADT); Tightbeam startup off for SWEET |
| 0027 (new, .sh) | CoreEntitlements V2 headers are KDK-only | type stubs when no KDK (`use_kdk=false`); with the KDK it does nothing |

**KDK:** still needed for headers only (`TrustCache/API.h` and friends are closed and not in any SDK). Nothing from the KDK is linked.

## 3. Open items

* Local build: `USE_KDK=1 tools/xnu-local-build.sh 26.5` (full: dxb, pinned commit, our series, sccache, `BOUND_CHECKS=0`), then
  `USE_KDK=1 tools/xnu-local-build.sh --remake [-j1] 26.5` to rebuild after editing `research/xnu-local/dxb/xnu` in place (`-j1`
  serialises xnu's own parallelism, for readable errors). Needs KDK 26.5 (25F71) installed; works with Xcode 27.1. About 8 GB.
* `tools/mkadt.py` needs the N104AP tree (`research/ios26/n104ap.adt`) as identity source; patch 0059 identity strings for iPhone12,1.
* Renegade root for the 26.7.1 OTA (`tools/renegade`), then first boot.
