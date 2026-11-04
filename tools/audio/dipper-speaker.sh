#!/bin/sh
# The Mi 8's speaker path by hand, on the phone (test boot with sweetaudio>=3, bsd/dev/dipper_audio.c):
#   AFE QUAT_MI2S_RX port + LPASS bit clock, TAS2557 (scripts from tools/audio/tas2557fw.py), apps_smmu stream
#   0x1821, ASM session 1 stream 1 (PCM 48 kHz 16-bit stereo from kern.sweet_audio_pool), ADM COPP on the port,
#   matrix routing, run, writes. Opcodes and structures: techpack/audio/include/dsp/apr_audio-v2.h (downstream).
#
#   dipper-speaker.sh port-on | port-off | amp-load | amp-on GAINSCRIPT | amp-off | smmu | stream-on |
#                     write BYTES [OFFSET] | stream-off | tone | play FILE | amp-register | status
# play uses the kernel's player instead (3045, kern.sweet_audio_play: all of the above in the kernel, any length).
# Tools in /var/root: sweetapr, sweeti2c, sweetsys, sweetpool, sweetplay; amp scripts in /var/root/amp.
set -u
A=/var/root/sweetapr
I=/var/root/sweeti2c
SYS=/var/root/sweetsys
AMP=/var/root/amp
SESSION=1
PORT=0x0101                     # ASM session 1 << 8 | stream 1
POOL_LSW=0xe1000000             # kern.sweet_audio_pool
POOL_MSW=0x1                    # apps_smmu SID 0x1821 & 0xf
POOL_SIZE=0x200000
ST=/var/root/amp/state          # mem map handle and COPP id

case "${1:-}" in
port-on)
	$SYS kern.sweet_audio_pins=1 >/dev/null
	$A 4 0x100f3 1024 2000 w:32 w:0 w:0 w:0 w:0x1028f w:0x10290 h:20 h:0 w:1 w:0x106 w:1536000 h:1 h:0 w:1
	$A 4 0x100ef 0x1006 2000 h:0x1006 h:32 w:0 w:0 w:0 w:0x1020c w:0x1020d h:20 h:0 w:1 h:16 h:1 h:1 h:1 w:48000 h:0 h:0
	$A 4 0x100e5 0x1006 3000 h:0x1006 h:0
	$SYS kern.sweet_audio_pins
	;;
port-off)
	$A 4 0x100e6 0x1006 2000 h:0x1006 h:0
	$A 4 0x100f3 1024 2000 w:32 w:0 w:0 w:0 w:0x1028f w:0x10290 h:20 h:0 w:1 w:0x106 w:0 h:1 h:0 w:0
	$SYS kern.sweet_audio_pins=0 >/dev/null
	;;
amp-load)
	$I $AMP/load-rom.bin
	;;
amp-on)
	$I "$2"
	;;
amp-off)
	$I $AMP/off.bin
	;;
smmu)
	$SYS kern.sweet_audio_smmu=6177            # probe 0x1821 (sweetsys takes decimal)
	$SYS kern.sweet_audio_smmu=71713           # map 0x1821 (0x10000 | sid)
	;;
stream-on)
	# ASM_CMD_SHARED_MEM_MAP_REGIONS: pool 3 (SHMEM8_4K), 1 region, flags 0; -> ASM_CMDRSP_SHARED_MEM_MAP_REGIONS {handle}
	out=$($A 7 0x10d92 $((SESSION << 8)) 2000 h:3 h:1 w:0 w:$POOL_LSW w:$POOL_MSW w:$POOL_SIZE)
	echo "$out"
	handle=$(echo "$out" | sed -n 's/.*opcode 0x00010d93 .*(header [0-9]*): \([0-9a-f]*\).*/\1/p')
	[ -n "$handle" ] || { echo "no mem map handle"; exit 1; }
	# ASM_STREAM_CMD_OPEN_WRITE_V3: mode 0, sink = device matrix, 16 bits, post-processing NONE, multi-channel PCM v2
	$A --port $PORT 7 0x10db3 $PORT 2000 w:0 h:0 h:16 w:0x10c68 w:0x10da5
	# ADM_CMD_DEVICE_OPEN_V5: flags 0, mode RX, endpoints 0x1006 / none, NULL_COPP_TOPOLOGY, 2 ch, 16 bit, 48 kHz, FL FR
	out=$($A --port 0x1006 8 0x10326 0 2000 h:0 h:1 h:0x1006 h:0xffff w:0x10312 h:2 h:16 w:48000 b:1 b:2 b:0 b:0 b:0 b:0 b:0 b:0)
	echo "$out"
	copp=$(echo "$out" | sed -n 's/.*opcode 0x00010329 .*(header [0-9]*): [0-9a-f]* \([0-9a-f]*\).*/\1/p')
	[ -n "$copp" ] || { echo "no COPP id"; exit 1; }
	echo "handle=0x$handle copp=0x$copp" > $ST
	# ADM_CMD_MATRIX_MAP_ROUTINGS_V5: audio RX matrix, 1 session: session 1 -> 1 COPP
	$A 8 0x10325 0 2000 w:0 w:1 h:$SESSION h:1 h:0x$copp h:0
	# ASM_DATA_CMD_MEDIA_FMT_UPDATE_V2: multi-channel PCM, 2 ch, 16 bit, 48000, signed, FL FR
	$A --port $PORT 7 0x10d98 $PORT 2000 w:20 h:2 h:16 w:48000 h:1 h:0 b:1 b:2 b:0 b:0 b:0 b:0 b:0 b:0
	# ASM_SESSION_CMD_RUN_V2: now
	$A --port $PORT 7 0x10daa $PORT 2000 w:0 w:0 w:0
	;;
write)
	. $ST
	off=${3:-0}
	# ASM_DATA_CMD_WRITE_V2 {addr lsw, msw, handle, size, seq, ts lsw, ts msw, flags} -> ASM_DATA_EVENT_WRITE_DONE_V2
	$A --port $PORT 7 0x10dab $off 3000 w:$((POOL_LSW + off)) w:$POOL_MSW w:$handle w:$2 w:0 w:0 w:0 w:0
	;;
stream-off)
	. $ST
	$A --port $PORT 7 0x10bd3 $PORT 2000                     # ASM_SESSION_CMD_PAUSE
	$A 8 0x10325 0 2000 w:0 w:1 h:$SESSION h:0 h:0 h:0 2>/dev/null >/dev/null
	$A --port $PORT 7 0x10bcd $PORT 2000                     # ASM_STREAM_CMD_CLOSE
	# the ADM COPP stays open: its close wants src port 0x1006 and dest port = the COPP id (not yet in sweetapr)
	$A 7 0x10d94 $((SESSION << 8)) 2000 w:$handle            # ASM_CMD_SHARED_MEM_UNMAP_REGIONS
	;;
tone)
	# the first listening test: 2 s of tone440.pcm (mkpcm.py --freq 440 --seconds 2 --dbfs -30), amp ROM mode at DAC
	# gain 2 of 15 (no speaker protection in ROM mode: stay low), everything off again afterwards
	sync
	$0 port-on >/dev/null
	$I $AMP/id.bin
	$I $AMP/load-rom.bin
	$I $AMP/on-g2.bin
	$0 stream-on >/dev/null || { $I $AMP/off.bin; $0 port-off >/dev/null; exit 1; }
	/var/root/sweetpool $AMP/tone440.pcm
	$0 write 384000 0
	$I $AMP/status.bin
	$I $AMP/off.bin
	$0 stream-off >/dev/null
	$0 port-off >/dev/null
	;;
amp-register)
	# the amp's scripts into the kernel for SweetSpeaker.driver (root only; once per boot, after the DSP is up)
	[ -s $AMP/amp-on.bin ] || { cat $AMP/load-rom.bin $AMP/on-g2.bin > $AMP/amp-on.bin; sync; }
	/var/root/sweetplay -a $AMP/amp-on.bin -o $AMP/off.bin -w $AMP/on-g2.bin
	;;
play)
	# FILE: raw 48 kHz 16-bit stereo (mkpcm.py); amp ROM mode at DAC gain 2 of 15, as for tone (no speaker protection)
	sync
	[ -s $AMP/amp-on.bin ] || { cat $AMP/load-rom.bin $AMP/on-g2.bin > $AMP/amp-on.bin; sync; }
	/var/root/sweetplay -a $AMP/amp-on.bin -o $AMP/off.bin "$2"
	;;
status)
	$SYS kern.sweet_audio_pins
	$I $AMP/status.bin
	$A -r
	;;
*)
	sed -n '2,10p' "$0"
	exit 2
	;;
esac
