#!/bin/sh
# A finger on the real touch path (kern.sweet_touch_drag, xnu 3010: input boost and HID event in the kernel, one report every 8 ms), and what
# reaches the panel while it moves. sweettouch cannot measure this: started over SSH its timers run up to 100 ms late (tools/sweetnet/sweetwake.c).
#   tools/dipper-drag.sh [ROUNDS, default 3]
# Panel pixels, 1080x2248, home screen pages: slow drags (2 s), then flicks (250 ms, the page animation runs on). Vertical drags here open Spotlight.
cd "$(dirname "$0")/.." || exit 1
rounds="${1:-3}"
s=root@192.168.7.2
out=$(mktemp -t drag)
ssh -o ConnectTimeout=10 -o BatchMode=yes "$s" 'sweettouch home; sleep 1; sweettouch swipe 187 790 187 300 250; sleep 1.5; sweettouch home; sleep 1.2' >/dev/null 2>&1
r=0
while [ "$r" -lt "$rounds" ]; do
	for a in 980,1100,100,1100 100,1100,980,1100; do
		ssh -o BatchMode=yes "$s" "/var/root/sweetsys kern.sweet_touch_drag=$a,2000; sleep 1.8; /var/root/sweetsys kern.sweet_fb_trace; sleep 0.8" 2>/dev/null > "$out"
		echo "drag:  $(python3 -I tools/dipper-fbtrace.py < "$out" | tr '\n' ' ')"
	done
	for a in 980,1100,100,1100 100,1100,980,1100; do
		ssh -o BatchMode=yes "$s" "/var/root/sweetsys kern.sweet_touch_drag=$a,250; sleep 0.7; /var/root/sweetsys kern.sweet_touch_drag=$a,250; sleep 0.7; /var/root/sweetsys kern.sweet_fb_trace; sleep 0.3" 2>/dev/null > "$out"
		echo "flick: $(python3 -I tools/dipper-fbtrace.py < "$out" | tr '\n' ' ')"
	done
	r=$((r + 1))
done
rm -f "$out"
