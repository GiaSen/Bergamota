#pragma once
#include <stdint.h>

/*
 * Powering the phone off, and waiting without burning the battery (docs/BERGAMOTA_POWER.md).
 *
 * Until 2026-11 Enxerto could only reset: the charging screen and Bergamota fastboot ran for ever, one core spinning
 * in their wait loops, whether a cable was in or not, and a phone left there got warm and emptied its battery.
 *
 * power_off: the charger registers back to what ABL left (charger.c), PM8998's PS_HOLD action set to "shutdown"
 *   (pmic.c; without that a falling PS_HOLD is a warm reset on this phone), PS_HOLD low; PSCI SYSTEM_OFF if the
 *   phone is still on 2 s later. The same sequence as the iOS kernel's (xnu 3074, bsd/dev/sweet_reboot.c). Returns
 *   only when nothing worked (PS_HOLD's action is then put back, so a later reset is a reset again).
 *   The caller stops USB first and makes sure the power key is up: a key held through the shutdown starts the phone.
 * power_idle_init: the generic timer's event stream on (CNTKCTL_EL1.EVNTEN, an event about every 0.85 ms at the
 *   19.2 MHz counter; what Linux turns on for every core), checked once: WFE must come back within a few periods.
 *   "bergamota.idle=0" on the boot.img cmdline keeps the old spinning waits.
 * power_wait_ms / power_nap: wait with the core in WFE between events (spinning when the check failed or it is off).
 *   power_nap is one event, under a millisecond: for polling loops.
 */
void power_idle_init(uintptr_t dtb);
/*
 * The storage link asleep when idle (ufs.c auto-hibernate): about 80 mA less on the Mi 8 (`oem load`, 2026-11-13,
 * docs/BERGAMOTA_POWER.md). power_storage_idle(1) at the start of the charging screen and of fastboot; fastboot turns
 * it off for the length of a flash. (Stopping the MDP's frames while the screen is black was tried too: at most 20 mA,
 * and the frames did not come back; not done.)
 */
#define POWER_UFS_IDLE_MS	10	/* as the iOS kernel (xnu 3054) */
void power_storage_idle(int on);
int power_idle_ok(void);
void power_wait_ms(unsigned ms);
void power_nap(void);
/* 0 never returned; -1 = the PMIC could not be set up and PSCI did not power off either */
int power_off(void);
/* how the last power_off failed, for the screen ("" before any) */
const char *power_off_why(void);
