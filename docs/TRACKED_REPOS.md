# Tracked & Surveyed Repositories (as of 2026-11-24)

Master index of repositories tracked, cloned locally (git-ignored under `research/`), or surveyed across [`NOTES.md`](../NOTES.md) and [`docs/FORKS_SURVEY.md`](FORKS_SURVEY.md) for the **Xiaomi Mi 8 (`dipper`, SDM845, iOS 26.6.2)** port. All third-party repositories are untrusted reference material; check each repository's licence before taking code (keep GPL-only code out of XNU/userland).

**Activity labels** (verified via GitHub API on `2026-11-24`):
- **Active** — pushed in the past week (`2026-11-18` .. `2026-11-24`)
- **Recent** — pushed earlier in Nov 2026 (`2026-11-01` .. `2026-11-17`)
- **Dormant** — last push `<= 2026-10-31`
- **Gone (`404`)** — deleted or made private on GitHub

---

## 0. Project Remotes, Submodules & Local Reference Clones

| Repository | Branch / Pin | Last Push | Activity | Local Path | Role |
| --- | --- | --- | --- | --- | --- |
| [GiaSen/Bergamota](https://github.com/GiaSen/Bergamota) | `dipper` | 2026-11-24 | **Active** | `.` (`origin`) | This fork: iOS 26.6.2 (`23G90`) + Heartwood `xnu-12377.121.6` on Xiaomi Mi 8 (`dipper`). |
| [GiaSen/Chlorophyll](https://github.com/GiaSen/Chlorophyll) | `dipper` (`4f37778`) | 2026-11-20 | **Active** | `gpu/metal` (submodule) | Metal on Adreno 630 over Mesa Turnip (with rotated framebuffer & memoryless attachment fixes). |
| [ry-diffusion/Bergamota](https://github.com/ry-diffusion/Bergamota) | `develop` (`37a7a7a`), `claude/exciting-tesla-739695` | 2026-11-24 | **Active** | `.` (`upstream`) | Upstream Poco F1 (`beryllium`, SDM845) port; `develop` unchanged since 2026-10-26, new `1020`/`1021` panic-recovery + `sweetcores` branch on 2026-11-24. |
| [ry-diffusion/Chlorophyll](https://github.com/ry-diffusion/Chlorophyll) | `main` (`787338f`) | 2026-10-26 | Dormant | `gpu/metal` (`upstream`) | Upstream Metal-on-Turnip translator for Bergamota (★6). |
| [oosexgang/hakios-xnu-kernel](https://github.com/oosexgang/hakios-xnu-kernel) | `common` (local on `main` `63fc2b4`) | 2026-11-22 | **Active** | `research/hakios-xnu-kernel` | Core HakiOS kernel + Darwin 26/27 userland (`components/apple-id/`, `HakiosMetal`, drivers; ★2855). Note: local shallow clone tracks `main`; active remote branch is `common`. |
| [kiwiiiii-eth/hakios-xnu-kernel](https://github.com/kiwiiiii-eth/hakios-xnu-kernel) | `fajita` (`278b6b9`, `fajita-v0.7-beta`) | 2026-11-23 | **Active** | `research/hakios-fajita-kernel` | OnePlus 6T (SDM845) HakiOS kernel: QMI LOC GPS, TSENS thermal guard, MDP `fb_hw`, 3.2 Mbit/s BT + AirPods, `MiniAppleKeyStore` `aks_flags`. |
| [youzjuzi/dipper-xnu](https://github.com/youzjuzi/dipper-xnu) | `main` (`5fcd752`) | 2026-11-19 | **Active** | `research/youzjuzi-dipper-xnu` | Xiaomi Mi 8 (`dipper`) on HakiOS / iOS 16.5 (★105): 66 °C `thermgov`, `fb_native=2` scanout, Wi-Fi LQM bars (keep GPL `mi8_a630_hw_init.inc` out). |
| [LineageOS/android_kernel_xiaomi_sdm845](https://github.com/LineageOS/android_kernel_xiaomi_sdm845) | `lineage-22.2` (`aa8adfe9`) | 2026-02-09 | Reference | `research/lineage-sdm845` | Linux 4.9 GPL-2.0 hardware reference only (sparse checkout: DTBs, EA8074 panel, `fts_521` touch, SDE, TAS2557/ADSP). |
| [linux-msm/hexagonrpc](https://github.com/linux-msm/hexagonrpc) | `main` (`da7a374`) | — | Reference | `research/hexagonrpc` | GPL-3.0 protocol reference for Qualcomm SLPI / FastRPC sensor registry serving. |

---

## 1. High Usefulness for Mi 8 & Actively Updated (`pushed 2026-11-18..24`)

### 1A. iCloud Sign-In, App Store Catalog, Activation & FairPlay Research

> **Status across all ports (2026-11-24):** No project has solved on-device `fairplayd.H2`, FairPlay DRM binary decryption (`cryptid 1` / `mremap_encrypted`), or App Store app downloads. The working path for **iCloud Settings sign-in** and **App Store catalog browsing** on Mi 8 (`iOS 26.6.2`) is combining **`SuperProgramer64/HackiCloud`** (Mac native helpers + phone hooks) with **`oosexgang/hakios-xnu-kernel@common`** (`inject_kc`, `inject_mad`, `appstored` migration/storefront fixes).

| Repository | Branch | Last Push | ★ | Licence | What Makes It Useful for Mi 8 |
| --- | --- | --- | ---: | --- | --- |
| [SuperProgramer64/HackiCloud](https://github.com/SuperProgramer64/HackiCloud) | `main` | 2026-11-19 | 1 | MIT | **Best Mac-bridge & catalog tool.** Self-contained universal (`arm64`+`x86_64`) macOS helpers + pure `method_setImplementation` iOS hooks: relays anonymous Anisette (`AOSUtilities` → `akd` `AKNativeAnisetteService`), `Preferences` NAC signing (`AAAbsintheSigner`), and caches a ~30-day anonymous `AMSMediaTokenService` Bearer token into `AMSMediaTokenServiceKeychainStore` for `amp-api` catalog browsing. Needs swapping `usbmuxd` for TCP/`ssh -R` over `192.168.7.1`. No App Store login/downloads. |
| [oosexgang/hakios-xnu-kernel](https://github.com/oosexgang/hakios-xnu-kernel) | `common` | 2026-11-22 | 2855 | MIT (userland/tools) / APSL 2.0 (XNU) | **Best iOS 26/27 daemon fixes (`components/apple-id/`).** `inject_kc.c` downgrades `akpu` → `cku` & strips `kSecAttrAccessControl` in `akd`/`accountsd` so `PersistGrandslamTokens` does not sign out; `inject_mad.c` dev-fuses `mobileactivationd` (`should_hactivate` → `"Activated"`); `inject_store.c` + `root26-darwin.sh` fix `appstored` migration deadlock (`LastOSBuildVersion`), `ZACCOUNTTYPE` account types, and storefront; `inject_locationd.c` stops `locationd` blocking on `fairplayd`; `first-generation/inject_fairplay.c` proves `fairplayd.H2` exits `0` without calling IOKit. (`inject_mescal.m` relies on an uncommitted host `sapd`.) |
| [HouseOfBalance/hakios-xnu-kernel](https://github.com/HouseOfBalance/hakios-xnu-kernel) | `main` | 2026-11-24 | 0 | MIT / APSL 2.0 | `xnu-12377.121.6` / iOS 27.2 port (`sapphire`, SM6225). Carries Substrate-free `__DATA,__interpose` versions of `inject_mad.c` (`MGCopyAnswer`) and `inject_kc.c` probes, plus `kernel/overlay/iokit/Kernel/MiniFairPlay.cpp` (a `com_apple_driver_FairPlayIOKitUserClient` selector logger for `adid` that zeroes outputs — diagnostic instrument only, not real FairPlay). |
| [jesvi-eulah/Jesvi-iOS](https://github.com/jesvi-eulah/Jesvi-iOS) & [N1709/hakios-universal9830](https://github.com/N1709/hakios-universal9830) | `main`, `feat/s20-native-fairplay` | 2026-11-24 / 2026-11-22 | 43 / 1 | MIT / APSL 2.0 | Exynos 990 (Galaxy S20, iOS 16.5) twin repos with 114 files in `tools/apple-account/`: `native-media-provider.m` (Mac-side `AMSMescalSession` `sign`/`prime`/`verify` + `AMSAnisette` Store AMD type-2 `X-Apple-AMD` proofs), `docs/APPLE-ACCOUNT-HANDOVER.md` (iCloud sign-in working via Mac SSH; Media & Purchases still fails with empty HTTP 200 → `AMSErrorDomain 100`), `docs/devices/x1slte/continuity.md` (APNs blocked at `albert.apple.com`), and `feat/s20-native-fairplay` (unfinished `FairPlayIOKit` kernelcache sidecar prototype, rolled back). |
| [Martinvlba/hakios-xnu-kernel](https://github.com/Martinvlba/hakios-xnu-kernel) | `akita-port` | 2026-11-23 | 0 | MIT / APSL 2.0 | Pixel 8a (`akita`) port moving to `xnu-12377` / iOS 27.2.1; `userland/src/inject_akd.c` (v2–v9) hooks `AKNativeAnisetteService` in `akd` over raw BSD sockets (`3 s` timeout) with identity-coherence header overrides (`X-Mme-Device-Id`, `X-Apple-I-MD-LU`), cited by `HackiCloud`. Companion board repo: [Martinvlba/hakios-devices-akita](https://github.com/Martinvlba/hakios-devices-akita) (`2026-11-23`). |

### 1B. SDM845 Drivers, Thermal, GPS & Core XNU / Metal Ecosystems

| Repository | Branch | Last Push | ★ | Licence | What Makes It Useful for Mi 8 |
| --- | --- | --- | ---: | --- | --- |
| [kiwiiiii-eth/hakios-fajita](https://github.com/kiwiiiii-eth/hakios-fajita) & [kiwiiiii-eth/hakios-xnu-kernel](https://github.com/kiwiiiii-eth/hakios-xnu-kernel) | `main` / `fajita` | 2026-11-23 | 6 / 0 | NOASSERTION / MIT+APSL | **Closest active SDM845 sibling (OnePlus 6T, Beta 0.7).** Actionable references for Mi 8's open items: **TSENS temperature guard** (`hakios.thermal.c` + `tools/dt-thermal.py`), **QMI LOC GPS + `CLSimulationManager`** (`hakios.mpss845.c` + `gnssfeed.m`), main camera OIS notes (`BU24218GWL`), `F_GETPROTECTIONCLASS` class-D stub for `StreamingZip`/`mobileassetd` (AirPods cards), and `LOCKDOWN=1` (`lockdownd` persistent device name). |
| [youzjuzi/dipper-xnu](https://github.com/youzjuzi/dipper-xnu) | `main` | 2026-11-19 | 105 | MIT / APSL (1 GPL file) | **Same phone (`dipper`) on HakiOS / iOS 16.5.** Behind us on OS/cameras/cellular/mic/BT-audio, but useful SDM845 Mi 8 references for its 66 °C `thermgov` CPU cap, `fb_native=2` scanout, Wi-Fi LQM signal bars, and muted volume HUD ring-switch note (`docs/FORKS_SURVEY.md` I1). |
| [UniXNU/UniXNU](https://github.com/UniXNU/UniXNU) | `main` (50 branches) | 2026-11-19 | 3108 | BSD / APSL / MIT | Major UEFI ARM64 XNU framework (`xnu-12377`, iPadOS 27.0.1 & macOS 27.3 profiles). Useful for `scripts/appsync/` (on-device `installd` ad-hoc re-signing + dynamic engineering trust-cache registration), 4 KiB page signature hash cache, and `AppleKeyStoreState`. Explicitly provides no FairPlay or App Store auth. |
| [yfl520/hackios-raphael](https://github.com/yfl520/hackios-raphael) | `main` | 2026-11-21 | 3 | NOASSERTION | Redmi K20 Pro (SM8150, iOS 16.5): Titan CSIPHY/CSID/IFE camera path (`hakios.camera.c`), Android dual-boot module, screen recorder (`FORKS_SURVEY.md` G5). |

---

## 2. Moderate / Specific-Topic Reference (`Recent` or `Dormant`, Targeted Value)

Repositories that are either less frequently updated or target different hardware/VMs, but contain specific technical findings already used or worth consulting:

| Repository | Branch | Last Push | ★ | Activity | Topic & Usefulness |
| --- | --- | --- | ---: | --- | --- |
| [Lakr233/vphone-cli](https://github.com/Lakr233/vphone-cli) | `main` | 2026-11-24 | 16805 | **Active** | Apple Silicon `Virtualization.framework` iOS VM tool. `Research/Kernel/kernel_fairplay_kexts.md` documents `AvpFairPlayDriver.kext` + `FairPlayIOKit.kext` (VM-only, not usable on Android); `Research/Guest/post_setup_signin_and_appstore.md` documents `CoreFollowUp` (`appleidsetupd`/`followupd`) badge suppression. (Older fork: [zackben1git/vphone-cli](https://github.com/zackben1git/vphone-cli), `2026-03-02`, ★15.) |
| [UniXNU/Adreno740](https://github.com/UniXNU/Adreno740) | `main` | 2026-11-17 | 13 | Recent | Native XNU Adreno 740 (a7xx, SM8550) kernel driver + `NativeSandboxGrantProcess` IOKit sandbox hook reference. |
| [frxncyyy/ios-denniz](https://github.com/frxncyyy/ios-denniz) | `main` | 2026-11-17 | 0 | Recent | OnePlus Nord 2 (MT6893, `ios-sweet` fork); origin of the `locfix2` (`locationd` Mescal silo hang), `respawn1` (`fairplayd` throttle), and `0277y` (`IMDPersistence` Messages banner build key) fixes credited by HakiOS. |
| [UniXNU/QcomBaseband](https://github.com/UniXNU/QcomBaseband) | `main` | 2026-11-09 | 5 | Recent | Qualcomm baseband bridge & SC7180 IPA data path reference for XNU. |
| [oosexgang/hakios-metal](https://github.com/oosexgang/hakios-metal) | `main` | 2026-11-05 | 41 | Recent (merged) | Native A6xx Metal driver (`AIR -> NIR -> ir3`, MIT; `FORKS_SURVEY.md` G1). Now folded into `oosexgang/hakios-xnu-kernel` (`components/metal/`). |
| [dipa-studio/ios-sweet](https://github.com/dipa-studio/ios-sweet) | `main` | 2026-10-23 | 1386 | Dormant | Original `ios-sweet` upstream (Redmi Note 10 Pro, SM7150, iOS 16 / `xnu-8796`). Historical ancestor of Bergamota's early patch series. |
| [MakrSas/ios-topaz](https://github.com/MakrSas/ios-topaz) | `topaz` | 2026-10-22 | 641 | Dormant | Redmi Note 12 (`topaz`, SM6225): early MDP direct scanout, backlight, and Qualcomm PAS/QRTR/WLFW/WLAN bring-up ancestor (`docs/TOPAZ_REVIEW.md`). |
| [ch1tmdgus/ios-v60](https://github.com/ch1tmdgus/ios-v60) | `main` | 2026-10-22 | 7 | Dormant | LG V60 (SM8250): clean QCA Bluetooth UART SE clock/FIFO/HCI bring-up notes (`FORKS_SURVEY.md` C). |
| [anonbeat1/ios-sweet](https://github.com/anonbeat1/ios-sweet) | `main` | 2026-10-21 | 0 | Dormant | Nothing Phone (1) (`Spacewar`, SM7325): SMMU SMR-reuse DMA fix, DWC3 USB gadget, `SweetNetwork.cpp` `configd` interface (`FORKS_SURVEY.md` A1, D1, D5). |
| [arielTROY/ios-sweet](https://github.com/arielTROY/ios-sweet) | `main` | 2026-10-19 | 0 | Dormant | Pixel (`stallion`, Tensor G4): DWC3 `GUSB2PHYCFG0` `SUSPHY` clearing around endpoint commands (`FORKS_SURVEY.md` A3). |

---

## 3. Actively Updated Other-Device Ports (`pushed 2026-11-18..24`, Low Direct Transfer to Mi 8)

Active ports whose recent commits are board-specific bring-up (other SoCs, or SDM845 ports still far behind `dipper`):

### 3A. From Our Surveyed Set

| Repository | Branch | Last Push | ★ | Target / Notes |
| --- | --- | --- | ---: | --- |
| [keyfan/UniXNU-enchilada-bringup](https://github.com/keyfan/UniXNU-enchilada-bringup) | `main` | 2026-11-24 | 4 | OnePlus 6 (SDM845) on UniXNU: very active Adreno 630 GMU/HFI start-up bisecting (`R293`–`R302`); behind `dipper` on userland/peripherals. |
| [lizi600jin/hakios-xaga](https://github.com/lizi600jin/hakios-xaga) | `main` | 2026-11-24 | 7 | Redmi Note 11T Pro (`xaga`, MediaTek MT6895): iOS 16.5 SpringBoard, `/private/var` on UFS, USB network just brought up. |
| [limonetexd/ios-sweet-gpu](https://github.com/limonetexd/ios-sweet-gpu) | `main` | 2026-11-23 | 0 | Redmi Note 10 Pro (`sweet`, SM7150): iOS 16 Metal on Adreno 618. |
| [wuxianlin/hackios-os_devices_oneplus-dodge](https://github.com/wuxianlin/hackios-os_devices_oneplus-dodge) & [wuxianlin/hakios_devices_dodge](https://github.com/wuxianlin/hakios_devices_dodge) | `main` | 2026-11-23 | 6 / 6 | OnePlus 13 (`dodge`, SM8750) HakiOS device package: Iris VPU firmware, `bluetool`, Wi-Fi/haptic config. |
| [Swaggyxren/hackios-lh8n](https://github.com/Swaggyxren/hackios-lh8n) | `mtk` | 2026-11-22 | 0 | Tecno Pova 5 Pro 5G (`LH8n`, MT6833): 119 fps OVL zero-copy scanout, Mali Panfrost, MT6359P keys/battery. |
| [criollojoel10/hakios-sm6125](https://github.com/criollojoel10/hakios-sm6125) & [criollojoel10/hakios-begonia](https://github.com/criollojoel10/hakios-begonia) | `main` | 2026-11-22 / 2026-11-23 | 0 / 0 | Xiaomi Mi A3 (`laurel_sprout`, SM6125) & Redmi Note 8 Pro (`begonia`, MT6785) early UEFI/ramoops/XNU bring-up. |
| [oosexgang/hakios-sm7325](https://github.com/oosexgang/hakios-sm7325) | `main` | 2026-11-22 | 7 | Official HakiOS board repo for POCO X5 Pro 5G (`redwood`, SM7325). |
| [ampekk/ios-guacamole-hotdog](https://github.com/ampekk/ios-guacamole-hotdog) | `main` | 2026-11-22 | 0 | OnePlus 7 Pro / 7T Pro (`guacamole`/`hotdog`, SM8150): `xnu-12377` SWEET adaptation, CI builds. |
| [suryastark6/ios-alioth](https://github.com/suryastark6/ios-alioth) | `main` | 2026-11-20 | 0 | POCO F3 / Redmi K40 (`alioth`, SM8250): iOS 16 + Adreno 650 early frames (`gpu-test`). |
| [azjhf-dev/ios26-on-xiaomi15](https://github.com/azjhf-dev/ios26-on-xiaomi15) | `main` | 2026-11-19 | 0 | Instructions-only repo for iOS 26 (`arm64e`) on Xiaomi 15 (`dada`, SM8750). |
| [RisanYu/r1-hakios-port](https://github.com/RisanYu/r1-hakios-port) | `main` | 2026-11-18 | 1 | Smartisan Nut R1 (`trident`, SDM845) on HakiOS: reached home screen 2026-11-18; behind `dipper`. |

### 3B. Newly Seen Board Repos in `2026-11-22..24` GitHub Searches (Board Overlays / Forks)

- **HakiOS forks & device repos (`2026-11-22..24`):** [iola1999/hackios-redmi-k90-annibale](https://github.com/iola1999/hackios-redmi-k90-annibale) (★45, Redmi K90 SM8750), [Luoxueowo/hakios-xnu-kernel](https://github.com/Luoxueowo/hakios-xnu-kernel) (★7), [lyteenb/hackios-xnu-kernel-OnePlus9-27.2](https://github.com/lyteenb/hackios-xnu-kernel-OnePlus9-27.2) (OnePlus 9 iOS 27.2), [3kierz/hackios-devices-shiba](https://github.com/3kierz/hackios-devices-shiba) (Pixel 8 Tensor G3), [lopro104/hakios_device_google_sunfish](https://github.com/lopro104/hakios_device_google_sunfish) (Pixel 4a), [AnkitChoudhary-1/Hakios-Galaxy-A515F](https://github.com/AnkitChoudhary-1/Hakios-Galaxy-A515F), [BeruCrypt02/x6886-hakios](https://github.com/BeruCrypt02/x6886-hakios) (MT6789), [chenlumina/hakios-mesa-ci](https://github.com/chenlumina/hakios-mesa-ci), [BxiiDN/hakios-pipa](https://github.com/BxiiDN/hakios-pipa), [S0SL/hakios-mars](https://github.com/S0SL/hakios-mars), [unix-qv/hakios-sm6475](https://github.com/unix-qv/hakios-sm6475), [mrmdgomes/hakios-motog825g](https://github.com/mrmdgomes/hakios-motog825g), [vael01id/HakiOS-Garnet-by-Vael](https://github.com/vael01id/HakiOS-Garnet-by-Vael), [SUBdeep/hackios-pocof3](https://github.com/SUBdeep/hackios-pocof3), [tejaskhanna989/ios-m30lte](https://github.com/tejaskhanna989/ios-m30lte).
- **UniXNU device repos (`2026-11-22..24`):** [lenzhang/UniXNU-xiaomipad8pro](https://github.com/lenzhang/UniXNU-xiaomipad8pro) (★16, Xiaomi Pad 8 Pro SM8750 macOS 27) & [dongyanchen-dev/UniXNU-piano](https://github.com/dongyanchen-dev/UniXNU-piano), [jerry-2009/UNIXNU_elden](https://github.com/jerry-2009/UNIXNU_elden) (★7), [Denis0x00/UniXNU-j716f](https://github.com/Denis0x00/UniXNU-j716f) (★5), [kerrinz/UniXNU-zorn](https://github.com/kerrinz/UniXNU-zorn) (★4, Redmi K80) & [kerrinz/uefi-zorn](https://github.com/kerrinz/uefi-zorn), [obaosp/UniXNU-cupid](https://github.com/obaosp/UniXNU-cupid) (★3, Xiaomi 12 SM8450 iOS 27.0.1), [Dracen-W/UniXNU-merlinx](https://github.com/Dracen-W/UniXNU-merlinx) (★3, MT6768) & [Dracen-W/NativeEmmc](https://github.com/Dracen-W/NativeEmmc), [qiumochen/UniXNU-zizhan](https://github.com/qiumochen/UniXNU-zizhan) (★3, MIX Fold 2), [breezeczz/unixnu-xigua](https://github.com/breezeczz/unixnu-xigua), [Dogsdoge/ShengUfs-mt6895](https://github.com/Dogsdoge/ShengUfs-mt6895), [NIJIKA-529/UniXNU-wayne](https://github.com/NIJIKA-529/UniXNU-wayne) & [NIJIKA-529/uefi-wayne](https://github.com/NIJIKA-529/uefi-wayne), [yecw/UniXNU-kebab](https://github.com/yecw/UniXNU-kebab), [redmagikarp13/UniXNU-ginkgo](https://github.com/redmagikarp13/UniXNU-ginkgo), [zhangxucheng018/UniXNU-ace6t](https://github.com/zhangxucheng018/UniXNU-ace6t), [zjh3215588/unixnu-vince](https://github.com/zjh3215588/unixnu-vince), [nian0114/UniXNU-houji](https://github.com/nian0114/UniXNU-houji), [1359352487-droid/meizu15-unixnu](https://github.com/1359352487-droid/meizu15-unixnu), [yeyingjun-codes/unixnu-sheng-fence](https://github.com/yeyingjun-codes/unixnu-sheng-fence), [MikelikeXiaoyezi/UniXNU-munch](https://github.com/MikelikeXiaoyezi/UniXNU-munch), [pyhs5g27vr-hue/unixnu-ci](https://github.com/pyhs5g27vr-hue/unixnu-ci), [BrowserPorts/UniXNU](https://github.com/BrowserPorts/UniXNU) (mirror).
- **Bergamota / `ios-sweet` derivatives (`2026-11-22..24`):** [tomcat080/ios-xnu](https://github.com/tomcat080/ios-xnu) (`xnu-8796` beryllium 135-patch build), [hyperOS-li/ios-sweet-camellia-build](https://github.com/hyperOS-li/ios-sweet-camellia-build) (★3, MT6833), [albrans1bas-beep/ios-sweet](https://github.com/albrans1bas-beep/ios-sweet), [asasasasqwqw391/ios-sweet-onc](https://github.com/asasasasqwqw391/ios-sweet-onc), [shin5968/ios-xcover5](https://github.com/shin5968/ios-xcover5) (Exynos 850), [zhouzhoublm/ios-unicorn](https://github.com/zhouzhoublm/ios-unicorn) (Xiaomi 12S Pro SM8475), [andrecremo/ios-doha](https://github.com/andrecremo/ios-doha) (Moto G8 Plus SM6125).

---

## 4. Older / Dormant Surveyed Ports (`pushed <= 2026-11-17`, Low Usefulness Now)

### 4A. Older SDM845 Ports (Superseded by `dipper`)

| Repository | Branch | Last Push | ★ | Activity | Notes |
| --- | --- | --- | ---: | --- | --- |
| [edi194/ios-fajita](https://github.com/edi194/ios-fajita) | `main`, `brg-port` | 2026-11-14 | 6 | Recent | OnePlus 6T (`ios-sweet` / Bergamota `37a7a7a` import); behind `dipper` (`FORKS_SURVEY.md` E, H0). |
| [dragon120820/UniXNU-sdm845-common](https://github.com/dragon120820/UniXNU-sdm845-common) | `main` | 2026-11-14 | 0 | Recent | Skeleton shared SDM845 SoC layer for UniXNU. |
| [JaneAwA/polaris-ios14](https://github.com/JaneAwA/polaris-ios14) | `main` | 2026-11-13 | 0 | Recent | Xiaomi Mi MIX 2S (`polaris`): early `xnu-7195` (iOS 14) pmap/TLB bring-up. |
| [WeiXiaoye/perseus-xnu](https://github.com/WeiXiaoye/perseus-xnu) | `main` | 2026-11-09 | 2 | Recent | Xiaomi MIX 3 (`perseus`): HakiOS bring-up with tearing GPU output. |
| [wangshaofan82-png/UniXNU-enchilada-port](https://github.com/wangshaofan82-png/UniXNU-enchilada-port) | `main` | 2026-11-01 | 2 | Recent | OnePlus 6 (`enchilada`): unverified on hardware (`FORKS_SURVEY.md` G7). |
| [johnpanos/UniXNU-fajita](https://github.com/johnpanos/UniXNU-fajita) | `main` | 2026-10-27 | 7 | Dormant | OnePlus 6T on UniXNU (iPadOS 17.7): stops at root mount (`FORKS_SURVEY.md` G7). |
| [GSHPChina/mi8-ios](https://github.com/GSHPChina/mi8-ios) | `main` | 2026-10-26 | 1 | Dormant | Windows PowerShell/WinForms wrapper around `ios-fajita` iOS 16 (`FORKS_SURVEY.md` G7). |
| [luuu20309/ios-sweet](https://github.com/luuu20309/ios-sweet) | `main` | 2026-10-23 | 10 | Dormant | Mi MIX 2S (`polaris`) early FB/scaling patches, not hardware-tested (`FORKS_SURVEY.md` E). |

### 4B. Older Non-SDM845 Forks & Copies

| Repository | Branch | Last Push | ★ | Activity | Notes |
| --- | --- | --- | ---: | --- | --- |
| [xm6661885/hakios-xnu-kernel-umi-fixes](https://github.com/xm6661885/hakios-xnu-kernel-umi-fixes) | `main` | 2026-11-16 | 7 | Recent | Xiaomi Mi 10 (`umi`, SM8250) fixes on HakiOS iOS 16.5. |
| [theasianviet-lab/hackios-s7-kernel](https://github.com/theasianviet-lab/hackios-s7-kernel) | `herolte` | 2026-11-15 | 0 | Recent | Galaxy S7 (`herolte`, Exynos 8890) HakiOS + Mesa/EAGL build repo. |
| [nithinyadavamaraboina-online/IOS-26-Hot](https://github.com/nithinyadavamaraboina-online/IOS-26-Hot) | `master` | 2026-11-12 | 2 | Recent | iOS 26.5.2 (`xnu-12377`) bring-up fork. |
| [qdizax-w/hakios-sm7125](https://github.com/qdizax-w/hakios-sm7125) | `main` | 2026-11-12 | 4 | Recent | Redmi Note 9S/Pro (`miatoll`, SM7125) HakiOS board repo. |
| [Gsjsjzhznsz/ios-sweet](https://github.com/Gsjsjzhznsz/ios-sweet) | `main` | 2026-11-10 | 29 | Recent | Redmi K20 Pro (`raphael`, SM8150) `ios-sweet` fork (`FORKS_SURVEY.md` A4). |
| [skglab-dev/ios-taoyao](https://github.com/skglab-dev/ios-taoyao) | `main` | 2026-11-09 | 0 | Recent | Xiaomi 12 Lite (`taoyao`, SM7325) copy of early HakiOS. |
| [olaffx/ios-miatoll](https://github.com/olaffx/ios-miatoll) | `main` | 2026-11-09 | 2 | Recent | Redmi Note 9 Pro (`miatoll`) copy of `ios-sweet` (`FORKS_SURVEY.md` A5). |
| [karthiknathan98-tech/A50s_IOS](https://github.com/karthiknathan98-tech/A50s_IOS) | `main` | 2026-11-08 | 0 | Recent | Bergamota layout adapted for Galaxy A50s (Exynos). |
| [austndoesui/ios-cactus](https://github.com/austndoesui/ios-cactus) | `main` | 2026-11-06 | 3 | Recent | Redmi 6A (`cactus`, MT6761/MT6765) board config (`FORKS_SURVEY.md` F). |
| [Jous99/ios-cepheus](https://github.com/Jous99/ios-cepheus) | `main` | 2026-11-06 | 0 | Recent | Xiaomi Mi 9 (`cepheus`, SM8150) boot markers only (`FORKS_SURVEY.md` top). |
| [danstronics/ios-s9plus-exynos](https://github.com/danstronics/ios-s9plus-exynos) | `main` | 2026-11-06 | 35 | Recent | Galaxy S9+ (Exynos 9810) iOS 16.5 GLES boot research port. |
| [MC-XiaoXiao/ios_sagit](https://github.com/MC-XiaoXiao/ios_sagit) | `main` | 2026-11-04 | 17 | Recent | Xiaomi Mi 6 (`sagit`, MSM8998 / SDM835) XNU tree. |
| [orhunnx/ios-a5xelte](https://github.com/orhunnx/ios-a5xelte) | `main` | 2026-11-03 | 9 | Recent | Galaxy A5 (2016) `ios-sweet` fork (`FORKS_SURVEY.md` F). |
| [superboyyy/hakios-arm64e-dada](https://github.com/superboyyy/hakios-arm64e-dada) | `main` | 2026-10-31 | 166 | Dormant | Early iOS 26 (`arm64e`) drop for Xiaomi 15 (`dada`, SM8750) carrying first-gen HakiOS userland. |
| [azzlantern/hackios-thyme](https://github.com/azzlantern/hackios-thyme) | `main` | 2026-10-27 | 3 | Dormant | Xiaomi Mi 10S (`thyme`, SM8250) HakiOS bring-up. |
| [HeliumStudio-Dev/hackios-xnu-kernel](https://github.com/HeliumStudio-Dev/hackios-xnu-kernel) | `raphael-bringup` | 2026-10-27 | 59 | Dormant | Earlier Redmi K20 Pro (`raphael`) HakiOS fork (base of `yfl520/hackios-raphael`). |
| [kuyu132/HackiOS9r](https://github.com/kuyu132/HackiOS9r) | `main` | 2026-10-27 | 0 | Dormant | OnePlus 9R (`lemonades`, SM8250) early HakiOS fork. |
| [qz888795-glitch/hackios_xnu_kernel-umi](https://github.com/qz888795-glitch/hackios_xnu_kernel-umi) | `main` | 2026-10-26 | 1 | Dormant | Xiaomi Mi 10 (`umi`) early HakiOS migration. |
| [SQMY-dor/hackios-xnu-kernel-sm8750](https://github.com/SQMY-dor/hackios-xnu-kernel-sm8750) | `main` | 2026-10-23 | 5 | Dormant | Early OnePlus 13 (`dodge`, SM8750) HakiOS fork. |
| [Log1nYT/ios-sweet](https://github.com/Log1nYT/ios-sweet) | `main` | 2026-10-23 | 0 | Dormant | Xiaomi Mi 11 (`venus`, SM8350) GCC USB offset patch (`FORKS_SURVEY.md` A4). |
| [blahajcoding/ios-lemonadep](https://github.com/blahajcoding/ios-lemonadep) | `main` | 2026-10-22 | 0 | Dormant | OnePlus 9 Pro (`lemonadep`, SM8350) board stub (`FORKS_SURVEY.md` F). |
| [palazik/ios-dodge](https://github.com/palazik/ios-dodge) | `main` | 2026-10-21 | 11 | Dormant | Early OnePlus 13 (`dodge`, SM8750) `ios-sweet` fork (`FORKS_SURVEY.md` F). |
| [PalanBanana/ios-sweet](https://github.com/PalanBanana/ios-sweet) | `main` | 2026-10-21 | 0 | Dormant | Skeleton WCN3990/A618 notes (`FORKS_SURVEY.md` C). |
| [zsariboga/ios-sweet](https://github.com/zsariboga/ios-sweet) | `main` | 2026-10-20 | 0 | Dormant | QEMU scanout & empty `IOAcceleratorES` logger (`FORKS_SURVEY.md` B). |

---

## 5. Gone / Private (`HTTP 404` as of 2026-11-24)

Previously surveyed repositories that are no longer publicly accessible on GitHub (key technical details remain recorded in [`docs/FORKS_SURVEY.md`](FORKS_SURVEY.md)):

| Former Repository | Preserved Notes in `FORKS_SURVEY.md` |
| --- | --- |
| `dipa-studio/ios-extra` | Section C — early Adreno 618 GMU RSC/OOB experiments (`sweet`). |
| `Lrdsnow/ios-froggerpro` | Sections A2, B, C, D2–D5 — Nothing Phone (4a) Pro (`kera`, SM7750): USB shim, EPSS 85% thermal cap, default route, PTY shell. |
| `ibragruslan/ios-sweet` | Sections B, C, D7 — Xiaomi Pad 5 (`nabu`, SM8150): Adreno 640 GMU/HFI/SCM bring-up, HFS hotfiles off (`0081`). |
| `marnov999/ios-sweet` | Section C — Mi 9T (`davinci`, SM7150): Adreno 618 GMU cold-boot / ARC vote notes. |
| `RiverKawa271828/ios-meizu-m2381` | Section D6 — Meizu 20 (SM8550): UFS bring-up & Gunyah GICv3 `nASSGIreq` note. |
| `terx1232/ios-sweet` | Section B — Galaxy Tab A 8.0 (`t290`, SDM429 QEMU): 4K-under-16K `PAGE_RATIO` & zone-map patches. |
| `damjankakak3/ios-zeus` | Section F — Xiaomi 12 Pro (`zeus`), was identical to upstream `ios-sweet` (went 404 between 2026-11-22 and 2026-11-24). |
| `new-green/ios-pacman` | Section F — Nothing Phone (2a) board stub. |
| `0xDive/ios-nabu` | Top / Section A5 — U-Boot/Termux notes only. |
