# Power off and idle power (Enxerto / Bergamota fastboot)

Files: `enxerto/power.c` (power off, WFE waits, storage idle), `enxerto/pmic.c` (`pmic_pshold_type`, `pmic_usb_present`), `enxerto/bergamota.c` (`power_tick`,
`do_poweroff`, `oem load`, `oem tune`), `enxerto/charge_mode.c` (`unplugged_off`), `enxerto/ufs.c` (`ufs_auto_hibernate`), `oem poweroff` in `enxerto/fastboot.c`.
Status (2026-11-13): **run on the Mi 8 from RAM** (`fastboot boot` from Xiaomi's fastboot; results below), host tests pass (525 checks). **Not flashed to `boot` yet.**
Test images: `enxerto/out/bergamota-fastboot-power.img`, `enxerto/out/charge-test-power.img` (`BOARD=dipper IMGSUFFIX=-power enxerto/build.sh`);
`research/helpers/enxerto-ramboot.sh IMG` loads one without hands (Bergamota fastboot -> iOS -> `sweetreboot fastboot` -> Xiaomi's fastboot -> `fastboot boot IMG`).

## Why (user, 2026-11-13)
"phone even with bergamota power off mode felt hot and battery was going down quickly; after turning off from twrp, it really got off".
Read in the code, not measured: Enxerto had no power off at all, only resets. Its charging screen (`charge_run`) and Bergamota fastboot (`fb_run`) looped for ever,
their waits spinning one core (`while (ms_now() < end);`), the fastboot with its full bright screen lit, the charging screen with black pixels after 20 s but the
panel and the SoC still on, and neither looked at whether the cable was still in. A phone that ended up there on battery (iOS powered off and a charger put in
later, a reset or a panic, a press of the power key away from the Mac) stayed on until the battery was empty. One measurement of old: in fastboot on a 1.5 A
port the battery got +1.2 A (NOTES "BERGAMOTA FASTBOOT CHARGES AT +1.2 A"), so the phone itself took something like 2 W there.
iOS's own power off (xnu 3074) is the PMIC sequence below; TWRP's is Linux's same sequence (Linux only configures PM8998).
**Seen on the phone, 2026-11-13:** a real power off with the cable in does not stay off: the PMIC starts the phone again (PON1: a charger is there) and ABL boots
`boot` into the charging screen; the user: "bergamota power off mode with the charging screen and percentage". With the cable out the same power off stays off
(Volume Down lights nothing). So a phone on a charger is never off, and the charging screen has to be cheap; a phone off the charger must be switched off.

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

## Storage idle
`power_storage_idle(1)` (UFSHCI auto-hibernate, AHIT = 10 ms, as xnu 3054) at the start of the charging screen and of fastboot: the link sleeps between commands
and the host wakes it at the next doorbell. Off for the length of a flash (`p_flash_begin` / `p_flash_end`), so writes run on the link as they always did.

## Measured on the Mi 8 (2026-11-13)
`fastboot oem load[:<seconds>[:dark]]` suspends the charger's USB input (USBIN_CMD_IL bit 0) so the battery feeds the phone, and prints the fuel gauge's current
once a second; `dark` blackens the screen for the test. Fastboot, Mac's port, battery 87-98 %:

| build | screen lit | screen black |
|---|---|---|
| waits spinning (`bergamota.idle=0`: the old behaviour) | 311 mA | 277 mA |
| waits in WFE | 256 mA | 231 mA |
| WFE + storage link asleep (the final build; two runs each, the gauge wanders at these currents) | 109, 147 mA | 115, 87 mA |

In one boot, in this order: black 185 mA, storage link asleep 105 mA. The readings drift down by tens of mA over minutes in a boot, so small steps cannot be
told apart; the order of magnitude is what counts: about 1.2 W before, about 0.4-0.5 W now, in a state where the phone looks off.
Storage after the link has slept: `oem gpt` (6 LUNs), `oem selftest:boot` OKAY, the same 16 MiB of userdata hashed three times with and without it: equal.
**Tried and dropped:** stopping the MDP's autorefresh while the screen is black (PP_AUTOREFRESH_CONFIG = 0, then EN + CTL_START to resume): at most 20 mA, and the
frames did not come back (black screen until the next start; the first try only looked fine because the panel still held the old picture). Linux turns the tear
check off around the change and polls until the transfer has ended (`_sde_encoder_autorefresh_disable_seq1`); not attempted.

## Tried on the phone (2026-11-13, RAM boots, the user at the phone)
- The build starts (WFE check passes: "waits in WFE"), answers `getvar`, and RAM-boots iOS (`fastboot boot` of image 141, several times).
- `fastboot oem poweroff`, cable in: OKAY, USB gone; the phone came back by itself into the (flashed, old) charging screen.
- Fastboot, Power held 3 s: "POWERING OFF", then black.
- Charging screen: dark after 20 s, Volume Down lights it again; cable out: "Unplugged: powering off", then black, and Volume Down lights nothing (really off).
  Cable in again: the phone starts by itself into the charging screen.

## Not tried
The five minutes without a host (off on battery; black screen on a charger, then off when the charger goes); a wall charger; a flash through the new build (the
storage link is awake for it, as before); iOS's own power off on battery alone; how warm the phone gets on the new charging screen over an hour.
Open: lowering the CPU clock; the autorefresh stop done Linux's way; whether ABL's charger path can be told to keep the phone off.
