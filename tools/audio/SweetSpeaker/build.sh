#!/bin/sh
# Builds SweetSpeaker.driver (the Mi 8's loudspeaker as a Core Audio device, see SweetSpeaker.c) into
# research/sweetnet/ios18/SweetSpeaker.driver: arm64e, ad-hoc signed, PAC stripped like the other phone tools.
# On the phone it goes to /System/Library/Audio/Plug-Ins/HAL/ (the image build: root_tweaks18.speaker).
# The guard's own test runs on the Mac: cc -O2 -o /tmp/guard_test guard_test.c guard.c && /tmp/guard_test
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
out=$root/research/sweetnet/ios18/SweetSpeaker.driver
rm -rf "$out"
mkdir -p "$out"
cp "$here/Info.plist" "$out/Info.plist"
xcrun -sdk iphoneos clang -arch arm64e -mios-version-min=26.0 -O2 -Wall -Wextra -bundle \
	-framework CoreAudio -framework CoreFoundation "$here/SweetSpeaker.c" "$here/guard.c" -o "$out/SweetSpeaker"
python3 -I "$root/tools/renegade/pacstrip.py" --sign "$out/SweetSpeaker"
codesign -s - -f "$out"
echo "$out"
