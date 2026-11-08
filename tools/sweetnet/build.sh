#!/bin/sh
# Build and ad-hoc sign the on-device tools for iOS 16 -> research/sweetnet/
# (sweetnetcfg, cscheck, hcitest, bluetool-stub, sweetreboot, sweetdur = UFS durability test, kernel 0221; set TOOLS="hcitest" to build a subset; sweetreboot = reboot-to-fastboot, kernel 0137)
# iOS 18: also research/sweetnet/ios18/{sweetuicache,sweetfp.dylib} (arm64e + pacstrip --sign)
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out=$here/../../research/sweetnet
mkdir -p "$out"
for t in ${TOOLS:-sweetnetcfg cscheck hcitest bluetool-stub sweetreboot sweetdur}; do
	ents=$here/entitlements.plist
	case $t in
	cscheck) frameworks="-framework CoreFoundation -framework Security" ;;
	hcitest|sweetreboot|sweetdur) frameworks="" ;;
	bluetool-stub) frameworks=""; ents=$here/bluetool.entitlements ;;
	*) frameworks="-framework CoreFoundation" ;;
	esac
	xcrun -sdk iphoneos clang -arch arm64 -mios-version-min=16.0 -O2 -Wall \
		$frameworks "$here/$t.c" -o "$out/$t"
	codesign -s - -f --entitlements "$ents" "$out/$t"
	ls -l "$out/$t"
done
# LaunchServices register tool for sideloaded apps (tools/sweet-install-ipa.sh)
xcrun -sdk iphoneos clang -arch arm64 -mios-version-min=16.0 -O2 -fobjc-arc \
	-framework Foundation -framework Security "$here/sweetuicache.m" -o "$out/sweetuicache"
codesign -s - -f --entitlements "$here/uicache.entitlements" "$out/sweetuicache"

# iOS 18 (Renegade): arm64e builds that the kernel without pointer authentication runs after
# `renegade strip --sign` (pacstrip). Output: research/sweetnet/ios18/ (set IOS18=0 to skip)
if [ "${IOS18:-1}" = 1 ]; then
	out18=$out/ios18
	pacstrip=$here/../renegade/pacstrip.py
	mkdir -p "$out18"
	# sweetprefs: set/read a user default through cfprefsd (installed in /usr/local/bin by root_tweaks18.base())
	xcrun -sdk iphoneos clang -arch arm64e -mios-version-min=18.0 -O2 -Wall -framework CoreFoundation \
		"$here/sweetprefs.c" -o "$out18/sweetprefs"
	codesign -s - -f --entitlements "$here/entitlements.plist" "$out18/sweetprefs"
	python3 -I "$pacstrip" --sign "$out18/sweetprefs"
	# sweetdur: UFS/HFS durability test (kernel patch 0221)
	xcrun -sdk iphoneos clang -arch arm64e -mios-version-min=18.0 -O2 -Wall "$here/sweetdur.c" -o "$out18/sweetdur"
	codesign -s - -f --entitlements "$here/entitlements.plist" "$out18/sweetdur"
	python3 -I "$pacstrip" --sign "$out18/sweetdur"
	# sweetcpu: CPU time per kernel thread and process over a window
	xcrun -sdk iphoneos clang -arch arm64e -mios-version-min=18.0 -O2 -Wall "$here/sweetcpu.c" -o "$out18/sweetcpu"
	codesign -s - -f --entitlements "$here/entitlements.plist" "$out18/sweetcpu"
	python3 -I "$pacstrip" --sign "$out18/sweetcpu"
	# sweetmem: core clock, cache/DRAM latency, memory bandwidth; sweetsys: read string/int sysctls, set int ones; sweetwake: timer and wake latency
	for t in sweetmem sweetsys sweetwake; do
		xcrun -sdk iphoneos clang -arch arm64e -mios-version-min=18.0 -O2 -Wall "$here/$t.c" -o "$out18/$t"
		codesign -s - -f --entitlements "$here/entitlements.plist" "$out18/$t"
		python3 -I "$pacstrip" --sign "$out18/$t"
	done
	# sweetuicache: LaunchServices registration, run by the first-boot job (root_tweaks18.firstboot)
	xcrun -sdk iphoneos clang -arch arm64e -mios-version-min=18.0 -O2 -fobjc-arc \
		-framework Foundation -framework Security "$here/sweetuicache.m" -o "$out18/sweetuicache"
	codesign -s - -f --entitlements "$here/uicache.entitlements" "$out18/sweetuicache"
	python3 -I "$pacstrip" --sign "$out18/sweetuicache"
	# sweetfp.dylib: NSURLFileProtectionKey shim, linked into PosterBoard (root_tweaks18.posterboard)
	xcrun -sdk iphoneos clang -arch arm64e -mios-version-min=18.0 -O2 -fobjc-arc -dynamiclib \
		-install_name /usr/local/lib/sweetfp.dylib -framework Foundation \
		"$here/sweetfp.m" -o "$out18/sweetfp.dylib"
	codesign -s - -f "$out18/sweetfp.dylib"
	python3 -I "$pacstrip" --sign "$out18/sweetfp.dylib"
	ls -l "$out18"
fi

# First-boot wallpaper/icon style and the mobile-domain runner (root_tweaks18.firstboot, iOS 18, arm64e + pacstrip)
if [ "${IOS18:-1}" = 1 ]; then
	out18=$out/ios18
	pacstrip=$here/../renegade/pacstrip.py
	b18() { # name source entitlements [extra clang args]
		n=$1; src=$2; ents=$3; shift 3
		xcrun -sdk iphoneos clang -arch arm64e -mios-version-min=18.0 -O2 -fobjc-arc -framework Foundation "$@" \
			"$here/$src" -o "$out18/$n"
		codesign -s - -f --entitlements "$here/$ents" "$out18/$n"
		python3 -I "$pacstrip" --sign "$out18/$n"
	}
	# sweetmetrics: Bergamota live metrics (docs/BERGAMOTA_METRICS.md), plain C, root_tweaks18.sweetmetrics
	xcrun -sdk iphoneos clang -arch arm64e -mios-version-min=18.0 -O2 -Wall -framework CoreFoundation -framework IOKit \
		"$here/sweetmetrics.c" -o "$out18/sweetmetrics"
	codesign -s - -f --entitlements "$here/entitlements.plist" "$out18/sweetmetrics"
	python3 -I "$pacstrip" --sign "$out18/sweetmetrics"
	b18 sweetposterset sweetposterset.m posterset.entitlements
	# a picture as the lock and home wallpaper through PosterBoard's Photos poster (tools/identity/mkwallpaper.sh)
	b18 sweetwallpaper sweetwallpaper.m posterset.entitlements
	# iOS 26: the Bergamota picture as the legacy wallpaper, drawn by PosterBoard's LegacyPoster (no HEIC, no Photos pipeline)
	b18 sweetlegacywall sweetlegacywall.m posterset.entitlements -framework UIKit
	# iOS 26: PosterBoard on the HFS root without data protection (file protection, purgeable, the empty StandBy role)
	xcrun -sdk iphoneos clang -arch arm64e -mios-version-min=18.0 -O2 -fobjc-arc -dynamiclib \
		-install_name /usr/local/lib/sweetpb26.dylib -framework Foundation "$here/sweetpb26.m" -o "$out18/sweetpb26.dylib"
	codesign -s - -f "$out18/sweetpb26.dylib"
	python3 -I "$pacstrip" --sign "$out18/sweetpb26.dylib"
	# iOS 26: the flashlight in cameracaptured (FigFlashlight gets a vendor whose torch level goes to kern.sweet_torch)
	xcrun -sdk iphoneos clang -arch arm64e -mios-version-min=18.0 -O2 -Wall -Wno-objc-designated-initializers -fobjc-arc \
		-dynamiclib -install_name /usr/local/lib/sweettorch.dylib -framework Foundation "$here/sweettorch.m" \
		-o "$out18/sweettorch.dylib"
	codesign -s - -f "$out18/sweettorch.dylib"
	python3 -I "$pacstrip" --sign "$out18/sweettorch.dylib"
	# iOS 26: the rear main camera in cameracaptured (loaded by sweettorch.dylib; frames from the kernel's kern.sweet_cam_live)
	xcrun -sdk iphoneos clang -arch arm64e -mios-version-min=18.0 -O2 -Wall -Wno-objc-designated-initializers -Wno-four-char-constants -Wno-arc-performSelector-leaks -fno-objc-arc \
		-dynamiclib -install_name /usr/local/lib/sweetcam.dylib -framework Foundation -framework CoreMedia -framework CoreVideo -framework Accelerate -framework CoreGraphics \
		"$here/sweetcam.m" -o "$out18/sweetcam.dylib"
	codesign -s - -f "$out18/sweetcam.dylib"
	python3 -I "$pacstrip" --sign "$out18/sweetcam.dylib"
	b18 sweeticonstyle sweeticonstyle.m iconstyle.entitlements -framework UIKit
	b18 sweetopen sweetopen.m uicache.entitlements
	# remote testing over SSH: screenshot of the panel (PNG) and synthetic touch/buttons
	b18 sweetshot sweetshot.m touch.entitlements -framework CoreGraphics -framework ImageIO -framework IOSurface \
		-framework QuartzCore
	# a CPU profile of one process over SSH (running threads only, frame-pointer stacks, aggregated on the phone)
	xcrun -sdk iphoneos clang -arch arm64e -mios-version-min=18.0 -O2 -Wall "$here/sweetsample.c" -o "$out18/sweetsample"
	codesign -s - -f --entitlements "$here/sample.entitlements" "$out18/sweetsample"
	python3 -I "$pacstrip" --sign "$out18/sweetsample"
	# which service a thread stuck in mach_msg waits on (receive-right owner, launchd name)
	b18 sweetportwho sweetportwho.m sample.entitlements
	# silence through an AudioQueue: does the audio server's output device run, and at what rate
	xcrun -sdk iphoneos clang -arch arm64e -mios-version-min=18.0 -O2 -Wall -framework AudioToolbox -framework CoreFoundation \
		"$here/sweetaq.c" -o "$out18/sweetaq"
	codesign -s - -f --entitlements "$here/entitlements.plist" "$out18/sweetaq"
	python3 -I "$pacstrip" --sign "$out18/sweetaq"
	# the Mi 8's audio DSP over SSH: one APR command in, its answers out (kern.sweet_audio_apr, test boots with sweetaudio>=3)
	xcrun -sdk iphoneos clang -arch arm64e -mios-version-min=18.0 -O2 -Wall "$here/sweetapr.c" -o "$out18/sweetapr"
	codesign -s - -f --entitlements "$here/entitlements.plist" "$out18/sweetapr"
	python3 -I "$pacstrip" --sign "$out18/sweetapr"
	# and its speaker amp: an I2C script in, the bytes read out (kern.sweet_audio_i2c; scripts from tools/audio/tas2557fw.py)
	xcrun -sdk iphoneos clang -arch arm64e -mios-version-min=18.0 -O2 -Wall "$here/sweeti2c.c" -o "$out18/sweeti2c"
	codesign -s - -f --entitlements "$here/entitlements.plist" "$out18/sweeti2c"
	python3 -I "$pacstrip" --sign "$out18/sweeti2c"
	# and PCM for it: a file into the low-bank window the DSP reads (kern.sweet_audio_pool; PCM from tools/audio/mkpcm.py)
	xcrun -sdk iphoneos clang -arch arm64e -mios-version-min=18.0 -O2 -Wall "$here/sweetpool.c" -o "$out18/sweetpool"
	codesign -s - -f --entitlements "$here/entitlements.plist" "$out18/sweetpool"
	python3 -I "$pacstrip" --sign "$out18/sweetpool"
	# and the kernel's speaker player: a PCM file streamed through its ring, amp scripts on/off (kern.sweet_audio_play)
	xcrun -sdk iphoneos clang -arch arm64e -mios-version-min=18.0 -O2 -Wall "$here/sweetplay.c" -o "$out18/sweetplay"
	codesign -s - -f --entitlements "$here/entitlements.plist" "$out18/sweetplay"
	python3 -I "$pacstrip" --sign "$out18/sweetplay"
	# iOS system sounds / the vibration over SSH: what reaches SweetSpeaker.driver's Actuator device
	xcrun -sdk iphoneos clang -arch arm64e -mios-version-min=18.0 -O2 -Wall -framework AudioToolbox "$here/sweetvibe.c" \
		-o "$out18/sweetvibe"
	codesign -s - -f --entitlements "$here/entitlements.plist" "$out18/sweetvibe"
	python3 -I "$pacstrip" --sign "$out18/sweetvibe"
	# Reduce Motion / Reduce Transparency over SSH (libAccessibility's setters, as mobile): A/B of what the effects cost
	xcrun -sdk iphoneos clang -arch arm64e -mios-version-min=18.0 -O2 -Wall "$here/sweetax.c" -lAccessibility -o "$out18/sweetax"
	codesign -s - -f --entitlements "$here/entitlements.plist" "$out18/sweetax"
	python3 -I "$pacstrip" --sign "$out18/sweetax"
	# sweetaqin: record through AVAudioSession + an AudioQueue input (SweetSpeaker.driver's "Mic" device)
	xcrun -sdk iphoneos clang -arch arm64e -mios-version-min=18.0 -O2 -Wall -fobjc-arc -framework Foundation \
		-framework AVFAudio -framework AudioToolbox "$here/sweetaqin.m" -o "$out18/sweetaqin"
	codesign -s - -f --entitlements "$here/mic.entitlements" "$out18/sweetaqin"
	python3 -I "$pacstrip" --sign "$out18/sweetaqin"
	# sweetcx: a kern.sweet_codec stage 0-14 as one character (the 3060-3067c handler reads ints only below 10)
	xcrun -sdk iphoneos clang -arch arm64e -mios-version-min=18.0 -O2 -Wall "$here/sweetcx.c" -o "$out18/sweetcx"
	codesign -s - -f --entitlements "$here/entitlements.plist" "$out18/sweetcx"
	python3 -I "$pacstrip" --sign "$out18/sweetcx"
	# sweetreg: WCD9340 registers through kern.sweet_codec_reg (xnu 3067b)
	xcrun -sdk iphoneos clang -arch arm64e -mios-version-min=18.0 -O2 -Wall "$here/sweetreg.c" -o "$out18/sweetreg"
	codesign -s - -f --entitlements "$here/entitlements.plist" "$out18/sweetreg"
	python3 -I "$pacstrip" --sign "$out18/sweetreg"
	# sweetrec: the handset mic through kern.sweet_audio_rec (xnu 3065)
	xcrun -sdk iphoneos clang -arch arm64e -mios-version-min=18.0 -O2 -Wall "$here/sweetrec.c" -o "$out18/sweetrec"
	codesign -s - -f --entitlements "$here/entitlements.plist" "$out18/sweetrec"
	python3 -I "$pacstrip" --sign "$out18/sweetrec"
	# sweetdump: a sysctl's raw value to stdout (kern.sweet_log_prev, 3058d)
	xcrun -sdk iphoneos clang -arch arm64e -mios-version-min=18.0 -O2 -Wall "$here/sweetdump.c" -o "$out18/sweetdump"
	codesign -s - -f --entitlements "$here/entitlements.plist" "$out18/sweetdump"
	python3 -I "$pacstrip" --sign "$out18/sweetdump"
	# sweetqmi: the modem's QMI services through the kernel pass-through (xnu 3057)
	xcrun -sdk iphoneos clang -arch arm64e -mios-version-min=18.0 -O2 -Wall "$here/sweetqmi.c" -o "$out18/sweetqmi"
	codesign -s - -f --entitlements "$here/entitlements.plist" "$out18/sweetqmi"
	python3 -I "$pacstrip" --sign "$out18/sweetqmi"
	# sweetorient: CoreMotion orientation test tool; sweetorient.dylib: the backboardd orientation shim (no AOP on the Mi 8)
	xcrun -sdk iphoneos clang -arch arm64e -mios-version-min=18.0 -O2 -Wall -fobjc-arc -framework Foundation -framework CoreMotion \
		"$here/sweetorient.m" -o "$out18/sweetorient"
	codesign -s - -f --entitlements "$here/entitlements.plist" "$out18/sweetorient"
	python3 -I "$pacstrip" --sign "$out18/sweetorient"
	xcrun -sdk iphoneos clang -arch arm64e -mios-version-min=18.0 -O2 -Wall -fobjc-arc -dynamiclib -framework Foundation \
		-framework CoreMotion -install_name /usr/local/lib/sweetorient.dylib "$here/sweetorient-shim.m" -o "$out18/sweetorient.dylib"
	codesign -s - -f "$out18/sweetorient.dylib"
	python3 -I "$pacstrip" --sign "$out18/sweetorient.dylib"
	# sweetssc: the sensors behind the SLPI's SNS service (QMI 400) through the kernel pass-through (xnu 3071)
	xcrun -sdk iphoneos clang -arch arm64e -mios-version-min=18.0 -O2 -Wall "$here/sweetssc.c" -o "$out18/sweetssc"
	codesign -s - -f --entitlements "$here/entitlements.plist" "$out18/sweetssc"
	python3 -I "$pacstrip" --sign "$out18/sweetssc"
	# CoreHaptics over SSH: taps + a buzz or an AHAP file, through audiomxd's haptic server to the Actuator device
	xcrun -sdk iphoneos clang -arch arm64e -mios-version-min=18.0 -O2 -Wall -fobjc-arc -framework Foundation \
		-framework CoreHaptics "$here/sweethaptic.m" -o "$out18/sweethaptic"
	codesign -s - -f --entitlements "$here/entitlements.plist" "$out18/sweethaptic"
	python3 -I "$pacstrip" --sign "$out18/sweethaptic"
	# Wi-Fi over SSH (iOS 26 stand-in, docs/WIFI_IOS26.md): Apple80211 info/power/scan without wifid or the UI
	xcrun -sdk iphoneos clang -arch arm64e -mios-version-min=18.0 -O2 -Wall -framework CoreFoundation \
		"$here/sweetwifi.c" -o "$out18/sweetwifi"
	codesign -s - -f --entitlements "$here/wifi.entitlements" "$out18/sweetwifi"
	python3 -I "$pacstrip" --sign "$out18/sweetwifi"
	# takes fairplayd.H2's job: answers FairPlay's Mach services with an error instead of leaving clients waiting
	xcrun -sdk iphoneos clang -arch arm64e -mios-version-min=18.0 -O2 -Wall "$here/sweetfpd.c" -o "$out18/sweetfpd"
	codesign -s - -f --entitlements "$here/entitlements.plist" "$out18/sweetfpd"
	python3 -I "$pacstrip" --sign "$out18/sweetfpd"
	# the unified log over SSH (no `log` tool on iOS)
	b18 sweetlog sweetlog.m log.entitlements
	# open a URL over SSH as a tapped link would (Safari for http/https, Settings for prefs:)
	b18 sweeturl sweeturl.m url.entitlements
	xcrun -sdk iphoneos clang -arch arm64e -mios-version-min=18.0 -O2 -Wall -framework CoreFoundation -framework IOKit \
		"$here/sweettouch.c" -o "$out18/sweettouch"
	codesign -s - -f --entitlements "$here/touch.entitlements" "$out18/sweettouch"
	python3 -I "$pacstrip" --sign "$out18/sweettouch"
	# SweetRun.app: runs /private/var/tmp/sweetrun.sh as mobile in the user's launchd domain (an app started by FrontBoard)
	app=$out18/SweetRun.app
	rm -rf "$app"; mkdir -p "$app"
	cp "$here/sweetrun-app/Info.plist" "$app/Info.plist"
	xcrun -sdk iphoneos clang -arch arm64e -mios-version-min=18.0 -O2 -fobjc-arc -framework UIKit -framework Foundation \
		"$here/sweetrun-app/sweetrun.m" -o "$app/SweetRun"
	codesign -s - -f --entitlements "$here/sweetrun-app/run.entitlements" "$app"
	python3 -I "$pacstrip" --sign "$app/SweetRun"
	codesign -s - -f --entitlements "$here/sweetrun-app/run.entitlements" "$app"      # seal the bundle again
	ls -l "$out18"
fi

# sweetmetrics (Bergamota live metrics, docs/BERGAMOTA_METRICS.md): iOS 18, arm64e, then `renegade strip --sign`
# (pacstrip) so the kernel without pointer authentication runs it. Output: research/sweetnet/ios18/sweetmetrics
if [ "${IOS18:-1}" = 1 ]; then
	out18=$out/ios18
	mkdir -p "$out18"
	xcrun -sdk iphoneos clang -arch arm64e -mios-version-min=18.0 -O2 -Wall \
		-framework CoreFoundation -framework IOKit "$here/sweetmetrics.c" -o "$out18/sweetmetrics"
	codesign -s - -f --entitlements "$here/entitlements.plist" "$out18/sweetmetrics"
	"$here/../renegade/renegade" strip --sign "$out18/sweetmetrics"
	ls -l "$out18/sweetmetrics"
fi
