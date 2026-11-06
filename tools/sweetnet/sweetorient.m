/*
 * sweetorient: Mi 8 device orientation for iOS without Apple's always-on processor (AOP/SPU), step 1 (a test tool).
 *   sweetorient dump            CoreMotion's CMDeviceOrientationManager / CMDeviceOrientation methods and ivars (runtime)
 *   sweetorient watch [SECONDS] accelerometer updates through CoreMotion (what locationd gets from the kernel) and the
 *                               orientation computed from them, printed on every change
 *   sweetorient apple [SECONDS] Apple's own CMDeviceOrientationManager in this process (blocking query, then updates);
 *                               with SWEETORIENT_SHIM=/usr/local/lib/sweetorient.dylib SWEETORIENT_ANY=1, through the shim
 * Why: on an iPhone 11 identity, CoreMotion's device orientation (what backboardd rotates the screen with) is computed on
 * the AOP and fetched through AppleSPU's HID driver interface ("fHidDeviceInterface NULL", "No reply for LastOrientation"
 * in backboardd's log, image 118); the Mi 8 has no AOP, so it is always "unknown". This computes it from the accelerometer.
 * Orientation values are UIDeviceOrientation's: 1 portrait, 2 upside down, 3 landscape left (home right, top left),
 * 4 landscape right, 5 face up, 6 face down. Accelerometer in g, Apple's sign (gravity vector: upright = y -1).
 * iOS 18+, arm64e + pacstrip (tools/sweetnet/build.sh).
 */
#import <Foundation/Foundation.h>
#import <CoreMotion/CoreMotion.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>
#import <stdio.h>
#import <dlfcn.h>

static const char *const names[] = { "unknown", "portrait", "upside down", "landscape left", "landscape right",
	"face up", "face down" };

/* UIDeviceOrientation from a gravity vector (g), with hysteresis around the previous answer */
static int
orientation_from(double x, double y, double z, int prev)
{
	double n = sqrt(x * x + y * y + z * z);
	if (n < 0.5 || n > 1.6) {
		return prev;                            /* shaking: keep the last one */
	}
	x /= n;
	y /= n;
	z /= n;
	if (fabs(z) > 0.85) {                           /* flat: about 32 degrees from the horizontal */
		return z < 0 ? 5 : 6;
	}
	double ax = fabs(x), ay = fabs(y);
	double margin = (prev >= 1 && prev <= 4) ? 0.25 : 0.0;     /* stay until clearly past the 45-degree diagonal */
	bool portraitish = prev == 1 || prev == 2;
	if (ay > ax + (portraitish ? -margin : margin)) {
		return y < 0 ? 1 : 2;
	}
	return x < 0 ? 3 : 4;
}

static void
dump_class(const char *cname)
{
	Class c = objc_getClass(cname);
	if (!c) {
		printf("%s: no such class\n", cname);
		return;
	}
	printf("%s : %s\n", cname, class_getSuperclass(c) ? class_getName(class_getSuperclass(c)) : "-");
	for (int meta = 0; meta < 2; meta++) {
		unsigned n = 0;
		Method *m = class_copyMethodList(meta ? object_getClass(c) : c, &n);
		for (unsigned i = 0; i < n; i++) {
			printf("  %c%s  %s\n", meta ? '+' : '-', sel_getName(method_getName(m[i])), method_getTypeEncoding(m[i]) ?: "");
		}
		free(m);
	}
	unsigned n = 0;
	Ivar *iv = class_copyIvarList(c, &n);
	for (unsigned i = 0; i < n; i++) {
		printf("  ivar %s %s @%td\n", ivar_getName(iv[i]), ivar_getTypeEncoding(iv[i]) ?: "", ivar_getOffset(iv[i]));
	}
	free(iv);
	objc_property_t *p = class_copyPropertyList(c, &n);
	for (unsigned i = 0; i < n; i++) {
		printf("  property %s %s\n", property_getName(p[i]), property_getAttributes(p[i]));
	}
	free(p);
}

int
main(int argc, char **argv)
{
	@autoreleasepool {
		const char *cmd = argc > 1 ? argv[1] : "watch";
		double secs = argc > 2 ? atof(argv[2]) : 10;
		if (strcmp(cmd, "dump") == 0) {
			dump_class("CMDeviceOrientationManager");
			dump_class("CMDeviceOrientation");
			return 0;
		}
		if (strcmp(cmd, "apple") == 0) {
			const char *shim = getenv("SWEETORIENT_SHIM");     /* e.g. /usr/local/lib/sweetorient.dylib + SWEETORIENT_ANY=1 */
			if (shim && !dlopen(shim, RTLD_NOW)) {
				printf("dlopen %s: %s\n", shim, dlerror());
				return 1;
			}
			Class c = objc_getClass("CMDeviceOrientationManager");
			id blk = ((id (*)(id, SEL))objc_msgSend)([[c alloc] init], NSSelectorFromString(@"deviceOrientationBlocking"));
			printf("deviceOrientationBlocking: %s\n", [[blk description] UTF8String] ?: "nil");
			id mgr = [[c alloc] init];
			NSOperationQueue *q = [[NSOperationQueue alloc] init];
			SEL start = NSSelectorFromString(@"startDeviceOrientationUpdatesToQueue:withHandler:");
			if (![mgr respondsToSelector:start]) {
				printf("no startDeviceOrientationUpdatesToQueue:withHandler:\n");
				return 1;
			}
			void (^h)(id, NSError *) = ^(id o, NSError *e) {
				printf("apple: %s error %s\n", [[o description] UTF8String] ?: "nil", e ? [[e description] UTF8String] : "none");
				fflush(stdout);
			};
			((void (*)(id, SEL, id, id))objc_msgSend)(mgr, start, q, h);
			[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:secs]];
			return 0;
		}
		CMMotionManager *mm = [[CMMotionManager alloc] init];
		printf("accelerometer available %d\n", mm.accelerometerAvailable);
		mm.accelerometerUpdateInterval = 0.05;
		__block int cur = 0;
		__block unsigned samples = 0;
		[mm startAccelerometerUpdatesToQueue:[[NSOperationQueue alloc] init] withHandler:^(CMAccelerometerData *d, NSError *e) {
			if (e || !d) {
				printf("error %s\n", e ? [[e description] UTF8String] : "no data");
				return;
			}
			samples++;
			int o = orientation_from(d.acceleration.x, d.acceleration.y, d.acceleration.z, cur);
			if (o != cur || samples == 1) {
				printf("%.3f s: accel %+.3f %+.3f %+.3f g -> %s (%d)\n", d.timestamp, d.acceleration.x, d.acceleration.y,
				    d.acceleration.z, names[o], o);
				fflush(stdout);
				cur = o;
			}
		}];
		[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:secs]];
		[mm stopAccelerometerUpdates];
		printf("%u samples\n", samples);
	}
	return 0;
}
