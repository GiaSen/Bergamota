#!/bin/sh
# uitest.sh LOG MARKER [SECONDS] [nowait]: wait for SpringBoard on the phone (unless "nowait"), then drive the UI with
# sweettouch for SECONDS (default 120) while watching LOG (the UDP kernel log) after the line MARKER for a GPU fault.
# Points are sweettouch's 375x812 space. One round: home (also leaves edit mode), page swipes, Control Center down/up,
# a 0.7 s hold on an icon (its context menu; 1.2 s would enter edit mode), a tap outside to close it, Settings open/close.
log="$1"; marker="$2"; secs="${3:-120}"
m=$(grep -a -n "$marker" "$log" | tail -1 | cut -d: -f1)
if [ "${4:-}" != nowait ]; then
	for i in $(seq 1 60); do
		ssh -o ConnectTimeout=5 -o BatchMode=yes root@192.168.7.2 'grep -q -E "springboard: |DEAD-MAN" /private/var/tmp/bgmtl.log' 2>/dev/null && break
		sleep 5
	done
	sleep 30
fi
faults() { tail -n +"$m" "$log" | grep -a -c 'SMMU CB1 FAULT'; }
echo "$(date +%T) driving the UI for $secs s (faults so far: $(faults))"
end=$(( $(date +%s) + secs ))
ssh -o ConnectTimeout=10 root@192.168.7.2 'sweettouch home; sleep 1; sweettouch swipe 187 790 187 300 250' >/dev/null 2>&1
rounds=0
while [ "$(date +%s)" -lt "$end" ] && [ "$(faults)" -eq 0 ]; do
	ssh -o ConnectTimeout=10 root@192.168.7.2 'sweettouch home; sleep 1;
		sweettouch swipe 320 400 50 400 200; sleep 1; sweettouch swipe 50 400 320 400 200; sleep 1;
		sweettouch swipe 340 5 340 500 300; sleep 1.5; sweettouch swipe 340 700 340 200 300; sleep 1;
		sweettouch swipe 228 476 228 476 700; sleep 1.5; sweettouch tap 187 760; sleep 1;
		sweettouch tap 143 557; sleep 2.5; sweettouch home; sleep 1' >/dev/null 2>&1
	rounds=$((rounds + 1))
done
echo "$(date +%T) $rounds rounds, faults: $(faults)"
tail -n +"$m" "$log" | grep -a -E 'SMMU CB1 FAULT|IB1 |fault master|in flight' | head -6 | cut -c1-200
ssh -o ConnectTimeout=10 root@192.168.7.2 'grep -E "refused by|DEAD|failure 1" /private/var/tmp/bgmtl.log | sed -E "s/^\[[0-9]+\] //" | sort | uniq -c | head -12; ls /private/var/tmp | grep "\.off" | tr "\n" " "' 2>&1
