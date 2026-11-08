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
static CFStringRef port_back;
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

static int
kernel_stream(int on)
{
	if (sysctlbyname("kern.sweet_cam_stream", NULL, NULL, &on, sizeof(on)) == 0) {
		return 0;
	}
	int e = errno;
	if (on && e == EIO) {
		/*
		 * no sensor sequence loaded yet (it is the phone vendor's, kept out of the image): loaded from a file on the phone
		 * (xnu 3082+ lets cameracaptured write kern.sweet_cam_seq; before, only root could)
		 */
		static const char *const paths[] = { "/usr/local/share/sweetcam/imx363-mode2.seq", "/var/root/imx363-mode2.seq" };
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

/* ---- pictures from RAW10 ------------------------------------------------------------------------------------------------ */

#define HW 960                          /* half of 1920x1080: one RGB value per 2x2 Bayer cell */
#define HH 540

struct isp {
	float wb[3];                    /* red, green, blue gains (grey world, smoothed) */
	float mean;                     /* the last frame's mean green above black, 0-1 of the range (for the metadata) */
	uint8_t gamma[4096];            /* linear (0-4095 over the sensor's range above black) to sRGB 8 bits */
	uint8_t *rgb;                   /* HW x HH x 3 */
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
	}
	p->rgb = malloc(HW * HH * 3);
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
	float m[9];                     /* colour matrix with the white balance and the scale to 0-4095 folded in */
	uint64_t sum[16][3];            /* per piece: R, G, B above black (for the next white balance) */
};

static void
half_piece(void *ctx, size_t piece)
{
	struct half_job *j = ctx;
	unsigned y0 = (unsigned)piece * (HH / 16), y1 = y0 + HH / 16;
	uint64_t sr = 0, sg = 0, sb = 0;
	for (unsigned y = y0; y < y1; y++) {
		const uint8_t *r0 = j->raw + (size_t)(2 * y) * j->stride, *r1 = r0 + j->stride;
		uint8_t *o = j->p->rgb + (size_t)y * HW * 3;
		for (unsigned x = 0; x < HW; x++) {
			int R = (int)raw10_at(r0, 2 * x) - (int)j->black;
			int G = (((int)raw10_at(r0, 2 * x + 1) + (int)raw10_at(r1, 2 * x)) >> 1) - (int)j->black;
			int B = (int)raw10_at(r1, 2 * x + 1) - (int)j->black;
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
	struct half_job j = { .p = p, .raw = raw, .stride = h->stride, .black = h->black };
	float scale = 4095.0f / (float)(h->white - h->black);
	for (int r = 0; r < 3; r++) {
		for (int c = 0; c < 3; c++) {
			j.m[r * 3 + c] = ccm[r * 3 + c] * p->wb[c] * scale;
		}
	}
	dispatch_apply_f(16, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), &j, half_piece);
	uint64_t s[3] = { 0, 0, 0 };
	for (int i = 0; i < 16; i++) {
		for (int c = 0; c < 3; c++) {
			s[c] += j.sum[i][c];
		}
	}
	p->mean = (float)s[1] / ((float)HW * HH * (float)(h->white - h->black));
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
	x0 = x0 < 0 ? 0 : x0 > HW - 2 ? HW - 2 : x0;
	y0 = y0 < 0 ? 0 : y0 > HH - 2 ? HH - 2 : y0;
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
format_from(CFStringRef name, CFDictionaryRef entry)
{
	CFMutableDictionaryRef f = CFDictionaryCreateMutableCopy(NULL, 0, entry);
	CFDictionaryRemoveValue(f, CFSTR("DepthCompanionFormat"));
	CFDictionaryRemoveValue(f, CFSTR("FESCompanionFormats"));
	CFDictionaryRemoveValue(f, CFSTR("NonSIFRCompanionFormat"));
	int64_t sw = get_i(entry, "SensorWidth", 4032), sh = get_i(entry, "SensorHeight", 3024);
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
	put(f, "PreGDCSensorCropWidth", num_i(sw));
	put(f, "PreGDCSensorCropHeight", num_i(sh));
	put(f, "PostGDCCropWidth", num_i(sw));
	put(f, "PostGDCCropHeight", num_i(sh));
	put(f, "GeometricDistortionCorrectedNativeWidth", num_i(sw));
	put(f, "GeometricDistortionCorrectedNativeHeight", num_i(sh));
	CFMutableDictionaryRef outputs = new_dict();
	int64_t ow = get_i(entry, "HighQualitySensorWidth", sw), oh = get_i(entry, "HighQualitySensorHeight", sh);
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

/* the back camera's stream formats of the model's AVCaptureSession.plist (the device entry with "Photo" and autofocus) */
static CFArrayRef
formats_of_model(void)
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
		if (![dev[@"hasAutoFocus"] boolValue] || !fs[@"Photo"]) {
			continue;
		}
		for (NSString *name in [[fs allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
			CFDictionaryRef f = format_from((__bridge CFStringRef)name, (__bridge CFDictionaryRef)fs[name]);
			CFArrayAppendValue(all, f);
			CFRelease(f);
		}
		say("%ld stream formats from %{public}@", (long)CFArrayGetCount(all), model);
		break;
	}
	}
	if (CFArrayGetCount(all) == 0) {
		CFMutableDictionaryRef e = new_dict();
		put(e, "SensorWidth", num_i(4032));
		put(e, "SensorHeight", num_i(3024));
		put(e, "MaxFrameRate", num_i(30));
		CFDictionaryRef f = format_from(CFSTR("Photo"), e);
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
		value = CFRetain(port_back);
	} else if (key_is(key, "ModuleInfo")) {
		/* the iPhone 11's back camera in N104/CameraSetup.plist: sensor 0x0503, FocalLengthCharacterization LensID 1, ActuatorID 1 */
		CFMutableDictionaryRef info = new_dict();
		put(info, "sensorID", num_i(0x0503));
		put(info, "ModuleLensID", num_i(1));
		put(info, "ModuleActuatorID", num_i(1));
		put(info, "ModuleIntegratorID", num_i(1));
		put(info, "ModuleFocusID", num_i(1));
		put(info, "ModuleIDSchemeVersion", num_i(1));
		value = info;
	} else if (key_is(key, "UniqueID") || key_is(key, "ModelID")) {
		value = CFRetain(CFSTR("com.apple.avfoundation.avcapturedevice.built-in_video:0"));
	} else if (key_is(key, "NonLocalizedName") || key_is(key, "LocalizedName")) {
		value = CFRetain(CFSTR("Back Camera"));
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
		value = num_f(4.25);            /* the iPhone 11 wide camera's, millimetres */
	} else if (key_is(key, "LensFNumber")) {
		value = num_f(1.8);
	} else if (key_is(key, "PixelSize")) {
		value = num_f(1.4);             /* required (BWFigVideoCaptureStream's init); the IMX363's pitch in micrometres */
	} else if (key_is(key, "MaxZoomFactor")) {
		value = num_f(16);
	} else if (key_is(key, "ZoomFactor")) {
		value = num_f(1);
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
				if (out->config) {
					CFRelease(out->config);
				}
				out->config = CFGetTypeID(values[i]) == CFDictionaryGetTypeID() ? CFRetain(values[i]) : NULL;
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
frame_metadata(const struct cam_live_hdr *h, const struct isp *p, uint64_t host_time)
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
	md_f(d, "FocalLength", 4.25);
	md_f(d, "Fnumber", 1.8);
	md_i(d, "FocalLenIn35mmFilm", 26);
	md_v(d, "PortType", port_back);
	md_i(d, "SensorID", 0x0503);
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
		if (CVPixelBufferPoolCreatePixelBuffer(NULL, (CVPixelBufferPoolRef)gp, &pb) != kCVReturnSuccess) {
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
	j.cx = (HW - j.cw) / 2;
	j.cy = (HH - j.ch) / 2;
	dispatch_apply_f(j.pieces, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), &j, render_piece);
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
	int e = kernel_stream(1);
	if (e || !isp.ready || sysctlbyname("kern.sweet_cam_live", NULL, &cap, NULL, 0) != 0) {
		say("the kernel's camera does not stream (%{public}s): no frames", strerror(e ? e : errno));
		free(isp.rgb);
		return NULL;
	}
	uint8_t *buf = malloc(cap);
	say("worker: streaming (%zu-byte frames)", cap);
	unsigned fails = 0;
	while (s->running && buf && fails < 20) {
		size_t len = cap;
		if (sysctlbyname("kern.sweet_cam_live", buf, &len, &last, sizeof(last)) != 0) {
			fails++;
			usleep(20000);
			continue;
		}
		const struct cam_live_hdr *h = (const void *)buf;
		if (h->magic != 0x4d414353u || h->seq == last || len < h->hdr_size + (size_t)h->stride * h->height) {
			continue;
		}
		fails = 0;
		last = h->seq;
		s->frames++;
		isp_half(&isp, h, buf + h->hdr_size);
		uint64_t host = h->timestamp_ns * tb.denom / tb.numer;
		CMTime pts = CMClockMakeHostTimeFromSystemUnits(host);
		CFDictionaryRef md = frame_metadata(h, &isp, host);
		pthread_mutex_lock(&s->lock);
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
		if (s->frames <= 2 || s->frames % 300 == 0) {
			say("frame %u: %u lines x %.1f x %.2f, lens %u; white balance R %.2f B %.2f; outputs %d%d%d%d enabled %d%d%d%d, delivering %d",
			    h->seq, h->exposure_lines, h->again_x256 / 256.0, h->dgain_x256 / 256.0, h->lens, isp.wb[0], isp.wb[2],
			    s->out[0].handler != NULL, s->out[1].handler != NULL, s->out[2].handler != NULL, s->out[3].handler != NULL,
			    s->out[0].enabled, s->out[1].enabled, s->out[2].enabled, s->out[3].enabled, s->delivering);
		}
	}
	free(buf);
	free(isp.rgb);
	(void)kernel_stream(0);
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
	(void)o;
	return CFRetain(CFSTR("<SweetCaptureStream: the Mi 8's rear main camera>"));
}

static const struct base_class stream_base = {
	1, sizeof(struct stream), NULL, stream_invalidate, stream_finalize, stream_description, stream_copy_property, stream_set_property,
	NULL, NULL, NULL
};
static const struct stream_class stream_derived = { 2, stream_start, stream_stop, stream_add_attachments };
static const struct vtable stream_vtable = { NULL, &stream_base, &stream_derived };

static CMBaseObjectRef
stream_create(CFAllocatorRef allocator)
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
	s->formats = formats_of_model();
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
	/* (HakiOS: the graph configures the stream, then reserves it here; the frames start from here and from Start) */
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
	CMBaseObjectRef stream = stream_create(allocator), device = NULL;
	if (!stream) {
		return ERR_UNSUPPORTED;
	}
	if (derived_create(allocator, &device_vtable, device_class_id(), &device) != 0 || !device) {
		CFRelease(stream);
		say("the device cannot be made");
		return ERR_UNSUPPORTED;
	}
	struct device *d = derived_storage(device);
	memset(d, 0, sizeof(*d));
	d->streams = CFArrayCreate(NULL, (const void **)&stream, 1, &kCFTypeArrayCallBacks);
	d->supported = supported(device_props, sizeof(device_props) / sizeof(device_props[0]));
	CFRelease(stream);
	*out = device;
	say("device made: one stream, the back camera");
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
 * ("Failed to setup processor coordinator -- all processing will fail!", photos end with -16808). The scheme is forced to
 * the number in /private/var/tmp/sweetcam.nrf (0 without the file).
 */
static IMP gOrigSetNRF[3];

static int
forced_nrf(void)
{
	FILE *f = fopen("/private/var/tmp/sweetcam.nrf", "r");
	int v = 0;
	if (f) {
		if (fscanf(f, "%d", &v) != 1) {
			v = 0;
		}
		fclose(f);
	}
	return v;
}

#define NRF_SETTER(n, cls)                                                                                                     \
	static void set_nrf##n(id self, SEL sel, int scheme)                                                                   \
	{                                                                                                                      \
		int v = forced_nrf();                                                                                          \
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

static void
hook(void)
{
	hook_nrf();
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
	void *h = dlopen("/usr/local/lib/bgmtl/bgmtl-inject.dylib", RTLD_NOW);
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
