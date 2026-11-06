#!/bin/sh
# sweetalsa for Linux arm64 (TWRP on the Mi 8): static, no libc, built with the bare-metal aarch64-elf-gcc.
#   tools/audio/sweetalsa/build.sh [OUT]   (default research/sweetnet/linux/sweetalsa)
# Push and run from TWRP: adb push OUT /tmp/sweetalsa; adb shell /tmp/sweetalsa list
cd "$(dirname "$0")/../../.." || exit 1
OUT=${1:-research/sweetnet/linux/sweetalsa}
mkdir -p "$(dirname "$OUT")"
aarch64-elf-gcc -O2 -static -nostdlib -ffreestanding -fno-builtin -fno-stack-protector \
	-fno-tree-loop-distribute-patterns -fno-pic -Wall -Wextra -Wno-unused-parameter \
	-Wl,-Ttext-segment=0x400000 -Wl,-e,_start -Wl,--build-id=none \
	-o "$OUT" tools/audio/sweetalsa/sweetalsa.c -lgcc || exit 1
echo "built $OUT"
