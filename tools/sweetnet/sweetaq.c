/*
 * sweetaq [SECONDS] [RATE]: play silence through an AudioQueue over SSH and say whether the audio server consumed it.
 * Prints AudioQueueNewOutput/Start results, then once a second the buffers handed back by the queue and its device time;
 * 0 buffers back means the output device ran no IO cycles. At the end: frames consumed per wall-clock second against the
 * queue's rate (a device clock that runs slow or fast shows here) and mach_timebase_info.
 * Default 5 s at 48000 Hz, stereo Float32, 8 x 4096 frames queued: more than one IO buffer (VirtualAudio's is 4096
 * frames), or the queue underruns every cycle and the rate reads low. Also prints AudioGetHostClockFrequency(), which must
 * match the counter (timebase_cache.py).
 * iOS 18+, arm64e + pacstrip (tools/sweetnet/build.sh).
 */
#include <AudioToolbox/AudioToolbox.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define FRAMES 4096
#define NBUF 8

static volatile unsigned back;

static void
refill(void *ud, AudioQueueRef q, AudioQueueBufferRef b)
{
	(void)ud;
	memset(b->mAudioData, 0, b->mAudioDataBytesCapacity);
	b->mAudioDataByteSize = b->mAudioDataBytesCapacity;
	__atomic_add_fetch(&back, 1, __ATOMIC_RELAXED);
	AudioQueueEnqueueBuffer(q, b, 0, NULL);
}

static const char *
fourcc(OSStatus s, char *buf)
{
	uint32_t v = (uint32_t)s;
	char c[4] = { (char)(v >> 24), (char)(v >> 16), (char)(v >> 8), (char)v };
	for (int i = 0; i < 4; i++) {
		if (c[i] < 32 || c[i] > 126) {
			snprintf(buf, 16, "%d", (int)s);
			return buf;
		}
	}
	snprintf(buf, 16, "'%.4s'", c);
	return buf;
}

int
main(int argc, char **argv)
{
	int secs = argc > 1 ? atoi(argv[1]) : 5;
	double rate = argc > 2 ? atof(argv[2]) : 48000;
	AudioStreamBasicDescription f = {
		.mSampleRate = rate, .mFormatID = kAudioFormatLinearPCM,
		.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
		.mBytesPerPacket = 8, .mFramesPerPacket = 1, .mBytesPerFrame = 8, .mChannelsPerFrame = 2, .mBitsPerChannel = 32,
	};
	AudioQueueRef q = NULL;
	char e[16];
	double (*hostfreq)(void) = (double (*)(void))dlsym(RTLD_DEFAULT, "AudioGetHostClockFrequency");
	if (hostfreq != NULL) {
		printf("AudioGetHostClockFrequency: %.0f\n", hostfreq());
	}
	OSStatus s = AudioQueueNewOutput(&f, refill, NULL, NULL, NULL, 0, &q);
	printf("AudioQueueNewOutput: %s\n", fourcc(s, e));
	if (s != noErr) {
		return 1;
	}
	for (int i = 0; i < NBUF; i++) {
		AudioQueueBufferRef b = NULL;
		if (AudioQueueAllocateBuffer(q, FRAMES * 8, &b) == noErr) {
			memset(b->mAudioData, 0, FRAMES * 8);
			b->mAudioDataByteSize = FRAMES * 8;
			AudioQueueEnqueueBuffer(q, b, 0, NULL);
		}
	}
	s = AudioQueueStart(q, NULL);
	printf("AudioQueueStart: %s\n", fourcc(s, e));
	uint64_t t0 = mach_absolute_time();
	unsigned b0 = back;
	for (int t = 1; t <= secs && s == noErr; t++) {
		sleep(1);
		AudioTimeStamp ts = { 0 };
		OSStatus ds = AudioQueueDeviceGetCurrentTime(q, &ts);
		printf("%2d s: %u buffers back, device time %s %.0f\n", t, back, fourcc(ds, e), ts.mSampleTime);
	}
	if (s == noErr) {
		mach_timebase_info_data_t tb;
		mach_timebase_info(&tb);
		double wall = (double)(mach_absolute_time() - t0) * tb.numer / tb.denom / 1e9;
		double fps = (double)(back - b0) * FRAMES / wall;
		printf("consumed %.0f frames/s for %.0f Hz (%.1f%%); timebase %u/%u\n", fps, rate, 100 * fps / rate, tb.numer, tb.denom);
	}
	AudioQueueStop(q, true);
	AudioQueueDispose(q, true);
	return back > 0 ? 0 : 1;
}
