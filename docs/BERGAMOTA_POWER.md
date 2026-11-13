# Power off and idle power (Enxerto / Bergamota fastboot)

Files: `enxerto/power.c` (power off, WFE waits), `enxerto/pmic.c` (`pmic_pshold_type`, `pmic_usb_present`), `enxerto/bergamota.c` (`power_tick`, `do_poweroff`),
`enxerto/charge_mode.c` (`unplugged_off`), `oem poweroff` in `enxerto/fastboot.c`. Status (2026-11-13): builds for the Mi 8, host tests pass (525 checks);
**nothing of this has run on a phone yet.** Test image: `enxerto/out/bergamota-fastboot-power.img`, `enxerto/out/charge-test-power.img` (`BOARD=dipper IMGSUFFIX=-power enxerto/build.sh`).

## Why (user, 2026-11-13)
"phone even with bergamota power off mode felt hot and battery was going down quickly; after turning off from twrp, it really got off".
Read in the code, not measured: Enxerto had no power off at all, only resets. Its charging screen (`charge_run`) and Bergamota fastboot (`fb_run`) looped for ever,
their waits spinning one core (`while (ms_now() < end);`), the fastboot with its full bright screen lit, the charging screen with black pixels after 20 s but the
panel and the SoC still on, and neither looked at whether the cable was still in. A phone that ended up there on battery (iOS powered off and a charger put in
later, a reset or a panic, a press of the power key away from the Mac) stayed on until the battery was empty. One measurement of old: in fastboot on a 1.5 A
port the battery got +1.2 A (NOTES "BERGAMOTA FASTBOOT CHARGES AT +1.2 A"), so the phone itself took something like 2 W there.
iOS's own power off (xnu 3074) is the PMIC sequence below and was seen to switch the phone off on 2026-11-07; with a charger in, the phone can come back by
itself into the charging screen (ABL's charger path), which is where the heat was. TWRP's power off is Linux's same sequence; Linux only configures PM8998.

## Power off (`power_off`)
The charger registers back to what ABL left (`enxerto_charger_handoff`: while the phone is off the PMI8998 charges by itself, with its own limits, not our
fast-charge ones), then PM8998 PON `PS_HOLD_RESET_CTL` 0x85a type 4 (shutdown) with `PS_HOLD_RESET_CTL2` 0x85b bit 7 off around the change and 1 ms between
(Linux `pm8941_reboot_notify`, downstream `qpnp_pon_reset_config`, xnu 3074 `sweet_reboot_poweroff`), read back, then PS_HOLD (0x0c264000) = 0. Still on after
2 s: PSCI SYSTEM_OFF. Still on after that: the type is put back (a later reset must be a reset) and the caller says so on the screen. If the type cannot be set
PS_HOLD is not dropped (it would warm-reset). The two PON registers are the only PM8998 writes `pmic.c` lets through, and only through an APID the apps EE owns.
Before it, callers wait for the power key to be up (a key held through the shutdown starts the phone again) and stop USB.

## Who calls it
- **Charging screen:** the cable out for 3 s (USBIN plug-in status read once a second; only a successful read that says "out" counts) -> "Unplugged: powering off".
  Plugged back in during the notice: stays. Power held 2 s and Volume Down do what they did.
- **Bergamota fastboot, while it waits for a command** (never during a transfer or a flash):
  Power held 3 s (the key must have been seen up first; with Volume Down held too nothing happens, that is the PMIC's own way to the bootloader);
  `fastboot oem poweroff`; five minutes without a USB host **on battery**. Five minutes without a host **on a charger** (wall charger, sleeping computer) only
  turn the screen black (off pixels on the Mi 8's AMOLED); USB stays up, a host or a key lights it again, and if the charger then goes the phone powers off.
- If the power off fails in fastboot the screen says why for 8 s and the phone restarts (USB was already stopped).

## Waiting without spinning
`power_idle_init` turns on the generic timer's event stream (CNTKCTL_EL1 EVNTEN, CNTVCT bit 13: an event about every 0.85 ms at 19.2 MHz; Linux turns the same
on for every core) and checks it once: eight WFEs must take 2..40 ms. Then `power_wait_ms` (the charging screen's 40 ms poll) and `power_nap` (one event between
two polls of the USB controller in fastboot's command wait) sit in WFE; if the check fails, or with `bergamota.idle=0` on the boot.img cmdline, the old spinning
waits stay. Transfers and flashes do not nap.

## To do on the phone (nothing below is done)
1. RAM-boot the test image from Xiaomi's fastboot (`fastboot boot enxerto/out/bergamota-fastboot-power.img`; from iOS `sweetreboot bootloader` gets there):
   does it start (a WFE that never returned would hang right here), `getvar`, a `boot` of an iOS image, a flash dry run.
2. `fastboot oem poweroff` with the cable in: does the phone stay off, or does it come back into the charging screen (PM8998's PON1 was the reason of every
   start seen so far, cable in)? Then Power held 3 s; then cable out and five minutes.
3. `charge-test-power.img`: the screen, then pull the cable: off after 3 s?
4. Battery current in fastboot and on the charging screen before and after (`getvar bergamota-battery`, the charging screen's own figure), and by hand: warm?
5. iOS's power off on battery alone and with the cable in: which state the phone ends in, and `kern.sweet_pon_reasons` at the next start.
6. Only then, with the user's word: flash it to `boot` (`tools/bergamota-flash.py`), and update README.
Open, after measurements: stopping the MDP's autorefresh while the screen is black, lowering the CPU clock, switching the phone off for good once the charging
screen has been shown (TWRP's night shows the PMI8998 charges a phone that is off; whether a power off with the cable in stays off is item 2).
