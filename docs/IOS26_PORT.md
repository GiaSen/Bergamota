# iOS 26 port: first image (branch `ios26`)

Why iOS 26 and what was measured: `docs/IOS26_FEASIBILITY.md`. Kernel: `docs/XNU12377_MIGRATION.md`. The Renegade pipeline
(PAC rewrite, root build) is the iOS 18 one (`docs/IOS18_PORT.md`, `tools/renegade/README.md`) with a target profile.

## 1. What was built (2026-10-24, nothing flashed or booted)

| Piece | File (git-ignored) | How |
| --- | --- | --- |
| Kernel | `research/ios26/kernel/kernel.development.sweet` (xnu-12377.121.6, sha256 `d1afbfd8...`) | `USE_KDK=1 tools/xnu-local-build.sh 26.5` |
| ADT, iPhone 11 | `enxerto/out/beryllium-n104-2x.adt` (N104AP / iPhone12,1, 414x896 @2x = 828x1792, sRGB) | `tools/mkadt.py OUT --board beryllium --highmem --display-scale 2 --points 414x896 --identity n104ap` (needs `research/ios26/n104ap.adt`) |
| Root | `research/ios26/ios26-root-full.simg` (17.9 GB sparse, iOS **26.6.2 23G90**, iPhone12,1) | `tools/renegade/fetch-root.sh`, then `RENEGADE_MIN_FREE_GB=10 tools/renegade/mkroot-full.sh --delete-sources --size 24g` |
| Boot image | `research/ios26/enxerto-boot-ios26full.img` | `tools/renegade/mkboot-full.sh` (iOS 18 boot-args, `rd=ufsroot0`, `sweetarm64e=1`) |

**Why 26.6.2, not 26.7.1:** 26.7/26.7.1 exist only as OTAs, where the root is `payloadv2` Apple Archives instead of a disk
image; Renegade's copy stage reads IPSW disk images (and their owners). An OTA path is future work; the kernel is the same.

Root verify stage, all OK: owners (3000-path spot check), no HFS compression, `codesign -v` sample, identity/CS flags of all
2986 re-signed Mach-Os, every boot-task program present, chained fixups of 3792 Mach-Os, no PAC words left, shared cache signatures.
Skipped features (prebuilt tools not in this worktree; `renegade fetch-tools` or `tools/sweetnet/build.sh`): app registration
(`sweetuicache`), default wallpaper, PosterBoard `sweetfp.dylib`, `sweetprefs`, Chlorophyll payload (`research/bgmtl`). In:
dropbear SSH (key-only), USB Ethernet 192.168.7.2, `sweetnetcfg`, `sweetreboot`, jailbreak userland.

## 2. Renegade changes

* `tools/renegade/targets.py`: one profile per target (device, version, build, dmg names, work dir, ADT target-type, default ADT),
  `RENEGADE_TARGET=ios26` (default) or `ios18`. `fetch-root.sh`, `mkroot-full.py`, `root_tweaks18.py` (build/version,
  event-timing copy only when the ADT claims another device) and `mkboot-full.sh` read it.
* `RENEGADE_MIN_FREE_GB` (default 5): the copy stage refuses to start a volume that would leave less than this free.
* `verify` stage: the content checks (fixup walk, PAC scan, cache) run on a read-only noowners remount; with owners on, root-only
  files (`/private/etc/master.passwd`) were unreadable and the newer fixup walk stopped.
* Disk on the Mac: about 21.6 GB free is needed for the OS copy with a 10 GB floor (OS volume 11.6 GiB apparent).

## 3. First boot (needs the user's OK; every flash goes through the Bergamota queue)

1. Flash `research/ios26/ios26-root-full.simg` to `userdata` and `fastboot boot` `research/ios26/enxerto-boot-ios26full.img`,
   both via `apps/Bergamota/scripts/bergamota` (never modem/persist/bluetooth/dsp).
2. Expected first problems (iOS 18 -> 26 userland drift): IOSurface / IOMobileFramebuffer user-client layouts (0157/0159 style),
   MobileGestalt answers for iPhone12,1, new launchd boot tasks, AKS selectors. Logs: `tools/sweet-log-pull.sh`, SSH once USB
   networking is up.
