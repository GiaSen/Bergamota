/*
 * What Camera.app's capability object (CameraUI's CAMCaptureCapabilities) answers on this phone, outside Camera: the
 * answers that decide what a tap on the zoom button does (-[CAMViewfinderViewController toggleBetweenZoomFactors...] and
 * -[CAMCaptureCapabilities shouldAllowCameraToggleForMode:...]).
 *   xcrun -sdk iphoneos clang -arch arm64e -mios-version-min=18.0 -fobjc-arc -framework Foundation camcaps.m -o camcaps
 *   codesign -s - -f camcaps && python3 tools/renegade/pacstrip.py --sign camcaps; copy to the phone, run as root or mobile
 */
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <stdio.h>

static long
ask(id o, const char *sel, int nargs, long a, long b, long c, long d, long e)
{
	SEL s = sel_registerName(sel);
	if (![o respondsToSelector:s]) {
		return -99;
	}
	switch (nargs) {
	case 0: return ((long (*)(id, SEL))objc_msgSend)(o, s) & 0xff;
	case 1: return ((long (*)(id, SEL, long))objc_msgSend)(o, s, a) & 0xff;
	case 3: return ((long (*)(id, SEL, long, long, long))objc_msgSend)(o, s, a, b, c) & 0xff;
	case 4: return ((long (*)(id, SEL, long, long, long, long))objc_msgSend)(o, s, a, b, c, d) & 0xff;
	default: return ((long (*)(id, SEL, long, long, long, long, long))objc_msgSend)(o, s, a, b, c, d, e) & 0xff;
	}
}

int
main(void)
{
	@autoreleasepool {
		if (!dlopen("/System/Library/PrivateFrameworks/CameraUI.framework/CameraUI", RTLD_NOW)) {
			fprintf(stderr, "%s\n", dlerror());
			return 1;
		}
		Class c = objc_getClass("CAMCaptureCapabilities");
		id caps = ((id (*)(id, SEL))objc_msgSend)((id)c, sel_registerName("capabilities"));
		if (!caps) {
			fprintf(stderr, "no capabilities object\n");
			return 1;
		}
		static const char *const plain[] = { "isBackWideDualSupported", "isWideDualSupported", "isBackSuperWideSupported", "isSuperWideSupported",
			                             "isBackTelephotoSupported", "isTelephotoSupported", "isBackDualSupported", "isDualSupported",
			                             "isFrontCameraSupported", "isBackCameraSupported", "fallbackCameraSupported",
			                             "fallbackCameraEnabled", "featureDevelopmentForceSingleCamera", "isFrontWideDualSupported",
			                             "isFrontSuperWideSupported", "isBackTripleCameraSupported" };
		for (unsigned i = 0; i < sizeof(plain) / sizeof(plain[0]); i++) {
			printf("%-44s %ld\n", plain[i], ask(caps, plain[i], 0, 0, 0, 0, 0, 0));
		}
		SEL fb = sel_registerName("_forcedBackCamera");
		printf("%-44s %ld\n", "_forcedBackCamera", [caps respondsToSelector:fb] ? ((long (*)(id, SEL))objc_msgSend)(caps, fb) : -99);
		id mods = ((id (*)(id, SEL))objc_msgSend)(caps, sel_registerName("getSupportedCameraModules"));
		printf("getSupportedCameraModules: %s\n", [[mods description] UTF8String]);
		id fbm = ((id (*)(id, SEL))objc_msgSend)(caps, sel_registerName("fallbackCameraModules"));
		printf("fallbackCameraModules: %s\n", [[fbm description] UTF8String]);
		/* mode 0 = Photo, position 0 = back, video configuration 0, stabilization strength 0 */
		printf("%-44s %ld\n", "isWideDualSupportedForDevicePosition:0", ask(caps, "isWideDualSupportedForDevicePosition:", 1, 0, 0, 0, 0, 0));
		printf("%-44s %ld\n", "isSuperWideSupportedForDevicePosition:0", ask(caps, "isSuperWideSupportedForDevicePosition:", 1, 0, 0, 0, 0, 0));
		printf("%-44s %ld\n", "isTelephotoSupportedForDevicePosition:0", ask(caps, "isTelephotoSupportedForDevicePosition:", 1, 0, 0, 0, 0, 0));
		printf("%-44s %ld\n", "_needsForcedSingleCameraEmulation(0,0,0)",
		    ask(caps, "_needsForcedSingleCameraEmulationForVideoStabilizationStrength:videoConfiguration:mode:", 3, 0, 0, 0, 0, 0));
		printf("%-44s %ld\n", "isWideDualSupportedForMode(photo, back)",
		    ask(caps, "isWideDualSupportedForMode:devicePosition:videoConfiguration:videoStabilizationStrength:", 4, 0, 0, 0, 0, 0));
		printf("%-44s %ld\n", "isDualSupportedForMode(photo, back)",
		    ask(caps, "isDualSupportedForMode:devicePosition:videoConfiguration:videoStabilizationStrength:", 4, 0, 0, 0, 0, 0));
		printf("%-44s %ld\n", "_isSuperWideZoomSupportedForMode(photo,back)",
		    ask(caps, "_isSuperWideZoomSupportedForMode:devicePosition:videoConfiguration:", 3, 0, 0, 0, 0, 0));
		printf("%-44s %ld\n", "shouldAllowCameraToggle(photo, back)",
		    ask(caps, "shouldAllowCameraToggleForMode:devicePosition:videoConfiguration:videoStabilizationStrength:frontRearSimultaneousVideoEnabled:", 5,
		    0, 0, 0, 0, 0));
		SEL pd = sel_registerName("preferredDeviceForPosition:mode:videoConfiguration:videoStabilizationStrength:frontRearSimultaneousVideoEnabled:");
		if ([caps respondsToSelector:pd]) {
			printf("%-44s %ld\n", "preferredDeviceForPosition(back, photo)",
			    ((long (*)(id, SEL, long, long, long, long, long))objc_msgSend)(caps, pd, 0, 0, 0, 0, 0));
		}
	}
	return 0;
}
