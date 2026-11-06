/*
 * sweetaqin SECONDS [FILE.wav] [-m] [-t FREQ DBFS] [-e]: record through iOS's audio stack over SSH, the way apps do:
 * AVAudioSession category Record (active), then an AudioQueue input at 48 kHz mono 16-bit.
 *   -m  mode Measurement (Apple's input processing off) instead of Default
 *   -t  also play a FREQ Hz sine at DBFS from this process (category PlayAndRecord, default to speaker): a loopback test
 *   -e  with -t: without DefaultToSpeaker, so iOS plays on the receiver (the earpiece) as in a call Prints the session's input route and its errors,
 * once a second the level of what came in (rms / peak dBFS) and the buffers handed back; writes FILE.wav if given.
 * With SweetSpeaker.driver's "Mic" device the route input should be the built-in microphone (MicrophoneBuiltIn).
 * Entitlements: mic.entitlements (com.apple.private.tcc.allow kTCCServiceMicrophone: no permission prompt over SSH).
 * iOS 18+, arm64e + pacstrip (tools/sweetnet/build.sh).
 */
#import <AVFAudio/AVFAudio.h>
#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define RATE 48000
#define FRAMES 4800                                     /* 100 ms per buffer */
#define NBUF 6

static int16_t *pcm;
static uint32_t total, got;
static volatile unsigned back;
static double tone_step, tone_amp, tone_phase;

static void
output_cb(void *ud, AudioQueueRef q, AudioQueueBufferRef b)
{
	(void)ud;
	float *p = b->mAudioData;
	unsigned n = b->mAudioDataBytesCapacity / 8;
	for (unsigned i = 0; i < n; i++) {
		float v = (float)(tone_amp * sin(tone_phase));
		tone_phase = fmod(tone_phase + tone_step, 2 * M_PI);
		p[2 * i] = p[2 * i + 1] = v;
	}
	b->mAudioDataByteSize = b->mAudioDataBytesCapacity;
	AudioQueueEnqueueBuffer(q, b, 0, NULL);
}

static void
input_cb(void *ud, AudioQueueRef q, AudioQueueBufferRef b, const AudioTimeStamp *t, UInt32 npd,
    const AudioStreamPacketDescription *pd)
{
	(void)ud; (void)t; (void)npd; (void)pd;
	uint32_t n = b->mAudioDataByteSize / 2;
	if (n > total - got) {
		n = total - got;
	}
	memcpy(pcm + got, b->mAudioData, n * 2);
	got += n;
	back++;
	AudioQueueEnqueueBuffer(q, b, 0, NULL);
}

static void
put32(FILE *f, uint32_t v)
{
	fwrite(&v, 4, 1, f);
}

static void
put16(FILE *f, uint16_t v)
{
	fwrite(&v, 2, 1, f);
}

static void
route(AVAudioSession *s)
{
	for (AVAudioSessionPortDescription *p in s.currentRoute.inputs) {
		printf("route input: %s \"%s\" uid %s\n", p.portType.UTF8String, p.portName.UTF8String, p.UID.UTF8String);
	}
	if (!s.currentRoute.inputs.count) {
		printf("route input: none\n");
	}
	for (AVAudioSessionPortDescription *p in s.availableInputs) {
		printf("available input: %s \"%s\"\n", p.portType.UTF8String, p.portName.UTF8String);
	}
	for (AVAudioSessionPortDescription *p in s.currentRoute.outputs) {
		printf("route output: %s \"%s\" uid %s\n", p.portType.UTF8String, p.portName.UTF8String, p.UID.UTF8String);
	}
}

int
main(int argc, char **argv)
{
	@autoreleasepool {
		if (argc < 2) {
			fprintf(stderr, "usage: sweetaqin SECONDS [FILE.wav] [-m] [-t FREQ DBFS]\n");
			return 2;
		}
		unsigned secs = (unsigned)atoi(argv[1]);
		const char *file = NULL;
		bool measure = false, earpiece = false;
		double freq = 0, dbfs = -40;
		for (int i = 2; i < argc; i++) {
			if (!strcmp(argv[i], "-m")) {
				measure = true;
			} else if (!strcmp(argv[i], "-e")) {
				earpiece = true;
			} else if (!strcmp(argv[i], "-t") && i + 2 < argc) {
				freq = atof(argv[i + 1]);
				dbfs = atof(argv[i + 2]);
				i += 2;
			} else {
				file = argv[i];
			}
		}
		total = secs * RATE;
		pcm = calloc(total ? total : 1, 2);
		AVAudioSession *s = [AVAudioSession sharedInstance];
		NSError *err = nil;
		BOOL ok = freq > 0 ? [s setCategory:AVAudioSessionCategoryPlayAndRecord mode:measure ? AVAudioSessionModeMeasurement :
		    AVAudioSessionModeDefault options:earpiece ? 0 : AVAudioSessionCategoryOptionDefaultToSpeaker error:&err] :
		    [s setCategory:AVAudioSessionCategoryRecord mode:measure ? AVAudioSessionModeMeasurement : AVAudioSessionModeDefault
		    options:0 error:&err];
		printf("setCategory %s, mode %s: %s %s\n", freq > 0 ? "PlayAndRecord" : "Record", measure ? "Measurement" : "Default",
		    ok ? "ok" : "FAILED", err ? err.description.UTF8String : "");
		err = nil;
		ok = [s setActive:YES error:&err];
		printf("setActive: %s %s\n", ok ? "ok" : "FAILED", err ? err.description.UTF8String : "");
		printf("record permission: %lu, input available: %d, input channels %ld, sample rate %.0f\n",
		    (unsigned long)AVAudioApplication.sharedInstance.recordPermission, s.inputAvailable, (long)s.inputNumberOfChannels, s.sampleRate);
		route(s);

		AudioStreamBasicDescription f = { 0 };
		f.mSampleRate = RATE;
		f.mFormatID = kAudioFormatLinearPCM;
		f.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
		f.mBytesPerPacket = f.mBytesPerFrame = 2;
		f.mFramesPerPacket = 1;
		f.mChannelsPerFrame = 1;
		f.mBitsPerChannel = 16;
		AudioQueueRef q = NULL;
		OSStatus r = AudioQueueNewInput(&f, input_cb, NULL, NULL, NULL, 0, &q);
		printf("AudioQueueNewInput: %d\n", (int)r);
		if (r) {
			return 1;
		}
		for (int i = 0; i < NBUF; i++) {
			AudioQueueBufferRef b;
			AudioQueueAllocateBuffer(q, FRAMES * 2, &b);
			AudioQueueEnqueueBuffer(q, b, 0, NULL);
		}
		r = AudioQueueStart(q, NULL);
		printf("AudioQueueStart: %d\n", (int)r);
		if (r) {
			return 1;
		}
		AudioQueueRef oq = NULL;
		if (freq > 0) {
			AudioStreamBasicDescription of = { 0 };
			of.mSampleRate = RATE;
			of.mFormatID = kAudioFormatLinearPCM;
			of.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
			of.mBytesPerPacket = of.mBytesPerFrame = 8;
			of.mFramesPerPacket = 1;
			of.mChannelsPerFrame = 2;
			of.mBitsPerChannel = 32;
			tone_step = 2 * M_PI * freq / RATE;
			tone_amp = pow(10, dbfs / 20);
			r = AudioQueueNewOutput(&of, output_cb, NULL, NULL, NULL, 0, &oq);
			for (int i = 0; r == 0 && i < 8; i++) {
				AudioQueueBufferRef b;
				AudioQueueAllocateBuffer(oq, 4096 * 8, &b);
				output_cb(NULL, oq, b);
			}
			OSStatus r2 = r ? r : AudioQueueStart(oq, NULL);
			printf("tone %.0f Hz at %.1f dBFS: AudioQueueNewOutput %d, start %d\n", freq, dbfs, (int)r, (int)r2);
		}
		uint32_t shown = 0;
		for (unsigned waited = 0; got < total && waited < secs * 10 + 50; waited++) {
			usleep(100000);
			uint32_t g = got;
			if (g / RATE != shown / RATE || g == total) {
				uint32_t a = shown, b = g;
				double s2 = 0;
				int peak = 0;
				for (uint32_t i = a; i < b; i++) {
					s2 += (double)pcm[i] * pcm[i];
					peak = abs(pcm[i]) > peak ? abs(pcm[i]) : peak;
				}
				printf("%2u s: rms %.1f dBFS, peak %.1f dBFS, %u buffers back\n", g / RATE,
				    20 * log10((sqrt(s2 / (b > a ? b - a : 1)) + 1e-9) / 32768.0), 20 * log10((peak + 1e-9) / 32768.0), back);
				shown = g;
			}
		}
		AudioQueueStop(q, true);
		if (oq) {
			AudioQueueStop(oq, true);
		}
		for (AVAudioSessionPortDescription *p in s.currentRoute.outputs) {
			printf("route output: %s \"%s\"\n", p.portType.UTF8String, p.portName.UTF8String);
		}
		route(s);
		[s setActive:NO error:nil];
		printf("%u samples (%u buffers back)\n", got, back);
		if (file && got) {
			FILE *o = fopen(file, "wb");
			if (!o) {
				perror(file);
				return 1;
			}
			fwrite("RIFF", 1, 4, o);
			put32(o, 36 + got * 2);
			fwrite("WAVEfmt ", 1, 8, o);
			put32(o, 16);
			put16(o, 1);
			put16(o, 1);
			put32(o, RATE);
			put32(o, RATE * 2);
			put16(o, 2);
			put16(o, 16);
			fwrite("data", 1, 4, o);
			put32(o, got * 2);
			fwrite(pcm, 2, got, o);
			fclose(o);
			printf("wrote %s\n", file);
		}
	}
	return 0;
}
