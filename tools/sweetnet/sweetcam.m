/*
 * sweetcam.dylib: the Mi 8's rear main camera (Sony IMX363) as iOS 26's capture stack wants a camera, inside cameracaptured.
 *
 * The capture stack's device vendor (+[BWFigCaptureDeviceVendor sharedCaptureDeviceVendorWithDefaultDeviceCreateFunction:],
 * CMCapture) makes its camera device with a create function that CMCapture finds in /System/Library/MediaCapture/
 * H10ISP.mediacapture (H10ISPCaptureDeviceCreate(allocator, options, &device); the plug-in lives in the dyld cache only).
 * Here the vendor is given ours instead when the kernel has a camera (kern.sweet_cam_stream, xnu 3080+): a CoreMedia derived
 * object of class FigCaptureDevice with one FigCaptureStream, laid out as H10ISP's are in iOS 26.6.2 (read from its tables in
 * the cache: base class version 1; device class version 3 = processing session, RequestStreams, RelinquishStreams, Pearl
 * calibration; stream class version 2 = Start, Stop, AddAttachmentsToSampleBuffer).
 *
 * The stream's frames: the kernel's stream (bsd/dev/dipper_camera.c: 1920x1080 MIPI RAW10 RGGB, 30 fps, auto exposure and
 * focus in the kernel) through kern.sweet_cam_live, made into pictures here on the CPU (RAW10 to RGB at half size, grey-world
 * white balance, a colour matrix, the sRGB curve, bilinear scaling and the centre crop to each output's shape) in the buffer
 * pool each output is given (VideoOutputConfigurations' BufferPool), then handed to the output's PixelBufferHandler.
 *
 * The stream says it is the iPhone 11's back camera as the model's own tables describe it: ModuleInfo with sensor ID 0x0503 and
 * the module IDs of its FocalLengthCharacterization (CMCapture.framework/N104/CameraSetup.plist), and the stream formats of
 * the back camera in N104/AVCaptureSession.plist (FigCaptureStreamFormats, read at run time), so that AVCaptureDevice formats
 * and session presets resolve. Every picture is made from the same 1920x1080 frames.
 *
 * What the capture graph needs beyond the obvious was found by HakiOS for iOS 16.5's mediaserverd on an Infinix phone
 * (oosexgang/hakios-xnu-kernel and hakios-mt6768, userland/camera/camera_device.c, MIT): tccd running, a processing session,
 * the stream's ModuleInfo, VideoOutputsColorInfo answered, no pictures before the graph enables its outputs, pictures made in
 * each output's own buffer pool. This is our own code after their findings.
 *
 * iOS 26 also wants, each found from CMCapture's log: a Metal device in cameracaptured (the Bergamota device is registered
 * here), a MetadataDictionary on every frame (exposure, gains, lens, white balance...: on the pixel buffer and, through
 * AddAttachmentsToSampleBuffer, on the sample buffer) and the still output in Apple's packed 10-bit 'pf20'.
 *
 * Loaded into cameracaptured by sweettorch.dylib (dlopen at its start). Logs: unified log, subsystem com.sweet.cam
 * (`sweetlog 60 sweetcam`). iOS 18+, arm64e + pacstrip (tools/sweetnet/build.sh).
 */
#import <Foundation/Foundation.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <IOSurface/IOSurfaceRef.h>
#include <CoreGraphics/CoreGraphics.h>
#include <Accelerate/Accelerate.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <errno.h>
#include <math.h>
#include <mach/mach_time.h>
#include <mach-o/dyld.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <os/log.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>
#include <sys/sysctl.h>
#include <unistd.h>

static os_log_t gLog;
#define say(...) os_log(gLog, "sweetcam: " __VA_ARGS__)

/* ---- CoreMedia's derived objects (the layouts of iOS 26.6.2's H10ISP.mediacapture) ------------------------------------- */

typedef struct OpaqueCMBaseObject *CMBaseObjectRef;
typedef const void *CMBaseClassID;

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
struct device_class {
	uint64_t version;                       /* 3 */
	void *processing_session_create;
	OSStatus (*request_streams)(CMBaseObjectRef, CFArrayRef, CFDictionaryRef);
	OSStatus (*relinquish_streams)(CMBaseObjectRef, CFArrayRef, CFDictionaryRef);
	void *pearl_calibration;
};
struct stream_class {
	uint64_t version;                       /* 2 */
	OSStatus (*start)(CMBaseObjectRef);
	OSStatus (*stop)(CMBaseObjectRef);
	OSStatus (*add_attachments)(CMBaseObjectRef, CMSampleBufferRef, CFDictionaryRef);
};
struct session_class {
	uint64_t version;                       /* 1 */
	OSStatus (*prepare)(CMBaseObjectRef, void *);
	OSStatus (*process)(CMBaseObjectRef, void *, void *, void *, int, void *);
	OSStatus (*flush)(CMBaseObjectRef);
};
struct vtable {
	const void *reserved;
	const struct base_class *base;
	const void *derived;
};

#define ERR_PARAM               (-12780)
#define ERR_UNSUPPORTED         (-12782)
#define ERR_NOT_AVAILABLE       (-12783)

typedef OSStatus (*device_create_fn)(CFAllocatorRef, CFDictionaryRef, CMBaseObjectRef *);
static OSStatus (*derived_create)(CFAllocatorRef, const struct vtable *, CMBaseClassID, CMBaseObjectRef *);
static void *(*derived_storage)(CMBaseObjectRef);
static CMBaseClassID (*device_class_id)(void);
static CMBaseClassID (*stream_class_id)(void);
static CMBaseClassID (*session_class_id)(void);
static CFStringRef port_back, port_front;
static CFStringRef md_attachment;       /* kFigCaptureSampleBufferAttachmentKey_MetadataDictionary */

/* ---- small helpers ------------------------------------------------------------------------------------------------------ */

static CFNumberRef
num_i(int64_t v)
{
	return CFNumberCreate(NULL, kCFNumberSInt64Type, &v);
}

static CFNumberRef
num_f(double v)
{
	return CFNumberCreate(NULL, kCFNumberDoubleType, &v);
}

static CFMutableDictionaryRef
new_dict(void)
{
	return CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
}

/* puts value (which it releases) under a C-string key */
static void
put(CFMutableDictionaryRef d, const char *key, CFTypeRef value)
{
	if (!value) {
		return;
	}
	CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
	CFDictionarySetValue(d, k, value);
	CFRelease(k);
	CFRelease(value);
}

static int64_t
get_i(CFDictionaryRef d, const char *key, int64_t otherwise)
{
	if (!d || CFGetTypeID(d) != CFDictionaryGetTypeID()) {
		return otherwise;
	}
	CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
	CFTypeRef v = CFDictionaryGetValue(d, k);
	CFRelease(k);
	int64_t r = otherwise;
	if (v && CFGetTypeID(v) == CFNumberGetTypeID()) {
		CFNumberGetValue(v, kCFNumberSInt64Type, &r);
	} else if (v && CFGetTypeID(v) == CFBooleanGetTypeID()) {
		r = CFBooleanGetValue(v);
	}
	return r;
}

static bool
key_is(CFStringRef key, const char *name)
{
	char b[160];
	return key && CFStringGetCString(key, b, sizeof(b), kCFStringEncodingUTF8) && strcmp(b, name) == 0;
}

/* what is asked and not answered (or set and not used): said once a name */
static CFMutableSetRef said_names;
static pthread_mutex_t said_lock = PTHREAD_MUTEX_INITIALIZER;

static void
say_once(const char *what, CFStringRef key, CFTypeRef value)
{
	pthread_mutex_lock(&said_lock);
	if (!said_names) {
		said_names = CFSetCreateMutable(NULL, 0, &kCFTypeSetCallBacks);
	}
	CFStringRef tag = CFStringCreateWithFormat(NULL, NULL, CFSTR("%s %@"), what, key);
	bool first = !CFSetContainsValue(said_names, tag);
	if (first) {
		CFSetAddValue(said_names, tag);
	}
	pthread_mutex_unlock(&said_lock);
	if (first) {
		NSString *v = value ? [(__bridge id)value description] : @"";
		if (v.length > 400) {
			v = [[v substringToIndex:400] stringByAppendingString:@"..."];
		}
		os_log(gLog, "sweetcam: %{public}s %{public}@ %{public}@", what, (__bridge NSString *)key,
		    [v stringByReplacingOccurrencesOfString:@"\n" withString:@" "]);
	}
	CFRelease(tag);
}

static bool
find_functions(void)
{
	derived_create = dlsym(RTLD_DEFAULT, "CMDerivedObjectCreate");
	derived_storage = dlsym(RTLD_DEFAULT, "CMBaseObjectGetDerivedStorage");
	device_class_id = dlsym(RTLD_DEFAULT, "FigCaptureDeviceGetClassID");
	stream_class_id = dlsym(RTLD_DEFAULT, "FigCaptureStreamGetClassID");
	session_class_id = dlsym(RTLD_DEFAULT, "FigCaptureISPProcessingSessionGetClassID");
	CFStringRef *port = dlsym(RTLD_DEFAULT, "kFigCapturePortType_BackFacingCamera");
	port_back = port ? *port : NULL;
	port = dlsym(RTLD_DEFAULT, "kFigCapturePortType_FrontFacingCamera");
	port_front = port ? *port : NULL;
	CFStringRef *mda = dlsym(RTLD_DEFAULT, "kFigCaptureSampleBufferAttachmentKey_MetadataDictionary");
	md_attachment = mda ? *mda : NULL;
	if (!derived_create || !derived_storage || !device_class_id || !stream_class_id || !port_back) {
		say("CoreMedia's or CMCapture's functions are not there: no camera (%d %d %d %d %d)", derived_create != NULL,
		    derived_storage != NULL, device_class_id != NULL, stream_class_id != NULL, port_back != NULL);
		return false;
	}
	return true;
}

/* ---- the kernel's stream ------------------------------------------------------------------------------------------------ */

struct cam_live_hdr {                   /* bsd/dev/dipper_camera.c, 3080 */
	uint32_t magic;
	uint16_t version, hdr_size;
	uint32_t seq;
	uint16_t width, height, stride, format;
	uint16_t black, white;
	uint32_t exposure_lines, line_ns, again_x256, dgain_x256, lens, af_state;
	uint64_t timestamp_ns;
	uint32_t frame_us, flags;
};

static bool
kernel_has_camera(void)
{
	int v = 0;
	size_t len = sizeof(v);
	return sysctlbyname("kern.sweet_cam_stream", &v, &len, NULL, 0) == 0;
}

/*
 * the kernel's stream on or off. sensor (xnu 3090+, kern.sweet_cam_sensor): 0 the rear main, 1 the rear tele, 2 the front;
 * each has its own register sequence file. An older kernel has the main one only.
 */
static int
kernel_stream(int on, int sensor)
{
	static const char *const seqs[3][2] = {
		{ "/usr/local/share/sweetcam/imx363-mode2.seq", "/var/root/imx363-mode2.seq" },
		{ "/usr/local/share/sweetcam/s5k3m3-mode1.seq", "/var/root/s5k3m3-mode1.seq" },
		{ "/usr/local/share/sweetcam/s5k3t1-mode1.seq", "/var/root/s5k3t1-mode1.seq" },
	};
	if (on) {
		if (sensor < 0 || sensor > 2) {
			return EINVAL;
		}
		/* another stream's worker may still be stopping the kernel (a switch between the cameras): up to 4 s */
		for (int i = 0; i < 200; i++) {
			int st = 0;
			size_t sl = sizeof(st);
			if (sysctlbyname("kern.sweet_cam_stream", &st, &sl, NULL, 0) != 0 || st == 0) {
				break;
			}
			usleep(20000);
		}
		if (sysctlbyname("kern.sweet_cam_sensor", NULL, NULL, &sensor, sizeof(sensor)) != 0 && sensor != 0) {
			int e = errno;
			say("kern.sweet_cam_sensor=%d: %{public}s", sensor, strerror(e));
			return e;
		}
	}
	if (sysctlbyname("kern.sweet_cam_stream", NULL, NULL, &on, sizeof(on)) == 0) {
		return 0;
	}
	int e = errno;
	if (on && e == EIO) {
		/*
		 * no sensor sequence loaded yet (it is the phone vendor's, kept out of the image): loaded from a file on the phone
		 * (xnu 3082+ lets cameracaptured write kern.sweet_cam_seq; before, only root could)
		 */
		const char *const *paths = seqs[sensor];
		for (unsigned i = 0; i < 2; i++) {
			FILE *f = fopen(paths[i], "rb");
			if (!f) {
				say("sequence: %{public}s: %{public}s", paths[i], strerror(errno));
				continue;
			}
			static char seq[2048 * 8];
			size_t n = fread(seq, 1, sizeof(seq), f);
			fclose(f);
			if (!n || n % 8 != 0) {
				say("sequence: %{public}s: %zu bytes, not 8-byte records", paths[i], n);
				continue;
			}
			if (sysctlbyname("kern.sweet_cam_seq", NULL, NULL, seq, n) != 0) {
				say("sequence: kern.sweet_cam_seq refused it: %{public}s", strerror(errno));
				break;
			}
			say("the sensor's sequence loaded from %{public}s (%zu records)", paths[i], n / 8);
			if (sysctlbyname("kern.sweet_cam_stream", NULL, NULL, &on, sizeof(on)) == 0) {
				return 0;
			}
			e = errno;
			break;
		}
	}
	return e;
}

/*
 * xnu 3085+: full-resolution stills. Mode 0's sequence (4032x3024) goes into kern.sweet_cam_seq0 from the phone's file (vendor
 * data, kept out of the image's git); at a photo kern.sweet_cam_still=1 makes the kernel switch the sensor to mode 0 for one
 * frame and back (about 0.8 s), and kern.sweet_cam_still reads it. /private/var/tmp/sweetcam.nofullstill: stills from the
 * preview's frames as before.
 */
static bool
load_seq0(void)
{
	static const char *const path = "/usr/local/share/sweetcam/imx363-mode0.seq";
	size_t probe = 0;
	if (sysctlbyname("kern.sweet_cam_still", NULL, &probe, NULL, 0) != 0) {
		say("still: the kernel takes no full-resolution stills (%{public}s)", strerror(errno));
		return false;
	}
	FILE *f = fopen(path, "rb");
	if (!f) {
		say("still: %{public}s: %{public}s: stills from the preview's frames", path, strerror(errno));
		return false;
	}
	static char seq[2048 * 8];
	size_t n = fread(seq, 1, sizeof(seq), f);
	fclose(f);
	if (!n || n % 8 || sysctlbyname("kern.sweet_cam_seq0", NULL, NULL, seq, n) != 0) {
		say("still: mode 0's sequence not loaded (%zu bytes, %{public}s)", n, strerror(errno));
		return false;
	}
	say("still: mode 0's sequence loaded (%zu records): full-resolution stills", n / 8);
	return true;
}

/* one full-resolution still: header + RAW10 in a buffer of its own (kept between photos); NULL on a failure */
static const struct cam_live_hdr *
take_full_still(void)
{
	static uint8_t *sb;
	static size_t scap;
	int one = 1;
	uint64_t t0 = clock_gettime_nsec_np(CLOCK_MONOTONIC);
	if (sysctlbyname("kern.sweet_cam_still", NULL, NULL, &one, sizeof(one)) != 0) {
		say("still: kern.sweet_cam_still=1: %{public}s", strerror(errno));
		return NULL;
	}
	size_t len = 0;
	if (sysctlbyname("kern.sweet_cam_still", NULL, &len, NULL, 0) != 0 || !len) {
		return NULL;
	}
	if (len > scap) {
		free(sb);
		sb = malloc(len);
		scap = sb ? len : 0;
	}
	if (!sb || sysctlbyname("kern.sweet_cam_still", sb, &len, NULL, 0) != 0) {
		say("still: read: %{public}s", strerror(errno));
		return NULL;
	}
	const struct cam_live_hdr *h = (const void *)sb;
	if (h->magic != 0x4d414353u || len < h->hdr_size + (size_t)h->stride * h->height) {
		return NULL;
	}
	/*
	 * the kernel fills the buffer with 0xa5 before a still: a frame that never arrived reads as that fill (two pink photos,
	 * 2026-11-09 16:16). Sixteen rows across the frame, 64 bytes each: mostly fill = no still (the preview's frame then)
	 */
	unsigned fill_rows = 0;
	for (unsigned k = 0; k < 16; k++) {
		const uint8_t *row = sb + h->hdr_size + (size_t)h->stride * ((h->height - 1) * k / 15) + h->stride / 2;
		unsigned same = 0;
		for (unsigned i = 0; i < 64; i++) {
			same += row[i] == 0xa5;
		}
		fill_rows += same > 48;
	}
	if (fill_rows > 4) {
		say("still: the kernel's frame is its fill in %u of 16 rows: not used", fill_rows);
		return NULL;
	}
	say("still: %ux%u from the kernel in %.0f ms (%u lines of %u ns x %.2f x %.2f)", h->width, h->height,
	    (clock_gettime_nsec_np(CLOCK_MONOTONIC) - t0) / 1e6, h->exposure_lines, h->line_ns, h->again_x256 / 256.0, h->dgain_x256 / 256.0);
	return h;
}

/* ---- pictures from RAW10 ------------------------------------------------------------------------------------------------ */

/* the preview picture: half the frame, one RGB value per 2x2 Bayer cell (the main's 1920x1080 at first; isp_half follows the frame) */
static unsigned HW = 960, HH = 540;

struct isp {
	float wb[3];                    /* red, green, blue gains (grey world, smoothed) */
	float mean;                     /* the last frame's mean green above black, 0-1 of the range (for the metadata) */
	uint8_t gamma[4096];            /* linear (0-4095 over the sensor's range above black) to sRGB 8 bits */
	uint16_t gamma10[4096];         /* ... the same curve to 10 bits (the still, developed at full size) */
	uint8_t *rgb;                   /* HW x HH x 3 */
	float m[9];                     /* the colour matrix of the last frame (white balance and scale folded in) */
	float crop;                     /* the part of the picture shown, 0-1 of its width and height about the centre (the zoom) */
	float gain;                     /* gain applied here, 1-4: the sensor at its limit and the picture still dark */
	uint8_t *ty, *tc;               /* render_420's luma and chroma of the part shown (tcap pixels) */
	size_t tcap;
	const uint8_t *raw;             /* the frame being delivered, RAW10, and its header (for the still) */
	const struct cam_live_hdr *hdr;
	const struct output *still_out; /* the still output (developed from raw, not from rgb) */
	bool ready;
};

static void
isp_init(struct isp *p)
{
	p->wb[0] = 1.35f;
	p->wb[1] = 1.0f;
	p->wb[2] = 2.7f;
	for (int i = 0; i < 4096; i++) {
		double x = i / 4095.0, s = x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055;
		s = s + 0.12 * s * (1 - s) * (2 * s - 1) * -1;  /* a gentle S */
		p->gamma[i] = (uint8_t)(s < 0 ? 0 : s > 1 ? 255 : s * 255 + 0.5);
		p->gamma10[i] = (uint16_t)(s < 0 ? 0 : s > 1 ? 1023 : s * 1023 + 0.5);
	}
	p->rgb = malloc((size_t)HW * HH * 3);
	p->crop = 1;
	p->gain = 1;
	p->ty = p->tc = NULL;
	p->tcap = 0;
	p->ready = p->rgb != NULL;
}

static inline unsigned
raw10_at(const uint8_t *row, unsigned x)
{
	const uint8_t *g = row + 5 * (x >> 2);
	return (unsigned)g[x & 3] << 2 | ((g[4] >> (2 * (x & 3))) & 3);
}

struct half_job {
	struct isp *p;
	const uint8_t *raw;
	unsigned stride, black;
	unsigned cfa;                   /* 0 RGGB, 1 GRBG (the frame header's flags) */
	float m[9];                     /* colour matrix with the white balance and the scale to 0-4095 folded in */
	uint64_t sum[16][3];            /* per piece: R, G, B above black (for the next white balance) */
};

static void
half_piece(void *ctx, size_t piece)
{
	struct half_job *j = ctx;
	unsigned rows = (HH + 15) / 16, y0 = (unsigned)piece * rows, y1 = MIN(HH, y0 + rows);
	uint64_t sr = 0, sg = 0, sb = 0;
	for (unsigned y = y0; y < y1; y++) {
		const uint8_t *r0 = j->raw + (size_t)(2 * y) * j->stride, *r1 = r0 + j->stride;
		uint8_t *o = j->p->rgb + (size_t)y * HW * 3;
		for (unsigned x = 0; x < HW; x++) {
			int c00 = (int)raw10_at(r0, 2 * x), c01 = (int)raw10_at(r0, 2 * x + 1), c10 = (int)raw10_at(r1, 2 * x),
			    c11 = (int)raw10_at(r1, 2 * x + 1), R, G, B;
			if (j->cfa == 1) {      /* GRBG (the Mi 8's tele and front sensors) */
				R = c01 - (int)j->black;
				G = ((c00 + c11) >> 1) - (int)j->black;
				B = c10 - (int)j->black;
			} else {
				R = c00 - (int)j->black;
				G = ((c01 + c10) >> 1) - (int)j->black;
				B = c11 - (int)j->black;
			}
			R = R < 0 ? 0 : R;
			G = G < 0 ? 0 : G;
			B = B < 0 ? 0 : B;
			if ((x & 7) == 0) {
				sr += (unsigned)R;
				sg += (unsigned)G;
				sb += (unsigned)B;
			}
			float fr = j->m[0] * R + j->m[1] * G + j->m[2] * B;
			float fg = j->m[3] * R + j->m[4] * G + j->m[5] * B;
			float fb = j->m[6] * R + j->m[7] * G + j->m[8] * B;
			int ir = (int)fr, ig = (int)fg, ib = (int)fb;
			o[0] = j->p->gamma[ir < 0 ? 0 : ir > 4095 ? 4095 : ir];
			o[1] = j->p->gamma[ig < 0 ? 0 : ig > 4095 ? 4095 : ig];
			o[2] = j->p->gamma[ib < 0 ? 0 : ib > 4095 ? 4095 : ib];
			o += 3;
		}
	}
	j->sum[piece][0] = sr;
	j->sum[piece][1] = sg;
	j->sum[piece][2] = sb;
}

/* the frame at half size into p->rgb; the white balance follows the frame (grey world, smoothed) */
static void
isp_half(struct isp *p, const struct cam_live_hdr *h, const uint8_t *raw)
{
	static const float ccm[9] = { 1.55f, -0.40f, -0.15f, -0.25f, 1.45f, -0.20f, -0.05f, -0.45f, 1.50f };
	struct half_job j = { .p = p, .raw = raw, .stride = h->stride, .black = h->black, .cfa = h->flags & 3 };
	float scale = 4095.0f / (float)(h->white - h->black) * (p->gain >= 1 ? p->gain : 1);
	unsigned hw = h->width / 2, hh = h->height / 2;
	if (hw != HW || hh != HH || !p->rgb) {
		/* another sensor's frames (the tele's 2104x1560, the front's 2592x1940) */
		free(p->rgb);
		p->rgb = malloc((size_t)hw * hh * 3);
		p->ready = p->rgb != NULL;
		if (!p->ready) {
			return;
		}
		HW = hw;
		HH = hh;
		say("frames of %ux%u (sensor %u, colour order %u): the preview picture is %ux%u", h->width, h->height,
		    (h->flags >> 8) & 3, h->flags & 3, HW, HH);
	}
	for (int r = 0; r < 3; r++) {
		for (int c = 0; c < 3; c++) {
			j.m[r * 3 + c] = ccm[r * 3 + c] * p->wb[c] * scale;
		}
	}
	memcpy(p->m, j.m, sizeof(p->m));
	dispatch_apply_f(16, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), &j, half_piece);
	uint64_t s[3] = { 0, 0, 0 };
	for (int i = 0; i < 16; i++) {
		for (int c = 0; c < 3; c++) {
			s[c] += j.sum[i][c];
		}
	}
	p->mean = (float)s[1] / ((float)HW * HH * (float)(h->white - h->black));
	/*
	 * the sensor at its analog limit and the picture under the kernel's exposure target (0.156 of the range): the rest as
	 * gain here, up to 4x, eased in (the front sensor has 16x analog gain and no digital gain; the tele's digital is 2x)
	 */
	{
		/* the true mean: the sums take every 8th pixel of a row (p->mean above divides by all of them, so it is 1/8 of this;
		 * left as it is: the photo pipeline has only been run with that value in its metadata) */
		float tm = (float)s[1] / ((float)((HW + 7) / 8) * HH * (float)(h->white - h->black)), want = 1;
		if (tm > 0.002f && h->again_x256 >= 15 * 256 && tm < 0.125f) {
			want = 0.156f / tm;
			want = want > 4.f ? 4.f : want;
		}
		p->gain = 0.9f * p->gain + 0.1f * want;
	}
	if (s[0] > 1000 && s[1] > 1000 && s[2] > 1000) {
		float gr = (float)s[1] / (float)s[0], gb = (float)s[1] / (float)s[2];
		gr = gr < 0.5f ? 0.5f : gr > 4.f ? 4.f : gr;
		gb = gb < 0.5f ? 0.5f : gb > 4.f ? 4.f : gb;
		p->wb[0] = 0.85f * p->wb[0] + 0.15f * gr;
		p->wb[2] = 0.85f * p->wb[2] + 0.15f * gb;
	}
}

#define PF_420F 0x34323066u     /* '420f' */
#define PF_420V 0x34323076u     /* '420v' */
#define PF_BGRA 0x42475241u     /* 'BGRA' */
#define PF_PF20 0x70663230u     /* 'pf20': 4:2:0 10-bit packed, the still output's */

struct render_job {
	const struct isp *p;
	CVPixelBufferRef pb;
	uint32_t pf;
	unsigned w, h, pieces;
	float cx, cy, cw, ch;           /* the region of the half-size picture shown (the centre crop to the output's shape) */
	bool mirror;
};

/* bilinear sample of the half-size picture at (sx, sy) */
static inline void
sample(const uint8_t *rgb, float sx, float sy, int out[3])
{
	int x0 = (int)sx, y0 = (int)sy;
	float fx = sx - x0, fy = sy - y0;
	x0 = x0 < 0 ? 0 : x0 > (int)HW - 2 ? (int)HW - 2 : x0;
	y0 = y0 < 0 ? 0 : y0 > (int)HH - 2 ? (int)HH - 2 : y0;
	const uint8_t *a = rgb + ((size_t)y0 * HW + x0) * 3, *b = a + HW * 3;
	for (int c = 0; c < 3; c++) {
		float t = a[c] + (a[c + 3] - a[c]) * fx, u = b[c] + (b[c + 3] - b[c]) * fx;
		out[c] = (int)(t + (u - t) * fy + 0.5f);
	}
}

/*
 * 'pf20' (the still output's format): 4:2:0 full range, 10 bits, two planes; luma three samples to a little-endian 32-bit
 * word (bits 0-9, 10-19, 20-29), chroma three Cb/Cr pairs to two such words (Cb0 Cr0 Cb1, Cr1 Cb2 Cr2)
 */
static void
render_piece_pf20(const struct render_job *j, unsigned y0, unsigned y1)
{
	unsigned w = j->w, cw = (w + 1) / 2;
	uint16_t *yv = malloc(sizeof(uint16_t) * (2 * (w + 3) + 2 * (cw + 3)));
	if (!yv) {
		return;
	}
	uint16_t *yv1 = yv + w + 3, *cv = yv1 + w + 3;
	uint8_t *yb = CVPixelBufferGetBaseAddressOfPlane(j->pb, 0), *cb = CVPixelBufferGetBaseAddressOfPlane(j->pb, 1);
	size_t ys = CVPixelBufferGetBytesPerRowOfPlane(j->pb, 0), cs = CVPixelBufferGetBytesPerRowOfPlane(j->pb, 1);
	float kx = j->cw / j->w, ky = j->ch / j->h;
	for (unsigned y = y0; y < y1; y += 2) {
		float sy0 = j->cy + (y + 0.5f) * ky - 0.5f, sy1 = j->cy + (y + 1.5f) * ky - 0.5f;
		memset(yv, 0, sizeof(uint16_t) * (2 * (w + 3) + 2 * (cw + 3)));
		for (unsigned x = 0; x < w; x += 2) {
			int acc[3] = { 0, 0, 0 }, n = 0;
			for (int dy = 0; dy < 2; dy++) {
				for (int dx = 0; dx < 2 && x + dx < w; dx++) {
					int c[3];
					sample(j->p->rgb, j->cx + (x + dx + 0.5f) * kx - 0.5f, dy ? sy1 : sy0, c);
					(dy ? yv1 : yv)[x + dx] = (uint16_t)((77 * c[0] + 150 * c[1] + 29 * c[2]) >> 6);
					acc[0] += c[0];
					acc[1] += c[1];
					acc[2] += c[2];
					n++;
				}
			}
			int R = acc[0] / n, G = acc[1] / n, B = acc[2] / n;
			int U = ((-43 * R - 85 * G + 128 * B) >> 6) + 512, V = ((128 * R - 107 * G - 21 * B) >> 6) + 512;
			cv[x] = (uint16_t)(U < 0 ? 0 : U > 1023 ? 1023 : U);
			cv[x + 1] = (uint16_t)(V < 0 ? 0 : V > 1023 ? 1023 : V);
		}
		for (int dy = 0; dy < 2 && y + dy < j->h; dy++) {
			uint32_t *o = (uint32_t *)(yb + (y + dy) * ys);
			const uint16_t *v = dy ? yv1 : yv;
			for (unsigned x = 0; x < w; x += 3) {
				*o++ = v[x] | (uint32_t)v[x + 1] << 10 | (uint32_t)v[x + 2] << 20;
			}
		}
		uint32_t *o = (uint32_t *)(cb + (y / 2) * cs);
		for (unsigned x = 0; x < 2 * cw; x += 3) {
			*o++ = cv[x] | (uint32_t)cv[x + 1] << 10 | (uint32_t)cv[x + 2] << 20;
		}
	}
	free(yv);
}

/*
 * The still at full size (2026-11-09): the 4:3 centre of the 1920x1080 RAW10 frame demosaiced pixel by pixel (Malvar, He and
 * Cutler's 5x5 linear filters on the RGGB mosaic), through the preview's white balance and colour matrix and the same tone
 * curve to 10 bits, then scaled to the still's size (bilinear) into 'pf20'. Before, the still was scaled up from the preview's
 * half-size picture (960x540, 8 bits: a quarter of the frame's detail). /private/var/tmp/sweetcam.halfstill: the old way.
 */
struct full_job {
	const struct isp *p;
	const struct cam_live_hdr *hd;
	uint16_t *u;                    /* the frame unpacked, 16 bits a sample, W x H */
	uint16_t *u0;                   /* ... as it came, before full_dpc put the corrected samples into u */
	uint16_t *d;                    /* the crop demosaiced and toned, 10-bit R G B, cw x ch */
	uint16_t *y, *y2;               /* its luma (10 bits), and after the noise filter */
	int16_t *cb, *cr, *t;           /* its chroma (signed, 10-bit scale), and a row-blurred copy */
	unsigned thr;                   /* the luma filter's threshold (from the frame's measured noise) */
	unsigned W, H, cx, cy, cw, ch;
	bool cells;                     /* cw x ch are 2x2 cells of the frame from (cx, cy), not pixels */
	unsigned xo;                    /* 1: GRBG, the mosaic taken one column over is RGGB's */
	CVPixelBufferRef pb;
	unsigned w, h, pieces;
};

static void
full_unpack(void *ctx, size_t piece)
{
	struct full_job *j = ctx;
	unsigned rows = (j->H + j->pieces - 1) / j->pieces, y0 = (unsigned)piece * rows, y1 = MIN(j->H, y0 + rows);
	for (unsigned y = y0; y < y1; y++) {
		const uint8_t *r = j->p->raw + (size_t)y * j->hd->stride;
		uint16_t *o = j->u + (size_t)y * j->W;
		for (unsigned x = 0; x + 3 < j->W; x += 4, r += 5) {
			o[x] = (uint16_t)(r[0] << 2 | (r[4] & 3));
			o[x + 1] = (uint16_t)(r[1] << 2 | (r[4] >> 2 & 3));
			o[x + 2] = (uint16_t)(r[2] << 2 | (r[4] >> 4 & 3));
			o[x + 3] = (uint16_t)(r[3] << 2 | (r[4] >> 6 & 3));
		}
	}
}

/*
 * Defective pixels (2026-11-09): a sample well outside its eight same-colour neighbours two away is brought back to their
 * range. The front sensor at 16x gain has hot pixels all over, and the demosaic's negative lobes turned each into dark
 * dots around it (the vendor's ISP corrects them; the IMX363 showed none).
 */
static void
full_dpc(void *ctx, size_t piece)
{
	struct full_job *j = ctx;
	unsigned rows = (j->H + j->pieces - 1) / j->pieces, y0 = (unsigned)piece * rows, y1 = MIN(j->H, y0 + rows);
	const int W = (int)j->W;
	for (unsigned y = y0; y < y1; y++) {
		const uint16_t *r = j->u0 + (size_t)y * j->W;
		uint16_t *o = j->u + (size_t)y * j->W;
		if (y < 2 || y + 2 >= j->H) {
			memcpy(o, r, (size_t)j->W * sizeof(uint16_t));
			continue;
		}
		o[0] = r[0];
		o[1] = r[1];
		o[W - 2] = r[W - 2];
		o[W - 1] = r[W - 1];
		for (int x = 2; x < W - 2; x++) {
			int a[8] = { r[x - 2], r[x + 2], r[x - 2 * W], r[x + 2 * W], r[x - 2 * W - 2], r[x - 2 * W + 2], r[x + 2 * W - 2],
				     r[x + 2 * W + 2] };
			int lo = a[0], hi = a[0], v = r[x];
			for (int k = 1; k < 8; k++) {
				lo = a[k] < lo ? a[k] : lo;
				hi = a[k] > hi ? a[k] : hi;
			}
			int t = 24 + (hi >> 3);
			o[x] = (uint16_t)(v > hi + t ? hi : v < lo - t ? lo : v);
		}
	}
}

/* the mosaic at (x, y), mirrored at the frame's edges (two away keeps the Bayer colour) */
static inline int
mos(const struct full_job *j, int x, int y)
{
	if (x < 0) x = -x;
	if (y < 0) y = -y;
	if (x >= (int)j->W) x = 2 * (int)j->W - 2 - x;
	if (y >= (int)j->H) y = 2 * (int)j->H - 2 - y;
	return j->u[(size_t)y * j->W + (unsigned)x];
}

static void
full_demosaic(void *ctx, size_t piece)
{
	struct full_job *j = ctx;
	const struct isp *p = j->p;
	const int black = j->hd->black;
	unsigned rows = (j->ch + j->pieces - 1) / j->pieces, y0 = (unsigned)piece * rows, y1 = MIN(j->ch, y0 + rows);
	for (unsigned yy = y0; yy < y1; yy++) {
		int y = (int)(yy + j->cy);
		uint16_t *o = j->d + (size_t)yy * j->cw * 3;
		bool inner_y = y >= 2 && y + 2 < (int)j->H;
		for (unsigned xx = 0; xx < j->cw; xx++) {
			int x = (int)(xx + j->cx), c, n, s, e, w, nn, ss, ee, ww, ne, nw, se, sw;
			if (inner_y && x >= 2 && x + 2 < (int)j->W) {
				const uint16_t *r = j->u + (size_t)y * j->W + x;
				const int W = (int)j->W;
				c = r[0]; n = r[-W]; s = r[W]; e = r[1]; w = r[-1]; nn = r[-2 * W]; ss = r[2 * W]; ee = r[2]; ww = r[-2];
				ne = r[-W + 1]; nw = r[-W - 1]; se = r[W + 1]; sw = r[W - 1];
			} else {
				c = mos(j, x, y); n = mos(j, x, y - 1); s = mos(j, x, y + 1); e = mos(j, x + 1, y); w = mos(j, x - 1, y);
				nn = mos(j, x, y - 2); ss = mos(j, x, y + 2); ee = mos(j, x + 2, y); ww = mos(j, x - 2, y);
				ne = mos(j, x + 1, y - 1); nw = mos(j, x - 1, y - 1); se = mos(j, x + 1, y + 1); sw = mos(j, x - 1, y + 1);
			}
			/* Malvar-He-Cutler, numerators doubled (the 1/2 and 3/2 weights), over 16 */
			int R, G, B;
			int cross = 8 * c + 4 * (n + s + e + w) - 2 * (nn + ss + ee + ww);                      /* G at R or B */
			int diag = 12 * c + 4 * (ne + nw + se + sw) - 3 * (nn + ss + ee + ww);                  /* B at R, R at B */
			int horiz = 10 * c + 8 * (e + w) - 2 * (ee + ww + ne + nw + se + sw) + (nn + ss);     /* the colour left/right of a G */
			int vert = 10 * c + 8 * (n + s) - 2 * (nn + ss + ne + nw + se + sw) + (ee + ww);      /* the colour above/below a G */
			bool odd_y = y & 1, odd_x = (x + (int)j->xo) & 1;
			if (!odd_y && !odd_x) {         /* R */
				R = 16 * c; G = cross; B = diag;
			} else if (odd_y && odd_x) {    /* B */
				B = 16 * c; G = cross; R = diag;
			} else if (!odd_y) {            /* G on an R row: R left and right, B above and below */
				G = 16 * c; R = horiz; B = vert;
			} else {                        /* G on a B row: B left and right, R above and below */
				G = 16 * c; B = horiz; R = vert;
			}
			float fr = (float)(R - 16 * black) / 16.f, fg = (float)(G - 16 * black) / 16.f, fb = (float)(B - 16 * black) / 16.f;
			fr = fr < 0 ? 0 : fr;
			fg = fg < 0 ? 0 : fg;
			fb = fb < 0 ? 0 : fb;
			int lr = (int)(p->m[0] * fr + p->m[1] * fg + p->m[2] * fb), lg = (int)(p->m[3] * fr + p->m[4] * fg + p->m[5] * fb),
			    lb = (int)(p->m[6] * fr + p->m[7] * fg + p->m[8] * fb);
			o[0] = p->gamma10[lr < 0 ? 0 : lr > 4095 ? 4095 : lr];
			o[1] = p->gamma10[lg < 0 ? 0 : lg > 4095 ? 4095 : lg];
			o[2] = p->gamma10[lb < 0 ? 0 : lb > 4095 ? 4095 : lb];
			o += 3;
		}
	}
}

/* the crop at one RGB pixel a 2x2 Bayer cell (RGGB, the two greens averaged): the full-resolution frame at half its size */
static void
full_cells(void *ctx, size_t piece)
{
	struct full_job *j = ctx;
	const struct isp *p = j->p;
	const int black = j->hd->black;
	unsigned rows = (j->ch + j->pieces - 1) / j->pieces, y0 = (unsigned)piece * rows, y1 = MIN(j->ch, y0 + rows);
	for (unsigned yy = y0; yy < y1; yy++) {
		const uint8_t *r0 = p->raw + (size_t)(2 * (yy + j->cy)) * j->hd->stride, *r1 = r0 + j->hd->stride;
		uint16_t *o = j->d + (size_t)yy * j->cw * 3;
		for (unsigned xx = 0; xx < j->cw; xx++, o += 3) {
			unsigned x = 2 * (xx + j->cx);
			float R, G, B;
			if (j->xo) {
				R = (float)((int)raw10_at(r0, x + 1) - black);
				G = (float)((int)(raw10_at(r0, x) + raw10_at(r1, x + 1)) / 2 - black);
				B = (float)((int)raw10_at(r1, x) - black);
			} else {
				R = (float)((int)raw10_at(r0, x) - black);
				G = (float)((int)(raw10_at(r0, x + 1) + raw10_at(r1, x)) / 2 - black);
				B = (float)((int)raw10_at(r1, x + 1) - black);
			}
			R = R < 0 ? 0 : R;
			G = G < 0 ? 0 : G;
			B = B < 0 ? 0 : B;
			int lr = (int)(p->m[0] * R + p->m[1] * G + p->m[2] * B), lg = (int)(p->m[3] * R + p->m[4] * G + p->m[5] * B),
			    lb = (int)(p->m[6] * R + p->m[7] * G + p->m[8] * B);
			o[0] = p->gamma10[lr < 0 ? 0 : lr > 4095 ? 4095 : lr];
			o[1] = p->gamma10[lg < 0 ? 0 : lg > 4095 ? 4095 : lg];
			o[2] = p->gamma10[lb < 0 ? 0 : lb > 4095 ? 4095 : lb];
		}
	}
}

/* the developed crop into luma and chroma (BT.601, full range: the still's attachments say 601) */
static void
full_ycc(void *ctx, size_t piece)
{
	struct full_job *j = ctx;
	unsigned rows = (j->ch + j->pieces - 1) / j->pieces, y0 = (unsigned)piece * rows, y1 = MIN(j->ch, y0 + rows);
	for (unsigned y = y0; y < y1; y++) {
		const uint16_t *d = j->d + (size_t)y * j->cw * 3;
		size_t o = (size_t)y * j->cw;
		for (unsigned x = 0; x < j->cw; x++, d += 3) {
			int R = d[0], G = d[1], B = d[2];
			j->y[o + x] = (uint16_t)((77 * R + 150 * G + 29 * B) >> 8);
			j->cb[o + x] = (int16_t)((-43 * R - 85 * G + 128 * B) >> 8);
			j->cr[o + x] = (int16_t)((128 * R - 107 * G - 21 * B) >> 8);
		}
	}
}

/*
 * Luma noise: an outlier (more than 3 sigmas from its 3x3 median) is replaced by that median, then a 5x5 bilateral filter
 * (spatial 1 4 6 4 1 weights, range weights a Gaussian of thr = the filter's range sigma). A hard-threshold sigma filter
 * before it left ragged edges and isolated dark dots in low light (2026-11-09).
 */
static float bil_range[1024];
static unsigned bil_range_thr;

static inline void
sort2(int *a, int *b)
{
	int x = *a, y = *b;
	*a = x < y ? x : y;
	*b = x < y ? y : x;
}

static inline int
median9(int *p)
{
	sort2(&p[1], &p[2]); sort2(&p[4], &p[5]); sort2(&p[7], &p[8]); sort2(&p[0], &p[1]); sort2(&p[3], &p[4]); sort2(&p[6], &p[7]);
	sort2(&p[1], &p[2]); sort2(&p[4], &p[5]); sort2(&p[7], &p[8]); sort2(&p[0], &p[3]); sort2(&p[5], &p[8]); sort2(&p[4], &p[7]);
	sort2(&p[3], &p[6]); sort2(&p[1], &p[4]); sort2(&p[2], &p[5]); sort2(&p[4], &p[7]); sort2(&p[4], &p[2]); sort2(&p[6], &p[4]);
	sort2(&p[4], &p[2]);
	return p[4];
}

static void
full_luma_nr(void *ctx, size_t piece)
{
	struct full_job *j = ctx;
	unsigned rows = (j->ch + j->pieces - 1) / j->pieces, y0 = (unsigned)piece * rows, y1 = MIN(j->ch, y0 + rows);
	const int W = (int)j->cw, H = (int)j->ch, out3 = (int)(3 * j->thr / 2);   /* thr is 1.5 sigma: 3 sigma = 2 thr */
	static const float sw[5] = { 1, 4, 6, 4, 1 };
	for (unsigned yy = y0; yy < y1; yy++) {
		int y = (int)yy;
		const uint16_t *rows5[5];
		for (int dy = -2; dy <= 2; dy++) {
			int ry = y + dy < 0 ? 0 : y + dy >= H ? H - 1 : y + dy;
			rows5[dy + 2] = j->y + (size_t)ry * W;
		}
		for (int x = 0; x < W; x++) {
			int v[5][5];
			for (int dy = 0; dy < 5; dy++)
				for (int dx = -2; dx <= 2; dx++) {
					int rx = x + dx < 0 ? 0 : x + dx >= W ? W - 1 : x + dx;
					v[dy][dx + 2] = rows5[dy][rx];
				}
			int c = v[2][2], m9[9] = { v[1][1], v[1][2], v[1][3], v[2][1], v[2][2], v[2][3], v[3][1], v[3][2], v[3][3] };
			int med = median9(m9);
			if (c - med > 2 * out3 || med - c > 2 * out3) c = med;
			float sum = 0, wsum = 0;
			for (int dy = 0; dy < 5; dy++)
				for (int dx = 0; dx < 5; dx++) {
					int d = v[dy][dx] - c;
					float wgt = sw[dy] * sw[dx] * bil_range[d < 0 ? -d : d];
					sum += wgt * v[dy][dx];
					wsum += wgt;
				}
			int o = wsum > 0 ? (int)(sum / wsum + 0.5f) : c;
			j->y2[(size_t)y * W + x] = (uint16_t)(o < 0 ? 0 : o > 1023 ? 1023 : o);
		}
	}
}

/* Chroma noise: a 13x13 box (rows, then columns), on chroma that the eye resolves far less finely than luma */
#define CNR 6
static void
full_chroma_rows(void *ctx, size_t piece)
{
	struct full_job *j = ctx;
	unsigned rows = (j->ch + j->pieces - 1) / j->pieces, y0 = (unsigned)piece * rows, y1 = MIN(j->ch, y0 + rows);
	const int W = (int)j->cw;
	for (int plane = 0; plane < 2; plane++) {
		int16_t *src = plane ? j->cr : j->cb, *dst = j->t + (size_t)plane * j->cw * j->ch;
		for (unsigned y = y0; y < y1; y++) {
			const int16_t *r = src + (size_t)y * W;
			int16_t *o = dst + (size_t)y * W;
			int sum = 0;
			for (int x = -CNR; x <= CNR; x++) sum += r[x < 0 ? 0 : x];
			for (int x = 0; x < W; x++) {
				o[x] = (int16_t)(sum / (2 * CNR + 1));
				int add = x + CNR + 1 >= W ? W - 1 : x + CNR + 1, sub = x - CNR < 0 ? 0 : x - CNR;
				sum += r[add] - r[sub];
			}
		}
	}
}

static void
full_chroma_cols(void *ctx, size_t piece)
{
	struct full_job *j = ctx;
	unsigned cols = (j->cw + j->pieces - 1) / j->pieces, x0 = (unsigned)piece * cols, x1 = MIN(j->cw, x0 + cols);
	const int W = (int)j->cw, H = (int)j->ch;
	for (int plane = 0; plane < 2; plane++) {
		const int16_t *src = j->t + (size_t)plane * j->cw * j->ch;
		int16_t *dst = plane ? j->cr : j->cb;
		for (unsigned x = x0; x < x1; x++) {
			int sum = 0;
			for (int y = -CNR; y <= CNR; y++) sum += src[(size_t)(y < 0 ? 0 : y) * W + x];
			for (int y = 0; y < H; y++) {
				dst[(size_t)y * W + x] = (int16_t)(sum / (2 * CNR + 1));
				int add = y + CNR + 1 >= H ? H - 1 : y + CNR + 1, sub = y - CNR < 0 ? 0 : y - CNR;
				sum += src[(size_t)add * W + x] - src[(size_t)sub * W + x];
			}
		}
	}
}

/* the frame's luma noise: the median absolute difference of horizontal neighbours (most of a picture is smooth), as a sigma */
static unsigned
full_noise(const struct full_job *j)
{
	static uint32_t hist[1024];
	memset(hist, 0, sizeof(hist));
	uint32_t n = 0;
	for (unsigned y = 0; y < j->ch; y += 3) {
		const uint16_t *r = j->y + (size_t)y * j->cw;
		for (unsigned x = 0; x + 1 < j->cw; x += 2, n++) hist[abs((int)r[x + 1] - (int)r[x])]++;
	}
	uint32_t acc = 0, med = 0;
	while (med < 1023 && (acc += hist[med]) < n / 2) med++;
	return med;     /* for neighbours of the same noise sigma s the median |difference| is about 0.95 s */
}

static inline int
plane_sample16(const uint16_t *pl, unsigned W, unsigned H, float sx, float sy)
{
	int x0 = (int)sx, y0 = (int)sy;
	float fx = sx - x0, fy = sy - y0;
	x0 = x0 < 0 ? 0 : x0 > (int)W - 2 ? (int)W - 2 : x0;
	y0 = y0 < 0 ? 0 : y0 > (int)H - 2 ? (int)H - 2 : y0;
	const uint16_t *a = pl + (size_t)y0 * W + x0, *b = a + W;
	float t = a[0] + (a[1] - a[0]) * fx, u = b[0] + (b[1] - b[0]) * fx;
	return (int)(t + (u - t) * fy + 0.5f);
}

static inline int
plane_sample_s16(const int16_t *pl, unsigned W, unsigned H, float sx, float sy)
{
	int x0 = (int)sx, y0 = (int)sy;
	float fx = sx - x0, fy = sy - y0;
	x0 = x0 < 0 ? 0 : x0 > (int)W - 2 ? (int)W - 2 : x0;
	y0 = y0 < 0 ? 0 : y0 > (int)H - 2 ? (int)H - 2 : y0;
	const int16_t *a = pl + (size_t)y0 * W + x0, *b = a + W;
	float t = a[0] + (a[1] - a[0]) * fx, u = b[0] + (b[1] - b[0]) * fx;
	return (int)lrintf(t + (u - t) * fy);
}

/* luma at the still's size from the filtered luma, chroma at half that from the blurred chroma, packed into 'pf20' */
static void
full_pf20(void *ctx, size_t piece)
{
	struct full_job *j = ctx;
	unsigned rows = (j->h + j->pieces - 1) / j->pieces, y0 = (unsigned)piece * rows, y1 = y0 + rows;
	y0 &= ~1u;
	y1 = piece + 1 == j->pieces ? j->h : (y1 & ~1u);
	y1 = MIN(y1, j->h);
	unsigned w = j->w, cw2 = (w + 1) / 2;
	uint16_t *v = malloc(sizeof(uint16_t) * (w + 3 + 2 * (cw2 + 3)));
	if (!v) {
		return;
	}
	uint16_t *cv = v + w + 3;
	uint8_t *yb = CVPixelBufferGetBaseAddressOfPlane(j->pb, 0), *cb = CVPixelBufferGetBaseAddressOfPlane(j->pb, 1);
	size_t ys = CVPixelBufferGetBytesPerRowOfPlane(j->pb, 0), cs = CVPixelBufferGetBytesPerRowOfPlane(j->pb, 1);
	float kx = (float)j->cw / j->w, ky = (float)j->ch / j->h;
	for (unsigned y = y0; y < y1; y++) {
		memset(v, 0, sizeof(uint16_t) * (w + 3));
		for (unsigned x = 0; x < w; x++) {
			int Y = plane_sample16(j->y2, j->cw, j->ch, (x + 0.5f) * kx - 0.5f, (y + 0.5f) * ky - 0.5f);
			v[x] = (uint16_t)(Y < 0 ? 0 : Y > 1023 ? 1023 : Y);
		}
		uint32_t *o = (uint32_t *)(yb + y * ys);
		for (unsigned x = 0; x < w; x += 3) {
			*o++ = v[x] | (uint32_t)v[x + 1] << 10 | (uint32_t)v[x + 2] << 20;
		}
		if (y & 1) {
			continue;
		}
		memset(cv, 0, sizeof(uint16_t) * 2 * (cw2 + 3));
		for (unsigned k = 0; k < cw2; k++) {
			float sx = (2 * k + 1.0f) * kx - 0.5f, sy = (y + 1.0f) * ky - 0.5f;   /* the centre of the 2x2 block */
			int U = plane_sample_s16(j->cb, j->cw, j->ch, sx, sy) + 512, V = plane_sample_s16(j->cr, j->cw, j->ch, sx, sy) + 512;
			cv[2 * k] = (uint16_t)(U < 0 ? 0 : U > 1023 ? 1023 : U);
			cv[2 * k + 1] = (uint16_t)(V < 0 ? 0 : V > 1023 ? 1023 : V);
		}
		uint32_t *oc = (uint32_t *)(cb + (y / 2) * cs);
		for (unsigned x = 0; x < 2 * cw2; x += 3) {
			*oc++ = cv[x] | (uint32_t)cv[x + 1] << 10 | (uint32_t)cv[x + 2] << 20;
		}
	}
	free(v);
}

/* the still (pf20, w x h) from the frame being delivered; false when it cannot (the caller falls back to the half-size picture) */
static bool
render_still_full(const struct isp *p, CVPixelBufferRef pb, unsigned w, unsigned h)
{
	const struct cam_live_hdr *hd = p->hdr;
	if (!p->raw || !hd || hd->format != 1 || hd->width < 64 || hd->height < 64 || hd->stride < hd->width * 5 / 4 ||
	    access("/private/var/tmp/sweetcam.halfstill", F_OK) == 0) {
		return false;
	}
	struct full_job j = { .p = p, .hd = hd, .W = hd->width & ~3u, .H = hd->height & ~1u, .pb = pb, .w = w, .h = h, .pieces = 16,
		              .xo = (hd->flags & 3) == 1 };
	float crop = p->crop > 0.02f && p->crop < 1.f ? p->crop : 1.f;         /* the zoom: the centre part */
	/* the part shown at least twice the still's size (mode 0's 4032x3024 for a 2016x1512 still): one RGB pixel a 2x2 Bayer cell */
	j.cells = j.W * crop >= 2 * w && j.H * crop >= 2 * h && access("/private/var/tmp/sweetcam.nocells", F_OK) != 0;
	/* the centre of the 16:9 frame cut to the still's shape, on even coordinates (the Bayer phase) */
	float aspect = (float)w / (float)h;
	unsigned FW = j.cells ? j.W / 2 : j.W, FH = j.cells ? j.H / 2 : j.H;     /* in cells or pixels */
	if (aspect < (float)FW / FH) {
		j.ch = FH;
		j.cw = (unsigned)(FH * aspect) & ~1u;
	} else {
		j.cw = FW;
		j.ch = (unsigned)(FW / aspect) & ~1u;
	}
	j.cw = MAX(64u, (unsigned)(j.cw * crop) & ~1u);
	j.ch = MAX(64u, (unsigned)(j.ch * crop) & ~1u);
	j.cx = ((FW - j.cw) / 2) & ~1u;
	j.cy = ((FH - j.ch) / 2) & ~1u;
	size_t px = (size_t)j.cw * j.ch;
	j.u = j.cells ? malloc(2) : malloc((size_t)j.W * j.H * 2);
	j.u0 = j.cells ? malloc(2) : malloc((size_t)j.W * j.H * 2);
	j.d = malloc(px * 6);
	j.y = malloc(px * 2);
	j.y2 = malloc(px * 2);
	j.cb = malloc(px * 2);
	j.cr = malloc(px * 2);
	j.t = malloc(px * 4);
	if (!j.u || !j.u0 || !j.d || !j.y || !j.y2 || !j.cb || !j.cr || !j.t) {
		free(j.u); free(j.u0); free(j.d); free(j.y); free(j.y2); free(j.cb); free(j.cr); free(j.t);
		return false;
	}
	uint64_t t0 = clock_gettime_nsec_np(CLOCK_MONOTONIC);
	dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0);
	if (j.cells) {
		dispatch_apply_f(j.pieces, q, &j, full_cells);
	} else {
		/* unpacked into u0, defective pixels corrected into u */
		uint16_t *keep = j.u;
		j.u = j.u0;
		dispatch_apply_f(j.pieces, q, &j, full_unpack);
		j.u = keep;
		dispatch_apply_f(j.pieces, q, &j, full_dpc);
		dispatch_apply_f(j.pieces, q, &j, full_demosaic);
	}
	dispatch_apply_f(j.pieces, q, &j, full_ycc);
	unsigned sigma = full_noise(&j);
	/* /private/var/tmp/sweetcam.nr: a number, the luma filter's range sigma in tenths of the measured noise (15 by default; 0: off) */
	static int nr10 = -1;
	static time_t nr_read;
	if (nr10 < 0 || time(NULL) != nr_read) {
		FILE *nf = fopen("/private/var/tmp/sweetcam.nr", "r");
		nr10 = 15;
		if (nf) {
			if (fscanf(nf, "%d", &nr10) != 1 || nr10 < 0) nr10 = 15;
			fclose(nf);
		}
		nr_read = time(NULL);
	}
	j.thr = (unsigned)((sigma * nr10 + 5) / 10);
	if (j.thr) {
		if (bil_range_thr != j.thr) {
			for (int d = 0; d < 1024; d++) bil_range[d] = expf(-(float)(d * d) / (2.f * j.thr * j.thr));
			bil_range_thr = j.thr;
		}
		dispatch_apply_f(j.pieces, q, &j, full_luma_nr);
	} else {
		memcpy(j.y2, j.y, px * 2);
	}
	dispatch_apply_f(j.pieces, q, &j, full_chroma_rows);
	dispatch_apply_f(j.pieces, q, &j, full_chroma_cols);
	dispatch_apply_f(j.pieces, q, &j, full_pf20);
	free(j.u); free(j.u0); free(j.d); free(j.y); free(j.y2); free(j.cb); free(j.cr); free(j.t);
	static unsigned said;
	if (said++ < 6) {
		say("still: %ux%u developed from the frame's %ux%u %{public}s centre (of %ux%u) in %.1f ms; luma noise %u, filter threshold %u",
		    w, h, j.cw, j.ch, j.cells ? "2x2-cell" : "pixel", j.W, j.H, (clock_gettime_nsec_np(CLOCK_MONOTONIC) - t0) / 1e6, sigma, j.thr);
	}
	return true;
}

static void
render_piece(void *ctx, size_t piece)
{
	struct render_job *j = ctx;
	unsigned rows = (j->h + j->pieces - 1) / j->pieces, y0 = (unsigned)piece * rows, y1 = y0 + rows;
	y0 &= ~1u;
	y1 = piece + 1 == j->pieces ? j->h : (y1 & ~1u);
	if (y1 > j->h) {
		y1 = j->h;
	}
	float kx = j->cw / j->w, ky = j->ch / j->h;
	if (j->pf == PF_BGRA) {
		uint8_t *base = CVPixelBufferGetBaseAddress(j->pb);
		size_t bpr = CVPixelBufferGetBytesPerRow(j->pb);
		for (unsigned y = y0; y < y1; y++) {
			uint8_t *o = base + y * bpr;
			float sy = j->cy + (y + 0.5f) * ky - 0.5f;
			for (unsigned x = 0; x < j->w; x++) {
				int c[3];
				sample(j->p->rgb, j->cx + (x + 0.5f) * kx - 0.5f, sy, c);
				o[0] = (uint8_t)c[2];
				o[1] = (uint8_t)c[1];
				o[2] = (uint8_t)c[0];
				o[3] = 255;
				o += 4;
			}
		}
		return;
	}
	if (j->pf == PF_PF20) {
		render_piece_pf20(j, y0, y1);
		return;
	}
	bool video = j->pf == PF_420V;
	uint8_t *yb = CVPixelBufferGetBaseAddressOfPlane(j->pb, 0), *cb = CVPixelBufferGetBaseAddressOfPlane(j->pb, 1);
	size_t ys = CVPixelBufferGetBytesPerRowOfPlane(j->pb, 0), cs = CVPixelBufferGetBytesPerRowOfPlane(j->pb, 1);
	for (unsigned y = y0; y < y1; y += 2) {
		uint8_t *l0 = yb + y * ys, *l1 = y + 1 < j->h ? l0 + ys : l0, *cl = cb + (y / 2) * cs;
		float sy0 = j->cy + (y + 0.5f) * ky - 0.5f, sy1 = j->cy + (y + 1.5f) * ky - 0.5f;
		for (unsigned x = 0; x < j->w; x += 2) {
			int acc[3] = { 0, 0, 0 };
			for (int dy = 0; dy < 2; dy++) {
				uint8_t *l = dy ? l1 : l0;
				for (int dx = 0; dx < 2 && x + dx < j->w; dx++) {
					int c[3];
					sample(j->p->rgb, j->cx + (x + dx + 0.5f) * kx - 0.5f, dy ? sy1 : sy0, c);
					int Y = (77 * c[0] + 150 * c[1] + 29 * c[2]) >> 8;
					l[x + dx] = (uint8_t)(video ? 16 + (Y * 219 >> 8) : Y);
					acc[0] += c[0];
					acc[1] += c[1];
					acc[2] += c[2];
				}
			}
			int R = acc[0] >> 2, G = acc[1] >> 2, B = acc[2] >> 2;
			int U = ((-43 * R - 85 * G + 128 * B) >> 8), V = ((128 * R - 107 * G - 21 * B) >> 8);
			if (video) {
				U = U * 224 >> 8;
				V = V * 224 >> 8;
			}
			U += 128;
			V += 128;
			cl[x] = (uint8_t)(U < 0 ? 0 : U > 255 ? 255 : U);
			cl[x + 1] = (uint8_t)(V < 0 ? 0 : V > 255 ? 255 : V);
		}
	}
}

/*
 * 4:2:0 outputs through vImage (2026-11-09): the part of the preview picture shown goes to a luma plane and a CbCr plane
 * at its own size (integer BT.601, 8 pieces), and vImage scales each into the output's planes. The loop in render_piece
 * (a float bilinear sample of three channels for every output pixel) made 9 frames a second of the front camera's
 * 3308x2482 preview with nearly six cores busy. /private/var/tmp/sweetcam.slow420: that loop again. false: not done
 * (the caller falls back to it).
 */
struct conv_job {
	const uint8_t *rgb;
	uint8_t *ty, *tc;
	int x0, y0, cw, ch;
	bool video;
};

static void
conv_piece(void *ctx, size_t piece)
{
	struct conv_job *c = ctx;
	int rows = (c->ch + 7) / 8, ya = (int)piece * rows, yb = MIN(c->ch, ya + rows);
	for (int y = ya; y < yb; y++) {
		const uint8_t *r = c->rgb + ((size_t)(c->y0 + y) * HW + (size_t)c->x0) * 3;
		uint8_t *oy = c->ty + (size_t)y * (size_t)c->cw, *oc = c->tc + (size_t)y * (size_t)c->cw * 2;
		for (int x = 0; x < c->cw; x++, r += 3) {
			int R = r[0], G = r[1], B = r[2];
			int Y = (77 * R + 150 * G + 29 * B) >> 8, U = (-43 * R - 85 * G + 128 * B) >> 8, V = (128 * R - 107 * G - 21 * B) >> 8;
			if (c->video) {
				Y = 16 + (Y * 219 >> 8);
				U = U * 224 >> 8;
				V = V * 224 >> 8;
			}
			U += 128;
			V += 128;
			oy[x] = (uint8_t)Y;
			oc[2 * x] = (uint8_t)(U < 0 ? 0 : U > 255 ? 255 : U);
			oc[2 * x + 1] = (uint8_t)(V < 0 ? 0 : V > 255 ? 255 : V);
		}
	}
}

static bool
render_420(const struct render_job *j)
{
	struct isp *p = (struct isp *)(uintptr_t)j->p;         /* its scratch planes only */
	int x0 = (int)j->cx, y0 = (int)j->cy, cw = (int)(j->cw + 0.5f), ch = (int)(j->ch + 0.5f);

	if (access("/private/var/tmp/sweetcam.slow420", F_OK) == 0) {
		return false;
	}
	x0 = x0 < 0 ? 0 : x0;
	y0 = y0 < 0 ? 0 : y0;
	cw = x0 + cw > (int)HW ? (int)HW - x0 : cw;
	ch = y0 + ch > (int)HH ? (int)HH - y0 : ch;
	if (cw < 2 || ch < 2) {
		return false;
	}
	size_t need = (size_t)cw * (size_t)ch;
	if (need > p->tcap) {
		free(p->ty);
		free(p->tc);
		p->ty = malloc(need);
		p->tc = malloc(need * 2);
		p->tcap = p->ty && p->tc ? need : 0;
		if (!p->tcap) {
			return false;
		}
	}
	struct conv_job c = { .rgb = p->rgb, .ty = p->ty, .tc = p->tc, .x0 = x0, .y0 = y0, .cw = cw, .ch = ch, .video = j->pf == PF_420V };
	dispatch_apply_f(8, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), &c, conv_piece);
	vImage_Buffer sy = { p->ty, (vImagePixelCount)ch, (vImagePixelCount)cw, (size_t)cw };
	vImage_Buffer sc = { p->tc, (vImagePixelCount)ch, (vImagePixelCount)cw, (size_t)cw * 2 };
	vImage_Buffer dy = { CVPixelBufferGetBaseAddressOfPlane(j->pb, 0), CVPixelBufferGetHeightOfPlane(j->pb, 0),
		             CVPixelBufferGetWidthOfPlane(j->pb, 0), CVPixelBufferGetBytesPerRowOfPlane(j->pb, 0) };
	vImage_Buffer dc = { CVPixelBufferGetBaseAddressOfPlane(j->pb, 1), CVPixelBufferGetHeightOfPlane(j->pb, 1),
		             CVPixelBufferGetWidthOfPlane(j->pb, 1), CVPixelBufferGetBytesPerRowOfPlane(j->pb, 1) };
	if (!dy.data || !dc.data) {
		return false;
	}
	vImage_Error e1 = vImageScale_Planar8(&sy, &dy, NULL, kvImageNoFlags), e2 = vImageScale_CbCr8(&sc, &dc, NULL, kvImageNoFlags);
	if (e1 != kvImageNoError || e2 != kvImageNoError) {
		static unsigned said;
		if (said++ < 3) {
			say("render_420: vImage %ld %ld (%dx%d -> %ux%u): the slow loop", (long)e1, (long)e2, cw, ch, j->w, j->h);
		}
		return false;
	}
	return true;
}

/* ---- the stream --------------------------------------------------------------------------------------------------------- */

struct prop {
	const char *name, *type, *access;
};

static const struct prop stream_props[] = {
	{ "PortType", "String", "ReadOnly" }, { "ModuleInfo", "Collection", "ReadOnly" }, { "UniqueID", "String", "ReadOnly" },
	{ "NonLocalizedName", "String", "ReadOnly" }, { "SupportedFormatsArray", "Collection", "ReadOnly" },
	{ "FocalLength", "Number", "ReadOnly" }, { "LensFNumber", "Number", "ReadOnly" }, { "PixelSize", "Number", "ReadOnly" },
	{ "MaxZoomFactor", "Number", "ReadOnly" }, { "SupportedColorSpaces", "Collection", "ReadOnly" },
	{ "HasAutoFocusPositionSensor", "Boolean", "ReadOnly" }, { "Clock", "Clock", "ReadOnly" },
	{ "FormatIndex", "Number", "ReadWrite" }, { "MinimumFrameRate", "Number", "ReadWrite" },
	{ "MaximumFrameRate", "Number", "ReadWrite" }, { "MaximumAllowedFrameRate", "Number", "ReadWrite" },
	{ "VideoOutputConfigurations", "Collection", "ReadWrite" }, { "VideoOutputsEnabled", "Collection", "ReadWrite" },
	{ "VideoOutputHandlers", "Collection", "WriteOnly" }, { "DeferAdditionOfAttachments", "Boolean", "ReadWrite" },
	{ "TorchLevel", "Number", "ReadWrite" }, { "HighCurrentTorchEnabled", "Boolean", "ReadWrite" },
	{ "ColorSpace", "Number", "ReadWrite" }, { "ZoomFactor", "Number", "ReadWrite" }, { "ExposureBias", "Number", "ReadWrite" },
	{ "DeviceOrientation", "Number", "ReadWrite" }, { "FlashMode", "Number", "ReadWrite" },
	{ "StillImageCaptureNow", "Collection", "WriteOnly" }, { "LockAENow", "Boolean", "WriteOnly" },
	{ "UnlockAENow", "Boolean", "WriteOnly" }, { "LockAWBNow", "Boolean", "WriteOnly" }, { "UnlockAWBNow", "Boolean", "WriteOnly" },
	{ "MaxIntegrationTime", "Number", "ReadWrite" }, { "AEMaxGain", "Number", "ReadWrite" }, { "AEMinGain", "Number", "ReadWrite" },
	{ "FaceDetectionEnabled", "Boolean", "ReadWrite" }, { "VideoRecordingInProgress", "Boolean", "ReadWrite" },
	{ "MemoryPoolID", "Number", "ReadWrite" }, { "ChromaNoiseReductionEnabled", "Boolean", "ReadWrite" },
	{ "TemporalNoiseReductionEnabled", "Boolean", "ReadWrite" }, { "MultipleOutputSupportEnabled", "Boolean", "ReadWrite" },
	{ "VideoOutputsColorInfo", "Collection", "ReadWrite" }, { "RegionOfInterestForCameraControls", "Collection", "ReadWrite" },
	{ "AEMeteringMode", "Number", "ReadWrite" }, { "MaxFrameCoalescingDuration", "Number", "ReadWrite" },
	{ "LimitAERange", "Boolean", "ReadWrite" },
	/* tap to focus and expose: CMCapture sets these (refused as unsupported they were -12787 on every tap) */
	{ "AFWindowParams", "Collection", "ReadWrite" }, { "AEWindowParams", "Collection", "ReadWrite" },
	{ "Apply3AWindowSettings", "Boolean", "WriteOnly" }, { "AutoFocusMode", "Number", "ReadWrite" },
	{ "MatrixFocusParams", "Collection", "ReadWrite" }, { "AFSearchPositions", "Collection", "ReadWrite" },
	{ "TimeMachineSuspendNow", "Boolean", "WriteOnly" }, { "TimeMachineResumeNow", "Boolean", "WriteOnly" },
}, device_props[] = {
	{ "StreamArray", "Collection", "ReadOnly" }, { "Clock", "Clock", "ReadOnly" }, { "ClientIsActive", "Boolean", "ReadWrite" },
	{ "SupportedSynchronizedStreamsGroups", "Collection", "ReadOnly" }, { "MemoryPoolID", "Number", "ReadWrite" },
}, session_props[] = {
	{ "SupportedOutputs", "Collection", "ReadOnly" }, { "InputPixelBufferAttributes", "Collection", "ReadOnly" },
	{ "OutputPixelBufferAttributes", "Collection", "ReadOnly" }, { "DeferAdditionOfAttachments", "Boolean", "ReadWrite" },
	{ "DefaultProcessingParameters", "Collection", "ReadOnly" }, { "OutputHandler", "Collection", "WriteOnly" },
};

static CFDictionaryRef
supported(const struct prop *p, size_t n)
{
	CFMutableDictionaryRef all = new_dict();
	for (size_t i = 0; i < n; i++) {
		CFMutableDictionaryRef one = new_dict();
		put(one, "PropertyType", CFStringCreateWithCString(NULL, p[i].type, kCFStringEncodingUTF8));
		put(one, "ReadWriteStatus", CFStringCreateWithCString(NULL, p[i].access, kCFStringEncodingUTF8));
		put(all, p[i].name, one);
	}
	return all;
}

#define OUTPUTS 5
static const char *const output_names[OUTPUTS] = { "PrimaryScaler", "SecondaryScaler", "StillImage", "IntermediateTap", "Depth" };

static CFDictionaryRef
output_info(int64_t w, int64_t h)
{
	CFMutableDictionaryRef o = new_dict();
	CFNumberRef pf[3] = { num_i(PF_420F), num_i(PF_420V), num_i(PF_BGRA) };
	put(o, "SupportedPixelFormats", CFArrayCreate(NULL, (const void **)pf, 3, &kCFTypeArrayCallBacks));
	for (int i = 0; i < 3; i++) {
		CFRelease(pf[i]);
	}
	put(o, "NativeWidth", num_i(w));
	put(o, "NativeHeight", num_i(h));
	put(o, "MaxDownscaleFactor", num_f(32));
	put(o, "MaxScaleFactor", num_f(1));
	put(o, "MinScaleFactor", num_f(1.0 / 32));
	put(o, "OutputWidthAlignmentRequirement", num_i(16));
	return o;
}

/*
 * one stream format from an entry of the model's FigCaptureStreamFormats: its own keys (the FES and SIFR ones too: without
 * them only 6 of the 16 device formats resolve, none for photos) but not its depth companion (a format that names one makes
 * the graph wire a depth output this stream does not have, and BWGraph throws "Output can't be nil"), and what a stream
 * format says
 */
static CFDictionaryRef
format_from(CFStringRef name, CFDictionaryRef entry, bool front)
{
	CFMutableDictionaryRef f = CFDictionaryCreateMutableCopy(NULL, 0, entry);
	CFDictionaryRemoveValue(f, CFSTR("DepthCompanionFormat"));
	CFDictionaryRemoveValue(f, CFSTR("FESCompanionFormats"));
	CFDictionaryRemoveValue(f, CFSTR("NonSIFRCompanionFormat"));
	int64_t sw = get_i(entry, "SensorWidth", 4032), sh = get_i(entry, "SensorHeight", 3024);
	/* (the front camera's formats must stay at the plist's sizes: halved, CMCapture's "Front Camera" source "is missing
	 * formats" and Camera could not switch to it, 2026-11-09) */
	int64_t fps = get_i(entry, "MaxFrameRate", 30);
	bool binned = get_i(entry, "Binned", 0) != 0;
	CMVideoFormatDescriptionRef fd = NULL;
	if (CMVideoFormatDescriptionCreate(NULL, PF_420F, (int32_t)sw, (int32_t)sh, NULL, &fd) == 0 && fd) {
		put(f, "FormatDescription", fd);
	}
	put(f, "FigCaptureStreamFormatName", CFRetain(name));
	put(f, "VideoMinFrameRate", num_f(2));
	put(f, "VideoMaxFrameRate", num_f((double)fps));
	put(f, "VideoIsBinned", CFRetain(binned ? kCFBooleanTrue : kCFBooleanFalse));
	put(f, "VideoBinningFactorHorizontal", num_i(binned ? 2 : 1));
	put(f, "VideoBinningFactorVertical", num_i(binned ? 2 : 1));
	put(f, "VideoFieldOfView", num_f(68.0));
	put(f, "VideoMinIntegrationTime", num_i(100));
	put(f, "VideoMaxIntegrationTime", num_i(1000000 / 15));
	put(f, "VideoRawBitDepth", num_i(10));
	put(f, "VideoMaxWidth", num_i(sw));
	put(f, "VideoMaxHeight", num_i(sh));
	put(f, "Experimental", CFRetain(kCFBooleanFalse));
	put(f, "ISOBase", num_f(32));
	put(f, "DefaultAEMaxGain", num_f(64));
	if (!CFDictionaryContainsKey(f, CFSTR("SensorCropWidth"))) {
		put(f, "SensorCropWidth", num_i(sw));
		put(f, "SensorCropHeight", num_i(sh));
	}
	(void)entry;
	put(f, "PreGDCSensorCropWidth", num_i(sw));
	put(f, "PreGDCSensorCropHeight", num_i(sh));
	put(f, "PostGDCCropWidth", num_i(sw));
	put(f, "PostGDCCropHeight", num_i(sh));
	put(f, "GeometricDistortionCorrectedNativeWidth", num_i(sw));
	put(f, "GeometricDistortionCorrectedNativeHeight", num_i(sh));
	CFMutableDictionaryRef outputs = new_dict();
	int64_t ow = get_i(entry, "HighQualitySensorWidth", sw), oh = get_i(entry, "HighQualitySensorHeight", sh);
	/*
	 * the still size halved in each dimension when it is over 2048 wide (4032x3024 -> 2016x1512): the frames are 1920x1080
	 * here, so a 12 MP still was only upscaled, and the still pipeline's buffers for it (shot buffers, NRF's pyramids, Live
	 * Photo's ring) went past the kernel's 1.5 GB for surfaces (SWEET_SURFACE_WIRED_MAX): every IOSurface after that failed
	 * and the phone starved
	 */
	if (ow > 2048) {
		ow /= 2;
		oh /= 2;
		/* the front camera's entries have no such keys: with them at half the sensor's size its photos came out at a quarter
		 * (1008x756), tried without (2026-11-09) */
		if (!front || access("/private/var/tmp/sweetcam.fronthq", F_OK) == 0) {
			put(f, "HighQualitySensorWidth", num_i(ow));
			put(f, "HighQualitySensorHeight", num_i(oh));
		}
	}
	put(outputs, "PrimaryScaler", output_info(sw, sh));
	put(outputs, "SecondaryScaler", output_info(sw, sh));
	put(outputs, "StillImage", output_info(ow, oh));
	/* the graph asks for a Depth output and throws "Output can't be nil" without one: listed (no pictures go to it) */
	{
		CFMutableDictionaryRef dep = (CFMutableDictionaryRef)output_info(sw / 4, sh / 4);
		CFNumberRef pf[2] = { num_i('hdis'), num_i('fdis') };
		put(dep, "SupportedPixelFormats", CFArrayCreate(NULL, (const void **)pf, 2, &kCFTypeArrayCallBacks));
		CFRelease(pf[0]);
		CFRelease(pf[1]);
		put(outputs, "Depth", dep);
	}
	put(f, "SupportedOutputs", outputs);
	return f;
}

/* a camera's stream formats of the model's AVCaptureSession.plist: the back camera's (the device entry with "Photo" and
 * autofocus) or the "Front Camera" entry's */
static CFArrayRef
formats_of_model(bool front)
{
	CFMutableArrayRef all = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	@autoreleasepool {
	NSString *model = nil;
	for (NSString *m in @[ @"N104", @"N141", @"D22" ]) {
		NSString *p = [NSString stringWithFormat:@"/System/Library/PrivateFrameworks/CMCapture.framework/%@/AVCaptureSession.plist", m];
		if ([[NSFileManager defaultManager] fileExistsAtPath:p]) {
			model = p;
			break;
		}
	}
	NSDictionary *plist = model ? [NSDictionary dictionaryWithContentsOfFile:model] : nil;
	for (NSDictionary *dev in plist[@"AVCaptureDevices"]) {
		NSDictionary *fs = dev[@"MultiStream"][@"FigCaptureStreamFormats"];
		if (front ? ![dev[@"uniqueName"] isEqual:@"Front Camera"] || !fs[@"Photo"] : ![dev[@"hasAutoFocus"] boolValue] || !fs[@"Photo"]) {
			continue;
		}
		for (NSString *name in [[fs allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
			CFDictionaryRef f = format_from((__bridge CFStringRef)name, (__bridge CFDictionaryRef)fs[name], front);
			CFArrayAppendValue(all, f);
			CFRelease(f);
		}
		say("%ld %{public}s stream formats from %{public}@", (long)CFArrayGetCount(all), front ? "front" : "back", model);
		break;
	}
	}
	if (CFArrayGetCount(all) == 0) {
		CFMutableDictionaryRef e = new_dict();
		put(e, "SensorWidth", num_i(4032));
		put(e, "SensorHeight", num_i(3024));
		put(e, "MaxFrameRate", num_i(30));
		CFDictionaryRef f = format_from(CFSTR("Photo"), e, false);
		CFArrayAppendValue(all, f);
		CFRelease(f);
		CFRelease(e);
		say("no model plist: one 4032x3024 format");
	}
	return all;
}

struct output {
	const char *name;
	CFDictionaryRef config;
	bool enabled;
	void *handler;                  /* a block ^(CVPixelBufferRef, CMTime) */
	uint64_t delivered;
	unsigned dropped;               /* frames not given: the pool at its threshold (deliver) */
};

struct stream {
	CFArrayRef formats;
	CFDictionaryRef supported;
	int format_index;
	double min_fps, max_fps;
	struct output out[OUTPUTS];
	pthread_mutex_t lock;
	pthread_t worker;
	volatile bool running, delivering, worker_started;
	uint64_t frames;
	volatile int still_pending;     /* still output pictures still to give after StillImageCaptureNow */
	bool front;                     /* the front camera's stream (the kernel's sensor 2), else the back's (0, or 1 the tele) */
	volatile float zoom;            /* ZoomFactor as CMCapture set it (1 = none) */
	volatile bool tele;             /* the back camera on the telephoto sensor: from zoom 2 up, back below 1.9 */
};

static struct stream *
stream_of(CMBaseObjectRef o)
{
	return derived_storage(o);
}

static int
output_index(CFStringRef name)
{
	for (int i = 0; i < OUTPUTS; i++) {
		if (key_is(name, output_names[i])) {
			return i;
		}
	}
	return -1;
}

static OSStatus
stream_copy_property_real(CMBaseObjectRef o, CFStringRef key, CFAllocatorRef allocator, void *out)
{
	struct stream *s = stream_of(o);
	CFTypeRef value = NULL;

	(void)allocator;
	if (key_is(key, "PortType")) {
		value = CFRetain(s->front ? port_front : port_back);
	} else if (key_is(key, "ModuleInfo")) {
		/* the iPhone 11's cameras in N104/CameraSetup.plist (DefaultSensorIDs): back 0x0503 (FocalLengthCharacterization LensID
		 * 1, ActuatorID 1), front 0x0514 */
		CFMutableDictionaryRef info = new_dict();
		put(info, "sensorID", num_i(s->front ? 0x0514 : 0x0503));
		put(info, "ModuleLensID", num_i(1));
		put(info, "ModuleActuatorID", num_i(1));
		put(info, "ModuleIntegratorID", num_i(1));
		put(info, "ModuleFocusID", num_i(1));
		put(info, "ModuleIDSchemeVersion", num_i(1));
		value = info;
	} else if (key_is(key, "UniqueID") || key_is(key, "ModelID")) {
		value = CFRetain(s->front ? CFSTR("com.apple.avfoundation.avcapturedevice.built-in_video:1") :
		    CFSTR("com.apple.avfoundation.avcapturedevice.built-in_video:0"));
	} else if (key_is(key, "NonLocalizedName") || key_is(key, "LocalizedName")) {
		value = CFRetain(s->front ? CFSTR("Front Camera") : CFSTR("Back Camera"));
	} else if (key_is(key, "Manufacturer")) {
		value = CFRetain(CFSTR("Apple Inc."));
	} else if (key_is(key, "SupportedFormatsArray")) {
		value = CFRetain(s->formats);
	} else if (key_is(key, "FormatIndex")) {
		value = num_i(s->format_index);
	} else if (key_is(key, "MinimumFrameRate")) {
		value = num_f(s->min_fps);
	} else if (key_is(key, "MaximumFrameRate") || key_is(key, "MaximumAllowedFrameRate")) {
		value = num_f(s->max_fps);
	} else if (key_is(key, "Clock")) {
		value = CFRetain(CMClockGetHostTimeClock());
	} else if (key_is(key, "TorchLevel") || key_is(key, "ExposureBias")) {
		value = num_f(0);
	} else if (key_is(key, "VideoOutputsColorInfo")) {
		/* read back right after configuring (HakiOS: a failed read tears the graph down); iOS 26 wants an entry for each
		 * configured output (an empty dictionary: BWMultiStreamCameraSourceNode fails its start with -12780) */
		CFMutableDictionaryRef d = new_dict();
		pthread_mutex_lock(&s->lock);
		for (int i = 0; i < OUTPUTS; i++) {
			if (!s->out[i].config) {
				continue;
			}
			CFMutableDictionaryRef ci = new_dict();
			CFDictionarySetValue(ci, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2);
			CFDictionarySetValue(ci, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2);
			CFDictionarySetValue(ci, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4);
			put(d, output_names[i], ci);
		}
		pthread_mutex_unlock(&s->lock);
		value = d;
	} else if (key_is(key, "VideoOutputConfigurations") || key_is(key, "VideoOutputsEnabled")) {
		bool configs = key_is(key, "VideoOutputConfigurations");
		CFMutableDictionaryRef d = new_dict();
		pthread_mutex_lock(&s->lock);
		for (int i = 0; i < OUTPUTS; i++) {
			CFStringRef name = CFStringCreateWithCString(NULL, output_names[i], kCFStringEncodingUTF8);
			if (configs) {
				if (s->out[i].config) {
					CFDictionarySetValue(d, name, s->out[i].config);
				}
			} else {
				CFDictionarySetValue(d, name, s->out[i].enabled ? kCFBooleanTrue : kCFBooleanFalse);
			}
			CFRelease(name);
		}
		pthread_mutex_unlock(&s->lock);
		value = d;
	} else if (key_is(key, "SupportedPropertiesDictionary")) {
		value = CFRetain(s->supported);
	} else if (key_is(key, "FocalLength")) {
		value = num_f(s->front ? 2.71 : 4.25);  /* the iPhone 11's wide and front cameras', millimetres */
	} else if (key_is(key, "LensFNumber")) {
		value = num_f(s->front ? 2.2 : 1.8);
	} else if (key_is(key, "PixelSize")) {
		value = num_f(s->front ? 0.9 : 1.4);    /* required (BWFigVideoCaptureStream's init); the sensors' pitch in micrometres */
	} else if (key_is(key, "MaxZoomFactor")) {
		value = num_f(16);
	} else if (key_is(key, "ZoomFactor")) {
		value = num_f(s->zoom >= 1 ? s->zoom : 1);
	} else if (key_is(key, "SupportedColorSpaces")) {
		CFNumberRef srgb = num_i(0);
		value = CFArrayCreate(NULL, (const void **)&srgb, 1, &kCFTypeArrayCallBacks);
		CFRelease(srgb);
	} else if (key_is(key, "ColorSpace") || key_is(key, "DeviceOrientation") || key_is(key, "FlashMode")) {
		value = num_i(0);
	} else if (key_is(key, "HasAutoFocusPositionSensor") || key_is(key, "HighCurrentTorchEnabled") ||
	    key_is(key, "DeferAdditionOfAttachments")) {
		value = CFRetain(kCFBooleanFalse);
	} else {
		say_once("stream: no answer for", key, NULL);
		return ERR_NOT_AVAILABLE;
	}
	*(CFTypeRef *)out = value;
	return 0;
}

static OSStatus
stream_set_property_real(CMBaseObjectRef o, CFStringRef key, CFTypeRef value)
{
	struct stream *s = stream_of(o);

	if (key_is(key, "FormatIndex")) {
		int64_t i = 0;
		if (value && CFGetTypeID(value) == CFNumberGetTypeID()) {
			CFNumberGetValue(value, kCFNumberSInt64Type, &i);
		}
		if (i < 0 || i >= CFArrayGetCount(s->formats)) {
			return ERR_PARAM;
		}
		s->format_index = (int)i;
		CFDictionaryRef f = CFArrayGetValueAtIndex(s->formats, i);
		say("stream: format %lld (%{public}@)", (long long)i, CFDictionaryGetValue(f, CFSTR("FigCaptureStreamFormatName")));
		return 0;
	}
	if (key_is(key, "MinimumFrameRate") || key_is(key, "MaximumFrameRate")) {
		double fps = 0;
		if (value && CFGetTypeID(value) == CFNumberGetTypeID()) {
			CFNumberGetValue(value, kCFNumberDoubleType, &fps);
		}
		*(key_is(key, "MinimumFrameRate") ? &s->min_fps : &s->max_fps) = fps;
		say_once("stream: set", key, value);
		return 0;
	}
	if (key_is(key, "VideoOutputConfigurations") || key_is(key, "VideoOutputsEnabled") || key_is(key, "VideoOutputHandlers")) {
		bool configs = key_is(key, "VideoOutputConfigurations"), enabled = key_is(key, "VideoOutputsEnabled");
		if (!value || CFGetTypeID(value) != CFDictionaryGetTypeID()) {
			say_once("stream: set", key, value);
			return 0;
		}
		{
			NSArray *names = [[(NSDictionary *)value allKeys] sortedArrayUsingSelector:@selector(compare:)];
			say("stream: set %{public}@: %{public}@", (NSString *)key, [names componentsJoinedByString:@" "]);
		}
		pthread_mutex_lock(&s->lock);
		CFIndex n = CFDictionaryGetCount(value);
		const void **keys = calloc((size_t)n + 1, sizeof(void *)), **values = calloc((size_t)n + 1, sizeof(void *));
		CFDictionaryGetKeysAndValues(value, keys, values);
		for (CFIndex i = 0; i < n; i++) {
			int k = CFGetTypeID(keys[i]) == CFStringGetTypeID() ? output_index(keys[i]) : -1;
			if (k < 0) {
				say_once("stream: an output not known:", keys[i], NULL);
				continue;
			}
			struct output *out = &s->out[k];
			if (configs) {
				/*
				 * merged into what the output had: at a photo CMCapture sends the still output only
				 * { RetainedBufferCount = 3 }, and taken as the whole configuration that left it with no size, format or
				 * pool (deliver gave nothing and the photo never came, 2026-11-09)
				 */
				CFDictionaryRef nc = CFGetTypeID(values[i]) == CFDictionaryGetTypeID() ? values[i] : NULL;
				CFDictionaryRef merged = NULL;
				if (nc && out->config) {
					CFMutableDictionaryRef m = CFDictionaryCreateMutableCopy(NULL, 0, out->config);
					CFIndex cn = CFDictionaryGetCount(nc);
					const void **ck = calloc((size_t)cn + 1, sizeof(void *)), **cv = calloc((size_t)cn + 1, sizeof(void *));
					CFDictionaryGetKeysAndValues(nc, ck, cv);
					for (CFIndex j = 0; j < cn; j++) {
						CFDictionarySetValue(m, ck[j], cv[j]);
					}
					free(ck);
					free(cv);
					merged = m;
				} else if (nc) {
					merged = CFRetain(nc);
				}
				if (out->config) {
					CFRelease(out->config);
				}
				out->config = merged;
			} else if (enabled) {
				int64_t on = 1;
				if (CFGetTypeID(values[i]) == CFBooleanGetTypeID()) {
					on = CFBooleanGetValue(values[i]);
				} else if (CFGetTypeID(values[i]) == CFNumberGetTypeID()) {
					CFNumberGetValue(values[i], kCFNumberSInt64Type, &on);
				}
				out->enabled = on != 0;
			} else {
				CFTypeRef h = CFGetTypeID(values[i]) == CFDictionaryGetTypeID() ?
				    CFDictionaryGetValue(values[i], CFSTR("PixelBufferHandler")) : NULL;
				if (out->handler) {
					CFRelease(out->handler);
				}
				out->handler = h ? (void *)CFRetain(h) : NULL;
				static const char *(*block_sig)(const void *);
				if (!block_sig) {
					block_sig = dlsym(RTLD_DEFAULT, "_Block_signature");
				}
				if (h && block_sig && k == 0) {
					say("stream: %{public}s handler signature %{public}s", output_names[k], block_sig(h) ? block_sig(h) : "(none)");
				}
			}
		}
		free(keys);
		free(values);
		pthread_mutex_unlock(&s->lock);
		return 0;
	}
	if (key_is(key, "ZoomFactor")) {
		/*
		 * the zoom is the stream's to apply (CMCapture ramps this property): the centre 1/zoom of the picture, and for the
		 * back camera the telephoto sensor from 2x (worker). /private/var/tmp/sweetcam.notele: the main sensor at any zoom
		 */
		double z = 1;
		if (value && CFGetTypeID(value) == CFNumberGetTypeID()) {
			CFNumberGetValue(value, kCFNumberDoubleType, &z);
		}
		z = z < 1 ? 1 : z > 16 ? 16 : z;
		s->zoom = (float)z;
		if (!s->front) {
			bool was = s->tele;
			if (z >= 2.0 && access("/private/var/tmp/sweetcam.notele", F_OK) != 0) {
				s->tele = true;
			} else if (z < 1.9) {
				s->tele = false;
			}
			if (was != s->tele) {
				say("stream: zoom %.2f: the %{public}s sensor", z, s->tele ? "telephoto" : "main");
			}
		}
		return 0;
	}
	if (key_is(key, "StillImageCaptureNow")) {
		/* the still output gets pictures only when one is asked for (CMCapture discards the others): the next 3 frames */
		s->still_pending = 3;
		say("stream: StillImageCaptureNow: the next 3 frames to the still output");
		return 0;
	}
	if (key_is(key, "TorchLevel")) {
		float level = 0;
		if (value && CFGetTypeID(value) == CFNumberGetTypeID()) {
			CFNumberGetValue(value, kCFNumberFloatType, &level);
		}
		uint32_t v = level <= 0 ? 0 : level >= 1 ? 1000 : (uint32_t)(level * 1000 + 0.5f);
		(void)sysctlbyname("kern.sweet_torch", NULL, NULL, &v, sizeof(v));
		return 0;
	}
	if (key_is(key, "Apply3AWindowSettings") || key_is(key, "RegionOfInterestForCameraControls")) {
		/* a tap (CMCapture applies its new AF/AE windows) or a new region: the kernel's focus sweep again, at most once a second */
		static uint64_t last;
		uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC);
		if (now - last > 1000000000ull) {
			int one = 1;
			last = now;
			(void)sysctlbyname("kern.sweet_cam_focus", NULL, NULL, &one, sizeof(one));
			if (key_is(key, "Apply3AWindowSettings")) {
				say("stream: Apply3AWindowSettings: focusing again");
			}
		}
	}
	say_once("stream: set (not used)", key, value);
	return 0;
}

/* a trace of every stream property call while /private/var/tmp/sweetcam.trace exists */
static bool
tracing(void)
{
	return access("/private/var/tmp/sweetcam.trace", F_OK) == 0;
}

static OSStatus
stream_copy_property(CMBaseObjectRef o, CFStringRef key, CFAllocatorRef allocator, void *out)
{
	OSStatus r = stream_copy_property_real(o, key, allocator, out);
	if (tracing()) {
		say("trace: stream get %{public}@ -> %d", (NSString *)key, (int)r);
	}
	return r;
}

static OSStatus
stream_set_property(CMBaseObjectRef o, CFStringRef key, CFTypeRef value)
{
	OSStatus r = stream_set_property_real(o, key, value);
	if (tracing()) {
		NSString *v = value ? [(id)value description] : @"(null)";
		v = [[v stringByReplacingOccurrencesOfString:@"\n" withString:@" "] stringByReplacingOccurrencesOfString:@"    " withString:@" "];
		if (v.length > 12000) {
			v = [v substringToIndex:12000];
		}
		/* os_log cuts a line at about 1 KB: long values in pieces */
		NSUInteger piece = 700, n = (v.length + piece - 1) / piece;
		say("trace: stream set %{public}@ = %{public}@%{public}s -> %d", (NSString *)key, n > 1 ? [v substringToIndex:piece] : v,
		    n > 1 ? " ..." : "", (int)r);
		for (NSUInteger i = 1; i < n; i++) {
			NSRange rg = NSMakeRange(i * piece, MIN(piece, v.length - i * piece));
			say("trace:   %{public}@ (%lu/%lu) %{public}@", (NSString *)key, (unsigned long)i + 1, (unsigned long)n, [v substringWithRange:rg]);
		}
	}
	return r;
}

typedef void (^pixel_buffer_handler)(CVPixelBufferRef, CMTime);

/*
 * ---- the frame's metadata ----
 * Apple's ISP gives every frame a "MetadataDictionary" (kFigCaptureStreamMetadata_* keys): without it CMCapture asserts on
 * every frame (BWFigVideoCaptureDevice "MetadataDictionary sample buffer attachment missing", FigMotionProcessingUtilities
 * -12780) and stills are not taken. The worker hangs one on each pixel buffer under SWEET_MD; the stream's
 * AddAttachmentsToSampleBuffer (DeferAdditionOfAttachments) moves it to the sample buffer.
 */
#define SWEET_MD CFSTR("SweetCamMetadata")

static CFStringRef
md_key(const char *name)
{
	static struct {
		const char *name;
		CFStringRef key;
	} cache[64];
	for (int i = 0; i < 64; i++) {
		if (cache[i].name == name) {
			return cache[i].key;
		}
		if (!cache[i].name) {
			char sym[128];
			snprintf(sym, sizeof(sym), "kFigCaptureStreamMetadata_%s", name);
			CFStringRef *k = dlsym(RTLD_DEFAULT, sym);
			cache[i].key = k && *k ? *k : NULL;
			cache[i].name = name;
			if (!cache[i].key) {
				say("metadata: %{public}s not found", sym);
			}
			return cache[i].key;
		}
	}
	return NULL;
}

static void
md_i(CFMutableDictionaryRef d, const char *name, int64_t v)
{
	CFStringRef k = md_key(name);
	if (k) {
		CFNumberRef n = CFNumberCreate(NULL, kCFNumberSInt64Type, &v);
		CFDictionarySetValue(d, k, n);
		CFRelease(n);
	}
}

static void
md_f(CFMutableDictionaryRef d, const char *name, double v)
{
	CFStringRef k = md_key(name);
	if (k) {
		CFNumberRef n = CFNumberCreate(NULL, kCFNumberDoubleType, &v);
		CFDictionarySetValue(d, k, n);
		CFRelease(n);
	}
}

static void
md_v(CFMutableDictionaryRef d, const char *name, CFTypeRef v)
{
	CFStringRef k = md_key(name);
	if (k && v) {
		CFDictionarySetValue(d, k, v);
	}
}

static CFDictionaryRef
frame_metadata(const struct cam_live_hdr *h, const struct isp *p, uint64_t host_time, bool front)
{
	CFMutableDictionaryRef d = new_dict();
	double exposure = h->exposure_lines * (double)h->line_ns / 1e9, again = h->again_x256 / 256.0, dgain = h->dgain_x256 / 256.0;
	double gain = again * dgain, level = p->mean > 0.0005f ? p->mean : 0.0005;
	double fps = h->frame_us ? 1e6 / h->frame_us : 30;
	md_f(d, "ExposureTime", exposure);
	md_i(d, "AGC", (int64_t)h->again_x256);
	md_i(d, "sensorDGain", (int64_t)h->dgain_x256);
	md_i(d, "ispDGain", 256);
	md_i(d, "ISOSpeedRating", (int64_t)(32 * gain + 0.5));
	/* a rough lux: 1/30 s at gain 4 with the picture at its usual level is a lit room (about 150 lux) */
	md_i(d, "LuxLevel", (int64_t)(150.0 * (level / 0.18) * (0.0333 * 4) / (exposure * gain) + 0.5));
	md_i(d, "AEAverage", (int64_t)(level * 255 + 0.5));
	md_i(d, "AETarget", 46);
	md_v(d, "AEStable", kCFBooleanTrue);
	md_i(d, "AELimitsReached", h->again_x256 >= 16 * 256 ? 1 : 0);
	md_v(d, "AFStable", h->af_state == 0 ? kCFBooleanTrue : kCFBooleanFalse);
	md_v(d, "AWBStable", kCFBooleanTrue);
	md_i(d, "AWBRGain", (int64_t)(p->wb[0] * 256));
	md_i(d, "AWBGGain", 256);
	md_i(d, "AWBBGain", (int64_t)(p->wb[2] * 256));
	md_i(d, "CCT", 4500);
	md_f(d, "ExposureBias", 0);
	md_f(d, "SNR", 30);
	md_f(d, "NormalizedSNR", 30);
	md_i(d, "FocusLensPosition", (int64_t)(h->lens >> 2));
	md_i(d, "CurrentFocusPosition", (int64_t)(h->lens >> 2));
	md_i(d, "LogicalFocusLensPosition", (int64_t)(h->lens >> 2));
	md_f(d, "FocalLength", front ? 2.71 : 4.25);
	md_f(d, "Fnumber", front ? 2.2 : 1.8);
	md_i(d, "FocalLenIn35mmFilm", front ? 23 : 26);
	md_v(d, "PortType", front ? port_front : port_back);
	md_i(d, "SensorID", front ? 0x0514 : 0x0503);
	md_i(d, "Timestamp", (int64_t)host_time);
	md_f(d, "CurrentFrameRate", fps);
	md_f(d, "PreviousFrameDurationInSec", 1 / fps);
	md_i(d, "BlackLevel", (int64_t)h->black);
	return d;
}

static void
deliver(struct output *out, const struct isp *p, CMTime pts, CFDictionaryRef md)
{
	CVPixelBufferRef pb = NULL;
	CFTypeRef gp = out->config ? CFDictionaryGetValue(out->config, CFSTR("BufferPool")) : NULL;
	int64_t w = get_i(out->config, "Width", 0), h = get_i(out->config, "Height", 0);
	uint32_t pf = (uint32_t)get_i(out->config, "PixelFormat", PF_420F);

	if (gp && CFGetTypeID(gp) == CVPixelBufferPoolGetTypeID()) {
		/*
		 * at most 6 buffers out of each pool (the still output's own count, when larger): when the consumers fall behind
		 * (the still pipeline's ~500 Metal pipelines compiling at the start of a session took the CPUs for ~15 s) the frame is
		 * dropped, as an ISP does, instead of the pool growing until the kernel's 1.5 GB of surfaces ran out
		 */
		static CFDictionaryRef aux;
		if (!aux) {
			int lim = 6;
			CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &lim);
			const void *k = kCVPixelBufferPoolAllocationThresholdKey, *v = n;
			aux = CFDictionaryCreate(NULL, &k, &v, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
			CFRelease(n);
		}
		CVReturn cr = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(NULL, (CVPixelBufferPoolRef)gp, aux, &pb);
		if (cr == kCVReturnWouldExceedAllocationThreshold) {
			out->dropped++;
			if (out->dropped == 1 || out->dropped % 300 == 0)
				say("%{public}s: %u frames dropped (its consumers hold all %d buffers)", out->name, out->dropped, 6);
			return;
		}
		if (cr != kCVReturnSuccess) {
			pb = NULL;
		}
	}
	if (!pb) {
		if (out->delivered == 0) {
			CFStringRef n = CFStringCreateWithCString(NULL, out->name, kCFStringEncodingUTF8);
			say_once("deliver: no buffer pool in", n, out->config);
			CFRelease(n);
		}
		if (w <= 0 || h <= 0 || w > 8192 || h > 8192 ||
		    CVPixelBufferCreate(NULL, (size_t)w, (size_t)h, pf, (__bridge CFDictionaryRef)@{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{} },
		    &pb) != kCVReturnSuccess) {
			return;
		}
	}
	w = (int64_t)CVPixelBufferGetWidth(pb);
	h = (int64_t)CVPixelBufferGetHeight(pb);
	pf = CVPixelBufferGetPixelFormatType(pb);
	if (pf != PF_420F && pf != PF_420V && pf != PF_BGRA && pf != PF_PF20) {
		static unsigned said;
		if (said++ < 4) {
			say("%{public}s: pixel format %c%c%c%c not made here", out->name, pf >> 24, pf >> 16 & 255, pf >> 8 & 255, pf & 255);
		}
		CVPixelBufferRelease(pb);
		return;
	}
	CVPixelBufferLockBaseAddress(pb, 0);
	struct render_job j = { .p = p, .pb = pb, .pf = pf, .w = (unsigned)w, .h = (unsigned)h, .pieces = 16 };
	/* the centre of the half-size 16:9 picture cut to the output's shape */
	float aspect = (float)w / (float)h, src = (float)HW / (float)HH;
	if (aspect < src) {
		j.ch = HH;
		j.cw = HH * aspect;
	} else {
		j.cw = HW;
		j.ch = HW / aspect;
	}
	if (p->crop > 0.02f && p->crop < 1.f) {         /* the zoom: the centre part */
		j.cw *= p->crop;
		j.ch *= p->crop;
	}
	j.cx = (HW - j.cw) / 2;
	j.cy = (HH - j.ch) / 2;
	if ((pf == PF_420F || pf == PF_420V) && render_420(&j)) {
		/* done through vImage */
	} else if (!(pf == PF_PF20 && out == p->still_out && render_still_full(p, pb, (unsigned)w, (unsigned)h))) {
		dispatch_apply_f(j.pieces, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), &j, render_piece);
	}
	CVPixelBufferUnlockBaseAddress(pb, 0);
	CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, kCVAttachmentMode_ShouldPropagate);
	CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
	CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
	if (md) {
		/*
		 * the buffer's own mutable copy under Apple's key as well: CMCapture reads the frame's MetadataDictionary from the
		 * buffer, adds to it in place (FocusAccelerometerVector) and dereferences it without a check (a NULL there was
		 * a SIGSEGV in CFDictionaryGetValue)
		 */
		CFMutableDictionaryRef mine = CFDictionaryCreateMutableCopy(NULL, 0, md);
		CVBufferSetAttachment(pb, SWEET_MD, mine, kCVAttachmentMode_ShouldNotPropagate);
		if (md_attachment) {
			CVBufferSetAttachment(pb, md_attachment, mine, kCVAttachmentMode_ShouldNotPropagate);
		}
		CFRelease(mine);
	}
	((pixel_buffer_handler)out->handler)(pb, pts);
	CVPixelBufferRelease(pb);
	if (out->delivered++ == 0) {
		say("%{public}s: the first picture given (%lldx%lld %c%c%c%c)", out->name, w, h, pf >> 24, pf >> 16 & 255, pf >> 8 & 255,
		    pf & 255);
	}
}

static void *
worker(void *ctx)
{
	CMBaseObjectRef o = ctx;
	struct stream *s = stream_of(o);
	struct isp isp;
	size_t cap = 0;
	uint32_t last = 0;
	mach_timebase_info_data_t tb;

	pthread_setname_np("sweetcam");
	mach_timebase_info(&tb);
	isp_init(&isp);
	int cur = -1;                   /* the kernel's sensor now streaming: 0 the rear main, 1 the rear tele, 2 the front */
	uint8_t *buf = NULL;
	bool full_still = false, tele_failed = false;
	unsigned fails = 0;
	while (s->running && isp.ready && fails < 20) {
		int want = s->front ? 2 : (s->tele && !tele_failed) ? 1 : 0;
		if (want != cur) {
			/* the first start, or the back camera between its main and telephoto sensors (the zoom): the kernel's stream again */
			if (cur >= 0) {
				(void)kernel_stream(0, cur);
			}
			int e = kernel_stream(1, want);
			size_t ncap = 0;
			if (e || sysctlbyname("kern.sweet_cam_live", NULL, &ncap, NULL, 0) != 0 || !ncap) {
				say("the kernel's camera does not stream sensor %d (%{public}s)", want, strerror(e ? e : errno));
				cur = -1;
				if (want == 1) {
					tele_failed = true;     /* the main sensor again, the zoom as a crop of it */
					continue;
				}
				break;
			}
			if (ncap > cap) {
				free(buf);
				buf = malloc(ncap);
				cap = buf ? ncap : 0;
			}
			if (!buf) {
				break;
			}
			cur = want;
			last = 0;
			full_still = cur == 0 && load_seq0();
			say("worker: streaming sensor %d (%zu-byte frames)", cur, ncap);
			continue;
		}
		size_t len = cap;
		uint64_t t_a = clock_gettime_nsec_np(CLOCK_MONOTONIC);
		if (sysctlbyname("kern.sweet_cam_live", buf, &len, &last, sizeof(last)) != 0) {
			fails++;
			usleep(20000);
			continue;
		}
		uint64_t t_b = clock_gettime_nsec_np(CLOCK_MONOTONIC);
		const struct cam_live_hdr *h = (const void *)buf;
		if (h->magic != 0x4d414353u || h->seq == last || len < h->hdr_size + (size_t)h->stride * h->height) {
			continue;
		}
		fails = 0;
		last = h->seq;
		s->frames++;
		isp_half(&isp, h, buf + h->hdr_size);
		if (!isp.ready) {
			break;
		}
		uint64_t t_c = clock_gettime_nsec_np(CLOCK_MONOTONIC);
		/*
		 * the zoom: the centre 1/zoom of the picture. On the telephoto (twice the main lens) the part that shows what the
		 * main sensor's preview would at this zoom: that preview is the 4:3 middle of the main's 16:9 mode, 0.714 of its
		 * sensor's width, so the telephoto's whole frame is zoom 1.43 and at 2x it shows 0.714 of its own
		 */
		{
			float z = s->zoom >= 1 ? s->zoom : 1;
			isp.crop = cur == 1 ? MIN(1.f, 1.428f / z) : 1.f / z;
		}
		isp.raw = buf + h->hdr_size;   /* for the still's full-size development, during this frame's deliveries */
		isp.hdr = h;
		isp.still_out = &s->out[2];
		uint64_t host = h->timestamp_ns * tb.denom / tb.numer;
		CMTime pts = CMClockMakeHostTimeFromSystemUnits(host);
		CFDictionaryRef md = frame_metadata(h, &isp, host, s->front);
		const struct cam_live_hdr *fs = NULL;
		if (full_still && s->still_pending > 0 && access("/private/var/tmp/sweetcam.nofullstill", F_OK) != 0) {
			fs = take_full_still();     /* outside the lock: the kernel takes about 0.8 s */
		}
		pthread_mutex_lock(&s->lock);
		if (fs && s->still_pending > 0 && s->out[2].handler && s->out[2].config) {
			/* the full-resolution frame for every still picture asked for (CMCapture asks three: NRF keeps one) */
			isp.raw = (const uint8_t *)fs + fs->hdr_size;
			isp.hdr = fs;
			for (int k = 0; s->still_pending > 0; k++) {
				s->still_pending--;
				deliver(&s->out[2], &isp, CMTimeAdd(pts, CMTimeMake(k, 1000)), md);
			}
			isp.raw = buf + h->hdr_size;
			isp.hdr = h;
		}
		for (int i = 0; i < OUTPUTS; i++) {
			struct output *out = &s->out[i];
			if (!out->handler || !out->config || !(out->enabled || (i == 0 && s->delivering))) {
				continue;
			}
			if (i == 2) {
				if (s->still_pending <= 0) {
					continue;       /* the still output: only after StillImageCaptureNow (12 MP on the CPU) */
				}
				s->still_pending--;
			}
			if (i == 4) {
				continue;               /* no depth here */
			}
			deliver(out, &isp, pts, md);
		}
		pthread_mutex_unlock(&s->lock);
		CFRelease(md);
		{
			/* where a frame's time goes here: the wait for it and its copy, the preview picture, the outputs (every 150 frames) */
			static uint64_t acc[3];
			static unsigned nacc;
			uint64_t t_d = clock_gettime_nsec_np(CLOCK_MONOTONIC);
			acc[0] += t_b - t_a;
			acc[1] += t_c - t_b;
			acc[2] += t_d - t_c;
			if (++nacc == 150) {
				say("timing over 150 frames: frame wait and copy %.1f ms, preview picture %.1f ms, outputs %.1f ms (%ux%u, zoom crop %.2f, gain %.2f)",
				    acc[0] / 150e6, acc[1] / 150e6, acc[2] / 150e6, h->width, h->height, isp.crop, isp.gain);
				acc[0] = acc[1] = acc[2] = 0;
				nacc = 0;
			}
		}
		/*
		 * a guard while the still pipeline is brought up: past 1200 MiB of the kernel's 1536 MiB of surfaces (xnu 3083's
		 * kern.sweet_surface_list) cameracaptured ends itself, with the list in the log, rather than starve the phone (it did
		 * twice: every surface failed, SSH stopped answering)
		 */
		if (s->frames % 30 == 0) {
			char sl[8192];
			size_t sll = sizeof(sl);
			if (sysctlbyname("kern.sweet_surface_list", sl, &sll, NULL, 0) == 0 && strtoul(sl + 6, NULL, 10) >= 1200) {
				say("surface memory guard: %{public}s", sl);
				say("surface memory guard: cameracaptured ends itself");
				usleep(200000);
				_exit(1);
			}
		}
		if (s->frames <= 2 || s->frames % 300 == 0) {
			say("frame %u: %u lines x %.1f x %.2f, lens %u; white balance R %.2f B %.2f; outputs %d%d%d%d enabled %d%d%d%d, delivering %d",
			    h->seq, h->exposure_lines, h->again_x256 / 256.0, h->dgain_x256 / 256.0, h->lens, isp.wb[0], isp.wb[2],
			    s->out[0].handler != NULL, s->out[1].handler != NULL, s->out[2].handler != NULL, s->out[3].handler != NULL,
			    s->out[0].enabled, s->out[1].enabled, s->out[2].enabled, s->out[3].enabled, s->delivering);
		}
	}
	free(buf);
	free(isp.rgb);
	free(isp.ty);
	free(isp.tc);
	if (cur >= 0) {
		(void)kernel_stream(0, cur);
	}
	say("worker: stopped after %llu frames", s->frames);
	return NULL;
}

static OSStatus
stream_start_worker(CMBaseObjectRef o)
{
	struct stream *s = stream_of(o);
	if (s->running) {
		return 0;
	}
	s->running = true;
	s->frames = 0;
	if (pthread_create(&s->worker, NULL, worker, o) != 0) {
		s->running = false;
		return ERR_UNSUPPORTED;
	}
	s->worker_started = true;
	return 0;
}

static OSStatus
stream_start(CMBaseObjectRef o)
{
	say("stream: Start");
	stream_of(o)->delivering = true;
	return stream_start_worker(o);
}

static OSStatus
stream_stop(CMBaseObjectRef o)
{
	struct stream *s = stream_of(o);
	say("stream: Stop");
	s->delivering = false;
	s->running = false;
	if (s->worker_started) {
		pthread_join(s->worker, NULL);
		s->worker_started = false;
	}
	return 0;
}

static OSStatus
stream_add_attachments(CMBaseObjectRef o, CMSampleBufferRef sbuf, CFDictionaryRef options)
{
	static unsigned calls;
	(void)o;
	CVImageBufferRef pb = sbuf ? CMSampleBufferGetImageBuffer(sbuf) : NULL;
	CFTypeRef md = pb ? CVBufferCopyAttachment(pb, SWEET_MD, NULL) : NULL;
	if (md && md_attachment) {
		CMSetAttachment(sbuf, md_attachment, md, kCMAttachmentMode_ShouldPropagate);
	}
	if (calls++ < 3) {
		say("stream: AddAttachments %u (%{public}s metadata), options %{public}@", calls, md ? "with" : "no",
		    options ? [[(id)options description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "] : @"none");
	}
	if (md) {
		CFRelease(md);
	}
	return 0;
}

static OSStatus
stream_invalidate(CMBaseObjectRef o)
{
	(void)stream_stop(o);
	return 0;
}

static void
stream_finalize(CMBaseObjectRef o)
{
	struct stream *s = stream_of(o);
	(void)stream_stop(o);
	for (int i = 0; i < OUTPUTS; i++) {
		if (s->out[i].config) {
			CFRelease(s->out[i].config);
		}
		if (s->out[i].handler) {
			CFRelease(s->out[i].handler);
		}
	}
	if (s->formats) {
		CFRelease(s->formats);
	}
	if (s->supported) {
		CFRelease(s->supported);
	}
}

static CFStringRef
stream_description(CMBaseObjectRef o)
{
	return CFRetain(stream_of(o)->front ? CFSTR("<SweetCaptureStream: the Mi 8's front camera>") :
	    CFSTR("<SweetCaptureStream: the Mi 8's rear cameras>"));
}

static const struct base_class stream_base = {
	1, sizeof(struct stream), NULL, stream_invalidate, stream_finalize, stream_description, stream_copy_property, stream_set_property,
	NULL, NULL, NULL
};
static const struct stream_class stream_derived = { 2, stream_start, stream_stop, stream_add_attachments };
static const struct vtable stream_vtable = { NULL, &stream_base, &stream_derived };

static CMBaseObjectRef
stream_create(CFAllocatorRef allocator, bool front)
{
	CMBaseObjectRef o = NULL;
	if (derived_create(allocator, &stream_vtable, stream_class_id(), &o) != 0 || !o) {
		say("the stream cannot be made");
		return NULL;
	}
	struct stream *s = stream_of(o);
	memset(s, 0, sizeof(*s));
	pthread_mutex_init(&s->lock, NULL);
	s->min_fps = 2;
	s->max_fps = 30;
	for (int i = 0; i < OUTPUTS; i++) {
		s->out[i].name = output_names[i];
	}
	s->front = front;
	s->zoom = 1;
	s->formats = formats_of_model(front);
	s->supported = supported(stream_props, sizeof(stream_props) / sizeof(stream_props[0]));
	return o;
}

/* ---- the processing session (asked for by the graph; pictures come through the stream) ----------------------------------- */

struct session {
	CFDictionaryRef config;
	void *handler;
};

static OSStatus
session_copy_property(CMBaseObjectRef o, CFStringRef key, CFAllocatorRef allocator, void *out)
{
	CFTypeRef value = NULL;
	(void)o;
	(void)allocator;
	if (key_is(key, "SupportedPropertiesDictionary")) {
		value = supported(session_props, sizeof(session_props) / sizeof(session_props[0]));
	} else if (key_is(key, "SupportedOutputs")) {
		CFStringRef ids[2] = { CFSTR("PrimaryScaler"), CFSTR("SecondaryScaler") };
		value = CFArrayCreate(NULL, (const void **)ids, 2, &kCFTypeArrayCallBacks);
	} else if (key_is(key, "InputPixelBufferAttributes") || key_is(key, "OutputPixelBufferAttributes") ||
	    key_is(key, "DefaultProcessingParameters")) {
		value = new_dict();
	} else if (key_is(key, "DeferAdditionOfAttachments")) {
		value = CFRetain(kCFBooleanFalse);
	} else {
		say_once("session: no answer for", key, NULL);
		return ERR_NOT_AVAILABLE;
	}
	*(CFTypeRef *)out = value;
	return 0;
}

static OSStatus
session_set_property(CMBaseObjectRef o, CFStringRef key, CFTypeRef value)
{
	(void)o;
	say_once("session: set", key, value);
	return 0;
}

static OSStatus
session_invalidate(CMBaseObjectRef o)
{
	(void)o;
	return 0;
}

static void
session_finalize(CMBaseObjectRef o)
{
	struct session *s = derived_storage(o);
	if (s->config) {
		CFRelease(s->config);
	}
}

static CFStringRef
session_description(CMBaseObjectRef o)
{
	(void)o;
	return CFRetain(CFSTR("<SweetISPProcessingSession>"));
}

static OSStatus
session_prepare(CMBaseObjectRef o, void *handler)
{
	((struct session *)derived_storage(o))->handler = handler;
	say("session: prepare");
	return 0;
}

static OSStatus
session_process(CMBaseObjectRef o, void *buffer, void *refcon, void *descriptors, int count, void *parameters)
{
	(void)o;
	(void)buffer;
	(void)refcon;
	(void)descriptors;
	(void)parameters;
	static unsigned said;
	if (said++ < 3) {
		say("session: process (%d outputs): not done here", count);
	}
	return ERR_UNSUPPORTED;
}

static OSStatus
session_flush(CMBaseObjectRef o)
{
	(void)o;
	return 0;
}

static const struct base_class session_base = {
	1, sizeof(struct session), NULL, session_invalidate, session_finalize, session_description, session_copy_property,
	session_set_property, NULL, NULL, NULL
};
static const struct session_class session_derived = { 1, session_prepare, session_process, session_flush };
static const struct vtable session_vtable = { NULL, &session_base, &session_derived };

static OSStatus
device_processing_session_create(CMBaseObjectRef device, CFAllocatorRef allocator, CFDictionaryRef config, CMBaseObjectRef *out)
{
	CMBaseObjectRef o = NULL;
	(void)device;
	say_once("device: processing session asked, configuration", CFSTR("ProcessingSession"), config);
	if (!session_class_id || !out || derived_create(allocator, &session_vtable, session_class_id(), &o) != 0 || !o) {
		say("the processing session cannot be made");
		return ERR_UNSUPPORTED;
	}
	memset(derived_storage(o), 0, sizeof(struct session));
	if (config) {
		((struct session *)derived_storage(o))->config = CFRetain(config);
	}
	*out = o;
	return 0;
}

/* ---- the device --------------------------------------------------------------------------------------------------------- */

struct device {
	CFArrayRef streams;
	CFDictionaryRef supported;
};

static OSStatus
device_copy_property(CMBaseObjectRef o, CFStringRef key, CFAllocatorRef allocator, void *out)
{
	struct device *d = derived_storage(o);
	CFTypeRef value = NULL;
	(void)allocator;
	if (key_is(key, "StreamArray")) {
		value = CFRetain(d->streams);
	} else if (key_is(key, "Clock")) {
		value = CFRetain(CMClockGetHostTimeClock());
	} else if (key_is(key, "SupportedPropertiesDictionary")) {
		value = CFRetain(d->supported);
	} else if (key_is(key, "SupportedSynchronizedStreamsGroups")) {
		value = CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks);
	} else {
		say_once("device: no answer for", key, NULL);
		return ERR_NOT_AVAILABLE;
	}
	*(CFTypeRef *)out = value;
	return 0;
}

static OSStatus
device_set_property(CMBaseObjectRef o, CFStringRef key, CFTypeRef value)
{
	(void)o;
	say_once("device: set (not used)", key, value);
	return 0;
}

static OSStatus
device_request_streams(CMBaseObjectRef o, CFArrayRef streams, CFDictionaryRef options)
{
	static unsigned n;
	(void)o;
	if (n++ < 3) {
		say("device: RequestStreams (%ld)", streams ? (long)CFArrayGetCount(streams) : 0L);
		if (options) {
			say_once("device: RequestStreams options", CFSTR("options"), options);
		}
	}
	/*
	 * (HakiOS: the graph configures the stream, then reserves it here; the frames start from here and from Start.) Here the
	 * frames start at Start only (2026-11-09): SpringBoard's flashlight (AVFlashlight) has the device made and its streams
	 * requested at every cameracaptured launch, with no Start; starting the sensor here powered it for the device's 5 s close
	 * timer each time, then jetsam ended the idle cameracaptured (about 205 MB) and the flashlight relaunched it: a cycle every
	 * 7-10 s whenever no app kept the camera. /private/var/tmp/sweetcam.eager: start here as well (the old way).
	 */
	if (access("/private/var/tmp/sweetcam.eager", F_OK) != 0) {
		return 0;
	}
	for (CFIndex i = 0; streams && i < CFArrayGetCount(streams); i++) {
		(void)stream_start_worker((CMBaseObjectRef)CFArrayGetValueAtIndex(streams, i));
	}
	return 0;
}

static OSStatus
device_relinquish_streams(CMBaseObjectRef o, CFArrayRef streams, CFDictionaryRef options)
{
	static unsigned n;
	(void)o;
	(void)options;
	if (n++ < 3) {
		say("device: RelinquishStreams (%ld)", streams ? (long)CFArrayGetCount(streams) : 0L);
	}
	for (CFIndex i = 0; streams && i < CFArrayGetCount(streams); i++) {
		(void)stream_stop((CMBaseObjectRef)CFArrayGetValueAtIndex(streams, i));
	}
	return 0;
}

static OSStatus
device_pearl_calibration(void *a, void *b, void *c, void *d)
{
	(void)a;
	(void)b;
	(void)c;
	(void)d;
	say("device: Pearl calibration asked: none");
	return ERR_UNSUPPORTED;
}

static OSStatus
device_invalidate(CMBaseObjectRef o)
{
	(void)o;
	say("device: invalidate");
	return 0;
}

static void
device_finalize(CMBaseObjectRef o)
{
	struct device *d = derived_storage(o);
	if (d->streams) {
		CFRelease(d->streams);
	}
	if (d->supported) {
		CFRelease(d->supported);
	}
}

static CFStringRef
device_description(CMBaseObjectRef o)
{
	(void)o;
	return CFRetain(CFSTR("<SweetCaptureDevice: the Mi 8's rear main camera>"));
}

static const struct base_class device_base = {
	1, sizeof(struct device), NULL, device_invalidate, device_finalize, device_description, device_copy_property, device_set_property,
	NULL, NULL, NULL
};
static const struct device_class device_derived = { 3, (void *)device_processing_session_create, device_request_streams,
	                                            device_relinquish_streams, (void *)device_pearl_calibration };
static const struct vtable device_vtable = { NULL, &device_base, &device_derived };

static device_create_fn gAppleCreate;

/* the vendor's device create function (as H10ISPCaptureDeviceCreate is called) */
static OSStatus
sweetcam_device_create(CFAllocatorRef allocator, CFDictionaryRef options, CMBaseObjectRef *out)
{
	static bool looked, usable;
	if (!looked) {
		looked = true;
		usable = find_functions() && kernel_has_camera();
	}
	if (!usable || !out) {
		say("device create: no kernel camera, Apple's create function (%p) instead", gAppleCreate);
		return gAppleCreate ? gAppleCreate(allocator, options, out) : ERR_UNSUPPORTED;
	}
	say_once("device create: options", CFSTR("options"), options);
	/* the back camera's stream (the main sensor, the telephoto from 2x) and the front camera's
	 * (/private/var/tmp/sweetcam.nofront: the back one only) */
	CMBaseObjectRef stream = stream_create(allocator, false), device = NULL;
	if (!stream) {
		return ERR_UNSUPPORTED;
	}
	CMBaseObjectRef front = port_front && access("/private/var/tmp/sweetcam.nofront", F_OK) != 0 ? stream_create(allocator, true) : NULL;
	if (derived_create(allocator, &device_vtable, device_class_id(), &device) != 0 || !device) {
		CFRelease(stream);
		if (front) {
			CFRelease(front);
		}
		say("the device cannot be made");
		return ERR_UNSUPPORTED;
	}
	struct device *d = derived_storage(device);
	memset(d, 0, sizeof(*d));
	const void *both[2] = { stream, front };
	d->streams = CFArrayCreate(NULL, both, front ? 2 : 1, &kCFTypeArrayCallBacks);
	d->supported = supported(device_props, sizeof(device_props) / sizeof(device_props[0]));
	CFRelease(stream);
	if (front) {
		CFRelease(front);
	}
	*out = device;
	say("device made: %{public}s", front ? "two streams, the back camera and the front camera" : "one stream, the back camera");
	return 0;
}

/* ---- the vendor gets our create function ---------------------------------------------------------------------------------- */

static IMP gOrigSharedWith, gOrigInit1, gOrigInit3;

static void
note_apple(void *fn)
{
	if (fn && fn != (void *)sweetcam_device_create && !gAppleCreate) {
		gAppleCreate = (device_create_fn)fn;
	}
}

static id
shared_with(id self, SEL sel, void *fn)
{
	static unsigned n;
	note_apple(fn);
	if (n++ < 2) {
		say("+[BWFigCaptureDeviceVendor sharedCaptureDeviceVendorWithDefaultDeviceCreateFunction:] (Apple's %p): ours given", fn);
	}
	return ((id (*)(id, SEL, void *))gOrigSharedWith)(self, sel, (void *)sweetcam_device_create);
}

static id
init1(id self, SEL sel, void *fn)
{
	note_apple(fn);
	say("-[BWFigCaptureDeviceVendor initWithDefaultDeviceCreateFunction:] (Apple's %p): ours given", fn);
	return ((id (*)(id, SEL, void *))gOrigInit1)(self, sel, (void *)sweetcam_device_create);
}

static id
init3(id self, SEL sel, void *fn, void *cmio, id session)
{
	note_apple(fn);
	say("-[BWFigCaptureDeviceVendor initWithDefaultDeviceCreateFunction:cmio...] (Apple's %p): ours given", fn);
	return ((id (*)(id, SEL, void *, void *, id))gOrigInit3)(self, sel, (void *)sweetcam_device_create, cmio, session);
}

/*
 * -[BWGraph connectOutput:toInput:pipelineStage:deferredAttach:] with a nil output throws "Output can't be nil". The
 * preview sink pipeline of iOS 26 leaves its videoThumbnailSinkOutput nil for this camera (FigCapturePreviewSinkPipeline,
 * not yet known why) and the video thumbnail sink pipeline connects it: such a connection is skipped here (said once a
 * node) so the rest of the graph is built; that sink then gets no pictures.
 */
static IMP gOrigConnect;

static BOOL
connect_output(id self, SEL sel, id output, id input, id stage, BOOL deferred)
{
	if (!output) {
		static unsigned n;
		if (n++ < 6) {
			id node = [input respondsToSelector:@selector(node)] ? [input performSelector:@selector(node)] : nil;
			say("BWGraph: a nil output for %{public}@ (%{public}@): connection skipped", node ? [node description] : @"?",
			    input ? [input description] : @"nil");
		}
		return YES;
	}
	return ((BOOL (*)(id, SEL, id, id, id, BOOL))gOrigConnect)(self, sel, output, input, stage, deferred);
}

/*
 * The model's device entry (N104 AVCaptureSession.plist) says stillImageNoiseReductionAndFusionScheme 4: the still pipeline
 * then runs BWUBNode, whose NRF processor (DenoiseFusePipeline, Apple's GPU kernels) cannot be set up on this Metal device
 * ("Failed to setup processor coordinator -- all processing will fail!", photos end with -16808). An experiment: the scheme
 * can be forced to the number in /private/var/tmp/sweetcam.nrf; without the file it is left as it is. (Forcing 0 made the
 * setup fail on its own: BWUBNode's _nrProcessorControllerType must then be 1 or 6.)
 */
static IMP gOrigSetNRF[3];

static int
forced_nrf(int given)
{
	FILE *f = fopen("/private/var/tmp/sweetcam.nrf", "r");
	int v = given;
	if (f) {
		if (fscanf(f, "%d", &v) != 1) {
			v = given;
		}
		fclose(f);
	}
	return v;
}

#define NRF_SETTER(n, cls)                                                                                                     \
	static void set_nrf##n(id self, SEL sel, int scheme)                                                                   \
	{                                                                                                                      \
		int v = forced_nrf(scheme);                                                                                    \
		say("%{public}s %{public}s %d: %d given", cls, sel_getName(sel), scheme, v);                                  \
		((void (*)(id, SEL, int))gOrigSetNRF[n])(self, sel, v);                                                       \
	}
NRF_SETTER(0, "FigCaptureBaseStillImageSinkPipelineConfiguration")
NRF_SETTER(1, "BWDeferredPipelineParameters")
NRF_SETTER(2, "BWFigVideoCaptureDevice")

static void
hook_nrf(void)
{
	static const struct {
		const char *cls, *sel;
		void *imp;
	} t[3] = {
		{ "FigCaptureBaseStillImageSinkPipelineConfiguration", "setNoiseReductionAndFusionScheme:", (void *)set_nrf0 },
		{ "BWDeferredPipelineParameters", "setNoiseReductionAndFusionScheme:", (void *)set_nrf1 },
		{ "BWFigVideoCaptureDevice", "setStillImageFusionScheme:", (void *)set_nrf2 },
	};
	for (int i = 0; i < 3; i++) {
		Class c = objc_getClass(t[i].cls);
		Method m = c ? class_getInstanceMethod(c, sel_registerName(t[i].sel)) : NULL;
		if (m) {
			gOrigSetNRF[i] = method_setImplementation(m, (IMP)t[i].imp);
		} else {
			say("%{public}s -%{public}s not found", t[i].cls, t[i].sel);
		}
	}
}

/*
 * Metal function specialisation (-[_MTLLibrary newFunctionWithName:constantValues:error:], -newFunctionWithDescriptor:error:)
 * is not bgmtl's: it goes to Apple's own path. Still processing (NRFV1.bundle) makes its kernels that way; a failure is
 * logged here with the error (said for the first 40).
 */
static IMP gOrigFnCV, gOrigFnDesc;

static void
say_fn_fail(const char *how, NSString *name, NSError *err)
{
	static unsigned n;
	if (n++ < 80) {
		say("Metal: %{public}s %{public}@ failed: %{public}@", how, name, err ? [err description] : @"(no error)");
	}
}

static id
fn_cv(id self, SEL sel, NSString *name, id cv, NSError **err)
{
	NSError *e = nil;
	id r = ((id (*)(id, SEL, NSString *, id, NSError **))gOrigFnCV)(self, sel, name, cv, &e);
	if (!r) {
		say_fn_fail("specialising", name, e);
	}
	if (err) {
		*err = e;
	}
	return r;
}

static id
fn_desc(id self, SEL sel, id desc, NSError **err)
{
	NSError *e = nil;
	/*
	 * a descriptor naming binary archives (Apple's precompiled GPU code, e.g. NRFV1.bundle/binaryArchive.g12p) with
	 * MTLFunctionOptionFailOnBinaryArchiveMiss fails here ("Failed to find specialized function ... in binary archive": no
	 * archive has code for this GPU): specialised from the library's AIR instead, without archives
	 */
	static SEL s_archives, s_set_archives, s_options, s_set_options;
	if (!s_archives) {
		s_archives = sel_registerName("binaryArchives");
		s_set_archives = sel_registerName("setBinaryArchives:");
		s_options = sel_registerName("options");
		s_set_options = sel_registerName("setOptions:");
	}
	id use = desc;
	if ([desc respondsToSelector:s_archives] && [desc respondsToSelector:s_set_archives] && [desc respondsToSelector:@selector(copy)]) {
		NSArray *a = ((NSArray * (*)(id, SEL))objc_msgSend)(desc, s_archives);
		NSUInteger opt = [desc respondsToSelector:s_options] ? ((NSUInteger (*)(id, SEL))objc_msgSend)(desc, s_options) : 0;
		if (a.count || (opt & 4)) {
			use = [desc copy];
			((void (*)(id, SEL, id))objc_msgSend)(use, s_set_archives, nil);
			if ([use respondsToSelector:s_set_options]) {
				((void (*)(id, SEL, NSUInteger))objc_msgSend)(use, s_set_options, opt & ~(NSUInteger)4);
			}
			static unsigned said;
			if (said++ < 3) {
				say("Metal: %{public}@ asked from %lu binary archive(s), options %#lx: specialised from AIR instead",
				    [desc respondsToSelector:@selector(name)] ? [desc name] : @"?", (unsigned long)a.count, (unsigned long)opt);
			}
		}
	}
	id r = ((id (*)(id, SEL, id, NSError **))gOrigFnDesc)(self, sel, use, &e);
	if (use != desc) {
		[use release];
	}
	if (!r) {
		say_fn_fail("function from descriptor", [desc respondsToSelector:@selector(name)] ? [desc name] : @"?", e);
	}
	if (err) {
		*err = e;
	}
	return r;
}

/* more of the same watch: libraries, plain function lookups and the asynchronous specialisations (nil results said) */
static IMP gOrigFnName, gOrigFnCVAsync, gOrigFnDescAsync, gOrigLibBundle, gOrigLibURL, gOrigLibData, gOrigLibFile;

static id
fn_name(id self, SEL sel, NSString *name)
{
	id r = ((id (*)(id, SEL, NSString *))gOrigFnName)(self, sel, name);
	if (!r) {
		say_fn_fail("function lookup", name, nil);
	}
	return r;
}

static void
fn_cv_async(id self, SEL sel, NSString *name, id cv, void (^handler)(id, NSError *))
{
	void (^h)(id, NSError *) = [handler copy];
	void (^w)(id, NSError *) = ^(id f, NSError *e) {
		if (!f) {
			say_fn_fail("specialising (async)", name, e);
		}
		h(f, e);
	};
	((void (*)(id, SEL, NSString *, id, id))gOrigFnCVAsync)(self, sel, name, cv, w);
	[h release];
}

static void
fn_desc_async(id self, SEL sel, id desc, void (^handler)(id, NSError *))
{
	NSString *name = [desc respondsToSelector:@selector(name)] ? [[desc name] copy] : @"?";
	void (^h)(id, NSError *) = [handler copy];
	void (^w)(id, NSError *) = ^(id f, NSError *e) {
		if (!f) {
			say_fn_fail("function from descriptor (async)", name, e);
		}
		h(f, e);
	};
	((void (*)(id, SEL, id, id))gOrigFnDescAsync)(self, sel, desc, w);
	[h release];
}

#define LIB_WATCH(fn, orig, what)                                                                                              \
	static id fn(id self, SEL sel, id arg, NSError **err)                                                                  \
	{                                                                                                                      \
		NSError *e = nil;                                                                                              \
		id r = ((id (*)(id, SEL, id, NSError **))orig)(self, sel, arg, &e);                                           \
		if (!r) {                                                                                                      \
			say_fn_fail(what, [arg description], e);                                                               \
		}                                                                                                              \
		if (err) {                                                                                                     \
			*err = e;                                                                                              \
		}                                                                                                              \
		return r;                                                                                                      \
	}
LIB_WATCH(lib_bundle, gOrigLibBundle, "default library of bundle")
LIB_WATCH(lib_url, gOrigLibURL, "library from URL")
LIB_WATCH(lib_data, gOrigLibData, "library from data")
LIB_WATCH(lib_file, gOrigLibFile, "library from file")

static void
hook_one(Class c, const char *sel, IMP imp, IMP *orig)
{
	Method m = c ? class_getInstanceMethod(c, sel_registerName(sel)) : NULL;
	if (m && !*orig) {
		*orig = method_setImplementation(m, imp);
	}
}

static void
hook_specialise(void)
{
	Class lib = objc_getClass("_MTLLibrary");
	Method m;
	hook_one(lib, "newFunctionWithName:", (IMP)fn_name, &gOrigFnName);
	hook_one(lib, "newFunctionWithName:constantValues:completionHandler:", (IMP)fn_cv_async, &gOrigFnCVAsync);
	hook_one(lib, "newFunctionWithDescriptor:completionHandler:", (IMP)fn_desc_async, &gOrigFnDescAsync);
	Class dev = objc_getClass("BGMTLDevice");
	hook_one(dev, "newDefaultLibraryWithBundle:error:", (IMP)lib_bundle, &gOrigLibBundle);
	hook_one(dev, "newLibraryWithURL:error:", (IMP)lib_url, &gOrigLibURL);
	hook_one(dev, "newLibraryWithData:error:", (IMP)lib_data, &gOrigLibData);
	hook_one(dev, "newLibraryWithFile:error:", (IMP)lib_file, &gOrigLibFile);
	if (lib && (m = class_getInstanceMethod(lib, sel_registerName("newFunctionWithName:constantValues:error:")))) {
		gOrigFnCV = method_setImplementation(m, (IMP)fn_cv);
	}
	if (lib && (m = class_getInstanceMethod(lib, sel_registerName("newFunctionWithDescriptor:error:")))) {
		gOrigFnDesc = method_setImplementation(m, (IMP)fn_desc);
	}
	say("Metal: specialisation watched (%d %d %d %d %d; libraries %d %d %d %d)", gOrigFnCV != NULL, gOrigFnDesc != NULL,
	    gOrigFnName != NULL, gOrigFnCVAsync != NULL, gOrigFnDescAsync != NULL, gOrigLibBundle != NULL, gOrigLibURL != NULL,
	    gOrigLibData != NULL, gOrigLibFile != NULL);
}

/*
 * Diagnosis of BWUBNode's processor coordinator (-[BWUBNode _setupProcessorCoordinator], a direct method with about 20 exits
 * after object creations and checks, none of which logs): CMCapture's own classes' initialisers that BWUBNode calls there are
 * wrapped, and a nil one is said, as is a non-zero answer of prepareWithPixelBufferPoolProvider:. Only with
 * /private/var/tmp/sweetcam.nilwatch present when CMCapture loads.
 */
static void
nil_watch_class(Class cls, const char *cn)
{
	static const char *const id_sels[] = { "initWithConfiguration:", "initWithVideoFormat:capacity:name:memoryPool:",
		"initWithVideoFormat:capacity:name:", "initWithProcessorControllers:", "initWithPixelBufferAttributes:",
		"initWithProcessorControllers:configuration:" };
	unsigned n = 0;
	Method *ms = class_copyMethodList(cls, &n);
	for (unsigned i = 0; i < n; i++) {
		SEL sel = method_getName(ms[i]);
		const char *sn = sel_getName(sel);
		IMP orig = method_getImplementation(ms[i]);
		bool is_id = false;
		for (unsigned k = 0; k < sizeof(id_sels) / sizeof(id_sels[0]); k++)
			is_id |= !strcmp(sn, id_sels[k]);
		if (is_id) {
			bool pool = !strcmp(cn, "BWPixelBufferPool") && !strncmp(sn, "initWithVideoFormat:capacity:name:", 34);
			IMP nimp = imp_implementationWithBlock(^id(id self, void *a, void *b, void *c, void *d) {
				id r = ((id(*)(id, SEL, void *, void *, void *, void *))orig)(self, sel, a, b, c, d);
				if (!r) {
					say("nilwatch: -[%{public}s %{public}s] answered nil", cn, sn);
				}
				if (pool) {
					/* the pool inventory: format, capacity, name (the surface memory of the still pipeline) */
					id fmt = (id)a;
					SEL ws = sel_registerName("width"), hs = sel_registerName("height"), pf = sel_registerName("pixelFormat");
					unsigned long w = [fmt respondsToSelector:ws] ? ((unsigned long (*)(id, SEL))objc_msgSend)(fmt, ws) : 0;
					unsigned long h = [fmt respondsToSelector:hs] ? ((unsigned long (*)(id, SEL))objc_msgSend)(fmt, hs) : 0;
					unsigned f = [fmt respondsToSelector:pf] ? ((unsigned (*)(id, SEL))objc_msgSend)(fmt, pf) : 0;
					say("pool: %{public}@ %lux%lu %c%c%c%c x %lu", c ? (NSString *)(id)c : @"?", w, h, (char)(f >> 24),
					    (char)(f >> 16), (char)(f >> 8), (char)f, (unsigned long)b);
				}
				return r;
			});
			method_setImplementation(ms[i], nimp);
		} else if (!strcmp(sn, "prepareWithPixelBufferPoolProvider:")) {
			IMP nimp = imp_implementationWithBlock(^long(id self, void *a) {
				long r = ((long (*)(id, SEL, void *))orig)(self, sel, a);
				if ((int)r) {
					say("nilwatch: -[%{public}s %{public}s] answered %d", cn, sn, (int)r);
				}
				return r;
			});
			method_setImplementation(ms[i], nimp);
		}
	}
	free(ms);
}

/*
 * CMImaging's helpers that make a Metal texture over a pixel buffer's plane (bindPixelBufferToMTL2DTexture:..., NRF's input
 * luma among them): a nil answer is said with what was asked (Metal pixel format, usage, plane) and the buffer's own format
 * and size. With the nil watch.
 */
static void
bind_watch_methods(Class cls, const char *cn, bool meta)
{
	unsigned n = 0;
	Method *ms = class_copyMethodList(cls, &n);
	for (unsigned i = 0; i < n; i++) {
		SEL sel = method_getName(ms[i]);
		const char *sn = sel_getName(sel);
		if (strncmp(sn, "bindPixelBufferToMTL2DTexture:", 30) != 0) {
			continue;
		}
		/*
		 * at most 6 arguments: the wrapper passes x2-x7 on, and a 7th is on the caller's stack, which it does not copy
		 * (wrapped, ...slice:widthAlignmentFactor:heightAlignmentFactor: read its height alignment from the wrapper's frame:
		 * 0, so every texture over a plane came out 0 rows high, 2026-11-09)
		 */
		unsigned colons = 0;
		for (const char *q = sn; *q; q++) {
			colons += *q == ':';
		}
		if (colons > 6) {
			continue;
		}
		IMP orig = method_getImplementation(ms[i]);
		IMP nimp = imp_implementationWithBlock(^id(id self, void *a, void *b, void *c, void *d, void *e, void *f) {
			id r = ((id(*)(id, SEL, void *, void *, void *, void *, void *, void *))orig)(self, sel, a, b, c, d, e, f);
			static unsigned said;
			if (!r && said++ < 40) {
				CVPixelBufferRef pb = (CVPixelBufferRef)a;
				OSType pf = pb && CFGetTypeID(pb) == CVPixelBufferGetTypeID() ? CVPixelBufferGetPixelFormatType(pb) : 0;
				say("bindwatch: %{public}s[%{public}s %{public}s] answered nil: args %#lx %#lx %#lx %#lx; buffer %c%c%c%c %zux%zu, %zu planes",
				    meta ? "+" : "-", cn, sn, (unsigned long)b, (unsigned long)c, (unsigned long)d, (unsigned long)e,
				    (char)(pf >> 24), (char)(pf >> 16), (char)(pf >> 8), (char)pf, pf ? CVPixelBufferGetWidth(pb) : 0,
				    pf ? CVPixelBufferGetHeight(pb) : 0, pf ? CVPixelBufferGetPlaneCount(pb) : 0);
				if (pf) {
					size_t l = 0, rr = 0, t = 0, bt = 0;
					CVPixelBufferGetExtendedPixels(pb, &l, &rr, &t, &bt);
					IOSurfaceRef sf = CVPixelBufferGetIOSurface(pb);
					size_t pl = (size_t)c;
					say("bindwatch:   extended pixels l %zu r %zu t %zu b %zu; surface %u, plane %zu: %zux%zu, element %zux%zu, %zu bytes a row; "
					    "alignment args %#lx %#lx",
					    l, rr, t, bt, sf ? IOSurfaceGetID(sf) : 0, pl, sf ? IOSurfaceGetWidthOfPlane(sf, pl) : 0,
					    sf ? IOSurfaceGetHeightOfPlane(sf, pl) : 0, sf ? IOSurfaceGetElementWidth(sf) : 0, sf ? IOSurfaceGetElementHeight(sf) : 0,
					    sf ? IOSurfaceGetBytesPerRowOfPlane(sf, pl) : 0, (unsigned long)e, (unsigned long)f);
				}
			}
			return r;
		});
		method_setImplementation(ms[i], nimp);
		Dl_info di;
		unsigned long off = dladdr((void *)orig, &di) && di.dli_fbase ? (unsigned long)orig - (unsigned long)di.dli_fbase : 0;
		say("bindwatch: %{public}s[%{public}s %{public}s] watched (+%#lx in its image)", meta ? "+" : "-", cn, sn, off);
	}
	free(ms);
}

/*
 * What a call in a shared-cache image goes to, from the image's unslid address of the stub (the Mac's split copy): an
 * Objective-C stub (adrp/ldr x1 = the selector) or a C stub (adrp/ldr x16, or adrp/add x17 + ldr x16). For reading
 * disassembly of CMImaging on the Mac. base = the image's unslid __TEXT address.
 */
static void
say_stub(void *any_fn_in_image, unsigned long base, unsigned long stub)
{
	Dl_info di;
	if (!dladdr(any_fn_in_image, &di) || !di.dli_fbase) {
		return;
	}
	unsigned long slide = (unsigned long)di.dli_fbase - base;
	const uint32_t *ins = (const uint32_t *)(stub + slide);
	uint32_t i0 = ins[0], i1 = ins[1], i2 = ins[2];
	if ((i0 & 0x9f000000) != 0x90000000) {
		say("stub %#lx: not an adrp (%08x)", stub, i0);
		return;
	}
	long imm = (long)((((i0 >> 5) & 0x7ffff) << 2) | ((i0 >> 29) & 3));
	if (imm & (1l << 20)) {
		imm -= 1l << 21;
	}
	unsigned long page = ((unsigned long)ins & ~0xffful) + (unsigned long)(imm << 12), at = 0;
	unsigned reg = i0 & 31;
	if ((i1 & 0xff800000) == 0x91000000 && i2 == 0xd61f0200) {
		/* a branch island: adrp x16; add x16, x16, #off; br x16 */
		Dl_info t;
		void *fn = (void *)(page + ((i1 >> 10) & 0xfff));
		say("stub %#lx: %{public}s", stub, dladdr(fn, &t) && t.dli_sname ? t.dli_sname : "?");
		return;
	}
	if ((i1 & 0xffc00000) == 0xf9400000) {
		at = page + ((i1 >> 10) & 0xfff) * 8;
		reg = i1 & 31;
	} else if ((i1 & 0xff800000) == 0x91000000 && (i2 & 0xffc00000) == 0xf9400000) {
		at = page + ((i1 >> 10) & 0xfff) + ((i2 >> 10) & 0xfff) * 8;
		reg = i2 & 31;
	}
	if (!at) {
		say("stub %#lx: %08x %08x %08x not read", stub, i0, i1, i2);
		return;
	}
	uintptr_t v = *(const uintptr_t *)at;
	if (reg == 1) {
		say("stub %#lx: objc_msgSend %{public}s", stub, sel_getName((SEL)v));
		return;
	}
	v &= 0x0000007fffffffffull;   /* the PAC bits off */
	Dl_info t;
	say("stub %#lx: %{public}s", stub, dladdr((void *)v, &t) && t.dli_sname ? t.dli_sname : "?");
}

static void
bind_watch(void)
{
	if (access("/private/var/tmp/sweetcam.stubs", F_OK) == 0) {
		/* the calls of -[FigMetalContext bindPixelBufferToMTL2DTexture:pixelFormat:usage:plane:slice:widthAlignmentFactor:
		 * heightAlignmentFactor:] (CMImaging 26.6.2, __TEXT at 0x234a7c000 unslid) */
		static const unsigned long stubs[] = { 0x23a842ae0, 0x23a842af0, 0x23a842d60, 0x23a842b30, 0x23a842df0, 0x23a842d80,
			0x23a842d70, 0x23a842e30, 0x23a842dc0, 0x23a842d90, 0x23a842dd0, 0x23a843780, 0x234c94a60, 0x234c94a80,
			0x234c99ba0, 0x234c929a0, 0x234c98a00, 0x234c98180, 0x234c998c0, 0x234c98c20, 0x234c96aa0 };
		Class fmc = objc_getClass("FigMetalContext");
		Method m = fmc ? class_getInstanceMethod(fmc, sel_registerName("bindPixelBufferToMTL2DTexture:pixelFormat:usage:plane:")) : NULL;
		for (unsigned i = 0; m && i < sizeof(stubs) / sizeof(stubs[0]); i++) {
			say_stub((void *)method_getImplementation(m), 0x234a7c000ul, stubs[i]);
		}
	}
	unsigned n = 0;
	Class *cs = objc_copyClassList(&n);
	for (unsigned i = 0; i < n; i++) {
		const char *img = class_getImageName(cs[i]);
		if (!img || (!strstr(img, "CMImaging") && !strstr(img, "CMCapture.framework"))) {
			continue;
		}
		bind_watch_methods(cs[i], class_getName(cs[i]), false);
		bind_watch_methods(object_getClass(cs[i]), class_getName(cs[i]), true);
	}
	free(cs);
}

static void
nil_watch(void)
{
	if (access("/private/var/tmp/sweetcam.nilwatch", F_OK) != 0) {
		return;
	}
	unsigned n = 0, watched = 0;
	Class *cs = objc_copyClassList(&n);
	for (unsigned i = 0; i < n; i++) {
		const char *img = class_getImageName(cs[i]);
		if (!img || !strstr(img, "CMCapture.framework")) {
			continue;
		}
		nil_watch_class(cs[i], class_getName(cs[i]));
		watched++;
	}
	free(cs);
	say("nilwatch: %u classes of CMCapture watched", watched);
	bind_watch();
	/* +[BWVideoFormat formatByResolvingRequirements:] and the formats it gives: _setupProcessorCoordinator compares their
	 * extended (aligned) sizes with the format it asked for and gives up on a difference */
	Class vf = objc_getClass("BWVideoFormat");
	Method rm = vf ? class_getClassMethod(vf, sel_registerName("formatByResolvingRequirements:")) : NULL;
	if (rm) {
		IMP orig = method_getImplementation(rm);
		SEL sel = method_getName(rm);
		method_setImplementation(rm, imp_implementationWithBlock(^id(id cls, NSArray *reqs) {
			id r = ((id(*)(id, SEL, id))orig)(cls, sel, reqs);
			static unsigned said;
			if (said++ < 30) {
				SEL ew = sel_registerName("extendedWidth"), eh = sel_registerName("extendedHeight");
				say("nilwatch: formatByResolvingRequirements: %lu requirements -> %{public}@ (extended %lux%lu)", (unsigned long)reqs.count,
				    r ? [[r description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "] : @"nil",
				    r && [r respondsToSelector:ew] ? ((unsigned long (*)(id, SEL))objc_msgSend)(r, ew) : 0,
				    r && [r respondsToSelector:eh] ? ((unsigned long (*)(id, SEL))objc_msgSend)(r, eh) : 0);
				for (id q in reqs) {
					say("nilwatch:   requirement %{public}@", [[q description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "]);
				}
			}
			return r;
		}));
	}
}

/* where some CMCapture methods are (offset in their image), for reading them on the Mac */
static void
say_imps(void)
{
	static const struct {
		const char *cls, *sel;
	} t[] = {
		{ "BWUBNode", "_setupProcessorCoordinator" }, { "BWUBNode", "_setupProcessingStateWithSettings:" },
		{ "BWUBNode", "prepareForCurrentConfigurationToBecomeLive" },
	};
	for (unsigned i = 0; i < sizeof(t) / sizeof(t[0]); i++) {
		Class c = objc_getClass(t[i].cls);
		Method m = c ? class_getInstanceMethod(c, sel_registerName(t[i].sel)) : NULL;
		IMP imp = m ? method_getImplementation(m) : NULL;
		Dl_info di = { 0 };
		if (imp && dladdr((void *)imp, &di) && di.dli_fbase) {
			say("imp: -[%{public}s %{public}s] at %{public}s+%#lx", t[i].cls, t[i].sel, strrchr(di.dli_fname, '/') + 1,
			    (unsigned long)((uintptr_t)imp - (uintptr_t)di.dli_fbase));
		} else {
			say("imp: -[%{public}s %{public}s] not found", t[i].cls, t[i].sel);
		}
	}
}

/* names of some instance variables (by offset) that BWUBNode's coordinator setup reads, for reading it on the Mac */
static void
say_ivars(const char *cls_name, const ptrdiff_t *offs, unsigned n_offs)
{
	Class cls = objc_getClass(cls_name);
	unsigned n = 0;
	Ivar *iv = cls ? class_copyIvarList(cls, &n) : NULL;
	for (unsigned i = 0; i < n; i++) {
		ptrdiff_t o = ivar_getOffset(iv[i]);
		for (unsigned k = 0; k < n_offs; k++)
			if (o == offs[k])
				say("ivar: %{public}s +%td %{public}s %{public}s", cls_name, o, ivar_getName(iv[i]), ivar_getTypeEncoding(iv[i]));
	}
	free(iv);
}

/*
 * ---- a software M2M scaler ----
 * NRF's pyramid stage (NRFV1.bundle, PyramidStage_NRFV1) needs a FigM2MController, CMCapture's wrapper over the memory-to-
 * memory scaler (IOSurfaceAccelerator over AppleM2ScalerCSCDriver), which this phone does not have: its -init answers nil,
 * NRF cannot make its DenoiseFusePipeline and the still pipeline gives up. Here -init makes a controller without the
 * accelerator and the transforms are done on the CPU: every plane of the source rectangle scaled (vImage, 16 bits a sample)
 * into the destination rectangle, between 4:2:0 two-plane YCbCr formats of 8 bits ('420f', '420v'), 10 bits in 16
 * ('x420', 'xf20') and 10 bits packed ('pf20', 'p420'), and BGRA to BGRA. No rotation or flip; custom filters are ignored.
 */
#include <Accelerate/Accelerate.h>

enum m2m_kind { M2M_NONE, M2M_8, M2M_16, M2M_PACKED, M2M_BGRA };

static enum m2m_kind
m2m_kind_of(OSType f)
{
	switch (f) {
	case '420f': case '420v': return M2M_8;
	case 'xf20': case 'x420': return M2M_16;
	case 'pf20': case 'p420': return M2M_PACKED;
	case 'BGRA': return M2M_BGRA;
	default: return M2M_NONE;
	}
}

/* a plane's region as 16-bit samples (comps a texel: 1 luma, 2 chroma), 10 bits at the top as in 'x420' */
static void
m2m_read_plane(CVPixelBufferRef pb, size_t plane, enum m2m_kind k, unsigned comps, unsigned x0, unsigned y0, unsigned w, unsigned h,
               uint16_t *out)
{
	const uint8_t *base = CVPixelBufferGetBaseAddressOfPlane(pb, plane);
	size_t bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, plane);
	for (unsigned y = 0; y < h; y++) {
		const uint8_t *row = base + (y0 + y) * bpr;
		uint16_t *o = out + (size_t)y * w * comps;
		if (k == M2M_8) {
			for (unsigned i = 0; i < w * comps; i++)
				o[i] = (uint16_t)(row[x0 * comps + i] << 8);
		} else if (k == M2M_16) {
			memcpy(o, row + (size_t)x0 * comps * 2, (size_t)w * comps * 2);
		} else {
			/* packed: three 10-bit values a little-endian word, low bits first */
			for (unsigned i = 0; i < w * comps; i++) {
				unsigned v = x0 * comps + i;
				uint32_t word;
				memcpy(&word, row + (v / 3) * 4, 4);
				o[i] = (uint16_t)(((word >> (10 * (v % 3))) & 0x3ff) << 6);
			}
		}
	}
}

static void
m2m_write_plane(CVPixelBufferRef pb, size_t plane, enum m2m_kind k, unsigned comps, unsigned x0, unsigned y0, unsigned w, unsigned h,
                const uint16_t *in)
{
	uint8_t *base = CVPixelBufferGetBaseAddressOfPlane(pb, plane);
	size_t bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, plane);
	for (unsigned y = 0; y < h; y++) {
		uint8_t *row = base + (y0 + y) * bpr;
		const uint16_t *s = in + (size_t)y * w * comps;
		if (k == M2M_8) {
			for (unsigned i = 0; i < w * comps; i++)
				row[x0 * comps + i] = (uint8_t)((s[i] + 0x80) >> 8 > 255 ? 255 : (s[i] + 0x80) >> 8);
		} else if (k == M2M_16) {
			for (unsigned i = 0; i < w * comps; i++) {
				uint16_t v = (uint16_t)(s[i] & 0xffc0);
				memcpy(row + ((size_t)x0 * comps + i) * 2, &v, 2);
			}
		} else {
			for (unsigned i = 0; i < w * comps; i++) {
				unsigned v = x0 * comps + i, sh = 10 * (v % 3);
				uint32_t word;
				memcpy(&word, row + (v / 3) * 4, 4);
				word = (word & ~(0x3ffu << sh)) | (uint32_t)(s[i] >> 6) << sh;
				memcpy(row + (v / 3) * 4, &word, 4);
			}
		}
	}
}

static int
m2m_scale(CVPixelBufferRef src, CGRect sr, CVPixelBufferRef dst, CGRect dr)
{
	if (!src || !dst)
		return -1;
	uint64_t t_start = clock_gettime_nsec_np(CLOCK_MONOTONIC);
	OSType sf = CVPixelBufferGetPixelFormatType(src), df = CVPixelBufferGetPixelFormatType(dst);
	enum m2m_kind sk = m2m_kind_of(sf), dk = m2m_kind_of(df);
	size_t sw = CVPixelBufferGetWidth(src), sh = CVPixelBufferGetHeight(src), dw = CVPixelBufferGetWidth(dst), dh = CVPixelBufferGetHeight(dst);
	if (CGRectIsEmpty(sr) || CGRectIsNull(sr))
		sr = CGRectMake(0, 0, sw, sh);
	if (CGRectIsEmpty(dr) || CGRectIsNull(dr))
		dr = CGRectMake(0, 0, dw, dh);
	if (!sk || !dk || (sk == M2M_BGRA) != (dk == M2M_BGRA)) {
		static unsigned said;
		if (said++ < 8)
			say("m2m: %c%c%c%c to %c%c%c%c not done here", sf >> 24, sf >> 16 & 255, sf >> 8 & 255, sf & 255, df >> 24, df >> 16 & 255,
			    df >> 8 & 255, df & 255);
		return -12780;
	}
	CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
	CVPixelBufferLockBaseAddress(dst, 0);
	int err = 0;
	if (sk == M2M_BGRA) {
		unsigned x0 = (unsigned)sr.origin.x, y0 = (unsigned)sr.origin.y, w = (unsigned)sr.size.width, h = (unsigned)sr.size.height;
		unsigned X0 = (unsigned)dr.origin.x, Y0 = (unsigned)dr.origin.y, W = (unsigned)dr.size.width, H = (unsigned)dr.size.height;
		vImage_Buffer a = { (uint8_t *)CVPixelBufferGetBaseAddress(src) + y0 * CVPixelBufferGetBytesPerRow(src) + x0 * 4, h, w,
			            CVPixelBufferGetBytesPerRow(src) };
		vImage_Buffer b = { (uint8_t *)CVPixelBufferGetBaseAddress(dst) + Y0 * CVPixelBufferGetBytesPerRow(dst) + X0 * 4, H, W,
			            CVPixelBufferGetBytesPerRow(dst) };
		err = vImageScale_ARGB8888(&a, &b, NULL, kvImageHighQualityResampling) == kvImageNoError ? 0 : -12780;
	} else {
		for (size_t plane = 0; plane < 2 && !err; plane++) {
			unsigned comps = plane ? 2 : 1, div = plane ? 2 : 1;
			unsigned x0 = (unsigned)sr.origin.x / div, y0 = (unsigned)sr.origin.y / div, w = (unsigned)sr.size.width / div,
			         h = (unsigned)sr.size.height / div;
			unsigned X0 = (unsigned)dr.origin.x / div, Y0 = (unsigned)dr.origin.y / div, W = (unsigned)dr.size.width / div,
			         H = (unsigned)dr.size.height / div;
			if (!w || !h || !W || !H)
				continue;
			uint16_t *a = malloc((size_t)w * h * comps * 2), *b = malloc((size_t)W * H * comps * 2);
			if (!a || !b) {
				err = -12786;
			} else {
				m2m_read_plane(src, plane, sk, comps, x0, y0, w, h, a);
				vImage_Buffer va = { a, h, w, (size_t)w * comps * 2 }, vb = { b, H, W, (size_t)W * comps * 2 };
				vImage_Error e = comps == 1 ? vImageScale_Planar16U(&va, &vb, NULL, kvImageHighQualityResampling)
				                            : vImageScale_CbCr16U(&va, &vb, NULL, kvImageHighQualityResampling);
				if (e != kvImageNoError)
					err = -12780;
				else
					m2m_write_plane(dst, plane, dk, comps, X0, Y0, W, H, b);
			}
			free(a);
			free(b);
		}
	}
	CVPixelBufferUnlockBaseAddress(dst, 0);
	CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
	static unsigned done;
	if (done++ < 6)
		say("m2m: %c%c%c%c %.0fx%.0f to %c%c%c%c %.0fx%.0f: %d", sf >> 24, sf >> 16 & 255, sf >> 8 & 255, sf & 255, sr.size.width,
		    sr.size.height, df >> 24, df >> 16 & 255, df >> 8 & 255, df & 255, dr.size.width, dr.size.height, err);
	/* how much of the CPU this costs: calls and milliseconds over each 5 s */
	static uint64_t t_window, busy_ns;
	static unsigned calls;
	uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC);
	busy_ns += now - t_start;
	calls++;
	if (!t_window)
		t_window = now;
	if (now - t_window > 5000000000ull) {
		say("m2m: %u transforms, %.0f ms of CPU in the last %.1f s", calls, busy_ns / 1e6, (now - t_window) / 1e9);
		t_window = now;
		busy_ns = 0;
		calls = 0;
	}
	return err;
}

static IMP gM2MInit, gM2MDealloc;

static id
m2m_init(id self, SEL sel)
{
	/* the accelerator first, as Apple's -init does; none here (IOServiceMatching fails for AppleM2ScalerCSCDriver), so the
	 * object is made without it. Apple's -init releases self when it fails: a second allocation then. */
	Class cls = object_getClass(self);
	id r = ((id(*)(id, SEL))gM2MInit)(self, sel);
	if (r)
		return r;
	r = class_createInstance(cls, 0);
	Ivar cap = class_getInstanceVariable(cls, "_cap");
	if (cap) {
		struct { int hTaps, vTaps, hPhases, vPhases, prePointBits, postPointBits; CGSize maxUpscale, maxDownscale; } *c =
		    (void *)((uint8_t *)r + ivar_getOffset(cap));
		c->hTaps = c->vTaps = 4;
		c->hPhases = c->vPhases = 16;
		c->prePointBits = c->postPointBits = 10;
		c->maxUpscale = CGSizeMake(8, 8);
		c->maxDownscale = CGSizeMake(64, 64);
	}
	static unsigned said;
	if (said++ < 3)
		say("m2m: FigM2MController made without the scaler: transforms on the CPU");
	return r;
}

static bool
m2m_is_soft(id self)
{
	Ivar a = class_getInstanceVariable(object_getClass(self), "_accelRef");
	return !a || !*(void **)((uint8_t *)self + ivar_getOffset(a));
}

static void
m2m_dealloc(id self, SEL sel)
{
	if (m2m_is_soft(self)) {
		struct objc_super sup = { self, class_getSuperclass(object_getClass(self)) };
		((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&sup, sel);
		return;
	}
	((void (*)(id, SEL))gM2MDealloc)(self, sel);
}

static void
hook_m2m(void)
{
	Class c = objc_getClass("FigM2MController");
	if (!c)
		return;
	Method m;
	if ((m = class_getInstanceMethod(c, sel_registerName("init"))))
		gM2MInit = method_setImplementation(m, (IMP)m2m_init);
	if ((m = class_getInstanceMethod(c, sel_registerName("dealloc"))))
		gM2MDealloc = method_setImplementation(m, (IMP)m2m_dealloc);
	struct { const char *sel; id block; } t[] = {
		{ "transform:srcRect:dst:sync_m2m:", ^int(id self, CVPixelBufferRef a, CGRect sr, CVPixelBufferRef b, BOOL sync) {
			 return m2m_scale(a, sr, b, CGRectNull);
		 } },
		{ "transform:srcRect:dst:dstRect:rotate:sync_m2m:", ^int(id self, CVPixelBufferRef a, CGRect sr, CVPixelBufferRef b, CGRect dr,
		                                                          int rot, BOOL sync) {
			 return rot ? -12780 : m2m_scale(a, sr, b, dr);
		 } },
		{ "transform:srcRect:dst:dstRect:rotate:flipX:flipY:sync_m2m:", ^int(id self, CVPixelBufferRef a, CGRect sr, CVPixelBufferRef b,
		                                                                        CGRect dr, int rot, BOOL fx, BOOL fy, BOOL sync) {
			 return rot || fx || fy ? -12780 : m2m_scale(a, sr, b, dr);
		 } },
		{ "_transform:srcRect:dst:dstRect:symmetricTransform:sync_m2m:", ^int(id self, CVPixelBufferRef a, CGRect sr, CVPixelBufferRef b,
		                                                                         CGRect dr, unsigned sym, BOOL sync) {
			 return m2m_scale(a, sr, b, dr);
		 } },
		{ "downsample:dst:sync_m2m:", ^int(id self, CVPixelBufferRef a, CVPixelBufferRef b, BOOL sync) {
			 return m2m_scale(a, CGRectNull, b, CGRectNull);
		 } },
		{ "setCustomFilter:alignment:src:dst:luma_param:chroma_param:", ^int(id self, int f, int al, CVPixelBufferRef a, CVPixelBufferRef b,
		                                                                        float l, float ch) {
			 return 0;
		 } },
		{ "setCustomFilter:alignment:sourceWidth:sourceHeight:destinationWidth:destinationHeight:luma_param:chroma_param:",
		  ^int(id self, int f, int al, unsigned long sw, unsigned long sh, unsigned long dw, unsigned long dh, float l, float ch) {
			  return 0;
		  } },
		{ "unsetCustomFilter", ^void(id self) {} },
		{ "queryCapabilities", ^int(id self) { return 0; } },
	};
	for (unsigned i = 0; i < sizeof(t) / sizeof(t[0]); i++) {
		Method mm = class_getInstanceMethod(c, sel_registerName(t[i].sel));
		if (!mm)
			continue;
		IMP orig = method_getImplementation(mm);
		IMP soft = imp_implementationWithBlock(t[i].block);
		SEL sel = method_getName(mm);
		(void)sel;
		/* the hardware's own when there is one: chosen per call by the object */
		method_setImplementation(mm, soft);
		(void)orig;
	}
	say("m2m: FigM2MController falls back to the CPU");
}

/* the methods of a class (name and type encoding), once, for reading on the Mac */
static void
say_methods(const char *cls_name)
{
	Class cls = objc_getClass(cls_name);
	if (!cls) {
		say("methods: %{public}s not loaded", cls_name);
		return;
	}
	for (int meta = 0; meta < 2; meta++) {
		unsigned n = 0;
		Method *ms = class_copyMethodList(meta ? object_getClass((id)cls) : cls, &n);
		for (unsigned i = 0; i < n; i++)
			say("methods: %{public}s %{public}s%{public}s %{public}s", cls_name, meta ? "+" : "-", sel_getName(method_getName(ms[i])),
			    method_getTypeEncoding(ms[i]));
		free(ms);
	}
	unsigned n = 0;
	Ivar *iv = class_copyIvarList(cls, &n);
	for (unsigned i = 0; i < n; i++)
		say("methods: %{public}s ivar %{public}s %{public}s", cls_name, ivar_getName(iv[i]), ivar_getTypeEncoding(iv[i]));
	free(iv);
}

/*
 * Photographic/smart style rendering off: with FigColorCube working (Chlorophyll's RGB-over-YCbCr formats 540-545) every
 * preview frame went through a style stage drawing into a two-plane RGB8/RGB10_420_2P surface, which bgmtl encodes back on
 * the CPU (~0.6 s a 1734x1300 frame): frames piled up until the kernel's 1.5 GB of surfaces ran out. The source formats say
 * they cannot render styles, as the iPhone 11 they describe could not before iOS 26's styles came. /private/var/tmp/
 * sweetcam.styles leaves them on.
 */
static BOOL
answer_no(id self, SEL sel)
{
	(void)self;
	(void)sel;
	return NO;
}

static void
hook_styles(void)
{
	if (access("/private/var/tmp/sweetcam.styles", F_OK) == 0)
		return;
	static const char *const sels[] = { "isSemanticStyleRenderingSupported", "isSmartStyleRenderingSupported", "semanticRenderingSupported",
		"isApplyStandardSmartStyleForStillsWhenNoStyleRequestedSupported" };
	Class c = objc_getClass("FigCaptureSourceVideoFormat");
	unsigned n = 0;
	for (unsigned i = 0; c && i < sizeof(sels) / sizeof(sels[0]); i++) {
		Method m = class_getInstanceMethod(c, sel_registerName(sels[i]));
		if (m) {
			method_setImplementation(m, (IMP)answer_no);
			n++;
		}
	}
	say("styles: %u FigCaptureSourceVideoFormat answers made NO", n);
}

static void
hook(void)
{
	hook_nrf();
	hook_styles();
	hook_m2m();
	say_imps();
	if (access("/private/var/tmp/sweetcam.nilwatch", F_OK) == 0)
		say_methods("FigM2MController");
	static const ptrdiff_t ub_offs[] = { 144, 240, 248, 280 };
	say_ivars("BWUBNode", ub_offs, 4);
	nil_watch();
	Class g = objc_getClass("BWGraph");
	Method gm = g ? class_getInstanceMethod(g, sel_registerName("connectOutput:toInput:pipelineStage:deferredAttach:")) : NULL;
	if (gm) {
		gOrigConnect = method_setImplementation(gm, (IMP)connect_output);
	}
	Class c = objc_getClass("BWFigCaptureDeviceVendor");
	if (!c) {
		return;
	}
	Method m;
	if ((m = class_getClassMethod(c, sel_registerName("sharedCaptureDeviceVendorWithDefaultDeviceCreateFunction:")))) {
		gOrigSharedWith = method_setImplementation(m, (IMP)shared_with);
	}
	if ((m = class_getInstanceMethod(c, sel_registerName("initWithDefaultDeviceCreateFunction:")))) {
		gOrigInit1 = method_setImplementation(m, (IMP)init1);
	}
	if ((m = class_getInstanceMethod(c, sel_registerName("initWithDefaultDeviceCreateFunction:cmioExtensionDeviceCreateFunction:cmioDiscoverySession:")))) {
		gOrigInit3 = method_setImplementation(m, (IMP)init3);
	}
	say("vendor hooked (%d %d %d), BWGraph connect %d; kernel camera %d", gOrigSharedWith != NULL, gOrigInit1 != NULL,
	    gOrigInit3 != NULL, gOrigConnect != NULL, kernel_has_camera());
}

static void
image_added(const struct mach_header *mh, intptr_t slide)
{
	(void)slide;
	static bool done;
	Dl_info info;
	if (done || !dladdr(mh, &info) || !info.dli_fname || !strstr(info.dli_fname, "/CMCapture.framework/")) {
		return;
	}
	done = true;
	hook();
}

/* messages a class does not answer: said once, answered with zero (a method signature of v@:@ is assumed when none is known) */
static CFMutableSetRef lenient_said;

static NSMethodSignature *
lenient_signature(id self, SEL sel)
{
	(void)self;
	const char *n = sel_getName(sel);
	unsigned colons = 0;
	for (const char *c = n; *c; c++) {
		colons += *c == ':';
	}
	char types[64] = "@@:";
	for (unsigned i = 0; i < colons && i < 8; i++) {
		strlcat(types, "@", sizeof(types));
	}
	return [NSMethodSignature signatureWithObjCTypes:types];
}

static void
lenient_forward(id self, SEL sel, NSInvocation *inv)
{
	(void)sel;
	SEL s = inv.selector;
	CFStringRef name = CFStringCreateWithFormat(NULL, NULL, CFSTR("%s %s"), class_getName(object_getClass(self)), sel_getName(s));
	if (!lenient_said) {
		lenient_said = CFSetCreateMutable(NULL, 0, &kCFTypeSetCallBacks);
	}
	if (!CFSetContainsValue(lenient_said, name)) {
		CFSetAddValue(lenient_said, name);
		say("Metal: %{public}@ not implemented: answered nil", (NSString *)name);
	}
	CFRelease(name);
	id zero = nil;
	[inv setReturnValue:&zero];
}

static void
q_set_completion_queue(id self, SEL sel, id queue)
{
	(void)self;
	(void)sel;
	(void)queue;
}

static id
q_completion_queue(id self, SEL sel)
{
	(void)self;
	(void)sel;
	return nil;
}

/* the no-op every unknown selector of a lenient class gets: arguments ignored, zero returned (nil, NO, 0) */
static uint64_t
zero_imp(id self, SEL sel)
{
	(void)self;
	(void)sel;
	return 0;
}

static BOOL
lenient_resolve(id cls, SEL sel, SEL wanted)
{
	(void)sel;
	const char *n = sel_getName(wanted);
	if (!n || n[0] == '_' || !strncmp(n, "init", 4) || !strncmp(n, "retain", 6) || !strncmp(n, "release", 7) ||
	    !strcmp(n, "dealloc") || !strncmp(n, "copy", 4) || !strncmp(n, "new", 3)) {
		return NO;
	}
	unsigned colons = 0;
	for (const char *c = n; *c; c++) {
		colons += *c == ':';
	}
	char types[16] = "Q@:";
	for (unsigned i = 0; i < colons && i < 8; i++) {
		strlcat(types, "Q", sizeof(types));
	}
	class_addMethod((Class)cls, wanted, (IMP)zero_imp, types);
	say("Metal: %{public}s -%{public}s not implemented: a no-op returning 0", class_getName((Class)cls), n);
	return YES;
}

static void
lenient(Class c)
{
	if (!c) {
		return;
	}
	class_addMethod(object_getClass((id)c), @selector(resolveInstanceMethod:), (IMP)lenient_resolve, "c@::");
	class_addMethod(c, @selector(methodSignatureForSelector:), (IMP)lenient_signature, "@@::");
	class_addMethod(c, @selector(forwardInvocation:), (IMP)lenient_forward, "v@:@");
	/* class_addMethod does not replace a method the class has itself: the superclass's (NSObject's) is what is replaced here */
}

/*
 * A Metal device in cameracaptured: iOS 26's preview sink pipeline bails without one (Fig assert "metalDevice",
 * FigCapturePreviewSinkPipeline.m:740), and the graph then lacks the preview's video thumbnail and movie outputs. The
 * Bergamota device (Chlorophyll's BGMTLDevice, gpu/metal) is made and registered here the way bgmtl-inject.dylib does it
 * for its own allow-list: the same gates (armed, no kill switch, GPU ready), MTLCopyAllDevices first, CoreImage's MTL DAG
 * and MPS off, then MTLAddDevice in this process only.
 */
static void
metal_device(void)
{
	if (access("/private/var/tmp/bgmtl.arm", F_OK) != 0 || access("/private/var/tmp/bgmtl.off", F_OK) == 0) {
		say("Metal: Bergamota device not armed (or switched off): none");
		return;
	}
	/* a camera build of the driver when one is installed (Chlorophyll changes tried in cameracaptured before the rest of
	 * the phone gets them), else the phone's own */
	const char *drv = access("/usr/local/lib/bgmtl-cam/bgmtl-inject.dylib", R_OK) == 0 ? "/usr/local/lib/bgmtl-cam/bgmtl-inject.dylib"
	                                                                                     : "/usr/local/lib/bgmtl/bgmtl-inject.dylib";
	/* bgmtl's trace for this process only (one line per command buffer, pass and pipeline: bgmtl-trace-<pid>.txt) */
	if (access("/private/var/tmp/sweetcam.mtltrace", F_OK) == 0)
		setenv("BGMTL_TRACE", "1", 1);
	/*
	 * the preview stages that the camera's pipeline does without, refused as they were before Chlorophyll could build them:
	 * the Metal stand-in for the missing rotation hardware (VTPixelRotationSession's transform shaders) and the colour cube;
	 * built, they ran every preview frame at about 6 a second here and the frames waiting for them filled the surfaces.
	 * VTMTSComputeFunction: VideoToolbox's Metal pixel transfer (each 1734x1300 preview frame to the 828x1792 portrait one
	 * the screen shows) wrote luma-like values into the chroma plane (green and magenta preview, 2026-11-09) and spent 80 ms
	 * a frame decoding its source on the CPU; refused, VideoToolbox converts on the CPU as with the phone's own driver.
	 * VTMTSComputeFunction1x1: its scaler for the photo (NRF's 2016x1512 output to the 1924x1444 picture and the thumbnails)
	 * asks for 2048 threads a threadgroup, past the GPU's 1024: nothing was written and the JPEG came out green.
	 * /private/var/tmp/sweetcam.allstages: nothing refused
	 */
	if (access("/private/var/tmp/sweetcam.allstages", F_OK) != 0)
	{
		/* the list: /private/var/tmp/sweetcam.deny (one line, comma-separated) when present, else these */
		char deny[1024] = "fragmentTransformYUV,fragmentTransformRGBA,fragmentTransformY,fragmentTransformUV,fragmentTransformYY,"
		                  "colorCubeFragment2D,VCPRender,VCPDownsample,VTMTSComputeFunction,VTMTSComputeFunction1x1";
		FILE *df = fopen("/private/var/tmp/sweetcam.deny", "r");
		if (df) {
			if (fgets(deny, sizeof(deny), df)) {
				deny[strcspn(deny, "\r\n")] = 0;
			}
			fclose(df);
		}
		setenv("BGMTL_DENY", deny, 1);
		say("Metal: refused here: %{public}s", deny);
	}
	void *h = dlopen(drv, RTLD_NOW);
	say("Metal: driver %{public}s", drv);
	int (*state)(unsigned *) = h ? dlsym(h, "bgmtl_gpu_state") : NULL;
	id (*create)(void) = h ? dlsym(h, "bgmtl_create_device") : NULL;
	void (*add)(id) = dlsym(RTLD_DEFAULT, "MTLAddDevice");
	NSArray *(*all)(void) = dlsym(RTLD_DEFAULT, "MTLCopyAllDevices");
	unsigned minor = 0;
	if (!state || !create || !add || !all) {
		say("Metal: Bergamota device not available (%{public}s)", h ? "symbols missing" : dlerror());
		return;
	}
	int st = state(&minor);
	if (st != 1) {
		say("Metal: GPU state %d (1 = ready): no device", st);
		return;
	}
	NSArray *pre = all();
	NSUInteger had = pre.count;
	[pre release];
	if (had) {
		say("Metal: %lu device(s) already", (unsigned long)had);
		return;
	}
	setenv("CI_USE_MTL_DAG_FOR_CIKL_SRC", "0", 0);
	setenv("CI_ENABLE_MPS", "0", 0);
	id dev = create();
	if (!dev) {
		say("Metal: no device could be made");
		return;
	}
	add(dev);
	say("Metal: %{public}@ registered in cameracaptured", [dev description]);
	hook_specialise();
	/* CoreMedia's CMMTLCommandQueue forwards Apple's private queue methods (setCompletionQueue: ...) that Chlorophyll's queue
	 * does not have: such messages are taken here (said once a selector) and answered with zero */
	id q = [dev performSelector:@selector(newCommandQueue)];
	if (q) {
		lenient(object_getClass(q));
		/* CMMTLCommandQueue asks respondsToSelector: first: these are added as real methods */
		class_addMethod(object_getClass(q), sel_registerName("setCompletionQueue:"), (IMP)q_set_completion_queue, "v@:@");
		class_addMethod(object_getClass(q), sel_registerName("completionQueue"), (IMP)q_completion_queue, "@@:");
		id cb = [q performSelector:@selector(commandBuffer)];
		if (cb) {
			lenient(object_getClass(cb));
		}
		[q release];
	}
	lenient(object_getClass(dev));
}

static NSUncaughtExceptionHandler *gPrevHandler;

static void
uncaught(NSException *e)
{
	os_log_error(gLog, "sweetcam: UNCAUGHT %{public}@: %{public}@", e.name, e.reason);
	NSArray *st = e.callStackSymbols;
	for (NSUInteger i = 0; i < st.count && i < 24; i++) {
		os_log_error(gLog, "sweetcam:   %{public}@", st[i]);
	}
	if (gPrevHandler) {
		gPrevHandler(e);
	}
}

__attribute__((constructor)) static void
sweetcam_init(void)
{
	gLog = os_log_create("com.sweet.cam", "camera");
	say("loaded into %{public}s", getprogname());
	gPrevHandler = NSGetUncaughtExceptionHandler();
	NSSetUncaughtExceptionHandler(uncaught);
	if (!strcmp(getprogname(), "cameracaptured")) {
		@autoreleasepool {
			metal_device();
		}
	}
	_dyld_register_func_for_add_image(image_added);
}
