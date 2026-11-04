/*
 * guard_test: the speaker's guard (guard.c) on synthetic signals, on the Mac:
 *   cc -O2 -o /tmp/guard_test tools/audio/SweetSpeaker/guard_test.c tools/audio/SweetSpeaker/guard.c && /tmp/guard_test
 * Each case prints, once per reported second, the output's peak (dBFS) and power (dB under a full-scale sine), and the
 * checks fail with exit status 1: no sample over -3 dBFS, the averages' limits held, the high-pass where it should be.
 */
#include "guard.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>

#define RATE    48000.0f
#define BLOCK   1024u

static int failures;

static void
check(int ok, const char *what)
{
	if (!ok) {
		printf("  FAIL: %s\n", what);
		failures++;
	}
}

/* a sine of freq at amp (0..1) for secs, then silence for rest_secs; returns the output power (dB re full-scale sine)
 * averaged over [from_s, to_s) of the tone, and its highest peak (dBFS) */
static void
tone(struct ss_guard *g, float freq, float amp, float secs, const float *report, int nreport, float *pow_db, float *peak_db)
{
	static float buf[2 * BLOCK];
	double phase = 0, sum = 0, sum_all = 0;
	unsigned long n = (unsigned long)(secs * RATE), done = 0, cnt = 0;
	float peak = 0, peak_all = 0;
	int r = 0;
	while (done < n) {
		unsigned k = n - done < BLOCK ? (unsigned)(n - done) : BLOCK;
		for (unsigned i = 0; i < k; i++) {
			float v = amp * (float)sin(phase);
			phase += 2 * M_PI * freq / RATE;
			buf[2 * i] = buf[2 * i + 1] = v;
		}
		guard_run(g, buf, k);
		for (unsigned i = 0; i < k; i++) {
			float v = buf[2 * i];
			sum += (double)v * v;
			sum_all += (double)v * v;
			peak = fmaxf(peak, fabsf(v));
			peak_all = fmaxf(peak_all, fabsf(v));
			cnt++;
		}
		done += k;
		float t = (float)done / RATE;
		if (r < nreport && t >= report[r]) {
			printf("  t %5.1f s: power %6.2f dB, peak %6.2f dBFS\n", t, 10 * log10(sum / cnt / 0.5 + 1e-30),
			    20 * log10(peak + 1e-30));
			sum = 0;
			cnt = 0;
			peak = 0;
			r++;
		}
	}
	*pow_db = (float)(10 * log10(sum_all / (double)n / 0.5 + 1e-30));
	*peak_db = 20 * log10f(peak_all + 1e-30f);
}

int
main(void)
{
	struct ss_guard g;
	float pw, pk;

	printf("1 kHz at -12 dBFS (what Apple's chain leaves of full scale), +12 dB make-up, 70 s:\n");
	guard_init(&g, RATE, 12.0f);
	float rep1[] = { 0.1f, 0.5f, 1, 2, 3, 5, 10, 20, 30, 45, 60, 70 };
	tone(&g, 1000, 0.25f, 70, rep1, 12, &pw, &pk);
	check(pk <= -3.0f + 0.01f, "a peak over -3 dBFS");
	float lowest = guard_take_min_db(&g);
	printf("  guard's lowest gain %.1f dB\n", lowest);
	check(lowest > -20.0f, "the gain dropped towards silence (a click)");
	/* the 60 s average sits at -9 dB at the end; the 3 s one under -6, the 0.2 s one under -3 */
	for (int k = 0; k < 3; k++) {
		printf("  average over %4.1f s: %6.2f dB (limit %6.2f)\n", g.tau[k], 10 * log10f(g.avg[k] / 0.5f),
		    10 * log10f(g.limit[k] / 0.5f));
		check(g.avg[k] <= g.limit[k] * 1.01f, "an average over its limit");
	}
	check(10 * log10f(g.avg[2] / 0.5f) > -9.3f, "the 60 s average did not reach its limit");

	printf("the same after 30 s of rest (the averages fell):\n");
	guard_rest(&g, 30);
	float rep2[] = { 0.5f, 1, 2, 3 };
	tone(&g, 1000, 0.25f, 3, rep2, 4, &pw, &pk);

	printf("1 kHz at -32 dBFS (ordinary music level after Apple's chain), 3 s: untouched but the make-up\n");
	guard_init(&g, RATE, 12.0f);
	float rep3[] = { 1, 3 };
	tone(&g, 1000, powf(10, -32 / 20.0f), 3, rep3, 2, &pw, &pk);
	check(fabsf(pw - (-20.0f)) < 0.2f, "a quiet 1 kHz tone was not just lifted by 12 dB");

	float freqs[] = { 50, 100, 200, 400, 1000 };
	float want[] = { -24.1f, -12.3f, -3.0f, -0.3f, 0.0f };   /* 2nd-order Butterworth at 200 Hz, in dB */
	printf("high-pass, quiet tones (-40 dBFS in, so no limiting), level change after the make-up:\n");
	for (int i = 0; i < 5; i++) {
		guard_init(&g, RATE, 0.0f);
		float none[] = { 99 };
		tone(&g, freqs[i], 0.01f, 2, none, 0, &pw, &pk);
		float gain = pw - 10 * log10f(0.01f * 0.01f);
		printf("  %5.0f Hz: %6.2f dB (Butterworth %6.2f)\n", freqs[i], gain, want[i]);
		check(fabsf(gain - want[i]) < 0.5f, "high-pass response");
	}

	printf(failures ? "%d FAILED\n" : "all checks passed\n", failures);
	return failures ? 1 : 0;
}
