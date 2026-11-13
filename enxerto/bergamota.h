#pragma once
#include <stdint.h>

/*
 * Bergamota fastboot glue (docs/BERGAMOTA_FASTBOOT.md): USB + protocol + screen + boot/reset.
 *
 * Entry: /chosen bootargs "bergamota.fastboot=1" (boot.img cmdline) forces it, "=0" forbids it;
 * without the flag it runs when the ABL ramdisk holds no SWEETXNU payload.
 */
int bergamota_wanted(uintptr_t dtb);
/*
 * Serve fastboot. Returns only if it could not start (USB init failed, no buffer): the reason.
 * Since 2026-11 (docs/BERGAMOTA_POWER.md) it no longer waits for ever with the screen lit: five minutes without a USB
 * host power the phone off on battery and darken the screen on a charger (USB stays up; a host or a key lights it
 * again); Power held for three seconds and `fastboot oem poweroff` power it off.
 */
const char *bergamota_fastboot(uintptr_t dtb);
