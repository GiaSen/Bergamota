/*
 * sweetzoom.dylib: in Camera.app (weak-linked into /Applications/Camera.app/Camera), the back camera opens at 1x and a
 * tap on the zoom button at 1x goes to 2x, where sweetcam.dylib (in cameracaptured) switches the back camera to the Mi 8's
 * telephoto.
 *
 * Why (CameraUI of iOS 26.6.2 read with ipsw, 2026-11-10): as an iPhone 11 (N104) Camera wants the back "dual wide"
 * camera (0.5x + 1x), does not find it ("Failed to find device BackWideDual for mode Photo. Falling back to BackWide")
 * and runs the one back camera sweetcam offers, starting it at zoom factor 2, the dual wide camera's 1x: the viewfinder
 * opens at "2x", on the telephoto. Its zoom button then works as CAMZoomControl's single camera mode does
 * (-[CAMZoomControl _handleButtonTappedForSingleCameraZoomPlusToggle]): above the minimum zoom a tap goes back to it (1x);
 * at the minimum it asks the viewfinder to change camera, -[CAMViewfinderViewController
 * toggleBetweenZoomFactorsForZoomControl:], which for a back wide camera means the telephoto device when the phone has
 * one, else the super wide (-[... _toggleBetweenBackFacingZoomFactorsForZoomControl:]): "Will change to:
 * Photo/BackSuperWide", "Failed to find device BackSuperWide", nothing happens. The Mi 8 has neither as an iPhone device:
 * its telephoto is the back camera's zoom from 2x up. So for the back camera that request becomes the zoom control's own
 * zoom change to 2 (the call its other tap handlers make), which Camera ramps as it does a drag.
 * The front camera's button (-[... _toggleBetweenFrontFacingZoomFactorsForZoomControl:]) is left as it is.
 *
 * Opening at 1x (user, 2026-11-10: "Yes, open at 1x"): the zoom factor 2 at the start is -[CAMCaptureCapabilities
 * defaultZoomFactorForMode:device:...] answering the dual wide camera's switch-over factor because [self
 * resolvedDeviceForDesiredDevice:...] says BackWideDual (6). That answer, and preferredDeviceForPosition:...'s, become
 * BackWide (2) when they are BackWideDual or BackSuperWide (5): Camera asks for the camera that is there (no failed
 * lookup, no fallback) and starts it at its own default, 1. What Camera does once it runs on BackWide is what it did
 * after its fallback before.
 *
 * Movies in H.264 (2026-11-10, video recording): Camera set to "Most Compatible" wants avc1, but
 * +[AVCaptureMovieFileOutput availableVideoCodecTypesForSourceDevice:sourceFormat:outputDimensions:fileType:
 * videoCodecTypesAllowList:] leaves H.264 out when the camera says it supports HEVC and the format's size times its frame
 * rate is over H.264's limit (the 12 MP "Photo" stream format that video mode runs on here), and Camera then records HEVC
 * ("Failed to find desired codec avc1, using default of hvc1"). The phone's only encoder is H.264 (sweetavc.dylib, x264, in
 * cameracaptured; Apple's HEVC and H.264 encoders are drivers for a chip it does not have), so that list is made to be
 * H.264 first and no HEVC, unless an allow list leaves H.264 out.
 *
 * /private/var/tmp/sweetzoom.off (looked at when Camera starts): Apple's behaviour. Log: subsystem com.sweet.zoom.
 * iOS 26, arm64e + pacstrip (tools/sweetnet/build.sh); installed by tools/renegade/link_weak.py (by hand) or the root
 * image build (root_tweaks18.camera_zoom).
 */
#import <Foundation/Foundation.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <os/log.h>
#include <stdatomic.h>
#include <unistd.h>

static os_log_t gLog;
static IMP gOrig, gOrigResolved, gOrigPreferred, gOrigCodecs;

struct dims { int w, h; };

static id
movie_codecs(id self, SEL sel, id device, id format, struct dims d, id file_type, id allow)
{
	NSArray *apple = ((id (*)(id, SEL, id, id, struct dims, id, id))gOrigCodecs)(self, sel, device, format, d, file_type, allow);
	if (!apple || (allow && ![allow containsObject:@"avc1"])) {
		return apple;
	}
	NSMutableArray *ours = [NSMutableArray arrayWithObject:@"avc1"];
	for (id c in apple) {
		if (![c isEqual:@"avc1"] && ![c isEqual:@"hvc1"]) {
			[ours addObject:c];
		}
	}
	static _Atomic unsigned said;
	if (said++ < 2) {
		os_log(gLog, "sweetzoom: movie codecs for %dx%d: Apple's list %{public}@, ours %{public}@", d.w, d.h, [apple componentsJoinedByString:@" "],
		    [ours componentsJoinedByString:@" "]);
	}
	return ours;
}

/* CameraUI's camera numbers (CAMCaptureDevice), as its logs name them */
enum { DEV_BACK_WIDE = 2, DEV_BACK_SUPER_WIDE = 5, DEV_BACK_WIDE_DUAL = 6 };

static long
the_back_camera(long device, const char *asked_by)
{
	static _Atomic unsigned said;
	if (device != DEV_BACK_WIDE_DUAL && device != DEV_BACK_SUPER_WIDE) {
		return device;
	}
	if (said++ < 2) {
		os_log(gLog, "sweetzoom: %{public}s said camera %ld (the iPhone 11's dual wide or super wide): the back wide camera instead", asked_by, device);
	}
	return DEV_BACK_WIDE;
}

static long
resolved_device(id self, SEL sel, long device, long mode, long video, long strength, BOOL front_rear)
{
	return the_back_camera(((long (*)(id, SEL, long, long, long, long, BOOL))gOrigResolved)(self, sel, device, mode, video, strength, front_rear),
	           "resolvedDeviceForDesiredDevice");
}

static long
preferred_device(id self, SEL sel, long position, long mode, long video, long strength, BOOL front_rear)
{
	return the_back_camera(((long (*)(id, SEL, long, long, long, long, BOOL))gOrigPreferred)(self, sel, position, mode, video, strength, front_rear),
	           "preferredDeviceForPosition");
}

#define TELE_ZOOM 2.0   /* where sweetcam's back stream goes to the telephoto sensor */

static void
zoom_toggle(id self, SEL sel, id control)
{
	SEL pos = sel_registerName("_currentDevicePosition"), set = sel_registerName("_setZoomFactor:interactionType:shouldNotifyDelegate:animated:");
	SEL max = sel_registerName("maximumZoomFactor");
	bool back = [self respondsToSelector:pos] && ((long (*)(id, SEL))objc_msgSend)(self, pos) == 0;
	if (!back || ![control respondsToSelector:set] || ![control respondsToSelector:max] ||
	    ((double (*)(id, SEL))objc_msgSend)(control, max) < TELE_ZOOM) {
		((void (*)(id, SEL, id))gOrig)(self, sel, control);
		return;
	}
	os_log(gLog, "sweetzoom: the zoom button at its minimum, back camera: to %.1fx instead of another camera", TELE_ZOOM);
	/* interaction type 1, the delegate told, animated: as -[CAMZoomControl _handleButtonTappedForSingleCameraToggleOnly] calls it */
	((void (*)(id, SEL, double, long, BOOL, BOOL))objc_msgSend)(control, set, TELE_ZOOM, 1, YES, YES);
}

__attribute__((constructor)) static void
sweetzoom_init(void)
{
	gLog = os_log_create("com.sweet.zoom", "camera");
	if (access("/private/var/tmp/sweetzoom.off", F_OK) == 0) {
		os_log(gLog, "sweetzoom: /private/var/tmp/sweetzoom.off: nothing changed");
		return;
	}
	Class c = objc_getClass("CAMViewfinderViewController"), caps = objc_getClass("CAMCaptureCapabilities");
	Method m = c ? class_getInstanceMethod(c, sel_registerName("toggleBetweenZoomFactorsForZoomControl:")) : NULL;
	Method r = caps ? class_getInstanceMethod(caps, sel_registerName(
		    "resolvedDeviceForDesiredDevice:mode:videoConfiguration:videoStabilizationStrength:frontRearSimultaneousVideoEnabled:")) : NULL;
	Method p = caps ? class_getInstanceMethod(caps, sel_registerName(
		    "preferredDeviceForPosition:mode:videoConfiguration:videoStabilizationStrength:frontRearSimultaneousVideoEnabled:")) : NULL;
	if (m) {
		gOrig = method_setImplementation(m, (IMP)zoom_toggle);
	}
	if (r && p) {
		gOrigResolved = method_setImplementation(r, (IMP)resolved_device);
		gOrigPreferred = method_setImplementation(p, (IMP)preferred_device);
	}
	Class mfo = objc_getClass("AVCaptureMovieFileOutput");
	Method cm = mfo ? class_getClassMethod(mfo, sel_registerName(
		    "availableVideoCodecTypesForSourceDevice:sourceFormat:outputDimensions:fileType:videoCodecTypesAllowList:")) : NULL;
	if (cm) {
		gOrigCodecs = method_setImplementation(cm, (IMP)movie_codecs);
	}
	os_log(gLog, "sweetzoom: loaded into %{public}s: a tap on the back camera's zoom button at 1x goes to %.1fx (%{public}s), the back camera is the wide one and opens at 1x (%{public}s), movies in H.264 (%{public}s)",
	    getprogname(), TELE_ZOOM, m ? "yes" : "no such method here", r && p ? "yes" : "no such methods here", cm ? "yes" : "no such method here");
}
