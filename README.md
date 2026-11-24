<p align="center">
  <img src="tools/identity/icon-512.png" width="168" alt="Bergamota">
</p>

<h1 align="center">Bergamota Project</h1>

<p align="center">
  <b>Apple's iOS 26 on a Xiaomi Mi 8</b><br>
  Xiaomi <code>dipper</code> · Qualcomm Snapdragon 845 · iOS 26.6.2 (23G90)
</p>

<p align="center">
  <img alt="iOS 26.6.2" src="https://img.shields.io/badge/iOS-26.6.2-1a5933?style=flat-square">
  <img alt="SpringBoard" src="https://img.shields.io/badge/SpringBoard-on%20the%20GPU-d7e98a?style=flat-square">
  <img alt="Kernel" src="https://img.shields.io/badge/kernel-Heartwood%20xnu--12377-161616?style=flat-square">
  <img alt="Host" src="https://img.shields.io/badge/host-macOS-555?style=flat-square">
</p>

<p align="center"><sub>The face of the project is Isaac Newton, after Godfrey Kneller's 1689 portrait (public domain), printed as a halftone. Identity: <a href="tools/identity/IDENTITY.md"><code>tools/identity/IDENTITY.md</code></a>.</sub></p>

---

This is the `dipper` branch of [GiaSen/Bergamota](https://github.com/GiaSen/Bergamota): the port to the **Xiaomi Mi 8**. Upstream [Bergamota](https://github.com/ry-diffusion/Bergamota) (`develop`) runs iOS 18.7.8 on the Poco F1, which has the same Snapdragon 845. The Getting started guide further down is still upstream's Poco F1 route; the Mi 8 steps are in [Building for the Mi 8](#building-for-the-mi-8).

The Mi 8 boots the **unmodified iOS 26.6.2 userland of the iPhone 11** (`iPhone12,1`) to SpringBoard and its home screen, composited on the phone's own GPU. It runs from its own UFS storage and is driven from a Mac over USB. Five parts make that work, four of them named after a piece of the bergamot tree:

| | Part | What it does | Where |
| --- | --- | --- | --- |
| 🍋 | **Bergamota** | The macOS control plane. It shows phone status and the live kernel log, builds boot images, and runs the boot and flash queue. A second-screen Control Plane view also handles sideloading and media upload. | [`apps/Bergamota`](apps/Bergamota) |
| 🌿 | **Enxerto** | The bootloader ("graft"). Qualcomm ABL starts it from the `boot` partition. It inflates the kernel with the MMU on, hands it a device tree and boots it. It also has its own fastboot and an off-mode charging screen. | [`enxerto/`](enxerto) |
| 🪵 | **Heartwood** | The kernel: Apple's open-source XNU (xnu-12377, the iOS 26 generation) plus our patches for the Snapdragon 845. The Mi 8's own drivers are patches 3001 onwards. Built on the Mac with `tools/xnu-local-build.sh`. | [`xnu/patches-12377`](xnu/patches-12377) |
| 🏴 | **Renegade** | The patcher. It rewrites every arm64e Mach-O and the whole dyld shared cache so they run on a CPU without pointer authentication. It then builds the flashable iOS root image. | [`tools/renegade`](tools/renegade) |
| 🌱 | **Chlorophyll** | Metal for iOS on the Adreno 630, on top of Mesa's Turnip Vulkan driver. With it, backboardd, SpringBoard and the icon renderer draw on the GPU. | [`gpu/metal`](gpu/metal) (submodule, [GiaSen/Chlorophyll](https://github.com/GiaSen/Chlorophyll) `dipper`) |

> [!WARNING]
> This is an experimental bring-up, not a usable phone OS. It installs into `userdata` and **erases Android's user data**. Apple's security model is mostly switched off, so do not put anything personal on it.

## The boot chain

```
Qualcomm ABL (stock, unlocked)
  └─ Enxerto            boot partition · logo + progress bar · Bergamota fastboot · charging screen
      └─ Heartwood      XNU + Apple Device Tree (@2x iPhone 11 identity) + boot-args
          └─ HFS+ root  userdata · iOS 26.6.2, rewritten by Renegade
              └─ dyld → launchd → daemons → backboardd (Chlorophyll) → SpringBoard
```

<p align="center">
  <img src="docs/assets/enxerto-boot.png" width="216" alt="Enxerto boot screen">&nbsp;&nbsp;
  <img src="docs/assets/enxerto-fastboot.png" width="216" alt="Bergamota fastboot">&nbsp;&nbsp;
  <img src="docs/assets/enxerto-charge.png" width="216" alt="Off-mode charging">
</p>
<p align="center"><sub>Enxerto's screens, rendered by its host test: boot, Bergamota fastboot, off-mode charging</sub></p>

## Status (Mi 8, 2026-11-24)

| Part | State | In short |
| --- | --- | --- |
| iOS | ✅ | 26.6.2 (23G90) to SpringBoard and the home screen with the stock apps; Safari plays video, YouTube plays with sound |
| CPU | ✅ | All 8 cores (4× A55 + 4× A75); Renegade rewrites the code that needs pointer authentication |
| [Screen](docs/MI8_HARDWARE.md#screen) | ✅ | The whole panel with the right proportions, the iPhone 11 status bar, brightness |
| [Touch and buttons](docs/MI8_HARDWARE.md#touch-and-buttons) | ✅ | Responsive touch; power, volume and the power-off slider |
| [Graphics](docs/MI8_HARDWARE.md#graphics) | ✅ | iOS draws on the phone's own GPU (Chlorophyll); smooth, not quite iPhone smooth |
| [Wi-Fi](docs/MI8_HARDWARE.md#wi-fi) | ✅ | Joins, rejoins, about 60 Mbit/s each way, low power when idle |
| [Bluetooth](docs/MI8_HARDWARE.md#bluetooth) | ✅ | Finds devices; a Bluetooth speaker pairs and plays |
| [Mobile network](docs/MI8_HARDWARE.md#mobile-network) | 🟡 | SIM, LTE and mobile data work; calls and SMS do not |
| [Speaker](docs/MI8_HARDWARE.md#speaker) | ✅ | All of iOS's sound, with a protection limiter |
| [Microphone](docs/MI8_HARDWARE.md#microphone) | ✅ | Voice Memos and video sound record |
| [Earpiece](docs/MI8_HARDWARE.md#earpiece) | 🟡 | Plays sound; real calls not tried |
| [Vibration](docs/MI8_HARDWARE.md#vibration) | ✅ | Keyboard taps, alerts and haptic patterns |
| [Flashlight](docs/MI8_HARDWARE.md#flashlight) | ✅ | Control Center's button, both rear LEDs |
| [Cameras](docs/MI8_HARDWARE.md#cameras) | 🟡 | All three cameras, photos and video; no 4K, slow motion or HEVC |
| [Battery and charging](docs/MI8_HARDWARE.md#battery-and-charging) | ✅ | Real battery level, charging at up to 1.7 A, about 25-30 mA in standby |
| [Sensors](docs/MI8_HARDWARE.md#sensors) | 🟡 | Rotation, auto-brightness, proximity; no compass or barometer |
| [Temperature](docs/MI8_HARDWARE.md#temperature) | 🟡 | Read, but nothing protects the phone when it gets hot |
| [USB](docs/MI8_HARDWARE.md#usb) | ✅ | Network link to the Mac and charging |
| [Storage](docs/MI8_HARDWARE.md#storage) | ✅ | Internal storage; the Files app shows no locations (the root is HFS+) |
| [Not supported](docs/MI8_HARDWARE.md#not-supported) | ❌ | Fingerprint, face unlock, Secure Enclave, App Store and Weather (FairPlay); NFC and GPS not looked at |
| Kernel |  | Heartwood on xnu-12377.121.6 with the Mi 8's patches 3001-3127 (3097 is kept for the temperature guard), all in the default boot image 174; what each patch does: [kernel patches](docs/MI8_HARDWARE.md#kernel-patches-developer-reference) |
| Next |  | A temperature guard; deeper standby (the chip's own system sleep); calls, SMS, compass and barometer |

✅ works · 🟡 partly · ❌ does not work yet. What each part does, its limits and what was not tried: [`docs/MI8_HARDWARE.md`](docs/MI8_HARDWARE.md).

Every boot, crash and decision is in [`NOTES.md`](NOTES.md): its STATE entry says where things stand, and each piece of work has its own entry. The notes from before the Mi 8 port are in [`docs/NOTES-before-mi8.md`](docs/NOTES-before-mi8.md).

## Building for the Mi 8

The same tools as the Poco F1 guide below, with these differences. Firmware for the GPU, Wi-Fi, Bluetooth and audio comes from the Mi 8's own partitions (back them up first, see `NOTES.md`) and stays out of git, like the device trees and Apple's files.

```sh
# Heartwood, on this Mac (about 28 minutes from scratch; --remake about 18 s after an edit)
tools/xnu-local-build.sh 26.5      # -> research/xnu-local/dxb/fakeroot/System/Library/Kernels/kernel.development.sweet

# Apple Device Tree: the iPhone 11 identity (needs research/ios26/n104ap.adt), then Wi-Fi and the GPU firmware
python3 tools/mkadt.py enxerto/out/dipper-n104-2x.adt --board dipper --highmem --identity n104ap --display-scale 2 --points 414x896
python3 tools/adt-wlan.py enxerto/out/dipper-n104-2x.adt enxerto/out/dipper-n104-2x-wlan.adt
python3 tools/adt-gpufw.py enxerto/out/dipper-n104-2x-wlan.adt enxerto/out/dipper-n104-2x-wlan-gpu.adt \
    --fw research/gpu-fw/dipper --zap research/gpu-fw/dipper
# an ADT made before mkadt.py added /product/haptics, /product/camera "flash" and /arm-io/isp "camera-rear" and
# "camera-front" (it does now) gets them with (the isp node: MobileGestalt's still-camera and front-facing-camera, so
# Camera.app's icon, the lock screen's camera and the switch to the front camera):
python3 tools/adt-haptics.py --rear-camera --front-camera enxerto/out/dipper-n104-2x-wlan-gpu.adt enxerto/out/dipper-n104-2x-wlan-gpu-hap-cam2.adt
# the canvas of the panel's own shape (the default since image 174; the root then needs RENEGADE_NOTCH=1, below)
python3 tools/adt-canvas.py enxerto/out/dipper-n104-2x-wlan-gpu-hap-cam2.adt enxerto/out/dipper-n104-2x-wlan-gpu-hap-cam2-862.adt --points 414x862

# iOS root (RENEGADE_TARGET=ios26 is the default): Chlorophyll, Bluetooth firmware, the speaker, quieter daemons, mobile data
tools/x264-build.sh                                             # movie recording: x264 (GPL) cloned from VideoLAN and built -> research/x264/out
tools/sweetnet/build.sh                                         # our tools and libraries, sweetavc.dylib (the H.264 encoder) among them
tools/cellular/sweetcelld/build.sh                              # -> research/sweetnet/ios18/sweetcelld
tools/dipper-ipa-fw.sh --out research/ipa-dipper/fw             # the IPA firmware from backup/dipper/vendor.img
RENEGADE_CELL=1 RENEGADE_IPA_FW=research/ipa-dipper/fw RENEGADE_CAM_SEQ=research/camera-dipper \
RENEGADE_ORIENT=1 RENEGADE_NOTCH=1 RENEGADE_AMP_FW=research/audio-dipper/fw RENEGADE_BT_FW=research/bt-dipper/fw SWEET_QUIET=1 RENEGADE_CHL=1 \
    tools/renegade/renegade update research/ios26/ios26-root-chl.simg --no-jb
# RENEGADE_CAM_SEQ=DIRECTORY: the camera sensors' register sequences, every *.seq in it (from the phone's own module files
# with tools/camera/camx_v1.py MODULE.bin --seq MODE OUT: imx363-mode2.seq and imx363-mode0.seq for the rear main camera,
# s5k3m3-mode1.seq the telephoto, s5k3t1-mode1.seq the front; or copied from the phone's /usr/local/share/sweetcam/; never in
# git; a single FILE is taken as imx363-mode2.seq) and the cameras' colour tuning, every *.ctun in it (from the phone's
# own tuning files with tools/camera/chromatix.py com.qti.tuned.MAKER_SENSOR.bin OUT: imx363.ctun, s5k3m3.ctun,
# s5k3t1.ctun; never in git; without them plain colours and no lens shading); sweetcam.dylib and Camera's settings (Live Photo off,
# "Most Compatible") go in with the flashlight step either way, RENEGADE_NO_CAMERA=1 leaves all of it out
# RENEGADE_CELL=1 (opt-in): sweetcelld in CommCenter's place and the IPA firmware (mobile data needs a 3073+ kernel);
# on a phone already running, tools/cellular/sweetcelld-install.sh does the same over SSH (--uninstall undoes it)
# RENEGADE_NOTCH=1 (opt-in, needed with the default boot image's 414x862 canvas): the SpringBoard add-on that keeps the iPhone 11's
# status bar (tools/sweetnet/build.sh first; with the old 414x896 canvas it changes nothing; not yet run on a real root image)
# RENEGADE_ORIENT=1 (opt-in): the backboardd orientation shim for screen rotation (tools/sweetnet/build.sh first; rotates
# only with a sensors kernel, 3072c+; with an older kernel it should do nothing, not tried). If backboardd ever loops with
# it, boot the recovery image research/ios26/enxerto-boot-dipper-ios26-118r-noorient.img (kernel 3072d,
# sweetdenypath=sweetorient.dylib, Bluetooth boot-args dropped to fit the 607-byte field): backboardd then starts without it

# boot image with the current boot-args (default ADT: dipper-n104-2x-wlan-gpu-hap-cam2-862.adt, sweetfb_scale=2; needs dtb/dipper/dtb)
tools/dipper-mkboot.sh KERNEL research/ios26/enxerto-boot-dipper-ios26-NN.img
python3 tools/bergamota-flash.py flash userdata research/ios26/ios26-root-chl.simg   # from Bergamota fastboot, delta
fastboot -s bergamota0001 boot research/ios26/enxerto-boot-dipper-ios26-NN.img

# sensors: the sensor DSP's settings files from the backups to the phone. A root image does not carry them: run this
# again after every flash of the root. The kernel (3072 and later) then starts the DSP by itself 190 s into each boot
tools/dipper-sensor-files.sh
ssh root@192.168.7.2 '/var/root/sweetsys kern.sweet_ssc; /var/root/sweetsys kern.sweet_ssc_services'   # its log, its services
ssh root@192.168.7.2 '/var/root/sweetsys kern.sweet_ssc=2'   # start it by hand (test kernels 3070-3071)
ssh root@192.168.7.2 '/var/root/sweetssc lookup; /var/root/sweetssc stream accel 50 3'   # tools/sweetnet/sweetssc.c, not on the current root
```

## Getting started (Poco F1, upstream)

This is upstream's route for the Poco F1 on iOS 18.7.8; for the Mi 8 see [Building for the Mi 8](#building-for-the-mi-8).

You need a Mac (the Renegade root step also runs on Linux, see 3b), a Poco F1 with an **unlocked bootloader**, and a backup of its partitions (see [`docs/NOTES-before-mi8.md`](docs/NOTES-before-mi8.md)).

```sh
brew install --cask android-platform-tools
brew install aarch64-elf-gcc dtc blacktop/tap/ipsw
```

**0. The stock device tree.** Enxerto boots with your phone's own Qualcomm device tree (DTB). On the Poco F1 the ROM's `boot.img` is header v1. Its 21 DTBs are not in a separate section: they are appended to the gzipped kernel (`Image.gz-dtb`), so generic unpackers only give you `kernel`. `tools/extract-dtb.py` gunzips the kernel, splits off the DTBs and picks the one ABL would use:

```sh
# with the phone in OrangeFox/TWRP (adb root), save the stock boot image and the running device tree
adb pull /dev/block/by-name/boot backup/boot.img
adb pull /sys/firmware/fdt dtb/beryllium/live.dtb
python3 tools/extract-dtb.py backup/boot.img dtb/beryllium --live dtb/beryllium/live.dtb
# -> dtb/beryllium/rom-0..20.dtb and dtb/beryllium/dtb = "Beryllium MP v2.1" (msm-id 0x141 0x20001, board-id 0x45 0)
```

Without `--live`, it lists every blob (model, `qcom,msm-id`, `qcom,board-id`) and you choose with `--pick N`. `dtb/` and `backup/` are git-ignored, because they hold your phone's serial and calibration data. Enxerto's `build.sh` reads `dtb/beryllium/dtb`, or takes the path from `DTB=`.

**1. Heartwood (the kernel).** `develop` builds xnu-11215 (`xnu/patches-11215/`) on GitHub's macOS runners:

```sh
gh workflow run xnu.yml -R ry-diffusion/Bergamota -r develop
gh run list -R ry-diffusion/Bergamota -b develop -L 1                       # wait for it, ~20 min
gh run download <RUN_ID> -R ry-diffusion/Bergamota -n xnu-kernel -D xnu/out-develop
```

For a local single-file compile check before spending a CI run, see `tools/xnu-cc.py` and `docs/XNU11215_MIGRATION.md`.

**2. The Apple Device Tree.** Our ADT carries the iPhone identity (`/product`, copied from the real iPhone X device tree) and the Poco F1 hardware:

```sh
python3 tools/remotezip.py IPSW_URL DeviceTree.d22ap.im4p research/ipsw-x/dt      # any iPhone X (iPhone10,3) IPSW
ipsw img4 im4p extract research/ipsw-x/dt/Firmware/all_flash/DeviceTree.d22ap.im4p -o research/ipsw-x/d22ap.adt
python3 tools/mkadt.py enxerto/out/beryllium-hi-3x.adt --board beryllium --highmem --display-scale 3
```

**2b. GPU firmware (optional, for the Adreno 630).** It goes into the ADT, so nothing is written to the iOS root. It is Qualcomm's, so keep it out of git:

```sh
# a630_gmu.bin + a630_sqe.fw from linux-firmware (qcom/), the zap from sdm845-mainline/firmware-xiaomi-beryllium
python3 tools/zap-split.py a630_zap.mbn research/gpu-fw/zap
python3 tools/adt-gpufw.py enxerto/out/beryllium-hi-3x.adt enxerto/out/beryllium-hi-3x-gpu.adt \
    --fw research/gpu-fw/dl --zap research/gpu-fw/zap
```

**3. Renegade (the iOS root).** Download the iOS 18.7.8 root and build the image. No sudo is needed, but you need about 20 GB free. Renegade bakes everything in: app registration on first boot, the PosterBoard fix, the Bluetooth setup, Procursus + Sileo + TrollStore, the default wallpaper, and the `bglrender` launcher (see `tools/renegade/README.md`):

```sh
tools/renegade/renegade fetch-tools   # berga-tools.zip: the prebuilt on-device tools Renegade installs (below)
tools/renegade/renegade fetch         # root dmg + SystemOS/AppOS cryptexes, decrypted
tools/renegade/renegade root          # -> research/ios18/ios18-root-full.simg
tools/renegade/renegade update research/ios18/ios18-root-full.simg   # later: re-apply the tweaks in place
```

**3b. Renegade on Linux (Debian/Ubuntu).** The root image can be built and updated on Linux without compiling anything: `renegade fetch-tools` downloads the same prebuilt on-device tools as on a Mac. If you skip it, the tools that need Xcode (`sweetuicache`, `sweetfp`, the wallpaper tools, `sweetmetrics`, `sweetprefs`, the `bglrender` payload) are skipped automatically, with a summary at the end, unless prebuilt copies are in `research/sweetnet/` or `research/bergamota-gl/`. Everything that is plist or data still happens: launchd edits, preferences (battery %), event timing, Bluetooth environment, the jailbreak userland (Procursus, Sileo, TrollStore) and the dropbear job if its prebuilt binaries exist. It needs **root** (loop device and `mount -t hfsplus`) and the `hfsplus` kernel module:

```sh
sudo apt install python3 curl hfsprogs util-linux zstd dropbear-bin cmake g++ git libfuse3-dev libbz2-dev zlib1g-dev libattr1-dev fuse3
# ipsw: the .deb from https://github.com/blacktop/ipsw/releases ; apfs-fuse (not in the archives): build https://github.com/sgan81/apfs-fuse
tools/renegade/renegade fetch                    # ipsw: root dmg + cryptexes, decrypted
sudo -E tools/renegade/renegade root             # -> research/ios18/ios18-root-full.simg (the ldid signer is downloaded and SHA-256 checked)
sudo -E tools/renegade/renegade update research/ios18/ios18-root-full.simg
RENEGADE_DRY_RUN=1 tools/renegade/renegade root  # prints the mkfs/losetup/mount/apfs-fuse/ldid commands, runs nothing
```

Details, the macOS/Linux matrix and what is not verified yet: `tools/renegade/README.md`, "Platforms".

**3c. berga-tools.zip (the prebuilt on-device binaries).** The small programs Renegade puts into the root (`sweetuicache`, `sweetfp.dylib`, `sweetmetrics`, the wallpaper tools, `SweetRun.app`, `sweetreboot`, ...) and the `bglrender` payload (the EAGL shim, Mesa's `libOSMesa`, our `libdrm` stand-in) are compiled for the phone, so most people should not build them. They are published as `berga-tools.zip` on the [releases page](https://github.com/ry-diffusion/Bergamota/releases) (tags `berga-tools-vN`). `renegade fetch-tools` downloads the newest one, checks it and unpacks it into a cache; it needs only Python 3, on macOS and on Linux, no `gh`:

```sh
tools/renegade/renegade fetch-tools                       # newest berga-tools-vN -> ~/.cache/bergamota/berga-tools
tools/renegade/renegade fetch-tools --tag berga-tools-v1  # a specific one
tools/renegade/renegade fetch-tools --zip ~/Downloads/berga-tools.zip   # a zip you downloaded yourself (offline)
tools/renegade/renegade fetch-tools --status              # what is installed and where Renegade will look
```

`renegade root` and `renegade update` use a binary you built yourself (`research/sweetnet/`, `research/bergamota-gl/`, `$RENEGADE_SWEETNET`, `$RENEGADE_BGL`) first, and the cache only when it is missing. The zip is checked against its SHA-256 (the release's, when it publishes one) and every file in it against the `berga-tools.json` manifest (SHA-256, size, architecture, commit it was built from). A feature whose binary is in neither place is skipped with a message, as before. The zip holds only our own code and the Mesa build, never anything of Apple's or Qualcomm's (`LICENSES/NOTICE.txt` in the zip). The cache is `$RENEGADE_TOOLS_CACHE` if set; `$RENEGADE_BERGA_TOOLS` points at an already unpacked directory.

**Building the tools yourself.** Only needed if you changed the sources in `tools/sweetnet/` or `gpu/eagl/`, or you do not want to run our binaries. It needs a Mac with **Xcode** (the full app, not only the command line tools: the build uses the iPhone SDK through `xcrun -sdk iphoneos`, plus `codesign`) and Python 3. There is no Linux build and no Docker/VM route.

```sh
xcode-select -p && xcrun -sdk iphoneos --show-sdk-version         # both must work
tools/sweetnet/build.sh                      # -> research/sweetnet/ (iOS 16 arm64) and research/sweetnet/ios18/ (arm64e, then `renegade strip --sign`)
TOOLS="hcitest sweetreboot" IOS18=0 tools/sweetnet/build.sh       # a subset; IOS18=0 skips the iOS 18 builds
```

The GL payload (`bglrender`) is built from the `gpu-eagl` branch, not from `develop`: Mesa 25.0.7 is cross-built for iOS (about 1.6 GB of scratch space, `brew install meson bison`), then the shim and the launcher are compiled and signed. `docs/GPU_EAGL.md` on that branch has the details:

```sh
git worktree add ../ios-beryllium-gpu-eagl gpu-eagl && cd ../ios-beryllium-gpu-eagl
export GPU_EAGL_WORK=$HOME/gpu-eagl-work                   # scratch directory
gpu/eagl/mesa/build-mesa.sh                                # Mesa for arm64e (long)
gpu/eagl/make-payload.sh                                   # -> research/bergamota-gl/ (bgl-launch, OpenGLES.framework, libOSMesa, libdrm)
export RENEGADE_BGL=$PWD/research/bergamota-gl             # or copy it into research/bergamota-gl/ of your checkout
```

To make your own `berga-tools.zip` (to share it, or to test what a release would contain):

```sh
tools/berga-tools/package.sh                               # builds tools/sweetnet, then packages -> research/berga-tools-out/berga-tools.zip (+ .sha256)
BUILD=0 tools/berga-tools/package.sh                       # package the binaries that are already built
tools/renegade/renegade fetch-tools --zip research/berga-tools-out/berga-tools.zip
```

`package.sh` takes only an allowlist of files, refuses anything that looks like firmware, an image or a dump, refuses binaries that link anything but system libraries by path, and reads the finished zip back against its manifest. Publishing is `gh release create berga-tools-vN research/berga-tools-out/berga-tools.zip research/berga-tools-out/berga-tools.zip.sha256 --prerelease` (`BERGA_TOOLS_VERSION=N` when packaging). From berga-tools-v2 the zip also carries the dropbear/dash/toybox SSH binaries of `research/ssh-build/out/` (third-party, built by `tools/ssh/build.sh`, license texts in `LICENSES/`): dash is the image's `/bin/sh`, which the first-boot job (app registration, jailbreak post-install) needs, so a Linux build without them fails `verify`.

**4. Enxerto (the boot image).** Pack the kernel, the ADT and the boot-args into an Enxerto boot image. It also takes the Apple logo for the boot screen from your root image, so it is never committed:

```sh
# plain iOS
DTB=dtb/beryllium/dtb tools/renegade/mkboot-full.sh xnu/out-develop/kernel.development.sweet \
    enxerto/out/beryllium-hi-3x.adt enxerto/out/enxerto-boot-develop.img
# with the GPU kept up (sweetgpu=8) and its firmware ADT, as in our tests
CMDLINE="$(sed -n 's/^CMDLINE=${CMDLINE:-"\(.*\)"}$/\1/p' tools/renegade/mkboot-full.sh) sweetgpu=8 ufslogsecs=1" \
DTB=dtb/beryllium/dtb tools/renegade/mkboot-full.sh xnu/out-develop/kernel.development.sweet \
    enxerto/out/beryllium-hi-3x-gpu.adt enxerto/out/enxerto-boot-develop-gpu.img
```

**5. Flash and boot with Bergamota.** Open `apps/Bergamota/Bergamota.xcodeproj` and run it. Bergamota fastboot (`enxerto/out/bergamota-fastboot.img`, built by `enxerto/build.sh`) can flash `userdata`, `boot` and `logo` itself. It flashes `userdata` as a **delta**: it hashes what is on the phone and sends only the changed blocks:

```sh
fastboot boot enxerto/out/bergamota-fastboot.img                                  # from ABL fastboot (Power + Volume Down)
python3 tools/bergamota-flash.py flash userdata research/ios18/ios18-root-full.simg   # delta, verified
python3 tools/bergamota-flash.py flash boot enxerto/out/enxerto-boot-develop-gpu.img  # optional: make it the cold-boot image
apps/Bergamota/scripts/bergamota enqueue enxerto/out/enxerto-boot-develop-gpu.img     # or just RAM-boot it from the queue
```

The first boot takes a few minutes while the first-boot job registers the apps. Then `ssh root@192.168.7.2`. On iOS with an xnu-11215 kernel, `sweetreboot fastboot` and `sweetreboot bergamota` get you back to fastboot without the buttons.

## Troubleshooting

**"I unpacked the boot image but there is no DTB."** The Poco F1 boot.img appends the DTBs to the gzipped kernel, so unpackers don't show them. Pull the latest `develop` and, with the phone in OrangeFox:

```sh
adb pull /dev/block/by-name/boot backup/boot.img
adb pull /sys/firmware/fdt dtb/beryllium/live.dtb
python3 tools/extract-dtb.py backup/boot.img dtb/beryllium --live dtb/beryllium/live.dtb
```

That writes `dtb/beryllium/dtb`, which Enxerto's `build.sh` uses.

**Bergamota shows "REMOTE HOST IDENTIFICATION HAS CHANGED".** Every new iOS root generates a new SSH host key for `192.168.7.2`, so the old entry in `~/.ssh/known_hosts` no longer matches. Remove it with `ssh-keygen -R 192.168.7.2`. If you switch between roots often, keep a separate file instead (`-o UserKnownHostsFile=~/.ssh/known_hosts_ios18`).

## Renegade, briefly

On iOS 18 every system binary is **arm64e**, but the Snapdragon 845 (ARMv8.2) has no pointer authentication. Renegade rewrites the code 4 bytes for 4 bytes, so no offset, branch, unwind table or fixup chain moves:

```
RETAA / RETAB           →  RET
BRAA / BLRAA …          →  BR / BLR
LDRAA / LDRAB           →  LDR
PACIA / AUTIA / XPACI…  →  NOP
PACGA Xd, Xn, Xm        →  EOR Xd, Xn, Xm, ROR #13
```

It does this for every Mach-O in the root and for all of the dyld shared cache. It then re-signs each binary ad hoc (keeping its identifiers and entitlements), recomputes corecrypto's FIPS HMAC and sets the HFS+ owners without root. Heartwood's side of the deal (`sweetarm64e=1`) lets arm64e binaries load and emulates FJCVTZS. See [`tools/renegade/README.md`](tools/renegade/README.md) and [`docs/IOS18_PORT.md`](docs/IOS18_PORT.md).

## Repository layout

| Path | What |
| --- | --- |
| `apps/Bergamota/` | Bergamota, the SwiftUI control plane, plus its CLI (`scripts/bergamota`) |
| `enxerto/` | Enxerto, the bare-metal bootloader (C + asm): loader, inflate, UFS, USB/DWC3, fastboot, PMIC, boot UI |
| `xnu/patches-12377/` | Heartwood for iOS 26 (xnu-12377), applied in order by `tools/xnu-local-build.sh` and `.github/workflows/xnu.yml`; 3001 onwards are the Mi 8's drivers |
| `xnu/patches-11215/` | Heartwood, the XNU patch series (xnu-11215), applied in order by `.github/workflows/xnu.yml`; `xnu/patches/` is the older xnu-8796 series |
| `tools/renegade/` | Renegade: `pacstrip*`, `fips_rehmac`, root build, HFS+ and sparse-image tools, `dsctools` (shared-cache symbolication) |
| `tools/adt-gpufw.py`, `zap-split.py` | GPU firmware into the ADT (`/sweet-gpu`); split a squashed `.mbn` into `.mdt` + `.bNN` |
| `tools/bergamota-flash.py` | Delta/full flashing of userdata, boot and logo through Bergamota fastboot |
| `tools/extract-dtb.py` | Extracts the stock DTBs from a boot.img (also the Poco F1's appended Image.gz-dtb) and picks yours |
| `tools/mkadt.py`, `mkpayload.py` | Apple Device Tree generator; kernel + ADT + boot-args payload packer |
| `tools/sweetnet/` | Small on-device tools (`sweetps`, `sweetprefs`, `sweetuicache`, …) |
| `tools/dipper-mkboot.sh` | The Mi 8 boot image with its current boot-args and ADT |
| `tools/adt-wlan.py`, `adt-haptics.py`, `adt-canvas.py` | Wi-Fi node; `/product/haptics` and `/product/camera` "flash" (iOS's vibration route and flashlight button); the display canvas iOS draws (414x862 points, the panel's own shape) into an ADT |
| `tools/camera/` | Camera bring-up helpers: `camx_v1.py` (reads the phone's own CamX sensor module files; its output stays out of git), `camframe.c` (on the phone: loads the sensor sequence, writes the kernel's frame to stdout) and `frame2png.py` (RAW8/RAW10 Bayer to PNG on the Mac) |
| `tools/audio/` | `SweetSpeaker.driver` (the speaker and vibration motor as Core Audio devices, with the speaker guard), TAS2557 amp scripts from TI's firmware |
| `gpu/metal/` | Chlorophyll, Metal on the Adreno 630 (submodule) |
| `tools/identity/` | The Bergamota identity (Newton halftone, lime ground, Archivo + JetBrains Mono): `mkidentity.py` generates Enxerto's `art.h` and the kernel console's portrait, `mkicon.sh` the app icon |
| `tools/mksplash.py` | The ABL screens of the `logo` partition, from Enxerto's own renders |
| `docs/` | Design notes: iOS 18 and iOS 26 ports, Wi-Fi on iOS 26, Bergamota fastboot and charging, GPU research, forks survey, … |
| `NOTES.md` | The engineering log: every boot, crash and decision |
| `docs/NOTES-before-mi8.md` | The log from before the Mi 8 port (Poco F1, Redmi Note 10 Pro, iOS 16 and 18), archived |
| `AGENTS.md` | Rules for coding agents working on this branch |

Not in git: partition backups, device trees, Apple firmware and root images, or anything with serial numbers or calibration data.

## Credits

The Mi 8 port is a fork of [Bergamota](https://github.com/ry-diffusion/Bergamota) (Poco F1), which itself started as a fork of [ios-sweet](https://github.com/dipa-studio/ios-sweet) (iOS 16 on the Redmi Note 10 Pro). The iOS 16 days of this port are in [`docs/IOS16_README.md`](docs/IOS16_README.md). The route to iOS's vibration (`/product/haptics`), the flashlight's way in through the capture device vendor, and the speaker guard's design come from HakiOS ([oosexgang/hakios-xnu-kernel](https://github.com/oosexgang/hakios-xnu-kernel)); our code for them is our own. It is built on Apple's open-source releases (xnu, IOHIDFamily, libpthread, hfs), [BearSSL](https://bearssl.org), [blacktop/darwin-xnu-build](https://github.com/blacktop/darwin-xnu-build) and [ipsw](https://github.com/blacktop/ipsw), the Linux kernel's SDM845 drivers (and LineageOS's Mi 8 kernel) for the hardware details, [Mesa](https://mesa3d.org)'s Turnip for Chlorophyll, and [OrangeFox Recovery](https://orangefox.download). iOS itself is Apple's and is not distributed here.
