#!/bin/bash
# Mi 8 (dipper): the Android files the sensor DSP (SLPI) reads over FastRPC, copied to the phone's iOS root.
# xnu 3070+ (bsd/dev/dipper_sensors.c) serves the SLPI's apps_std file calls from /private/var/sweet/qcom, with
# Android's paths under it:
#   vendor/etc/sensors/{config/*.json,sns_reg_config,...}   from backup/dipper/vendor.img   (/etc/sensors)
#   mnt/vendor/persist/sensors/{registry/registry/*,...}    from backup/dipper/persist.img  (/sensors)
# /sys/devices/soc0 is made by the kernel from SMEM. These are device data (calibration): never commit them.
#   tools/dipper-sensor-files.sh [WORKDIR]     build the tree in WORKDIR (default: a temp dir) and push it over SSH
# Needs Homebrew e2fsprogs (debugfs) and the phone on USB networking (root@192.168.7.2).
set -euo pipefail
cd "$(dirname "$0")/.."
DEBUGFS=${DEBUGFS:-/opt/homebrew/opt/e2fsprogs/sbin/debugfs}
PHONE=${PHONE:-root@192.168.7.2}
DEST=/private/var/sweet/qcom
WORK=${1:-$(mktemp -d)}
Q="$WORK/qcom"
rm -rf "$Q"
mkdir -p "$Q/mnt/vendor/persist" "$Q/vendor/etc"
"$DEBUGFS" -R "rdump /sensors $Q/mnt/vendor/persist" backup/dipper/persist.img 2>&1 | grep -v "debugfs\|chown\|Operation not permitted" || true
"$DEBUGFS" -R "rdump /etc/sensors $Q/vendor/etc" backup/dipper/vendor.img 2>&1 | grep -v "debugfs\|chown\|Operation not permitted" || true
test -d "$Q/vendor/etc/sensors/config" && test -d "$Q/mnt/vendor/persist/sensors/registry/registry"
echo "files: $(find "$Q" -type f | wc -l | tr -d ' ') ($Q)"
(cd "$Q" && COPYFILE_DISABLE=1 tar -cf - .) | ssh "$PHONE" "mkdir -p $DEST && tar -xf - -C $DEST && find $DEST -type f | wc -l"
