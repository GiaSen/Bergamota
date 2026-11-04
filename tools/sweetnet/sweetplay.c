/*
 * sweetplay: raw PCM (48 kHz, 16-bit little-endian, stereo interleaved) to the Mi 8's speaker through the kernel's
 * player (kern.sweet_audio_play / kern.sweet_audio_amp, a test boot with sweetaudio>=3, bsd/dev/dipper_audio.c).
 *
 *   sweetplay [-a AMP_ON] [-o AMP_OFF] FILE|-   register the amp's I2C scripts (tools/audio/tas2557fw.py), start the
 *                                               stream, feed the file as the ring has room, drain, report
 *   sweetplay -a AMP_ON -o AMP_OFF [-w WAKE]    only register the amp's scripts (for SweetSpeaker.driver); WAKE (the on
 *                                               script without the ROM load) lets the kernel put the amp to sleep
 *                                               through silence (xnu 3048)
 *   sweetplay -s                                the player's state
 *   sweetplay -x                                stop now
 *
 * Without -a the amp keeps whatever scripts the kernel already holds (none after a boot: the stream runs, the amp stays
 * off). Ctrl-C stops the stream.
 */
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <time.h>
#include <unistd.h>

struct pl_status {
	uint32_t state, result, ring, period;
	uint64_t written, sent, played;
	uint32_t queued, zeros, gaps, writes;
	uint32_t errors, handle, copp, amp_checks;
	uint8_t flags1, flags2, amp, idle;
	uint64_t done_time;
} __attribute__((packed));

enum { OP_START = 1, OP_STOP = 2, OP_DATA = 3, OP_DRAIN = 4 };
static const char *const states[] = { "off", "playing", "draining" };
static volatile sig_atomic_t interrupted;

static int
op(uint32_t code, const void *data, size_t len, struct pl_status *st)
{
	static uint8_t in[4 + 65536];
	struct pl_status tmp;
	size_t olen = sizeof(tmp);
	memcpy(in, &code, 4);
	if (len) {
		memcpy(in + 4, data, len);
	}
	if (sysctlbyname("kern.sweet_audio_play", st ? st : &tmp, &olen, code ? in : NULL, code ? 4 + len : 0) != 0) {
		return errno;
	}
	return 0;
}

static void
show(const struct pl_status *s)
{
	printf("state %s (last start %d), ring %u bytes in %u-byte periods; %llu bytes written, %llu sent, %llu played; "
	    "%u queued, %u writes, %u periods of zeros (%u after data), %u errors; mem map %#x, COPP %u; amp %s, %u checks, "
	    "flags %#x %#x\n", s->state < 3 ? states[s->state] : "?", s->result, s->ring, s->period,
	    (unsigned long long)s->written, (unsigned long long)s->sent, (unsigned long long)s->played, s->queued, s->writes,
	    s->zeros, s->gaps, s->errors, s->handle, s->copp, !s->amp ? "off" : s->idle ? "on (asleep: silence)" : "on", s->amp_checks, s->flags1, s->flags2);
}

static int
amp_script(uint8_t which, const char *path)
{
	static uint8_t buf[1 + 65536];
	int fd = open(path, O_RDONLY);
	if (fd < 0) {
		perror(path);
		return -1;
	}
	ssize_t n = read(fd, buf + 1, sizeof(buf) - 1);
	close(fd);
	if (n <= 0) {
		fprintf(stderr, "%s: empty or unreadable\n", path);
		return -1;
	}
	buf[0] = which;
	char text[64];
	size_t tlen = sizeof(text);
	if (sysctlbyname("kern.sweet_audio_amp", text, &tlen, buf, 1 + (size_t)n) != 0) {
		perror("kern.sweet_audio_amp");
		return -1;
	}
	printf("%s", text);
	return 0;
}

static double
now(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
}

static void
on_int(int sig)
{
	(void)sig;
	interrupted = 1;
}

int
main(int argc, char **argv)
{
	const char *on = NULL, *off = NULL, *wake = NULL;
	int c;
	struct pl_status s;
	while ((c = getopt(argc, argv, "a:o:w:sx")) != -1) {
		switch (c) {
		case 'a':
			on = optarg;
			break;
		case 'o':
			off = optarg;
			break;
		case 'w':
			wake = optarg;
			break;
		case 's':
		case 'x': {
			int e = op(c == 'x' ? OP_STOP : 0, NULL, 0, &s);
			if (e) {
				fprintf(stderr, "kern.sweet_audio_play: %s\n", strerror(e));
				return 1;
			}
			show(&s);
			return 0;
		}
		default:
			fprintf(stderr, "usage: sweetplay [-a AMP_ON] [-o AMP_OFF] [-w WAKE] FILE|- | sweetplay -s | sweetplay -x\n");
			return 2;
		}
	}
	if (optind == argc && (on || off || wake)) {
		return (on && amp_script(1, on)) || (off && amp_script(0, off)) || (wake && amp_script(2, wake)) ? 1 : 0;
	}
	if (optind + 1 != argc) {
		fprintf(stderr, "usage: sweetplay [-a AMP_ON] [-o AMP_OFF] [-w WAKE] FILE|- | sweetplay -s | sweetplay -x\n");
		return 2;
	}
	int fd = strcmp(argv[optind], "-") ? open(argv[optind], O_RDONLY) : 0;
	if (fd < 0) {
		perror(argv[optind]);
		return 1;
	}
	if ((on && amp_script(1, on)) || (off && amp_script(0, off)) || (wake && amp_script(2, wake))) {
		return 1;
	}
	signal(SIGINT, on_int);
	signal(SIGTERM, on_int);
	double t0 = now();
	int e = op(OP_START, NULL, 0, &s);
	if (e) {
		fprintf(stderr, "start: %s (kernel log: SWEET AUDIO: player)\n", strerror(e));
		return 1;
	}
	printf("started in %.2f s\n", now() - t0);
	t0 = now();
	static uint8_t buf[16384];
	size_t have = 0;
	uint64_t total = 0;
	unsigned waits = 0;
	for (int eof = 0; !interrupted && (!eof || have >= 4);) {
		while (!eof && have < sizeof(buf)) {
			ssize_t n = read(fd, buf + have, sizeof(buf) - have);
			if (n <= 0) {
				eof = 1;
			} else {
				have += (size_t)n;
			}
		}
		size_t len = have & ~(size_t)3;
		if (!len) {
			break;
		}
		e = op(OP_DATA, buf, len, NULL);
		if (e == EAGAIN) {
			waits++;
			usleep(10000);
			continue;
		}
		if (e) {
			fprintf(stderr, "data: %s\n", strerror(e));
			break;
		}
		total += len;
		memmove(buf, buf + len, have - len);
		have -= len;
	}
	if (interrupted || e) {
		op(OP_STOP, NULL, 0, &s);
		show(&s);
		return 1;
	}
	op(OP_DRAIN, NULL, 0, NULL);
	do {
		usleep(50000);
		if (op(0, NULL, 0, &s)) {
			break;
		}
		if (interrupted) {
			op(OP_STOP, NULL, 0, &s);
		}
	} while (s.state != 0);
	double secs = now() - t0, audio = (double)total / 4 / 48000;
	printf("%llu bytes (%.2f s of audio) in %.2f s, %u waits for room\n", (unsigned long long)total, audio, secs, waits);
	show(&s);
	return s.played == total && !s.errors ? 0 : 1;
}
