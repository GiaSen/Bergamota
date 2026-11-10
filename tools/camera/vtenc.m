/*
 * Which video encoders VideoToolbox has on this phone, whether a compression session can be made for the codecs Camera
 * records with, and which of VideoToolbox's encoder plug-in functions are exported (for an encoder of our own).
 *   xcrun -sdk iphoneos clang -arch arm64e -mios-version-min=18.0 -fobjc-arc -framework Foundation -framework VideoToolbox \
 *     -framework CoreMedia -framework CoreVideo vtenc.m -o vtenc; codesign -s - -f vtenc; python3 tools/renegade/pacstrip.py --sign vtenc
 */
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <mach/mach.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <sys/resource.h>
#ifndef PRIO_DARWIN_ROLE     /* xnu bsd/sys/resource.h, private */
#define PRIO_DARWIN_ROLE 6
#define PRIO_DARWIN_ROLE_UI_FOCAL 1
#endif

static void
try_session(const char *name, CMVideoCodecType codec, int w, int h)
{
	VTCompressionSessionRef s = NULL;
	OSStatus e = VTCompressionSessionCreate(NULL, w, h, codec, NULL, NULL, NULL, NULL, NULL, &s);
	printf("VTCompressionSessionCreate %s %dx%d: %d%s\n", name, w, h, (int)e, e == 0 ? " (made)" : "");
	if (s) {
		CFStringRef eid = NULL;
		if (VTSessionCopyProperty(s, kVTCompressionPropertyKey_EncoderID, NULL, &eid) == 0 && eid) {
			printf("  encoder: %s\n", [(__bridge NSString *)eid UTF8String]);
			CFRelease(eid);
		}
		VTCompressionSessionInvalidate(s);
		CFRelease(s);
	}
}

/*
 * vtenc CODEC W H FRAMES [OUT]: FRAMES moving test pictures (4:2:0 8-bit) through a compression session at 30 fps, real time
 * asked: milliseconds a frame, bytes, key frames; OUT gets the stream with start codes (Annex B: parameter sets from the
 * format description, then every NAL unit) for a look with another decoder. VTENC_LIB=/path/to/sweetavc.dylib in the
 * environment: that library is loaded first and the session runs its encoder in this process.
 */
struct enc_state { FILE *out; unsigned frames, keys; size_t bytes; bool header; OSStatus err; };

static void
enc_done(void *ctx, void *frame_ctx, OSStatus status, VTEncodeInfoFlags flags, CMSampleBufferRef sb)
{
	struct enc_state *st = ctx;
	if (status != 0 || !sb) {
		st->err = status ? status : -1;
		return;
	}
	static const uint8_t start[4] = { 0, 0, 0, 1 };
	CFArrayRef att = CMSampleBufferGetSampleAttachmentsArray(sb, false);
	bool key = !att || CFArrayGetCount(att) == 0 ||
	    !CFDictionaryContainsKey(CFArrayGetValueAtIndex(att, 0), kCMSampleAttachmentKey_NotSync);
	st->frames++;
	st->keys += key;
	CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
	size_t len = bb ? CMBlockBufferGetDataLength(bb) : 0;
	st->bytes += len;
	if (!st->out || !len) {
		return;
	}
	CMFormatDescriptionRef fd = CMSampleBufferGetFormatDescription(sb);
	bool hevc = CMFormatDescriptionGetMediaSubType(fd) == kCMVideoCodecType_HEVC;
	if (key || !st->header) {
		size_t n = 0;
		int nal_len = 4;
		if (hevc) {
			CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, 0, NULL, NULL, &n, &nal_len);
		} else {
			CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, 0, NULL, NULL, &n, &nal_len);
		}
		for (size_t i = 0; i < n; i++) {
			const uint8_t *ps = NULL;
			size_t pl = 0;
			OSStatus e = hevc ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, i, &ps, &pl, NULL, NULL) :
			    CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, i, &ps, &pl, NULL, NULL);
			if (e == 0 && ps) {
				fwrite(start, 1, 4, st->out);
				fwrite(ps, 1, pl, st->out);
			}
		}
		st->header = true;
	}
	uint8_t *buf = malloc(len);
	if (buf && CMBlockBufferCopyDataBytes(bb, 0, len, buf) == 0) {
		for (size_t o = 0; o + 4 <= len;) {
			uint32_t nl = (uint32_t)buf[o] << 24 | (uint32_t)buf[o + 1] << 16 | (uint32_t)buf[o + 2] << 8 | buf[o + 3];
			if (nl > len - o - 4) {
				break;
			}
			fwrite(start, 1, 4, st->out);
			fwrite(buf + o + 4, 1, nl, st->out);
			o += 4 + nl;
		}
	}
	free(buf);
}

static int
encode(const char *codec_name, int w, int h, int frames, const char *out)
{
	CMVideoCodecType codec = !strcmp(codec_name, "hvc1") ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264;
	struct enc_state st = { .out = out ? fopen(out, "wb") : NULL };
	VTCompressionSessionRef s = NULL;
	OSStatus e;
	const char *lib = getenv("VTENC_LIB");
	if (lib) {
		/* an encoder library of our own (tools/sweetnet/sweetavc.m): loaded here, and the session kept in this process */
		OSStatus (*create_opts)(CFAllocatorRef, int32_t, int32_t, CMVideoCodecType, CFDictionaryRef, CFDictionaryRef, CFAllocatorRef,
		    VTCompressionOutputCallback, void *, CFDictionaryRef, VTCompressionSessionRef *) =
		    dlsym(RTLD_DEFAULT, "VTCompressionSessionCreateWithOptions");
		CFStringRef *in_proc = dlsym(RTLD_DEFAULT, "kVTCompressionSessionOption_AllowClientProcessEncode");
		if (!dlopen(lib, RTLD_NOW) || !create_opts || !in_proc) {
			printf("%s: %s\n", lib, dlerror() ?: "VideoToolbox's WithOptions is not there");
			return 1;
		}
		e = create_opts(NULL, w, h, codec, NULL, NULL, NULL, enc_done, &st, (__bridge CFDictionaryRef)@{ (__bridge NSString *)*in_proc: @YES }, &s);
	} else {
		e = VTCompressionSessionCreate(NULL, w, h, codec, NULL, NULL, NULL, enc_done, &st, &s);
	}
	if (e != 0 || !s) {
		printf("no session: %d\n", (int)e);
		return 1;
	}
	CFStringRef eid = NULL;
	VTSessionCopyProperty(s, kVTCompressionPropertyKey_EncoderID, NULL, &eid);
	int rate = w * h * 4, fps = 30, gop = 30;          /* about 8 Mbit/s at 1080p */
	printf("RealTime %d, bit rate %d: %d, key frame interval: %d, frame rate: %d, no reordering: %d\n",
	    (int)VTSessionSetProperty(s, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue), rate,
	    (int)VTSessionSetProperty(s, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFNumberRef)@(rate)),
	    (int)VTSessionSetProperty(s, kVTCompressionPropertyKey_MaxKeyFrameInterval, (__bridge CFNumberRef)@(gop)),
	    (int)VTSessionSetProperty(s, kVTCompressionPropertyKey_ExpectedFrameRate, (__bridge CFNumberRef)@(fps)),
	    (int)VTSessionSetProperty(s, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse));
	printf("prepare: %d\n", (int)VTCompressionSessionPrepareToEncodeFrames(s));
	NSDictionary *attrs = @{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
	CVPixelBufferRef pb[4] = { NULL, NULL, NULL, NULL };
	for (int k = 0; k < 4; k++) {
		/* four pictures of a moving scene: diagonal bars over a gradient, shifted, with some noise */
		CVPixelBufferCreate(NULL, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, (__bridge CFDictionaryRef)attrs, &pb[k]);
		if (!pb[k]) {
			return 1;
		}
		CVPixelBufferLockBaseAddress(pb[k], 0);
		uint8_t *y = CVPixelBufferGetBaseAddressOfPlane(pb[k], 0), *c = CVPixelBufferGetBaseAddressOfPlane(pb[k], 1);
		size_t ys = CVPixelBufferGetBytesPerRowOfPlane(pb[k], 0), cs = CVPixelBufferGetBytesPerRowOfPlane(pb[k], 1);
		unsigned seed = 12345u + (unsigned)k;
		const bool noise = !getenv("VTENC_CLEAN");      /* VTENC_CLEAN=1: no noise on the pictures (an easier job) */
		for (int r = 0; r < h; r++) {
			for (int x = 0; x < w; x++) {
				seed = seed * 1103515245u + 12345u;
				int v = 40 + x * 120 / w + (((x + r + 12 * k) / 48) & 1) * 60 + (noise ? (int)((seed >> 16) & 7) : 0);
				y[r * ys + x] = (uint8_t)v;
			}
		}
		for (int r = 0; r < h / 2; r++) {
			for (int x = 0; x < w / 2; x++) {
				c[r * cs + 2 * x] = (uint8_t)(100 + x * 60 / (w / 2));
				c[r * cs + 2 * x + 1] = (uint8_t)(110 + r * 50 / (h / 2));
			}
		}
		CVPixelBufferUnlockBaseAddress(pb[k], 0);
	}
	uint64_t t0 = clock_gettime_nsec_np(CLOCK_MONOTONIC), worst = 0;
	for (int i = 0; i < frames && st.err == 0; i++) {
		uint64_t a = clock_gettime_nsec_np(CLOCK_MONOTONIC);
		e = VTCompressionSessionEncodeFrame(s, pb[i & 3], CMTimeMake(i, fps), CMTimeMake(1, fps), NULL, NULL, NULL);
		uint64_t d = clock_gettime_nsec_np(CLOCK_MONOTONIC) - a;
		worst = d > worst ? d : worst;
		if (e != 0) {
			printf("frame %d: %d\n", i, (int)e);
			break;
		}
	}
	OSStatus ce = VTCompressionSessionCompleteFrames(s, kCMTimeInvalid);
	double total = (clock_gettime_nsec_np(CLOCK_MONOTONIC) - t0) / 1e6;
	printf("%s %dx%d by %s: %u of %d frames out (%u key), %zu bytes (%.1f Mbit/s at %d fps), %.1f ms a frame (longest call %.1f ms), complete %d, callback error %d\n",
	    codec_name, w, h, eid ? [(__bridge NSString *)eid UTF8String] : "?", st.frames, frames, st.keys, st.bytes,
	    st.frames ? st.bytes * 8.0 * fps / st.frames / 1e6 : 0.0, fps, frames ? total / frames : 0.0, worst / 1e6, (int)ce, (int)st.err);
	if (st.out) {
		fclose(st.out);
	}
	VTCompressionSessionInvalidate(s);
	CFRelease(s);
	return st.frames ? 0 : 1;
}

/* the calling thread's scheduling priority now (base), from the kernel */
static int
my_priority(void)
{
	struct thread_extended_info ti;
	mach_msg_type_number_t n = THREAD_EXTENDED_INFO_COUNT;
	mach_port_t t = mach_thread_self();
	kern_return_t kr = thread_info(t, THREAD_EXTENDED_INFO, (thread_info_t)&ti, &n);
	mach_port_deallocate(mach_task_self(), t);
	return kr == KERN_SUCCESS ? ti.pth_priority : -1;
}

int
main(int argc, char **argv)
{
	if (argc >= 5) {
		/*
		 * A tool started over SSH runs in the background band (thread priority 4, inherited from the SSH daemon), and
		 * Heartwood keeps threads under priority 31 on the small cores at 0.9 GHz: out of that band first (VTENC_ROLE=0
		 * leaves it), so the timing is nearer what a media server's threads get
		 */
		int before = my_priority(), role = getenv("VTENC_ROLE") ? atoi(getenv("VTENC_ROLE")) : 1;
		int rc0 = role ? setpriority(PRIO_DARWIN_PROCESS, 0, 0) : 0;            /* out of the background band (priority 4) */
		int rc = role ? setpriority(PRIO_DARWIN_ROLE, 0, PRIO_DARWIN_ROLE_UI_FOCAL) : 0;
		pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
		printf("thread priority %d; out of the background band (%d), foreground role (%d), user-interactive: %d\n", before, rc0, rc, my_priority());
		@autoreleasepool {
			return encode(argv[1], atoi(argv[2]), atoi(argv[3]), atoi(argv[4]), argc > 5 ? argv[5] : NULL);
		}
	}
	@autoreleasepool {
		CFArrayRef list = NULL;
		OSStatus e = VTCopyVideoEncoderList(NULL, &list);
		printf("VTCopyVideoEncoderList: %d, %ld encoders\n", (int)e, list ? (long)CFArrayGetCount(list) : 0);
		for (NSDictionary *d in (__bridge NSArray *)list) {
			printf("  %-28s %-58s codec %s hardware %s\n", [[d[(id)kVTVideoEncoderList_DisplayName] description] UTF8String],
			    [[d[(id)kVTVideoEncoderList_EncoderID] description] UTF8String], [[d[(id)kVTVideoEncoderList_CodecName] description] UTF8String],
			    [[d[@"IsHardwareAccelerated"] description] UTF8String]);
		}
		try_session("avc1", kCMVideoCodecType_H264, 1280, 720);
		try_session("avc1", kCMVideoCodecType_H264, 1920, 1080);
		try_session("hvc1", kCMVideoCodecType_HEVC, 1920, 1080);
		try_session("jpeg", kCMVideoCodecType_JPEG, 1280, 720);
		static const char *const syms[] = { "VTRegisterVideoEncoder", "VTRegisterVideoEncoderWithInfo", "VTVideoEncoderGetClassID",
			                            "VTVideoEncoderGetCMBaseObject", "VTEncoderSessionEmitEncodedFrame", "VTEncoderSessionEmitEncodedTile",
			                            "VTEncoderSessionCreateVideoFormatDescription", "VTEncoderSessionSetPixelBufferAttributes",
			                            "VTEncoderSessionCopyProperty?", "VTVideoEncoderRegistrationCopyList", "VTLoadVideoEncoders",
			                            "VTSelectAndCreateVideoEncoderInstance", "VTRegisterVideoDecoder", "VTVideoDecoderGetClassID",
			                            "FigRegisterIOKitVideoEncoders", "VTRegisterSupplementalVideoEncoder" };
		for (unsigned i = 0; i < sizeof(syms) / sizeof(syms[0]); i++) {
			printf("%-46s %s\n", syms[i], dlsym(RTLD_DEFAULT, syms[i]) ? "exported" : "-");
		}
	}
	return 0;
}
