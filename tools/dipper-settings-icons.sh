#!/bin/bash
# tools/dipper-settings-icons.sh: put Settings' symbol icons into IconServices' cache, from the Mac over SSH. Run it again if those rows go empty
# (a wiped cache, a reflashed root). Then reboot on the default image: the home screen's icons were cleared too and come back from the CPU agent.
#
# iconservicesagent runs without the GPU (bgmtl.off.com.apple.iconservicesagent) because glass layers come out damaged on Chlorophyll (Photos 4 of 8
# petals, Notes blank, Safari no compass), but without it CoreUI cannot draw an SF Symbol (_CUIGraphicVariantVectorGlyph: failed to produce foreground
# layer) and those icons stay empty: Wi-Fi, Bluetooth, Battery, Camera, Home Screen, Sounds, Passcode... Stock and GPU agents share the cache. So: with
# SpringBoard already up, so that it asks for nothing, GPU agent, empty cache, walk Settings; only what Settings wants gets rendered (28 files on
# iOS 26.5, Settings' main list). Then back to the CPU agent. After the reboot it renders the home screen beside them, about 2 minutes of CPU;
# until it finishes the icons look washed out, which is not damage.
# Never ask for these icons from a root tool here (ISIcon prepareImageForDescriptor:): it gets a blank 40x40 and the blank can end up in the cache.
set -e
C=/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.lsd.iconscache/Library/Caches/com.apple.IconsCache
ssh -o BatchMode=yes root@192.168.7.2 'sh -s' <<E
sweettouch lock; sleep 1.5; sweettouch home; sleep 2; /var/root/sweetsys kern.sweet_touch_drag=540,2230,540,700,300; sleep 2.5; sweettouch home; sleep 1
P=\$(ps -A -o pid,comm | grep -E "Preferences.app/Preferences\$" | sed -E "s/^ *([0-9]+).*/\1/"); [ -n "\$P" ] && kill -9 \$P
rm -f /private/var/tmp/bgmtl.off.com.apple.iconservicesagent /private/var/tmp/bgmtl.state.com.apple.iconservicesagent
I=\$(ps -A -o pid,comm | grep -E "/iconservicesagent\$" | sed -E "s/^ *([0-9]+).*/\1/"); [ -n "\$I" ] && kill -9 \$I
sleep 1; rm -f $C/*/*
sweetopen com.apple.Preferences >/dev/null 2>&1; sleep 10
for i in 1 2 3 4; do sweettouch swipe 187 700 187 120 300; sleep 1.5; done; sleep 3
P=\$(ps -A -o pid,comm | grep -E "Preferences.app/Preferences\$" | sed -E "s/^ *([0-9]+).*/\1/"); [ -n "\$P" ] && kill -9 \$P; sleep 1
sweetopen com.apple.Preferences >/dev/null 2>&1; sleep 6
for i in 1 2 3 4; do sweettouch swipe 187 700 187 120 300; sleep 1.5; done; sleep 2
touch /private/var/tmp/bgmtl.off.com.apple.iconservicesagent
echo "\$(ls $C/*/ | wc -l) files in the cache; reboot now"
sweettouch home
E
