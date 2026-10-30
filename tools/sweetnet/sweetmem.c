/*
 * sweetmem: core clock, cache/DRAM latency and memory bandwidth, as seen from user space. Tells a slow L3 or DDR clock
 * (nobody votes for them unless the kernel does) from a slow CPU clock.
 * Usage: sweetmem [ROUNDS, default 3] [q]. Only samples taken on an A75 count (clock probe before and after each), best of
 * several. Read-only, about 3 minutes a round; q = fewer sizes and samples, under a minute.
 * Build: tools/sweetnet/build.sh (arm64e, then `renegade strip --sign`).
 */
#include <mach/mach_time.h>
#include <pthread.h>
#include <sched.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static mach_timebase_info_data_t tb;
static int quick = 40;

static double
now_ns(void)
{
	return (double)mach_absolute_time() * tb.numer / tb.denom;
}

/* One dependent add per cycle on both the A55 and the A75: ns per add = the core's cycle time. */
static double
core_ghz(void)
{
	uint64_t n = 4000000, x = 0, left = n / 100;
	double t = now_ns();
	__asm__ volatile(
		"1:\n"
		".rept 100\n"
		"add %0, %0, #1\n"
		".endr\n"
		"subs %1, %1, #1\n"
		"b.ne 1b\n"
		: "+r"(x), "+r"(left) : : "cc");
	return (double)n / (now_ns() - t);
}

/* The kernel steers only at wakeup: sleep and spin until this thread is on a core faster than an A55's 1.77 GHz. */
static double
to_a75(void)
{
	double g = 0;
	for (int i = 0; i < 300 && g < 1.85; i++) {
		usleep(300);
		g = core_ghz();
	}
	return g;
}

static uint64_t
rnd(uint64_t *s)
{
	*s ^= *s << 13;
	*s ^= *s >> 7;
	*s ^= *s << 17;
	return *s;
}

/* Random cycle through `size` bytes, one 64-byte line per step (prefetchers cannot follow it): ns per load. */
static double
chase_ns(void **buf, size_t size)
{
	size_t lines = size / 64, step = 64 / sizeof(void *);
	uint32_t *order = malloc(lines * sizeof(uint32_t));
	uint64_t seed = 0x9e3779b97f4a7c15ull;
	for (size_t i = 0; i < lines; i++) {
		order[i] = (uint32_t)i;
	}
	for (size_t i = lines - 1; i > 0; i--) {
		size_t j = rnd(&seed) % (i + 1);
		uint32_t t = order[i];
		order[i] = order[j];
		order[j] = t;
	}
	for (size_t i = 0; i < lines; i++) {
		buf[order[i] * step] = &buf[order[(i + 1) % lines] * step];
	}
	free(order);
	void **p = buf;
	for (size_t i = 0; i < lines; i++) {
		p = (void **)*p;
	}
	/* The best of several short samples: an A55 in the middle or a preemption only ever makes a sample slower. */
	double best = 1e9;
	for (int s = 0; s < quick; s++) {
		uint64_t loads = size >= (8u << 20) ? 400000 : 2000000, left = loads;
		double g0 = to_a75(), t = now_ns();
		while (left >= 16) {
#define L4 p = (void **)*p; p = (void **)*p; p = (void **)*p; p = (void **)*p;
			L4 L4 L4 L4
			left -= 16;
		}
		double r = (now_ns() - t) / (double)(loads - left);
		if (g0 >= 1.85 && core_ghz() >= 1.85 && r < best) {
			best = r;
		}
	}
	__asm__ volatile("" : : : "memory", "cc");
	if (!p) {
		abort();
	}
	return best;
}

static double
mb_s(uint64_t bytes, double ns)
{
	return (double)bytes * 1e3 / ns;
}

static double
bw_read(const uint64_t *b, size_t size)
{
	size_t words = size / 8, passes = (128u << 20) / size;
	if (!passes) {
		passes = 1;
	}
	uint64_t sum = 0;
	double t = now_ns();
	for (size_t p = 0; p < passes; p++) {
		for (size_t i = 0; i + 8 <= words; i += 8) {
			sum += b[i] + b[i + 1] + b[i + 2] + b[i + 3] + b[i + 4] + b[i + 5] + b[i + 6] + b[i + 7];
		}
	}
	double dt = now_ns() - t;
	__asm__ volatile("" : "+r"(sum));
	return mb_s((uint64_t)passes * size, dt);
}

static double
bw_copy(void *d, const void *s, size_t size)
{
	size_t passes = (128u << 20) / size;
	if (!passes) {
		passes = 1;
	}
	double t = now_ns();
	for (size_t p = 0; p < passes; p++) {
		memcpy(d, s, size);
		__asm__ volatile("" : : "r"(d), "r"(s) : "memory");
	}
	return mb_s((uint64_t)passes * size, now_ns() - t);
}

int
main(int argc, char **argv)
{
	static const size_t all[] = { 16u << 10, 64u << 10, 128u << 10, 512u << 10, 1024u << 10, 1536u << 10,
		                      4u << 20, 16u << 20, 64u << 20 };
	static const size_t few[] = { 1024u << 10, 4u << 20, 16u << 20, 64u << 20 };
	const size_t max = 64u << 20;
	int rounds = argc > 1 ? atoi(argv[1]) : 3;
	bool q = argc > 2;
	if (q) {
		quick = 8;
	}
	mach_timebase_info(&tb);
	/* fixed priority 54, CoreAnimation's render thread: the kernel's steering (sweetamp_prio) prefers an A75 */
	struct sched_param sp = { .sched_priority = 54 };
	if (pthread_setschedparam(pthread_self(), SCHED_RR, &sp)) {
		perror("pthread_setschedparam");
	}
	void **a = malloc(max), **b = malloc(max);
	if (!a || !b) {
		perror("malloc");
		return 1;
	}
	memset(a, 1, max);
	memset(b, 2, max);
	for (int r = 0; r < rounds; r++) {
		printf("round %d: A75 search %.2f GHz\n  latency:", r, to_a75());
		const size_t *sizes = q ? few : all;
		for (size_t i = 0; i < (q ? sizeof(few) / sizeof(few[0]) : sizeof(all) / sizeof(all[0])); i++) {
			printf(" %zuK=%.1fns", sizes[i] >> 10, chase_ns(a, sizes[i]));
			fflush(stdout);
		}
		printf("\n");
		memset(a, 1, max);
		double r64k = 0, r1m = 0, r64m = 0, c64k = 0, c1m = 0, c8m = 0, c64m = 0;
#define BEST(var, expr) do { for (int s = 0; s < (q ? 2 : 12); s++) { double v, g0 = to_a75(); v = (expr); \
		if (g0 >= 1.85 && core_ghz() >= 1.85 && v > var) { var = v; } } } while (0)
		if (!q) {
			BEST(r64k, bw_read((uint64_t *)a, 64u << 10));
			BEST(c64k, bw_copy(b, a, 64u << 10));
		}
		BEST(r1m, bw_read((uint64_t *)a, 1u << 20));
		BEST(r64m, bw_read((uint64_t *)a, max));
		BEST(c1m, bw_copy(b, a, 1u << 20));
		BEST(c8m, bw_copy(b, a, 8u << 20));
		BEST(c64m, bw_copy(b, a, max));
		printf("  read MB/s: 64K=%.0f 1M=%.0f 64M=%.0f; memcpy MB/s: 64K=%.0f 1M=%.0f 8M=%.0f 64M=%.0f\n",
		    r64k, r1m, r64m, c64k, c1m, c8m, c64m);
		fflush(stdout);
	}
	return 0;
}
