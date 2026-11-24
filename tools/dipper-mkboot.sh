#!/bin/sh
# Boot image of the Mi 8 with its current boot-args: tools/dipper-mkboot.sh KERNEL OUT.img [ADT]
# Default ADT enxerto/out/dipper-n104-2x-wlan-gpu-hap-cam2-862.adt (since image 174, 2026-11-24): dipper-n104-2x-wlan-gpu-hap-cam2.adt
# (dipper-n104-2x-wlan-gpu.adt + /product/haptics, /product/camera "flash" and /arm-io/isp "camera-rear" and "camera-front", made by
# tools/adt-haptics.py --rear-camera --front-camera) with the canvas of the panel's own shape, tools/adt-canvas.py --points 414x862
# (828x1724 at @2x). sweetfb_scale=2 (SWEETFB_SCALE): the display scaler maps it onto the whole 1080x2248 panel, 1.3043 across and
# 1.3039 down. iOS then needs the SpringBoard add-on sweetnotch (root_tweaks18.notch, RENEGADE_NOTCH=1) to keep the iPhone 11's
# status bar; without it the status bar takes the generic layout near the notch (image 132, 2026-11-09). Images 133-173 used
# -hap-cam2.adt, the iPhone 11's 414x896 canvas, stretched 1.304 across and 1.254 down (4 % wider than tall); images up to 130f
# -hap.adt (no isp node), 131-137 -hap-cam.adt (rear only); up to image 131 sweetfb_scale=1 (fit, ~20 px black at each side). The boot-args field holds 607 bytes: the default line is 606.
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
	exec tools/renegade/mkboot-full.sh "$1" "${3:-enxerto/out/dipper-n104-2x-wlan-gpu-hap-cam2-862.adt}" "$2"
