#!/bin/sh
# One smoothness measurement on the Mi 8: clean reboot, boot IMAGE, run tools/dipper-uitest.sh, keep the numbers.
#   tools/dipper-abtest.sh NAME IMAGE [SECONDS] ['phone command run before the reboot']
# The phone must be up with SSH and tools/sweet-usbnet.sh must be appending to LOG (default research/dipper-ios26-16-sb.log).
# Results go to research/chl-work/ab/NAME.*: bgmtl.log, kernel log slice, ps before/after the UI test, sweetcpu right after it,
# summary (tools/dipper-absum.py).
cd "$(dirname "$0")/.." || exit 1
name="$1"; image="$2"; secs="${3:-180}"; pre="${4:-}"
log="${LOG:-research/dipper-ios26-16-sb.log}"
out=research/chl-work/ab
mkdir -p "$out"
marker="=== ab $name"
ssh -o ConnectTimeout=10 root@192.168.7.2 "${pre:+$pre;} : > /private/var/tmp/bgmtl.log; sync; sweetreboot bergamota" >/dev/null 2>&1
echo "$marker $(date +%T) image $(basename "$image")" >> "$log"
fastboot -s bergamota0001 boot "$image" 2>&1 | tail -1
for i in $(seq 1 90); do
	ssh -o ConnectTimeout=5 -o BatchMode=yes root@192.168.7.2 'grep -q -E "springboard: |DEAD-MAN" /private/var/tmp/bgmtl.log' 2>/dev/null && break
	sleep 5
done
sleep 60    # first-boot work settles; the same wait for every run
ps_now() { ssh -o ConnectTimeout=10 root@192.168.7.2 'ps -A -o pid,time,comm'; }
ps_now > "$out/$name.ps0"
sh tools/dipper-uitest.sh "$log" "$marker" "$secs" nowait | tee "$out/$name.ui"
ps_now > "$out/$name.ps1"
ssh -o ConnectTimeout=20 root@192.168.7.2 '[ -x /var/root/sweetcpu ] && { /var/root/sweetcpu --kernel 10; /var/root/sweetcpu 10; }' > "$out/$name.cpu" 2>&1
scp -O -q root@192.168.7.2:/private/var/tmp/bgmtl.log "$out/$name.bgmtl.log"
ssh -o ConnectTimeout=10 root@192.168.7.2 '/var/root/sweetgpu; ls /private/var/tmp | grep "\.off"' > "$out/$name.gpu" 2>&1
m=$(grep -a -n "$marker" "$log" | tail -1 | cut -d: -f1)
tail -n +"$m" "$log" > "$out/$name.klog"
python3 -I tools/dipper-absum.py "$out" "$name" | tee "$out/$name.sum"
