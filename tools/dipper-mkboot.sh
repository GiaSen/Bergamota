#!/bin/sh
# Boot image of the Mi 8 with its current boot-args: tools/dipper-mkboot.sh KERNEL OUT.img [ADT]
# Default ADT enxerto/out/dipper-n104-2x-wlan-gpu.adt. The boot-args field holds 607 bytes.
#   sweetwlan=5 ... sweet80211=3    Wi-Fi service
#   sweetbt=1 sweetbtfast=1 sweetbtibs=1   Bluetooth next to it (xnu 3011, firmware in /usr/standalone/firmware/sweet)
#   sweetcharger=2 sweetcharger_fcc=1700   charger control, 0.5 C of 3400 mAh
# Nothing is booted or flashed here: fastboot -s bergamota0001 boot OUT.img
cd "$(dirname "$0")/.." || exit 1
[ $# -ge 2 ] || { echo "usage: $0 KERNEL OUT.img [ADT]" >&2; exit 1; }
CMDLINE="debug=0xc serial=1 cpus=8 keepsyms=1 -noprogress rd=ufsroot0 unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin ufsrw=1 rootrw=1 launchd_unsecure_cache=1 wdt=-1 sweetfb_noconsole=1 sweetfb_hz=60 sweetfb_vsync=1 sweetfb_scale=1 sweetfb_flip=1 sweetusb=2 sweetbattery=1 sweetfb_hw=1 sweetarm64e=1 launchd_disable_all_timeouts=1 ufslogsecs=1 sweettouchdelay=0 sweetwlan=5 sweetwlandelay=60 sweet80211=3 sweetgpu=8 sweetgpufreq=gov sweetgpuhb=10 sweetgpuboost=7 sweetgpuubwc=1 sweetamp_yield=1 sweetbt=1 sweetbtfast=1 sweetbtibs=1 sweetcharger=2 sweetcharger_fcc=1700"
[ "${#CMDLINE}" -le 607 ] || { echo "boot-args are ${#CMDLINE} bytes, the field holds 607" >&2; exit 1; }
RENEGADE_TARGET=ios26 BOARD=dipper DTB="$PWD/dtb/dipper/dtb" CMDLINE="$CMDLINE" \
	exec tools/renegade/mkboot-full.sh "$1" "${3:-enxerto/out/dipper-n104-2x-wlan-gpu.adt}" "$2"
