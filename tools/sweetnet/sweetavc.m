/*
 * sweetavc.dylib: an H.264 video encoder for VideoToolbox, on the CPU, with x264 (VideoLAN, GPL; tools/x264-build.sh).
 *
 * Why: iOS has H.264 and HEVC encoders only as drivers for Apple's encoder chip (AVE). On the Mi 8 VTCopyVideoEncoderList
 * has h263 and jpeg; the "rtvc" encoders a session gets for avc1/hvc1 are fronts for that chip and fail every frame with
 * -12908; cameracaptured logs "AVE WARN: Register AVC video encoder of AVE -1005" and "VTVideoEncoderSelection signalled
 * err=-12908" (tools/camera/vtenc.m, NOTES 2026-11-10 "VIDEO RECORDING"). So Camera could not record a movie.
 *
 * What: VideoToolbox's encoder plug-in interface (exported, not in the SDK). An encoder is a CMBaseObject of the class
 * VTVideoEncoderGetClassID(), made by a function registered with VTRegisterVideoEncoder(codec, create); its vtable is
 * { reserved, CMBaseClass *, VTVideoEncoderClass * } and the encoder class, found on iOS 26.6.2 with a probe whose slots
 * only said they were called: version, then
 *   1 startSession(encoder, session, CMVideoDimensions)
 *   2 encodeFrame(encoder, frame, pixel buffer, CMTime *presentation, CMTime *duration, frame properties, info flags out)
 *   3 completeFrames(encoder, CMTime *until)
 *   4 copySupportedPropertyDictionary(encoder, CFDictionaryRef *out)   (asked before every property is set or read)
 *   5 setProperties, 6 copySerializableProperties (not seen called; left empty)
 * Properties come through the CMBaseClass's copyProperty/setProperty once the supported dictionary has their key. The
 * encoder hands a frame back with VTEncoderSessionEmitEncodedFrame(session, frame, status, flags, sample buffer).
 * A session runs its encoder in the calling process when that process is a media server (cameracaptured is) or when
 * VTCompressionSessionCreateWithOptions gets kVTCompressionSessionOption_AllowClientProcessEncode = true (vtenc does);
 * otherwise in videocodecd, where this library is not loaded.
 *
 * x264: preset ultrafast, tune zerolatency (no B-frames, no lookahead: every frame comes out of the call that brought
 * it in, in order), sliced threads, the bit rate and key frame interval the session sets, NV12 input straight from the
 * pixel buffer's planes, 4-byte NAL lengths (avcC), no parameter sets in the stream (they are in the format description).
 *
 * Loaded by sweetcam.dylib into cameracaptured (dlopen; the constructor registers the encoder). Log: subsystem
 * com.sweet.avc. /private/var/tmp/sweetavc.off: not registered. iOS 18+, arm64e + pacstrip (tools/sweetnet/build.sh).
 * This library contains x264 and is therefore under the GPL (version 2 or later) as a whole.
 */
#import <Foundation/Foundation.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <dlfcn.h>
#include <os/log.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include "x264.h"

static os_log_t gLog;
#define say(...) os_log(gLog, "sweetavc: " __VA_ARGS__)

typedef const void *CMBaseClassID;
typedef struct OpaqueCMBaseObject *CMBaseObjectRef;
typedef struct OpaqueVTVideoEncoder *VTVideoEncoderRef;
typedef struct OpaqueVTVideoEncoderSession *VTVideoEncoderSession;
typedef struct OpaqueVTVideoEncoderFrame *VTVideoEncoderFrame;

struct base_class {
	uint64_t version;
	uint64_t storage_size;
	Boolean (*equal)(CMBaseObjectRef, CMBaseObjectRef);
	OSStatus (*invalidate)(CMBaseObjectRef);
	void (*finalize)(CMBaseObjectRef);
	CFStringRef (*copy_debug_description)(CMBaseObjectRef);
	OSStatus (*copy_property)(CMBaseObjectRef, CFStringRef, CFAllocatorRef, void *);
	OSStatus (*set_property)(CMBaseObjectRef, CFStringRef, CFTypeRef);
	OSStatus (*notification_barrier)(CMBaseObjectRef);
	const void *protocols;
	const void *reserved;
};

struct encoder_class {
	uint64_t version;
	OSStatus (*start_session)(VTVideoEncoderRef, VTVideoEncoderSession, CMVideoDimensions);
	OSStatus (*encode_frame)(VTVideoEncoderRef, VTVideoEncoderFrame, CVPixelBufferRef, const CMTime *, const CMTime *, CFDictionaryRef, uint32_t *);
	OSStatus (*complete_frames)(VTVideoEncoderRef, const CMTime *);
	OSStatus (*copy_supported_properties)(VTVideoEncoderRef, CFDictionaryRef *);
	OSStatus (*set_properties)(VTVideoEncoderRef, CFDictionaryRef);
	OSStatus (*copy_serializable_properties)(VTVideoEncoderRef, CFDictionaryRef *);
	void *later[10];                /* what newer class versions add: version 1 says they are not there */
};

struct vtable {
	const void *reserved;
	const struct base_class *base;
	const struct encoder_class *encoder;
};

static OSStatus (*derived_create)(CFAllocatorRef, const struct vtable *, CMBaseClassID, CMBaseObjectRef *);
static void *(*derived_storage)(CMBaseObjectRef);
static CMBaseClassID (*encoder_class_id)(void);
static OSStatus (*emit_frame)(VTVideoEncoderSession, VTVideoEncoderFrame, OSStatus, uint32_t, CMSampleBufferRef);
static OSStatus (*set_pixel_attrs)(VTVideoEncoderSession, CFDictionaryRef);

#define kVTPropertyNotSupportedErr      (-12900)
#define kVTParameterErr                 (-12902)
#define kVTAllocationFailedErr          (-12904)
#define kVTVideoEncoderMalfunctionErr   (-12912)

struct avc {
	VTVideoEncoderSession session;
	int w, h;
	x264_t *x;
	CMVideoFormatDescriptionRef fd;
	pthread_mutex_t lock;
	/* what the session asked for (0 / NULL: not said) */
	int bitrate;                    /* bits a second */
	double fps;
	int keyint;                     /* frames */
	double keyint_s;                /* seconds */
	bool cavlc, baseline, main_profile;
	int primaries, transfer, matrix;        /* H.264 VUI codes (0: not said) */
	CFMutableDictionaryRef set;     /* every property set, as given (read back as given) */
	unsigned frames, keys;
	uint64_t bytes, enc_ns, worst_ns;
};

/*
 * x264's pthread_create (tools/x264-build.sh compiles it with -Dpthread_create=sweetavc_pthread_create): its slice threads
 * start user-interactive. At the default priority Heartwood runs them on the small cores, capped at 0.9 GHz.
 */
__attribute__((visibility("hidden"))) int
sweetavc_pthread_create(pthread_t *thread, const pthread_attr_t *attr, void *(*start)(void *), void *arg)
{
	if (attr) {
		return pthread_create(thread, attr, start, arg);
	}
	pthread_attr_t a;
	pthread_attr_init(&a);
	pthread_attr_set_qos_class_np(&a, QOS_CLASS_USER_INTERACTIVE, 0);
	int e = pthread_create(thread, &a, start, arg);
	pthread_attr_destroy(&a);
	return e;
}

static struct avc *
avc_of(void *encoder)
{
	return derived_storage ? derived_storage((CMBaseObjectRef)encoder) : NULL;
}

static void
x264_says(void *ctx, int level, const char *fmt, va_list ap)
{
	(void)ctx;
	if (level > X264_LOG_INFO) {
		return;
	}
	char line[256];
	vsnprintf(line, sizeof(line), fmt, ap);
	line[strcspn(line, "\n")] = 0;
	say("x264: %{public}s", line);
}

static int
vui_code(CFTypeRef v, bool matrix)
{
	if (!v || CFGetTypeID(v) != CFStringGetTypeID()) {
		return 0;
	}
	if (CFEqual(v, CFSTR("ITU_R_709_2"))) {
		return 1;
	}
	if (CFEqual(v, CFSTR("ITU_R_601_4")) || CFEqual(v, CFSTR("SMPTE_C"))) {
		return 6;
	}
	if (CFEqual(v, CFSTR("SMPTE_240M_1995"))) {
		return 7;
	}
	if (CFEqual(v, CFSTR("ITU_R_2020"))) {
		return matrix ? 9 : 9;
	}
	if (CFEqual(v, CFSTR("P3_D65"))) {
		return 12;
	}
	return 0;
}

/* x264 opened with what the session has asked for by now, and the format description made from its parameter sets */
static OSStatus
avc_open(struct avc *a, bool full_range)
{
	x264_param_t p;
	/*
	 * ultrafast: while a movie records, cameracaptured also develops every frame and turns the viewfinder's picture on
	 * the CPU, and all eight cores are about 90 % busy. superfast took 44 ms a 1504x1128 frame there (the movie came out at
	 * 23.6 frames a second), ultrafast 33 ms (29.5). /private/var/tmp/sweetavc.preset: another x264 preset's name for a try
	 */
	char preset[32] = "ultrafast";
	FILE *pf = fopen("/private/var/tmp/sweetavc.preset", "r");
	if (pf) {
		if (fgets(preset, sizeof(preset), pf)) {
			preset[strcspn(preset, "\r\n ")] = 0;
		}
		fclose(pf);
	}
	if (x264_param_default_preset(&p, preset, "zerolatency") != 0 && x264_param_default_preset(&p, "superfast", "zerolatency") != 0) {
		return kVTVideoEncoderMalfunctionErr;
	}
	double fps = a->fps >= 1 && a->fps <= 240 ? a->fps : 30;
	int kbps = a->bitrate > 0 ? a->bitrate / 1000 : a->w * a->h * 4 / 1000;
	p.i_width = a->w;
	p.i_height = a->h;
	p.i_csp = X264_CSP_NV12;
	p.i_bitdepth = 8;
	p.i_threads = 4;
	p.b_sliced_threads = 1;
	p.i_fps_num = (uint32_t)(fps * 1000 + 0.5);
	p.i_fps_den = 1000;
	p.i_timebase_num = 1;
	p.i_timebase_den = 90000;
	p.b_vfr_input = 0;              /* 1 holds every frame back until the next one's time is known; the rate control then
	                                 * takes the frame rate as steady (the sample buffers carry the real times) */
	p.i_keyint_max = a->keyint > 0 ? a->keyint : a->keyint_s > 0 ? (int)(a->keyint_s * fps + 0.5) : (int)(fps + 0.5);
	p.i_keyint_min = 1;
	p.i_scenecut_threshold = 0;
	p.rc.i_rc_method = X264_RC_ABR;
	p.rc.i_bitrate = kbps;
	p.rc.i_vbv_max_bitrate = kbps * 2;
	p.rc.i_vbv_buffer_size = kbps;
	p.b_repeat_headers = 0;
	p.b_annexb = 0;
	p.b_aud = 0;
	p.b_cabac = !a->cavlc && !a->baseline;
	p.vui.b_fullrange = full_range;
	p.vui.i_colorprim = a->primaries ? a->primaries : 1;
	p.vui.i_transfer = a->transfer ? a->transfer : 1;
	p.vui.i_colmatrix = a->matrix ? a->matrix : 6;
	p.pf_log = x264_says;
	p.i_log_level = X264_LOG_INFO;  /* at open: the CPU features and the profile it settled on; quiet while encoding */
	x264_param_apply_profile(&p, a->baseline ? "baseline" : a->main_profile ? "main" : "high");
	a->x = x264_encoder_open(&p);
	if (!a->x) {
		say("x264 did not open for %dx%d at %d kbit/s", a->w, a->h, kbps);
		return kVTVideoEncoderMalfunctionErr;
	}
	x264_nal_t *nal = NULL;
	int n = 0;
	if (x264_encoder_headers(a->x, &nal, &n) < 0) {
		return kVTVideoEncoderMalfunctionErr;
	}
	const uint8_t *sets[2] = { NULL, NULL };
	size_t sizes[2] = { 0, 0 };
	for (int i = 0; i < n; i++) {
		int k = nal[i].i_type == NAL_SPS ? 0 : nal[i].i_type == NAL_PPS ? 1 : -1;
		if (k >= 0 && nal[i].i_payload > 4) {
			sets[k] = nal[i].p_payload + 4; /* past the 4-byte length */
			sizes[k] = (size_t)nal[i].i_payload - 4;
		}
	}
	if (!sets[0] || !sets[1]) {
		say("x264 gave no parameter sets");
		return kVTVideoEncoderMalfunctionErr;
	}
	OSStatus e = CMVideoFormatDescriptionCreateFromH264ParameterSets(NULL, 2, sets, sizes, 4, &a->fd);
	say("x264 open (%{public}s): %dx%d, %d kbit/s, %.2f fps, a key frame every %d frames, %{public}s %{public}s, %{public}s range, 4 sliced threads, %d frames held back; format description %d",
	    preset, a->w, a->h, kbps, fps, p.i_keyint_max, a->baseline ? "baseline" : a->main_profile ? "main" : "high", p.b_cabac ? "CABAC" : "CAVLC",
	    full_range ? "full" : "video", x264_encoder_maximum_delayed_frames(a->x), (int)e);
	return e;
}

static OSStatus
avc_start(VTVideoEncoderRef enc, VTVideoEncoderSession session, CMVideoDimensions dims)
{
	struct avc *a = avc_of(enc);
	if (!a || dims.width < 16 || dims.height < 16 || (dims.width & 1) || (dims.height & 1)) {
		return kVTParameterErr;
	}
	a->session = session;
	a->w = dims.width;
	a->h = dims.height;
	NSDictionary *attrs = @{
		(id)kCVPixelBufferPixelFormatTypeKey: @[ @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange), @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) ],
		(id)kCVPixelBufferWidthKey: @(dims.width),
		(id)kCVPixelBufferHeightKey: @(dims.height),
		(id)kCVPixelBufferIOSurfacePropertiesKey: @{},
	};
	OSStatus e = set_pixel_attrs ? set_pixel_attrs(session, (__bridge CFDictionaryRef)attrs) : 0;
	say("session started: %dx%d (pixel buffer attributes %d)", a->w, a->h, (int)e);
	return 0;
}

static OSStatus
avc_encode(VTVideoEncoderRef enc, VTVideoEncoderFrame frame, CVPixelBufferRef pb, const CMTime *pts, const CMTime *duration, CFDictionaryRef props,
    uint32_t *flags_out)
{
	struct avc *a = avc_of(enc);
	OSStatus err = 0;
	CMSampleBufferRef sb = NULL;
	if (flags_out) {
		*flags_out = 0;
	}
	if (!a || !pb || !pts) {
		return kVTParameterErr;
	}
	pthread_mutex_lock(&a->lock);
	OSType pf = CVPixelBufferGetPixelFormatType(pb);
	if (pf != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange && pf != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
		say("a frame in %c%c%c%c: only 8-bit 4:2:0 two-plane pictures are encoded", pf >> 24, pf >> 16 & 255, pf >> 8 & 255, pf & 255);
		err = kVTParameterErr;
		goto out;
	}
	if ((int)CVPixelBufferGetWidth(pb) != a->w || (int)CVPixelBufferGetHeight(pb) != a->h) {
		say("a frame of %zux%zu in a %dx%d session", CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb), a->w, a->h);
		err = kVTParameterErr;
		goto out;
	}
	if (!a->x && (err = avc_open(a, pf == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)) != 0) {
		goto out;
	}
	uint64_t t0 = clock_gettime_nsec_np(CLOCK_MONOTONIC);
	x264_picture_t in, outp;
	x264_picture_init(&in);
	in.img.i_csp = X264_CSP_NV12;
	in.img.i_plane = 2;
	CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
	in.img.plane[0] = CVPixelBufferGetBaseAddressOfPlane(pb, 0);
	in.img.plane[1] = CVPixelBufferGetBaseAddressOfPlane(pb, 1);
	in.img.i_stride[0] = (int)CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
	in.img.i_stride[1] = (int)CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
	CMTime t90 = CMTimeConvertScale(*pts, 90000, kCMTimeRoundingMethod_RoundHalfAwayFromZero);
	in.i_pts = t90.value;
	CFTypeRef force = props ? CFDictionaryGetValue(props, CFSTR("ForceKeyFrame")) : NULL;
	in.i_type = force == kCFBooleanTrue ? X264_TYPE_IDR : X264_TYPE_AUTO;
	x264_nal_t *nal = NULL;
	int n = 0, size = in.img.plane[0] && in.img.plane[1] ? x264_encoder_encode(a->x, &nal, &n, &in, &outp) : -1;
	CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
	uint64_t dt = clock_gettime_nsec_np(CLOCK_MONOTONIC) - t0;
	if (size <= 0 || n <= 0) {
		say("x264 gave %d bytes for frame %u", size, a->frames);
		err = kVTVideoEncoderMalfunctionErr;
		goto out;
	}
	/* x264 keeps a frame's NAL units one after the other, each after its 4-byte length: copied as they are */
	CMBlockBufferRef bb = NULL;
	err = CMBlockBufferCreateWithMemoryBlock(NULL, NULL, (size_t)size, kCFAllocatorDefault, NULL, 0, (size_t)size, kCMBlockBufferAssureMemoryNowFlag, &bb);
	if (err == 0 && bb) {
		err = CMBlockBufferReplaceDataBytes(nal[0].p_payload, bb, 0, (size_t)size);
	}
	if (err != 0 || !bb) {
		if (bb) {
			CFRelease(bb);
		}
		err = err ? err : kVTAllocationFailedErr;
		goto out;
	}
	CMSampleTimingInfo timing = { .duration = duration ? *duration : kCMTimeInvalid, .presentationTimeStamp = *pts, .decodeTimeStamp = kCMTimeInvalid };
	size_t ssize = (size_t)size;
	err = CMSampleBufferCreateReady(NULL, bb, a->fd, 1, 1, &timing, 1, &ssize, &sb);
	CFRelease(bb);
	if (err != 0 || !sb) {
		err = err ? err : kVTAllocationFailedErr;
		goto out;
	}
	bool key = outp.b_keyframe != 0;
	CFArrayRef atts = CMSampleBufferGetSampleAttachmentsArray(sb, true);
	if (atts && CFArrayGetCount(atts) > 0) {
		CFMutableDictionaryRef d = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(atts, 0);
		if (!key) {
			CFDictionarySetValue(d, kCMSampleAttachmentKey_NotSync, kCFBooleanTrue);
			CFDictionarySetValue(d, kCMSampleAttachmentKey_DependsOnOthers, kCFBooleanTrue);
		} else {
			CFDictionarySetValue(d, kCMSampleAttachmentKey_DependsOnOthers, kCFBooleanFalse);
		}
	}
	a->frames++;
	a->keys += key;
	a->bytes += (uint64_t)size;
	a->enc_ns += dt;
	a->worst_ns = dt > a->worst_ns ? dt : a->worst_ns;
	if (a->frames == 1 || a->frames % 150 == 0) {
		say("%u frames (%u key), %.1f ms a frame (longest %.1f), %.2f Mbit/s at 30 a second", a->frames, a->keys, a->enc_ns / 1e6 / a->frames,
		    a->worst_ns / 1e6, a->bytes * 8.0 * 30 / a->frames / 1e6);
	}
out:
	pthread_mutex_unlock(&a->lock);
	if (emit_frame) {
		emit_frame(a->session, frame, err, 0, err == 0 ? sb : NULL);
	}
	if (sb) {
		CFRelease(sb);
	}
	return 0;       /* the frame's own status went with it */
}

static OSStatus
avc_complete(VTVideoEncoderRef enc, const CMTime *until)
{
	(void)enc;
	(void)until;
	return 0;       /* nothing is ever held back (zerolatency) */
}

/*
 * The supported properties: every key. CMCapture and VideoToolbox set some forty properties, many of them private names;
 * a key missing here makes the set fail with -12900 before this encoder sees it. This dictionary answers any key with
 * "read/write, not to be serialized"; what is set is kept, the ones x264 can honour are used (avc_set), the rest ignored.
 */
@interface SweetAnyKey : NSDictionary
@end

@implementation SweetAnyKey
- (NSUInteger)count
{
	return 0;
}
- (id)objectForKey:(id)key
{
	(void)key;
	static NSDictionary *info;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		info = @{ @"PropertyType": @"Other", @"ReadWriteStatus": @"ReadWrite", @"ShouldBeSerialized": @NO };
	});
	return info;
}
- (NSEnumerator *)keyEnumerator
{
	return [@[] objectEnumerator];
}
- (id)copyWithZone:(NSZone *)zone
{
	(void)zone;
	return self;
}
@end

static OSStatus
avc_supported(VTVideoEncoderRef enc, CFDictionaryRef *out)
{
	(void)enc;
	if (!out) {
		return kVTParameterErr;
	}
	static SweetAnyKey *any;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		any = [[SweetAnyKey alloc] init];
	});
	*out = (CFDictionaryRef)CFRetain((__bridge CFTypeRef)any);
	return 0;
}

static bool
num_of(CFTypeRef v, double *out)
{
	if (v && CFGetTypeID(v) == CFNumberGetTypeID()) {
		return CFNumberGetValue(v, kCFNumberDoubleType, out);
	}
	return false;
}

static OSStatus
avc_set(CMBaseObjectRef o, CFStringRef key, CFTypeRef value)
{
	struct avc *a = derived_storage(o);
	static unsigned said;
	double d = 0;
	if (!a || !key) {
		return kVTParameterErr;
	}
	pthread_mutex_lock(&a->lock);
	if (value) {
		CFDictionarySetValue(a->set, key, value);
	} else {
		CFDictionaryRemoveValue(a->set, key);
	}
	if (CFEqual(key, CFSTR("AverageBitRate")) && num_of(value, &d)) {
		a->bitrate = (int)d;
		if (a->x && d >= 10000) {
			/* while encoding: the rate follows */
			x264_param_t p;
			x264_encoder_parameters(a->x, &p);
			p.rc.i_bitrate = (int)(d / 1000);
			p.rc.i_vbv_max_bitrate = p.rc.i_bitrate * 2;
			p.rc.i_vbv_buffer_size = p.rc.i_bitrate;
			x264_encoder_reconfig(a->x, &p);
		}
	} else if (CFEqual(key, CFSTR("ExpectedFrameRate")) && num_of(value, &d)) {
		a->fps = d;
	} else if (CFEqual(key, CFSTR("MaxKeyFrameInterval")) && num_of(value, &d)) {
		a->keyint = (int)d;
	} else if (CFEqual(key, CFSTR("MaxKeyFrameIntervalDuration")) && num_of(value, &d)) {
		a->keyint_s = d;
	} else if (CFEqual(key, CFSTR("H264EntropyMode")) && value && CFGetTypeID(value) == CFStringGetTypeID()) {
		a->cavlc = CFEqual(value, CFSTR("CAVLC"));
	} else if (CFEqual(key, CFSTR("ProfileLevel")) && value && CFGetTypeID(value) == CFStringGetTypeID()) {
		a->baseline = CFStringFind(value, CFSTR("Baseline"), 0).location != kCFNotFound;
		a->main_profile = CFStringFind(value, CFSTR("Main"), 0).location != kCFNotFound;
	} else if (CFEqual(key, CFSTR("ColorPrimaries"))) {
		a->primaries = vui_code(value, false);
	} else if (CFEqual(key, CFSTR("TransferFunction"))) {
		a->transfer = vui_code(value, false);
	} else if (CFEqual(key, CFSTR("YCbCrMatrix"))) {
		a->matrix = vui_code(value, true);
	}
	pthread_mutex_unlock(&a->lock);
	if (said++ < 80) {
		CFStringRef vs = value ? CFCopyDescription(value) : CFSTR("(null)");
		char k[96] = "", v[160] = "";
		CFStringGetCString(key, k, sizeof(k), kCFStringEncodingUTF8);
		CFStringGetCString(vs, v, sizeof(v), kCFStringEncodingUTF8);
		say("set %{public}s = %{public}s", k, v);
		if (value) {
			CFRelease(vs);
		}
	}
	return 0;
}

static OSStatus
avc_copy(CMBaseObjectRef o, CFStringRef key, CFAllocatorRef allocator, void *out)
{
	struct avc *a = derived_storage(o);
	(void)allocator;
	if (!a || !key || !out) {
		return kVTParameterErr;
	}
	CFTypeRef v = NULL;
	if (CFEqual(key, CFSTR("NumberOfPendingFrames"))) {
		int zero = 0;
		v = CFNumberCreate(NULL, kCFNumberIntType, &zero);
	} else if (CFEqual(key, CFSTR("UsingHardwareAcceleratedVideoEncoder"))) {
		v = CFRetain(kCFBooleanFalse);
	} else if (CFEqual(key, CFSTR("AllowFrameReordering"))) {
		v = CFRetain(kCFBooleanFalse);
	} else if (CFEqual(key, CFSTR("EncoderID"))) {
		v = CFRetain(CFSTR("com.sweet.videoencoder.x264"));
	} else {
		pthread_mutex_lock(&a->lock);
		v = CFDictionaryGetValue(a->set, key);
		if (v) {
			CFRetain(v);
		}
		pthread_mutex_unlock(&a->lock);
	}
	static unsigned said;
	if (said++ < 60) {
		char k[96] = "";
		CFStringGetCString(key, k, sizeof(k), kCFStringEncodingUTF8);
		say("copy %{public}s: %{public}s", k, v ? "answered" : "not there");
	}
	if (!v) {
		return kVTPropertyNotSupportedErr;
	}
	*(CFTypeRef *)out = v;
	return 0;
}

static OSStatus
avc_invalidate(CMBaseObjectRef o)
{
	struct avc *a = derived_storage(o);
	if (a) {
		pthread_mutex_lock(&a->lock);
		if (a->x) {
			say("closed after %u frames (%u key), %.1f ms a frame, %.2f MB", a->frames, a->keys, a->frames ? a->enc_ns / 1e6 / a->frames : 0.0,
			    a->bytes / 1e6);
			x264_encoder_close(a->x);
			a->x = NULL;
		}
		pthread_mutex_unlock(&a->lock);
	}
	return 0;
}

static void
avc_finalize(CMBaseObjectRef o)
{
	struct avc *a = derived_storage(o);
	avc_invalidate(o);
	if (a) {
		if (a->fd) {
			CFRelease(a->fd);
		}
		if (a->set) {
			CFRelease(a->set);
		}
		pthread_mutex_destroy(&a->lock);
	}
}

static CFStringRef
avc_describe(CMBaseObjectRef o)
{
	struct avc *a = derived_storage(o);
	return CFStringCreateWithFormat(NULL, NULL, CFSTR("<sweetavc x264 H.264 encoder %dx%d, %u frames>"), a ? a->w : 0, a ? a->h : 0, a ? a->frames : 0);
}

static const struct base_class avc_base = {
	.version = 1, .storage_size = sizeof(struct avc), .invalidate = avc_invalidate, .finalize = avc_finalize,
	.copy_debug_description = avc_describe, .copy_property = avc_copy, .set_property = avc_set,
};
static const struct encoder_class avc_class = {
	.version = 1, .start_session = avc_start, .encode_frame = avc_encode, .complete_frames = avc_complete,
	.copy_supported_properties = avc_supported,
};
static const struct vtable avc_vtable = { NULL, &avc_base, &avc_class };

static OSStatus
avc_create(uint32_t codec, CFAllocatorRef allocator, VTVideoEncoderRef *out)
{
	CMBaseObjectRef o = NULL;
	if (!out || codec != kCMVideoCodecType_H264) {
		return kVTParameterErr;
	}
	OSStatus e = derived_create(allocator, &avc_vtable, encoder_class_id(), &o);
	if (e != 0 || !o) {
		return e ? e : kVTAllocationFailedErr;
	}
	struct avc *a = derived_storage(o);
	memset(a, 0, sizeof(*a));
	pthread_mutex_init(&a->lock, NULL);
	a->set = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	say("an encoder made in %{public}s", getprogname());
	*out = (VTVideoEncoderRef)o;
	return 0;
}

/* 0, or why the encoder is not registered; also called by the constructor */
__attribute__((visibility("default"))) int
sweetavc_register(void)
{
	static int state = -1;
	if (state >= 0) {
		return state;
	}
	if (access("/private/var/tmp/sweetavc.off", F_OK) == 0) {
		say("/private/var/tmp/sweetavc.off: not registered");
		return state = 1;
	}
	dlopen("/System/Library/Frameworks/VideoToolbox.framework/VideoToolbox", RTLD_NOW);
	derived_create = dlsym(RTLD_DEFAULT, "CMDerivedObjectCreate");
	derived_storage = dlsym(RTLD_DEFAULT, "CMBaseObjectGetDerivedStorage");
	encoder_class_id = dlsym(RTLD_DEFAULT, "VTVideoEncoderGetClassID");
	emit_frame = dlsym(RTLD_DEFAULT, "VTEncoderSessionEmitEncodedFrame");
	set_pixel_attrs = dlsym(RTLD_DEFAULT, "VTEncoderSessionSetPixelBufferAttributes");
	/* VTRegisterVideoEncoderWithInfo(codec, info, create): VTRegisterVideoEncoder passes no info */
	OSStatus (*reg)(uint32_t, CFDictionaryRef, OSStatus (*)(uint32_t, CFAllocatorRef, VTVideoEncoderRef *)) =
	    dlsym(RTLD_DEFAULT, "VTRegisterVideoEncoderWithInfo");
	if (!derived_create || !derived_storage || !encoder_class_id || !emit_frame || !reg) {
		say("VideoToolbox's encoder plug-in functions are not all there (%d %d %d %d %d): not registered", derived_create != NULL,
		    derived_storage != NULL, encoder_class_id != NULL, emit_frame != NULL, reg != NULL);
		return state = 2;
	}
	OSStatus e = reg(kCMVideoCodecType_H264, NULL, avc_create);
	say("H.264 encoder (x264 build %d) registered with VideoToolbox in %{public}s: %d", X264_BUILD, getprogname(), (int)e);
	return state = e == 0 ? 0 : 3;
}

__attribute__((constructor)) static void
sweetavc_init(void)
{
	gLog = os_log_create("com.sweet.avc", "encoder");
	sweetavc_register();
}
