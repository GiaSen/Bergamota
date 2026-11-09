/*
 * sweetzoom.dylib: in Camera.app (weak-linked into /Applications/Camera.app/Camera), a tap on the zoom button at 1x goes
 * to 2x, where sweetcam.dylib (in cameracaptured) switches the back camera to the Mi 8's telephoto.
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
 * /private/var/tmp/sweetzoom.off: Apple's behaviour. Log: subsystem com.sweet.zoom.
 * iOS 26, arm64e + pacstrip (tools/sweetnet/build.sh); installed by tools/renegade/link_weak.py (by hand) or the root
 * image build (root_tweaks18.camera_zoom).
 */
#import <Foundation/Foundation.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <os/log.h>
#include <unistd.h>

static os_log_t gLog;
static IMP gOrig;

#define TELE_ZOOM 2.0   /* where sweetcam's back stream goes to the telephoto sensor */

static void
zoom_toggle(id self, SEL sel, id control)
{
	SEL pos = sel_registerName("_currentDevicePosition"), set = sel_registerName("_setZoomFactor:interactionType:shouldNotifyDelegate:animated:");
	SEL max = sel_registerName("maximumZoomFactor");
	bool back = [self respondsToSelector:pos] && ((long (*)(id, SEL))objc_msgSend)(self, pos) == 0;
	if (!back || access("/private/var/tmp/sweetzoom.off", F_OK) == 0 || ![control respondsToSelector:set] || ![control respondsToSelector:max] ||
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
	Class c = objc_getClass("CAMViewfinderViewController");
	Method m = c ? class_getInstanceMethod(c, sel_registerName("toggleBetweenZoomFactorsForZoomControl:")) : NULL;
	if (!m) {
		os_log(gLog, "sweetzoom: no -[CAMViewfinderViewController toggleBetweenZoomFactorsForZoomControl:] here: nothing changed");
		return;
	}
	gOrig = method_setImplementation(m, (IMP)zoom_toggle);
	os_log(gLog, "sweetzoom: loaded into %{public}s: a tap on the back camera's zoom button at 1x goes to %.1fx", getprogname(), TELE_ZOOM);
}
