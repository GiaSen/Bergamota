#!/bin/sh
# Rendered and shown frame rate on the Mi 8 while the UI moves: home page swipes, then Control Center down and up.
#   tools/dipper-fbfps.sh [ROUNDS, default 6]
# Synthetic touches: the kernel's touch path and touch boost are not exercised, a real finger has to be judged by hand.
# One line per trace (tools/dipper-fbtrace.py), then the totals over the whole run.
cd "$(dirname "$0")/.." || exit 1
rounds="${1:-6}"
s=root@192.168.7.2
out=$(mktemp -t fbfps)
ssh -o ConnectTimeout=10 -o BatchMode=yes "$s" 'sweettouch home; sleep 1' >/dev/null 2>&1
r=0
while [ "$r" -lt "$rounds" ]; do
	ssh -o BatchMode=yes "$s" 'sweettouch swipe 320 400 50 400 200; sleep 0.25; sweettouch swipe 50 400 320 400 200; sleep 0.25; sweettouch swipe 320 400 50 400 200; sleep 0.25; sweettouch swipe 50 400 320 400 200; sleep 0.25; /var/root/sweetsys kern.sweet_fb_trace' 2>/dev/null > "$out"
	echo "swipes:  $(python3 -I tools/dipper-fbtrace.py < "$out" | tr '\n' ' ')"
	ssh -o BatchMode=yes "$s" 'sweettouch swipe 340 5 340 500 300; sleep 0.4; sweettouch swipe 340 700 340 200 300; sleep 0.4; /var/root/sweetsys kern.sweet_fb_trace' 2>/dev/null > "$out"
	echo "control: $(python3 -I tools/dipper-fbtrace.py < "$out" | tr '\n' ' ')"
	r=$((r + 1))
done
rm -f "$out"
