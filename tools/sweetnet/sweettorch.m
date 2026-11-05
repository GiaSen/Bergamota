/*
 * sweettorch.dylib: the Mi 8's flashlight for iOS 26, inside cameracaptured.
 *
 * Control Center's flashlight button, AVFlashlight and Siri reach FigFlashlight (CMCapture) in cameracaptured over
 * com.apple.coremedia.flashlight. FigFlashlight asks the capture stack's device vendor
 * (+[BWFigCaptureDeviceVendor sharedCaptureDeviceVendor]) whether the default device is available to it
 * (-isActiveDefaultDeviceAvailableToFlashlight:, the FlashlightAvailable it posts), then for the camera device and the
 * back camera's stream, and sets the stream's torch level (0 to 1) with -setProperty:value:. This port has no camera, so
 * the vendor has no device to give. Here FigFlashlight, and only FigFlashlight's code (a caller between the exported
 * FigFlashlightCreate and the next exported function, both found with dlsym: no addresses), always gets a vendor of ours
 * whose stream sends the torch level to the kernel: kern.sweet_torch, thousandths (bsd/dev/dipper_haptics.c, xnu 3050,
 * sweethap=3). Every other caller gets Apple's vendor (or none), as before. Each distinct caller is logged once.
 *
 * Our vendor, device and stream answer the selectors FigFlashlight is known to send (iOS 26.6.2, disassembly of
 * FigFlashlight.m's device setup); any other message is logged and answered with zero, with the method signature of
 * Apple's own class (BWFigCaptureDeviceVendor, BWFigCaptureDevice, BWFigCaptureStream).
 *
 * The button only shows when MobileGestalt says camera-flash, i.e. the ADT has /product/camera "flash" (tools/mkadt.py,
 * tools/adt-haptics.py). Loaded by an LC_LOAD_WEAK_DYLIB in /usr/libexec/cameracaptured (root build, root_tweaks18.torch).
 * Logs: unified log, subsystem com.sweet.torch (`sweetlog 60 torch`). Idea after HakiOS's inject_media.c (MIT,
 * oosexgang/hakios-xnu-kernel), which does this for iOS 16's mediaserverd by code addresses; this is our own code.
 * iOS 18+, arm64e + pacstrip (tools/sweetnet/build.sh).
 */
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <os/log.h>
#include <string.h>
#include <sys/sysctl.h>

static os_log_t gLog;
static IMP gOrigShared;
static uint32_t gLevel;                 /* thousandths, what the kernel was last given */

static void
torch_set(float level)
{
	uint32_t v = level <= 0.f || level != level ? 0u : level >= 1.f ? 1000u : (uint32_t)(level * 1000.f + 0.5f);
	if (v == 0 && level > 0.f) {
		v = 1;
	}
	int e = sysctlbyname("kern.sweet_torch", NULL, NULL, &v, sizeof(v)) == 0 ? 0 : errno;
	os_log(gLog, "sweettorch: torch level %.3f -> kern.sweet_torch %u%{public}s%{public}s", level, v, e ? " FAILED: " : "",
	    e ? strerror(e) : "");
	if (!e) {
		gLevel = v;
	}
}

static BOOL
from_flashlight(void *ret)
{
	/*
	 * FigFlashlight.m's functions are static (dladdr calls them "<redacted>"), laid out from the exported
	 * FigFlashlightCreate up to the next exported function, FigFlatDictionaryKeySpaceRegister (iOS 26.6.2: 0x2c84 bytes).
	 */
	static uintptr_t from, to;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		uintptr_t a = (uintptr_t)dlsym(RTLD_DEFAULT, "FigFlashlightCreate");
		uintptr_t b = (uintptr_t)dlsym(RTLD_DEFAULT, "FigFlatDictionaryKeySpaceRegister");
		if (a && b > a && b - a < 0x10000) {
			from = a;
			to = b;
		}
		os_log(gLog, "sweettorch: FigFlashlight's code: %{public}s (%#lx bytes)", from ? "found" : "NOT FOUND",
		    (unsigned long)(to - from));
	});
	Dl_info info;
	bool found = dladdr(ret, &info) != 0;
	bool yes = from && (uintptr_t)ret >= from && (uintptr_t)ret < to;
	static const char *seen[24];
	static unsigned nseen;
	const char *name = found && info.dli_sname ? info.dli_sname : "?";
	bool known = false;
	for (unsigned i = 0; i < nseen; i++) {
		known = known || seen[i] == name;
	}
	if (!known && nseen < 24) {
		seen[nseen++] = name;
		os_log(gLog, "sweettorch: sharedCaptureDeviceVendor called from %{public}s+%#lx (%{public}s): %{public}s", name,
		    found && info.dli_saddr ? (unsigned long)((char *)ret - (char *)info.dli_saddr) : 0ul,
		    found && info.dli_fname ? strrchr(info.dli_fname, '/') + 1 : "?", yes ? "FigFlashlight's" : "not ours");
	}
	return yes;
}

/* ---- zero answers for anything not implemented, logged once per selector ---- */

static NSMethodSignature *
signature_from(const char *real, SEL sel)
{
	Class c = objc_getClass(real);
	NSMethodSignature *s = c ? [c instanceMethodSignatureForSelector:sel] : nil;
	return s ?: [NSMethodSignature signatureWithObjCTypes:"@@:"];
}

static void
zero_answer(NSInvocation *inv, const char *who)
{
	static NSMutableSet *said;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ said = [NSMutableSet new]; });
	NSString *key = [NSString stringWithFormat:@"%s %@", who, NSStringFromSelector(inv.selector)];
	@synchronized (said) {
		if (![said containsObject:key]) {
			[said addObject:key];
			os_log(gLog, "sweettorch: %{public}@ (not implemented: zero)", key);
		}
	}
	NSUInteger len = inv.methodSignature.methodReturnLength;
	if (len) {
		void *zero = calloc(1, len);
		[inv setReturnValue:zero];
		free(zero);
	}
}

/* -supportedProperties: every key is "supported", so FigFlashlight sets the torch level and the others it knows */
@interface SweetTorchProperties : NSDictionary
@end
@implementation SweetTorchProperties
- (instancetype)initWithObjects:(const id[])objects forKeys:(const id<NSCopying>[])keys count:(NSUInteger)n
{
	(void)objects; (void)keys; (void)n;
	return self;            /* NSDictionary's -init lands here; the abstract class would throw */
}
- (NSUInteger)count { return 0; }
- (id)objectForKey:(id)key { (void)key; return @{}; }
- (NSEnumerator *)keyEnumerator { return [@[] objectEnumerator]; }
@end

@interface SweetTorchStream : NSObject
@end
@implementation SweetTorchStream
- (NSDictionary *)supportedProperties { return [SweetTorchProperties new]; }
- (int)setProperty:(id)key value:(id)value
{
	NSString *k = [key isKindOfClass:[NSString class]] ? key : [key description];
	os_log(gLog, "sweettorch: stream setProperty %{public}@ = %{public}@", k, value);
	if ([k isEqualToString:@"TorchLevel"] && [value respondsToSelector:@selector(floatValue)]) {
		torch_set([value floatValue]);
	}
	return 0;
}
- (id)copyProperty:(id)key error:(int *)err
{
	if (err) {
		*err = 0;
	}
	NSString *k = [key isKindOfClass:[NSString class]] ? key : [key description];
	if ([k isEqualToString:@"TorchLevel"]) {
		return @(gLevel / 1000.f);
	}
	if ([k isEqualToString:@"TorchActive"]) {
		return @(gLevel != 0);
	}
	if ([k isEqualToString:@"TorchOverheated"]) {
		return @NO;
	}
	os_log(gLog, "sweettorch: stream copyProperty %{public}@: none", k);
	return nil;
}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel { return signature_from("BWFigCaptureStream", sel); }
- (void)forwardInvocation:(NSInvocation *)inv { zero_answer(inv, "stream"); }
@end

@interface SweetTorchDevice : NSObject
@end
@implementation SweetTorchDevice
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel { return signature_from("BWFigCaptureDevice", sel); }
- (void)forwardInvocation:(NSInvocation *)inv { zero_answer(inv, "device"); }
@end

@interface SweetTorchVendor : NSObject
@end
@implementation SweetTorchVendor {
	SweetTorchDevice *_device;
}
- (BOOL)isActiveDefaultDeviceAvailableToFlashlight:(id)arg
{
	(void)arg;
	return YES;
}
- (int)registerClientWithPID:(int)pid clientDescription:(id)desc clientPriority:(int)prio
    canStealFromClientsWithSamePriority:(BOOL)steal deviceSharingWithOtherClientsAllowed:(BOOL)share clientType:(int)type
    deviceAvailabilityChangedHandler:(id)handler
{
	os_log(gLog, "sweettorch: vendor registerClient pid %d %{public}@ priority %d type %d", pid, desc, prio, type);
	(void)steal; (void)share; (void)handler;
	return 1;
}
- (int)registerClientWithPID:(int)pid clientApplicationID:(id)app clientDescription:(id)desc clientPriority:(int)prio
    canStealFromClientsWithSamePriority:(BOOL)steal deviceSharingWithOtherClientsAllowed:(BOOL)share clientType:(int)type
    deviceAvailabilityChangedHandler:(id)handler
{
	(void)app;
	return [self registerClientWithPID:pid clientDescription:desc clientPriority:prio canStealFromClientsWithSamePriority:steal
	    deviceSharingWithOtherClientsAllowed:share clientType:type deviceAvailabilityChangedHandler:handler];
}
- (id)copyDeviceForClient:(int)client informClientWhenDeviceAvailableAgain:(BOOL)inform error:(int *)err
{
	(void)client; (void)inform;
	if (err) {
		*err = 0;
	}
	if (!_device) {
		_device = [SweetTorchDevice new];
	}
	os_log(gLog, "sweettorch: vendor copyDevice for client %d", client);
	return _device;
}
- (id)copyStreamWithoutControlFromDevice:(id)device position:(int)position deviceType:(int)type error:(int *)err
{
	if (err) {
		*err = 0;
	}
	os_log(gLog, "sweettorch: vendor copyStream position %d type %d", position, type);
	return [device isKindOfClass:[SweetTorchDevice class]] ? [SweetTorchStream new] : nil;
}
- (id)takeBackDevice:(id)device forClient:(int)client informClientWhenDeviceAvailableAgain:(BOOL)inform
    prefersDeviceInvalidatedImmediately:(BOOL)now
{
	(void)device; (void)inform; (void)now;
	os_log(gLog, "sweettorch: vendor takeBackDevice for client %d", client);
	torch_set(0);
	return nil;
}
- (void)unregisterClient:(int)client
{
	os_log(gLog, "sweettorch: vendor unregisterClient %d", client);
	torch_set(0);
}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel { return signature_from("BWFigCaptureDeviceVendor", sel); }
- (void)forwardInvocation:(NSInvocation *)inv { zero_answer(inv, "vendor"); }
@end

/* +[BWFigCaptureDeviceVendor sharedCaptureDeviceVendor] */
static id
shared_vendor(id self, SEL sel)
{
	void *ret = __builtin_extract_return_addr(__builtin_return_address(0));
	id vendor = ((id (*)(id, SEL))gOrigShared)(self, sel);
	if (!from_flashlight(ret)) {
		return vendor;
	}
	static SweetTorchVendor *ours;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		ours = [SweetTorchVendor new];
		os_log(gLog, "sweettorch: FigFlashlight gets the flashlight's own device vendor (Apple's: %{public}s)",
		    vendor ? "one, with no camera behind it" : "none");
	});
	return ours;
}

static bool
hook(void)
{
	Class c = objc_getClass("BWFigCaptureDeviceVendor");
	Method m = c ? class_getClassMethod(c, sel_registerName("sharedCaptureDeviceVendor")) : NULL;
	if (!m) {
		return false;
	}
	gOrigShared = method_setImplementation(m, (IMP)shared_vendor);
	os_log(gLog, "sweettorch: +[BWFigCaptureDeviceVendor sharedCaptureDeviceVendor] hooked");
	return true;
}

static void
image_added(const struct mach_header *mh, intptr_t slide)
{
	(void)slide;
	static bool done;
	Dl_info info;
	if (!done && dladdr(mh, &info) && info.dli_fname && strstr(info.dli_fname, "/CMCapture.framework/")) {
		done = hook();
	}
}

__attribute__((constructor)) static void
sweettorch_init(void)
{
	gLog = os_log_create("com.sweet.torch", "torch");
	if (!hook()) {
		_dyld_register_func_for_add_image(image_added);
	}
}
