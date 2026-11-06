/*
 * sweetrec: record the Mi 8's handset mic through the kernel's capture (kern.sweet_audio_rec, xnu 3065).
 *   sweetrec SECONDS [FILE.wav]   start the capture (the kernel brings the codec up if needed), read SECONDS of 16-bit
 *                                 mono 48 kHz, print the level once a second, write FILE.wav if given, stop
 *   sweetrec -x                   stop the capture now
 * iOS 18+, arm64e + pacstrip (tools/sweetnet/build.sh).
 */
#include <errno.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <unistd.h>

struct rq {
	uint32_t op, max;
	uint64_t pos;
};
struct rh {
	uint64_t wpos, from;
	uint32_t n, state;
};

static int
rec(uint32_t op, uint32_t max, uint64_t pos, struct rh *h, int16_t *out)
{
	static uint8_t buf[sizeof(struct rh) + 9600 * 2];
	struct rq q = { op, max, pos };
	size_t len = sizeof(buf);
	if (sysctlbyname("kern.sweet_audio_rec", buf, &len, &q, sizeof(q)) != 0) {
		return errno;
	}
	if (len < sizeof(*h)) {
		return EIO;
	}
	memcpy(h, buf, sizeof(*h));
	if (out && h->n) {
		memcpy(out, buf + sizeof(*h), h->n * 2);
	}
	return 0;
}

static void
put32(FILE *f, uint32_t v)
{
	fwrite(&v, 4, 1, f);
}

static void
put16(FILE *f, uint16_t v)
{
	fwrite(&v, 2, 1, f);
}

int
main(int argc, char **argv)
{
	struct rh h;
	if (argc >= 2 && !strcmp(argv[1], "-x")) {
		int e = rec(2, 0, 0, &h, NULL);
		printf("stop: %s\n", e ? strerror(e) : "ok");
		return e ? 1 : 0;
	}
	if (argc < 2) {
		fprintf(stderr, "usage: sweetrec SECONDS [FILE.wav] | -x\n");
		return 2;
	}
	unsigned secs = (unsigned)atoi(argv[1]);
	uint32_t total = secs * 48000u, got = 0;
	int16_t *pcm = calloc(total ? total : 1, 2);
	int e = rec(1, 0, 0, &h, NULL);
	if (e) {
		printf("start: %s\n", strerror(e));
		return 1;
	}
	uint64_t pos = h.wpos;
	printf("capture running (state %u), from sample %llu\n", h.state, (unsigned long long)pos);
	unsigned dropped = 0;
	while (got < total) {
		usleep(20000);
		int16_t chunk[9600];
		e = rec(3, 9600, pos, &h, chunk);
		if (e) {
			printf("read: %s\n", strerror(e));
			break;
		}
		if (h.from > pos) {
			dropped += (unsigned)(h.from - pos);
		}
		uint32_t n = h.n < total - got ? h.n : total - got;
		memcpy(pcm + got, chunk, n * 2);
		unsigned before = got / 48000u;
		got += n;
		pos = h.from + h.n;
		if (got / 48000u != before || got == total) {
			uint32_t a = before * 48000u, b = got;
			double s2 = 0;
			int peak = 0;
			for (uint32_t i = a; i < b; i++) {
				s2 += (double)pcm[i] * pcm[i];
				peak = abs(pcm[i]) > peak ? abs(pcm[i]) : peak;
			}
			double rms = sqrt(s2 / (b > a ? b - a : 1));
			printf("%2u s: rms %.1f dBFS, peak %.1f dBFS\n", got / 48000u, 20 * log10((rms + 1e-9) / 32768.0),
			    20 * log10((peak + 1e-9) / 32768.0));
		}
		if (h.state == 0) {
			printf("the capture stopped\n");
			break;
		}
	}
	e = rec(2, 0, 0, &h, NULL);
	printf("%u samples, %u dropped, stop %s\n", got, dropped, e ? strerror(e) : "ok");
	if (argc >= 3 && got) {
		FILE *f = fopen(argv[2], "wb");
		if (!f) {
			perror(argv[2]);
			return 1;
		}
		fwrite("RIFF", 1, 4, f);
		put32(f, 36 + got * 2);
		fwrite("WAVEfmt ", 1, 8, f);
		put32(f, 16);
		put16(f, 1);
		put16(f, 1);
		put32(f, 48000);
		put32(f, 96000);
		put16(f, 2);
		put16(f, 16);
		fwrite("data", 1, 4, f);
		put32(f, got * 2);
		fwrite(pcm, 2, got, f);
		fclose(f);
		printf("wrote %s\n", argv[2]);
	}
	return 0;
}
