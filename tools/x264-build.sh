#!/bin/sh
# x264 (VideoLAN, GPL 2 or later) as a static library for the phone: the H.264 encoder behind tools/sweetnet/sweetavc.m
# (user's choice, 2026-11-10: "x264 library"). Its source is not in this repository: this script clones it into
# research/x264/src (gitignored) when it is not there and builds research/x264/out/lib/libx264.a + include/x264.h.
#   tools/x264-build.sh            arm64e, iOS 18+, 8-bit 4:2:0 only, no command line tool, NEON assembly
# The library ends up inside /usr/local/lib/sweetavc.dylib on the phone (tools/sweetnet/build.sh), which is therefore
# GPL as a whole; nothing of x264 is linked into the other libraries.
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
w="$root/research/x264"
mkdir -p "$w"
[ -d "$w/src" ] || git clone --depth 1 https://code.videolan.org/videolan/x264.git "$w/src"
sdk=$(xcrun -sdk iphoneos --show-sdk-path)
cc=$(xcrun -sdk iphoneos -f clang)
flags="-arch arm64e -isysroot $sdk -mios-version-min=18.0"
cd "$w/src"
[ -f config.mak ] && make distclean >/dev/null 2>&1 || true
CC="$cc" ./configure --host=aarch64-apple-darwin --prefix="$w/out" --enable-static --enable-pic --disable-cli --disable-opencl \
	--bit-depth=8 --chroma-format=420 --disable-avs --disable-swscale --disable-lavf --disable-ffms --disable-gpac --disable-lsmash \
	--extra-cflags="$flags" --extra-asflags="$flags" --extra-ldflags="$flags"
# x264 starts its worker threads with plain pthread_create: default priority, and Heartwood keeps such threads on the four
# small cores at 0.9 GHz (kern.sweet_cpufreq: amp_pri=31, cluster0 cap_khz=902400): 1080p took 105 ms a frame. Its calls
# go to sweetavc.m's sweetavc_pthread_create, which starts them user-interactive. (After configure: its link tests must
# still find the real function.)
echo 'CFLAGS += -Dpthread_create=sweetavc_pthread_create' >> config.mak
make -j8 >"$w/build.log" 2>&1 || { tail -30 "$w/build.log"; echo "x264: build failed (research/x264/build.log)"; exit 1; }
make install >>"$w/build.log" 2>&1
ls -l "$w/out/lib/libx264.a" "$w/out/include/x264.h"
git -C "$w/src" log --oneline -1
