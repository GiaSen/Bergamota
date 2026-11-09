#!/bin/sh
# Boot image of the Mi 8 with its current boot-args: tools/dipper-mkboot.sh KERNEL OUT.img [ADT]
# Default ADT enxerto/out/dipper-n104-2x-wlan-gpu-hap-cam2.adt (dipper-n104-2x-wlan-gpu.adt + /product/haptics,
# /product/camera "flash" and /arm-io/isp "camera-rear" and "camera-front", made by tools/adt-haptics.py --rear-camera
# --front-camera; images up to 130f used dipper-n104-2x-wlan-gpu-hap.adt (no isp node), 131-137 -hap-cam.adt (rear only)). Its canvas is the iPhone 11's, 414x896 points at @2x.
# sweetfb_scale=2 (SWEETFB_SCALE, since image 133): the display scaler stretches that canvas onto the whole 1080x2248
# panel (1.304 across, 1.254 down: 4 % wider than tall); 1 = fit with bars (~20 px black at each side, up to image 131).
# A canvas of the panel's own shape (tools/adt-canvas.py --points 414x862, image 132) filled it without the 4 %, but iOS
# then laid the status bar out for another screen, its icons pushed into the notch (user, 2026-11-09). The boot-args field holds 607 bytes: the default line is 606.
#   sweetwlan=5 ... sweet80211=3    Wi-Fi service
#   sweetbt=1 sweetbtfast=1 sweetbtibs=1   Bluetooth next to it (xnu 3011, firmware in /usr/standalone/firmware/sweet)
#   sweetcharger=2 sweetcharger_fcc=1700   charger control, 0.5 C of 3400 mAh
#   sweetaudio=3   the speaker (xnu 3047): audio DSP, GLINK/APR and the kernel's player for SweetSpeaker.driver
#   sweethap=3     the vibration motor (bit 0, xnu 3049: PMI8998 haptics, kern.sweet_haptic, AHSFirmwareReadyNotifier)
#                  and the flashlight (bit 1, xnu 3050: PMI8998 flash LEDs in torch mode, kern.sweet_torch)
#   EXTRA_ARGS="..."   more boot-args for a test boot
# Nothing is booted or flashed here: fastboot -s bergamota0001 boot OUT.img
cd "$(dirname "$0")/.." || exit 1
[ $# -ge 2 ] || { echo "usage: $0 KERNEL OUT.img [ADT]" >&2; exit 1; }
CMDLINE="debug=0xc serial=1 cpus=8 keepsyms=1 -noprogress rd=ufsroot0 unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin ufsrw=1 rootrw=1 launchd_unsecure_cache=1 wdt=-1 sweetfb_noconsole=1 sweetfb_hz=60 sweetfb_vsync=1 sweetfb_scale=${SWEETFB_SCALE:-2} sweetfb_flip=1 sweetusb=2 sweetbattery=1 sweetfb_hw=1 sweetarm64e=1 launchd_disable_all_timeouts=1 ufslogsecs=1 sweettouchdelay=0 sweetwlan=5 sweetwlandelay=60 sweet80211=3 sweetgpu=8 sweetgpufreq=gov sweetgpuhb=10 sweetgpuboost=7 sweetgpuubwc=1 sweetamp_yield=1 sweetbt=1 sweetbtfast=1 sweetbtibs=1 sweetcharger=2 sweetcharger_fcc=1700 sweetaudio=3 sweethap=3"
# EXTRA_ARGS: appended for a test boot (e.g. EXTRA_ARGS="sweetaudio=1"), nothing by default
CMDLINE="$CMDLINE${EXTRA_ARGS:+ $EXTRA_ARGS}"
[ "${#CMDLINE}" -le 607 ] || { echo "boot-args are ${#CMDLINE} bytes, the field holds 607" >&2; exit 1; }
RENEGADE_TARGET=ios26 BOARD=dipper DTB="$PWD/dtb/dipper/dtb" CMDLINE="$CMDLINE" \
	exec tools/renegade/mkboot-full.sh "$1" "${3:-enxerto/out/dipper-n104-2x-wlan-gpu-hap-cam2.adt}" "$2"
