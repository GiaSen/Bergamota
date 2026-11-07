/*
 * sweetorient.dylib: device orientation for backboardd on the Mi 8, which has no AOP (Apple's always-on processor).
 *
 * backboardd rotates the screen with CoreMotion's CMDeviceOrientationManager. On an iPhone 11 identity CoreMotion
 * computes nothing on the AP: it asks the AOP through AppleSPU's HID driver interface (backboardd's log, image 118:
 * "fHidDeviceInterface NULL", "No reply for LastOrientation", "Updating device orientation from CoreMotion to: unknown").
 * Which path is used comes from a per-model capability mask in CoreMotion (bit 7 for the iPhone 11), not a setting.
 * This dylib, weak-linked into /usr/libexec/backboardd only, wraps three methods of CMDeviceOrientationManager:
 *   -startDeviceOrientationUpdatesToQueue:withHandler:  Apple's, then an accelerometer feed (CMMotionManager, 10 Hz:
 *        what locationd already gets from the kernel's SweetHIDSensor) whose orientation changes, debounced over
 *        DEBOUNCE samples, go to the handler on its queue as CMDeviceOrientation objects
 *   -stopDeviceOrientationUpdates                       the feed stops, then Apple's
 *   -deviceOrientationBlocking                          the feed's orientation when it has one (waits up to 0.3 s for a
 *        first sample), else Apple's ("unknown")
 * UIDeviceOrientation values: 1 portrait, 2 upside down, 3 landscape left (top to the left), 4 landscape right, 5 face up,
 * 6 face down. Accelerometer in g with Apple's sign (gravity vector: upright = y -1, face up = z -1).
 * Test switch: /private/var/tmp/sweetorient.force (one digit 1-6) forces that orientation while it exists.
 * Does nothing (logs why) when /private/var/root/sweetorient.off exists, outside backboardd (unless
 * SWEETORIENT_ANY=1, for tools/sweetnet/sweetorient), or when a class or method it wraps is missing.
 * Built by tools/sweetnet/build.sh (arm64e, pacstrip --sign); in a root image with RENEGADE_ORIENT=1 (root_tweaks18.orient),
 * on a running phone by hand (tools/renegade/link_weak.py on backboardd, NOTES "SENSORS" 2026-11-06).
 */
#import <Foundation/Foundation.h>
#import <CoreMotion/CoreMotion.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/log.h>
#import <math.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>
#import <fcntl.h>

#define DEBOUNCE 3              /* samples (10 Hz): ~0.3 s, about what an iPhone takes */

static os_log_t lg;
static IMP orig_start, orig_stop, orig_blocking;
static CMMotionManager *mm;
static NSOperationQueue *feedq;
static NSMutableArray *clients;                 /* {queue, handler} of every manager that started */
static int cur, cand, cand_n;                   /* the orientation reported, a candidate and how long it has held */
static double cur_ts;
static dispatch_semaphore_t first;
static NSObject *lock;

static int
orientation_from(double x, double y, double z, int prev)
{
	double n = sqrt(x * x + y * y + z * z);
	if (n < 0.5 || n > 1.6) {
		return prev;                            /* shaking or falling: keep the last one */
	}
	x /= n;
	y /= n;
	z /= n;
	if (fabs(z) > 0.85) {                           /* within ~32 degrees of flat */
		return z < 0 ? 5 : 6;
	}
	double ax = fabs(x), ay = fabs(y);
	double margin = (prev >= 1 && prev <= 4) ? 0.25 : 0.0;     /* stay until clearly past the diagonal */
	bool portraitish = prev == 1 || prev == 2;
	if (ay > ax + (portraitish ? -margin : margin)) {
		return y < 0 ? 1 : 2;
	}
	return x < 0 ? 3 : 4;
}

static id
make_orientation(int o, double ts)
{
	Class c = objc_getClass("CMDeviceOrientation");
	SEL s = sel_registerName("initWithOrientation:andTimestamp:");
	id obj = [c alloc];
	return ((id (*)(id, SEL, int, double))objc_msgSend)(obj, s, o, ts);
}

static void
deliver(int o, double ts)
{
	NSArray *cs;
	@synchronized(lock) {
		cs = [clients copy];
	}
	for (NSArray *pair in cs) {
		NSOperationQueue *q = pair[0];
		void (^h)(id, NSError *) = pair[1];
		id obj = make_orientation(o, ts);
		[q addOperationWithBlock:^{
			h(obj, nil);
		}];
	}
	os_log(lg, "sweetorient: orientation %d to %lu client(s)", o, (unsigned long)cs.count);
}

/*
 * Test switch (2026-11-07, for checking rotations without hands on the phone): /private/var/tmp/sweetorient.force holding
 * one digit 1-6 replaces the accelerometer's answer while it exists; 0 = none. Read at the feed's 10 Hz.
 */
static int
force_read(void)
{
	char c = 0;
	int fd = open("/private/var/tmp/sweetorient.force", O_RDONLY);
	if (fd < 0) {
		return 0;
	}
	ssize_t n = read(fd, &c, 1);
	close(fd);
	return n == 1 && c >= '1' && c <= '6' ? c - '0' : 0;
}

static void
feed_start(void)
{
	@synchronized(lock) {
		if (mm.accelerometerActive) {
			return;
		}
		cand_n = 0;
		mm.accelerometerUpdateInterval = 0.1;
		[mm startAccelerometerUpdatesToQueue:feedq withHandler:^(CMAccelerometerData *d, NSError *e) {
			if (e || !d) {
				return;
			}
			bool firstSample = cur == 0;
			int o = orientation_from(d.acceleration.x, d.acceleration.y, d.acceleration.z, cur);
			int forced = force_read();
			if (forced) {                           /* test switch: that orientation, no debounce */
				o = forced;
				cand = o;
				cand_n = DEBOUNCE;
			}
			if (o == cand) {
				cand_n++;
			} else {
				cand = o;
				cand_n = 1;
			}
			if (o != cur && (cand_n >= DEBOUNCE || firstSample)) {
				cur = o;
				cur_ts = d.timestamp;
				if (firstSample) {
					dispatch_semaphore_signal(first);
				}
				deliver(o, d.timestamp);
			}
		}];
		os_log(lg, "sweetorient: accelerometer feed on");
	}
}

static void
feed_stop(void)
{
	@synchronized(lock) {
		if (clients.count == 0 && mm.accelerometerActive) {
			[mm stopAccelerometerUpdates];
			os_log(lg, "sweetorient: accelerometer feed off");
		}
	}
}

static void
hook_start(id self, SEL _cmd, NSOperationQueue *q, id handler)
{
	((void (*)(id, SEL, id, id))orig_start)(self, _cmd, q, handler);
	if (q && handler) {
		@synchronized(lock) {
			[clients addObject:@[ q, [handler copy] ]];
		}
		feed_start();
		if (cur) {
			deliver(cur, cur_ts);                   /* the current one at once, as Apple's does */
		}
	}
}

static void
hook_stop(id self, SEL _cmd)
{
	@synchronized(lock) {
		[clients removeAllObjects];             /* backboardd has one manager */
	}
	feed_stop();
	((void (*)(id, SEL))orig_stop)(self, _cmd);
}

static id
hook_blocking(id self, SEL _cmd)
{
	if (!cur) {
		feed_start();
		dispatch_semaphore_wait(first, dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC));
		feed_stop();
	}
	if (cur) {
		os_log(lg, "sweetorient: blocking query -> %d", cur);
		return make_orientation(cur, cur_ts);
	}
	return ((id (*)(id, SEL))orig_blocking)(self, _cmd);
}

static bool
wrap(Class c, const char *sel, IMP repl, IMP *orig)
{
	Method m = class_getInstanceMethod(c, sel_registerName(sel));
	if (!m) {
		return false;
	}
	*orig = method_setImplementation(m, repl);
	return *orig != NULL;
}

__attribute__((constructor)) static void
sweetorient_init(void)
{
	lg = os_log_create("com.sweet.orient", "shim");
	const char *prog = getprogname();
	const char *any = getenv("SWEETORIENT_ANY");
	if (access("/private/var/root/sweetorient.off", F_OK) == 0) {
		os_log(lg, "sweetorient: off (/private/var/root/sweetorient.off)");
		return;
	}
	if (!(prog && strcmp(prog, "backboardd") == 0) && !(any && *any == '1')) {
		return;
	}
	Class mgr = objc_getClass("CMDeviceOrientationManager");
	if (!mgr || !objc_getClass("CMDeviceOrientation") ||
	    !class_getInstanceMethod(objc_getClass("CMDeviceOrientation"), sel_registerName("initWithOrientation:andTimestamp:"))) {
		os_log(lg, "sweetorient: CoreMotion classes not as expected, not active");
		return;
	}
	lock = [NSObject new];
	clients = [NSMutableArray new];
	first = dispatch_semaphore_create(0);
	mm = [CMMotionManager new];
	feedq = [NSOperationQueue new];
	feedq.maxConcurrentOperationCount = 1;
	feedq.name = @"sweetorient";
	static const char *const sels[] = { "startDeviceOrientationUpdatesToQueue:withHandler:", "stopDeviceOrientationUpdates",
		                            "deviceOrientationBlocking" };
	for (unsigned i = 0; i < 3; i++) {             /* all three or none */
		if (!class_getInstanceMethod(mgr, sel_registerName(sels[i]))) {
			os_log(lg, "sweetorient: CMDeviceOrientationManager has no %{public}s, not active", sels[i]);
			return;
		}
	}
	bool ok = wrap(mgr, sels[0], (IMP)hook_start, &orig_start) && wrap(mgr, sels[1], (IMP)hook_stop, &orig_stop) &&
	    wrap(mgr, sels[2], (IMP)hook_blocking, &orig_blocking);
	os_log(lg, "sweetorient: %s in %{public}s", ok ? "active" : "NOT active (a method is missing)", prog ?: "?");
}
