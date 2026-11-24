// sweetnotch.dylib: the iPhone 11's notch for SpringBoard when the canvas has the Mi 8 panel's own shape (414x862 points
// at @2x, tools/adt-canvas.py), so that apps keep the iPhone 11's status bar layout (NOTES.md "SCREEN ASPECT").
//
// SpringBoard tells every app where the notch is (UISDisplayContext.exclusionArea, from
// +[UISDisplaySingleRectShape sb_thisDeviceDisplayShape]), and UIKit picks the status bar layout from it:
// +[_UIStatusBarVisualProvider_Phone visualProviderSubclassForScreen:visualProviderInfo:] takes the fixed "Split" layouts
// for a notch at the top, and _UIStatusBarVisualProvider_Split828 (the iPhone 11's) needs an 828-pixel-wide screen and
// the iPhone 11's notch size. SpringBoard takes the shape from SpringBoardHome's screen type, an exact match on
// (414x896 points, @2x, artwork subtype 1792, home button type); 414x862 matches no type, falls back to a smaller phone's
// type and shape, and every app then draws its status bar in iOS 26's generic layout, nearer the Mi 8's notch.
// The swizzle below answers the shape of the screen type with the iPhone 11's specification when the device's own type
// is another one; with the iPhone 11's canvas (414x896) the types are the same and nothing changes.
//
// Loaded in SpringBoard only, as /usr/local/sbi.dylib (SpringBoard's weak load of /usr/local/bgi.dylib renamed to that
// path of the same length); this dylib weak-links /usr/local/bgi.dylib, so the GPU shim still loads at launch as before.
// Inert in any other process. Log: /private/var/tmp/sweetnotch.log.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* SpringBoardHome's SBHScreenSpecification (40 bytes, returned through x8): the fields _SBHScreenTypeLookup compares */
typedef struct {
	double width, height, scale;
	unsigned long artworkSubtype;
	long homeButtonType;
} sbh_spec_t;
typedef sbh_spec_t (*getspec_f)(unsigned long type);
typedef void (*enumtypes_f)(void (^)(unsigned long type, BOOL *stop));
typedef unsigned long (*curtype_f)(void);

static IMP orig_shape;

static void
nlog(const char *fmt, ...)
{
	FILE *f = fopen("/private/var/tmp/sweetnotch.log", "a");
	if (!f) return;
	va_list ap;
	va_start(ap, fmt);
	vfprintf(f, fmt, ap);
	va_end(ap);
	fputc('\n', f);
	fclose(f);
}

static id
notch_shape(id self, SEL _cmd)
{
	static id shape;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		getspec_f getspec = (getspec_f)dlsym(RTLD_DEFAULT, "SBHGetScreenSpecification");
		enumtypes_f enumtypes = (enumtypes_f)dlsym(RTLD_DEFAULT, "SBHEnumerateScreenTypes");
		curtype_f cur = (curtype_f)dlsym(RTLD_DEFAULT, "SBHScreenTypeForCurrentDevice");
		if (!getspec || !enumtypes || !cur) {
			nlog("SpringBoardHome functions not found (%p %p %p): shape left alone", getspec, enumtypes, cur);
			return;
		}
		unsigned long mine = cur();
		sbh_spec_t ms = getspec(mine);
		__block unsigned long want = (unsigned long)-1;
		enumtypes(^(unsigned long t, BOOL *stop) {
			sbh_spec_t s = getspec(t);
			if (s.width == 414 && s.height == 896 && s.scale == 2 && s.artworkSubtype == 1792) {
				want = t;
				*stop = YES;
			}
		});
		nlog("device screen type %lu (%gx%g @%g, artwork %lu, home %ld); iPhone 11 type %ld", mine, ms.width, ms.height,
		    ms.scale, ms.artworkSubtype, ms.homeButtonType, (long)want);
		if (want == (unsigned long)-1 || want == mine) {
			nlog("shape left alone");
			return;
		}
		SEL sel = sel_registerName("sb_displayShapeForScreenType:");
		if (![self respondsToSelector:sel]) {
			nlog("no +sb_displayShapeForScreenType:: shape left alone");
			return;
		}
		shape = ((id (*)(id, SEL, unsigned long))objc_msgSend)(self, sel, want);
		nlog("shape of type %lu answered: %s", want, shape ? [[shape description] UTF8String] : "(nil)");
	});
	if (shape) return shape;
	return ((id (*)(id, SEL))orig_shape)(self, _cmd);
}

__attribute__((constructor)) static void
sweetnotch_init(void)
{
	const char *p = getprogname();
	if (!p || strcmp(p, "SpringBoard") != 0) return;
	if (access("/private/var/tmp/sweetnotch.off", F_OK) == 0) {
		nlog("pid %d: /private/var/tmp/sweetnotch.off exists: not installed", getpid());
		return;
	}
	Class meta = objc_getMetaClass("UISDisplaySingleRectShape");
	Method m = meta ? class_getInstanceMethod(meta, sel_registerName("sb_thisDeviceDisplayShape")) : NULL;
	if (!m) {
		nlog("pid %d: +[UISDisplaySingleRectShape sb_thisDeviceDisplayShape] not found: not installed", getpid());
		return;
	}
	orig_shape = method_setImplementation(m, (IMP)notch_shape);
	nlog("pid %d: installed", getpid());
}
