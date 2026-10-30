#!/bin/sh
# soak.sh LOG MARKER [SECONDS]: open the home screen's apps one after another with sweettouch (375x812 space), scroll in each,
# go home; every 5th app also Control Center and an icon's context menu. Stops at the first GPU fault in LOG after MARKER.
log="$1"; marker="$2"; secs="${3:-900}"
m=$(grep -a -n "$marker" "$log" | tail -1 | cut -d: -f1)
faults() { tail -n +"$m" "$log" | grep -a -c 'SMMU CB1 FAULT'; }
apps="Calendar:60:278 Photos:145:278 Mail:231:278 Notes:316:278 Reminders:60:371 FaceTime:145:371 Clock:231:371 News:316:371
Games:60:463 AppStore:145:463 Maps:231:463 Health:316:463 Settings:145:556 TV:316:556 Safari:145:753 Messages:231:753 Music:316:753"
echo "$(date +%T) soak for $secs s (faults so far: $(faults))"
end=$(( $(date +%s) + secs ))
n=0
while [ "$(date +%s)" -lt "$end" ] && [ "$(faults)" -eq 0 ]; do
	for a in $apps; do
		[ "$(date +%s)" -lt "$end" ] && [ "$(faults)" -eq 0 ] || break
		name=${a%%:*}; xy=${a#*:}; x=${xy%%:*}; y=${xy##*:}
		n=$((n + 1))
		ssh -o ConnectTimeout=10 root@192.168.7.2 "sweettouch home; sleep 1; sweettouch tap $x $y; sleep 3;
			sweettouch swipe 187 600 187 200 250; sleep 1; sweettouch swipe 187 200 187 600 250; sleep 1; sweettouch home; sleep 1" >/dev/null 2>&1 \
			|| echo "$(date +%T) ssh failed at $name"
		if [ $((n % 5)) -eq 0 ]; then
			ssh -o ConnectTimeout=10 root@192.168.7.2 'sweettouch swipe 320 400 50 400 200; sleep 1; sweettouch swipe 50 400 320 400 200; sleep 1;
				sweettouch swipe 340 5 340 500 300; sleep 1.5; sweettouch swipe 340 700 340 200 300; sleep 1;
				sweettouch swipe 228 476 228 476 700; sleep 1.5; sweettouch tap 187 760; sleep 1' >/dev/null 2>&1
		fi
	done
done
echo "$(date +%T) $n app launches, faults: $(faults)"
tail -n +"$m" "$log" | grep -a -E 'SMMU CB1 FAULT|IB1 |fault master|in flight' | head -6 | cut -c1-200
ssh -o ConnectTimeout=10 root@192.168.7.2 'ls /private/var/tmp | grep "\.off" | tr "\n" " "; /var/root/sweetgpu | tr " " "\n" | grep -E "^(clients|pids|submitted|completed|recoveries|hangs|gvm_tables|gvm_free_ranges)=" | tr "\n" " "' 2>&1
