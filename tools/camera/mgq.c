/*
 * mgq: print MobileGestalt's answers for keys (MGCopyAnswer), for checking capability questions on the phone.
 *   mgq KEY...
 *   xcrun -sdk iphoneos clang -arch arm64 -mios-version-min=18.0 -framework CoreFoundation mgq.c -o mgq && codesign -s - -f mgq
 */
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdio.h>

int
main(int argc, char **argv)
{
	void *h = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_NOW);
	CFTypeRef (*copy)(CFStringRef, CFDictionaryRef) = h ? (CFTypeRef (*)(CFStringRef, CFDictionaryRef))dlsym(h, "MGCopyAnswer") : NULL;
	if (!copy) {
		fprintf(stderr, "no MGCopyAnswer\n");
		return 1;
	}
	for (int i = 1; i < argc; i++) {
		CFStringRef k = CFStringCreateWithCString(NULL, argv[i], kCFStringEncodingUTF8);
		CFTypeRef v = copy(k, NULL);
		char buf[512] = "(null)";
		if (v) {
			CFStringRef d = CFCopyDescription(v);
			CFStringGetCString(d, buf, sizeof(buf), kCFStringEncodingUTF8);
			CFRelease(d);
			CFRelease(v);
		}
		printf("%-44s %s\n", argv[i], buf);
		CFRelease(k);
	}
	return 0;
}
