/*
 * sweetwake: how late do threads wake up? Timers (mach_wait_until) and one thread waking another (semaphore), at the
 * scheduling classes the UI uses. A system that is mostly idle should answer in tens of microseconds; a lost wakeup shows
 * up as a tail that ends at some periodic tick.
 * Usage: sweetwake [SECONDS per test, default 4] [PERIOD_MS, default 8] [fg]. fg: first make this process a foreground application:
 * one started over SSH inherits the policy of the SSH server. Read-only.
 * Build: tools/sweetnet/build.sh (arm64e, then `renegade strip --sign`).
 */
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/task_policy.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>

static mach_timebase_info_data_t tb;
static uint64_t
us_of(uint64_t abs)
{
	return abs * tb.numer / tb.denom / 1000;
}
static uint64_t
abs_of_us(uint64_t us)
{
	return us * 1000 * tb.denom / tb.numer;
}

struct dist {
	uint64_t n, sum, max, b[6];     /* <50 us, <500 us, <2 ms, <10 ms, <50 ms, more */
};

static void
note(struct dist *d, uint64_t us)
{
	d->n++;
	d->sum += us;
	if (us > d->max) {
		d->max = us;
	}
	d->b[us < 50 ? 0 : us < 500 ? 1 : us < 2000 ? 2 : us < 10000 ? 3 : us < 50000 ? 4 : 5]++;
}

static void
show(const char *name, const struct dist *d)
{
	printf("%-26s n=%-5llu mean %6.0f us  <50us %-5llu <500us %-5llu <2ms %-4llu <10ms %-4llu <50ms %-4llu more %-4llu max %.1f ms\n", name,
	    d->n, d->n ? (double)d->sum / d->n : 0, d->b[0], d->b[1], d->b[2], d->b[3], d->b[4], d->b[5], d->max / 1000.0);
	fflush(stdout);
}

static semaphore_t sem;
static volatile uint64_t sent;
static volatile int stop;
static struct dist wake;
static int klass;

static void
set_class(int k)
{
	if (k == 1) {
		pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);   /* priority 47, like SpringBoard's event thread */
	} else if (k == 2) {
		pthread_set_qos_class_self_np(QOS_CLASS_DEFAULT, 0);            /* 31 */
	} else if (k == 3) {
		pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0);            /* 20: below the A75 steering threshold */
	}
}

static void *
waiter(void *arg)
{
	set_class(klass);
	while (!stop) {
		semaphore_wait(sem);
		if (sent) {
			note(&wake, us_of(mach_absolute_time() - sent));
			sent = 0;
		}
	}
	return arg;
}

static void
timers(const char *name, int k, int secs, int period_ms)
{
	struct dist d = { 0 };
	pthread_t th;
	klass = k;
	void *(*fn)(void *) = NULL;
	(void)fn;
	set_class(k);
	uint64_t period = abs_of_us((uint64_t)period_ms * 1000), end = mach_absolute_time() + abs_of_us((uint64_t)secs * 1000000);
	uint64_t next = mach_absolute_time();
	while (next < end) {
		next += period;
		mach_wait_until(next);
		note(&d, us_of(mach_absolute_time() - next));
	}
	char label[64];
	snprintf(label, sizeof(label), "timer, %s", name);
	show(label, &d);
	/* the same pacing, now waking another thread that sleeps on a semaphore */
	memset(&wake, 0, sizeof(wake));
	stop = 0;
	pthread_create(&th, NULL, waiter, NULL);
	end = mach_absolute_time() + abs_of_us((uint64_t)secs * 1000000);
	next = mach_absolute_time();
	while (next < end) {
		next += period;
		mach_wait_until(next);
		sent = mach_absolute_time();
		semaphore_signal(sem);
	}
	stop = 1;
	semaphore_signal(sem);
	pthread_join(th, NULL);
	snprintf(label, sizeof(label), "wake, %s", name);
	show(label, &wake);
}

int
main(int argc, char **argv)
{
	int secs = argc > 1 ? atoi(argv[1]) : 4, period = argc > 2 ? atoi(argv[2]) : 8;
	mach_timebase_info(&tb);
	printf("process: darwin-bg %d, thread darwin-bg %d\n", getpriority(PRIO_DARWIN_PROCESS, 0), getpriority(PRIO_DARWIN_THREAD, 0));
	struct task_category_policy cat = { TASK_FOREGROUND_APPLICATION };
	if (argc > 3) {         /* third argument: first make this task a foreground application, not whatever it inherited */
		setpriority(PRIO_DARWIN_PROCESS, 0, 0);
		kern_return_t kr = task_policy_set(mach_task_self(), TASK_CATEGORY_POLICY, (task_policy_t)&cat, TASK_CATEGORY_POLICY_COUNT);
		printf("made foreground: kr %d, darwin-bg now %d\n", kr, getpriority(PRIO_DARWIN_PROCESS, 0));
	}
	semaphore_create(mach_task_self(), &sem, SYNC_POLICY_FIFO, 0);
	timers("user-interactive (47)", 1, secs, period);
	timers("default (31)", 2, secs, period);
	timers("utility (20)", 3, secs, period);
	return 0;
}
