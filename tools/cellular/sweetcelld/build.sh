#!/bin/sh
# Build sweetcelld (CommCenter's place: CoreTelephony XPC + status bar + mobile data through the IPA) for the Mi 8:
# arm64 (as sweetnetcfg), ad hoc signed as com.apple.coretelephony with sweetcelld.entitlements.
# Output: research/sweetnet/ios18/sweetcelld (not in git). Installed by tools/cellular/sweetcelld-install.sh.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out=$here/../../../research/sweetnet/ios18
mkdir -p "$out"
xcrun -sdk iphoneos clang -arch arm64 -mios-version-min=18.0 -O2 -Wall -Wno-unused-function -Wno-unused-variable \
	-Wno-deprecated-declarations -fobjc-arc -framework Foundation -framework CoreTelephony \
	"$here/sweetcelld.m" "$here/qmi_cellular.c" -o "$out/sweetcelld"
codesign -s - -f -i com.apple.coretelephony --entitlements "$here/sweetcelld.entitlements" "$out/sweetcelld"
ls -l "$out/sweetcelld"
