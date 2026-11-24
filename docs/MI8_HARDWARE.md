# Mi 8 hardware under iOS

What each part of the Xiaomi Mi 8 does under iOS 26.6.2 on this port, in plain words. State on
2026-11-24, default boot image 174. The measurements, the history and how each part was made to
work are in [`NOTES.md`](../NOTES.md).

✅ works · 🟡 partly · ❌ does not work yet · ⚪ not looked at

## At a glance

| Part | State | In short |
| --- | --- | --- |
| [Screen](#screen) | ✅ | The whole panel, right proportions, iPhone 11 status bar, brightness |
| [Touch and buttons](#touch-and-buttons) | ✅ | Responsive touch; power, volume and the power-off slider |
| [Graphics](#graphics) | ✅ | iOS draws on the phone's own GPU; smooth, not quite iPhone smooth |
| [Wi-Fi](#wi-fi) | ✅ | Joins, rejoins, about 60 Mbit/s each way, low power when idle |
| [Bluetooth](#bluetooth) | ✅ | Finds devices; a Bluetooth speaker pairs and plays |
| [Mobile network](#mobile-network) | 🟡 | SIM, LTE and mobile data work; calls and SMS do not |
| [Speaker](#speaker) | ✅ | Plays all of iOS's sound, with a protection limiter |
| [Microphone](#microphone) | ✅ | Voice Memos and video sound record |
| [Earpiece](#earpiece) | 🟡 | Plays sound; real calls not tried |
| [Vibration](#vibration) | ✅ | Keyboard taps, alerts and haptic patterns |
| [Flashlight](#flashlight) | ✅ | Control Center's button, both rear LEDs |
| [Cameras](#cameras) | 🟡 | All three cameras, photos and video; no 4K, slow motion or HEVC |
| [Battery and charging](#battery-and-charging) | ✅ | Real battery level, safe charging, about 25-30 mA in standby |
| [Sensors](#sensors) | 🟡 | Rotation, auto-brightness, proximity; no compass or barometer |
| [Temperature](#temperature) | 🟡 | Read, but nothing protects the phone when it gets hot |
| [USB](#usb) | ✅ | Network link to the Mac and charging |
| [Storage](#storage) | ✅ | Internal storage; the Files app shows no locations |
| [Not supported](#not-supported) | ❌ | Fingerprint, face unlock, Secure Enclave, App Store; NFC and GPS not looked at |

## Screen

- **Works:** the whole 1080×2248 AMOLED panel at 60 Hz, with square icons and round buttons:
  iOS draws a picture of the panel's own shape (414×862 points), scaled evenly. The status bar
  sits beside the notch as on an iPhone 11. The brightness slider and auto-brightness work.
  When the phone locks, the panel goes fully to sleep.
- **Good to know:** against AMOLED burn-in the picture moves by one pixel every two minutes of
  screen-on time, inside a 2-pixel margin (`sweetfb_orbit=0` at boot turns it off).
- **Needs:** the status bar's position comes from a small SpringBoard add-on (sweetnotch). It is
  not in a root image yet: a root built with `RENEGADE_NOTCH=1` gets it. Without it the status
  bar moves next to the notch.

## Touch and buttons

- **Works:** touch at about 125 reports a second, fast typing without lost taps. A short press
  of the power key wakes the phone; the power-off slider switches it off. Volume keys work.

## Graphics

- **Works:** iOS draws on the phone's Adreno 630 GPU through Chlorophyll, our Metal driver.
  Dragging the home screen runs at 53-60 frames a second, flicks at 48-55.
- **Limits:** it feels smooth but not as smooth as a real iPhone. The App Library and the Today
  view are heavier: the GPU needs about 14 ms per frame there, half of it for the glass effects.

## Wi-Fi

- **Works:** WPA2 networks, internet, rejoining after a reboot, the switch in Settings, power
  save. About 58 Mbit/s down and 62 Mbit/s up. The Wi-Fi chip and the modem sleep between
  packets, so it costs little when idle.
- **Good to know:** with no known network nearby the phone keeps looking for one, at most a full
  scan a minute with the screen off; it then draws 24-30 mA in standby and rejoins about 10 s
  after the network is back.

## Bluetooth

- **Works:** Settings lists nearby devices, both classic and low-energy ones. A Bluetooth speaker
  pairs, reconnects after a restart and plays iOS's sound.
- **Not tried:** calls over Bluetooth, a speaker's own buttons, low-energy accessories such as
  watches.

## Mobile network

- **Works:** the SIM is read and the phone registers on LTE. Mobile data comes up at boot;
  Settings has a Cellular pane whose switch turns it on and off, and Safari loads pages over LTE
  with Wi-Fi off. Airplane mode puts the modem to sleep and back (tried without a SIM).
- **Does not work:** incoming SMS are not taken. Calls are not tried, and the modem offers no
  VoLTE yet.

## Speaker

- **Works:** all of iOS's sound. A protection stage (high-pass filter, power and peak limits)
  keeps the small speaker safe, and the amplifier sleeps during silence. Music keeps playing with
  the screen locked (not tried again since the latest power changes).

## Microphone

- **Works:** iOS's built-in microphone: Voice Memos records, and so does the camera's video.
- **Good to know:** once in twelve boots the microphone recorded only silence until a reboot.
  Since then the kernel checks the first recording of each boot and resets the link when it is
  silent. The fault has not come back, so this cure is not proven on it.

## Earpiece

- **Works:** iOS uses it as the call receiver and plays there for call-style sound; a test tone
  was heard.
- **Not tried:** a real call. The proximity sensor is not used at the ear yet.

## Vibration

- **Works:** keyboard taps, system vibrations and haptic patterns.

## Flashlight

- **Works:** Control Center's flashlight button lights both rear LEDs. Brightness is limited on
  purpose to half of what the LEDs can take.

## Cameras

- **Works:** the Camera app, also from the lock screen, with all three cameras:
  - the main 12 MP camera, with autofocus and tap to focus;
  - the telephoto, which takes over from 2× zoom;
  - the front camera, with the switch button.
  - Photos are saved as JPEG (1924×1444).
  - Videos are H.264 with sound at 1504×846, about 30 frames a second on the back cameras and 18
    on the front.
  - Colours use the phone's own factory tuning, so corners are no longer dark and greenish.
- **Limits:**
  - A photo takes about 2.3 s to save, and photos are grainy in dim light.
  - Everything is JPEG and H.264 whatever the format setting says.
  - No 4K, no 60 fps and no slow motion: those need the phone's own image processor and video
    encoder.
  - While recording, all CPU cores are busy.
  - Live Photos are off.
  - The zoom button switches between 1× and 2×, since the Mi 8 has no 0.5× ultra-wide camera.
- **Not tried:** flash photos; the colour tuning in daylight outdoors and under lamp light.
- **Needs:** the camera's start-up sequence and colour tuning come from the phone's own files and
  go into the root image when it is built (`RENEGADE_CAM_SEQ`).

## Battery and charging

- **Works:** the real battery level and charging state. Charging is limited to 1.7 A, a gentle
  rate for the 3400 mAh battery. The phone also charges in Bergamota's fastboot and on its own
  charging screen when switched off.
- **Standby:** with the screen off at home on Wi-Fi it draws about 25-27 mA. A 17.7-hour night
  unplugged averaged 32 mA (median 27). That is roughly four to five days of pure standby on a
  full battery: an estimate from those readings, not a measured run.
- **Limits:** the chip never enters its deepest sleep under this kernel yet; that is the next big
  step. With a charger plugged in the phone cannot stay switched off: it restarts into the
  charging screen.

## Sensors

- **Works:** screen rotation (from the accelerometer), auto-brightness (light sensor), and the
  proximity sensor switching on during use.
- **Does not work yet:** the compass and the barometer are not given to iOS. Raise to wake cannot
  work: the motion sensors pause while the screen is off, to save power.
- **Not tried:** the proximity sensor at the ear during a call.
- **Needs:** the sensor chip's settings files, copied to the phone after every flash of the root
  (`tools/dipper-sensor-files.sh`).

## Temperature

- **Works:** all of the chip's 21 temperature sensors and the battery's can be read
  (`kern.sweet_thermal`). Typical values: 36-38 °C at rest, the big cores at 70-74 °C for moments
  while booting or opening apps, the battery at 36-40 °C.
- **Does not work yet:** nothing slows the phone down or switches it off when it gets too hot.
  That guard is the next step.

## USB

- **Works:** a network link to the Mac over the cable: SSH, the live kernel log, internet shared
  from the Mac. iOS sees the cable at once, and the phone charges from it.
- **Not looked at:** USB accessories such as keyboards or drives.

## Storage

- **Works:** the phone's internal storage. iOS lives in the partition Android used for its data,
  so installing it erases Android's data (a backup brings it back). The storage sleeps when
  idle.
- **Limits:** the Files app shows no locations: iOS 26's file provider needs Apple's APFS, and
  this root uses HFS+.

## Not supported

- ❌ Fingerprint sensor, face unlock with the infrared camera, Face ID and the Secure Enclave.
- ❌ App Store and Weather: they stop at FairPlay, Apple's app encryption.
- ⚪ NFC and GPS (the Broadcom location chip): not looked at.

## What is next

- A temperature guard: slow the CPU and GPU when warm, switch off when too hot.
- Deeper standby: the chip's own system sleep, which needs every idle driver's clocks stopped and
  the power rails voted down.
- Calls, SMS, and the compass and barometer.

## Kernel patches (developer reference)

Heartwood on **xnu-12377.121.6**, Mi 8 patches 3001–3096 and 3098–3127, all in the default boot (image 174 since 2026-11-24: image 173's kernel with the panel-shaped canvas; 3097 is kept for the temperature guard, not written yet). 3126 (2026-11-23): with the screen off the Bluetooth driver waits for the UART's receive interrupt instead of polling on timers, and counts what it does (`kern.sweet_bt_stats`). 3127 (2026-11-24): Wi-Fi with no known network in range (the station interface made new after a link loss, `kern.sweet_wlan_vdev_reset`; screen-off scans spaced, `kern.sweet_wlan_scan_min_s`, `_scan_hot_s`; scan counters `kern.sweet_wlan_scan`, `kern.sweet_80211_scan`; a test switch that hides the joined network, `kern.sweet_wlan_hide`). 3099: counters of who wakes the phone (`kern.sweet_wake`). 3100: CPU 0 and the cluster power down in idle, off by default. 3101: screen-off pacing of the drivers' polls. 3102: paced polls stay on CPU 0. 3103: switches to try a rail level or drop the USB link. 3104: the main rail at nominal with the screen off. 3105: a switch for the touch controller's scanning (off: no gain). 3106: DCS commands to the panel by hand. 3107: the panel asleep while the display is off. 3108: the panel's longer commands sent whole, and a wake that checks itself and repeats. 3109: a key press is confirmed by quick reads, so a short press counts. 3110: a root-only probe that reads and writes device registers (`kern.sweet_mmio`). 3111: the display engine's clocks can stop while the panel sleeps, off by default. 3112: the chip's and its subsystems' sleep counters (`kern.sweet_sleep_stats`). 3113: a sleep vote and a wake vote for a power rail, a probe, not used. 3114: reads the kernel's own rail vote back from the power controller (`kern.sweet_rpmh_read`). 3115: reads back any standing vote and lists the power controller's resources. 3116: a probe that puts any of them in this processor's sleep and wake sets. 3117–3122: the Wi-Fi driver enables and services the chip's ring interrupts (as the reference driver does) instead of polling with them masked, so the Wi-Fi hardware and the modem can sleep between packets; on by default since 3122 (3119 and 3120 were steps on the way that froze the phone; 3121 added the fixes). 3118 and 3123: probes (a Wi-Fi parameter command by hand; the vendor's sleep-state signal to the sensor DSP, which changed nothing). 3124–3125: the accelerometer, gyroscope and compass streams stop at the sensor DSP while the screen is off and return at a wake; on by default since 3125. 3057 and later: modem QMI, codec, microphone, earpiece. 3068–3072d: sensor DSP, sensors for iOS. 3073–3073d: the IPA, mobile data (3073d polls it less often when quiet). 3074: power off. 3075–3086: the rear main camera (sensor, stream, focus, IOSurface planes' extended pixels for the photo pipeline, 12 MP stills, camera buffers mapped page by page in the SMMU). 3087: the pixel orbit against AMOLED burn-in. 3088: sensor samples to iOS at the rate it asks. 3089–3090: the telephoto and front cameras. 3091: the camera's auto exposure settles with lamps in the picture. 3092: the telephoto's and front camera's frame rate follows the exposure. 3093: the microphone's link to the audio DSP is checked by its first samples and set up again when it is dead. 3094: room for 16 PMIC write channels (with 6, the seventh peripheral to be written in a boot failed silently, which left the front camera without power in ordinary use). 3095: iOS's low-energy Bluetooth scan commands translated for the Qualcomm chip. 3096: the temperature sensors, reads only. 3098 (2026-11-20): the kernel's requests for power rails, power levels and memory speed (RPMh) no longer "time out". About one boot in eleven had lost the modem, Wi-Fi, the audio DSP and the camera's power for the whole boot to a request that had in fact finished before the kernel first looked; 12 boots counted with the fix, none lost
