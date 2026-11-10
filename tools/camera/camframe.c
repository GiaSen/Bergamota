/*
 * Camera bring-up helper for the Mi 8 kernels (xnu 3076+).
 *   camframe              writes kern.sweet_cam_frame (the last kern.sweet_cam=3 / =4 buffer) to stdout;
 *                         tools/camera/frame2png.py makes a PNG of it
 *   camframe -l N [OUT]   3080+: starts the stream (kern.sweet_cam_stream), reads N frames from kern.sweet_cam_live (each
 *                         a newer one), says their timing, exposure and lens, writes the last frame's RAW10 to OUT, stops
 *   camframe -s FILE      loads FILE into kern.sweet_cam_seq (3077+: the rear main sensor's register sequence, made on
 *                         the Mac by tools/camera/camx_v1.py --seq from the phone's own module file; never in git)
 *   camframe -g N [OUT]   as -l, of a stream somebody else runs (cameracaptured while Camera is open): it is neither started
 *                         nor stopped, the sensor is whichever streams; every frame's exposure is said (auto exposure's steps)
 *   camframe -c N ...     3090+: first selects the sensor (kern.sweet_cam_sensor: 0 rear main, 1 rear tele, 2 front); -s and
 *                         -l then load that sensor's sequence and stream it
 *   camframe -S FILE      3085+: loads FILE into kern.sweet_cam_seq0 (mode 0, 4032x3024, for full-resolution stills)
 *   camframe -t N OUT     3085+: streams, reads N frames (auto exposure settles), takes a full-resolution still
 *                         (kern.sweet_cam_still), writes its RAW10 to OUT (frame2png.py --raw10 --size 4032x3024), stops
 *   xcrun -sdk iphoneos clang -arch arm64 -mios-version-min=18.0 camframe.c -o camframe && codesign -s - -f camframe
 *   cat camframe | ssh root@192.168.7.2 'cat > /var/root/camframe && chmod 755 /var/root/camframe'
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <unistd.h>

static int
load_seq_to(const char *path, const char *name)
{
	FILE *f = fopen(path, "rb");
	if (!f) {
		perror(path);
		return 1;
	}
	static char buf[2048 * 8];
	size_t n = fread(buf, 1, sizeof(buf), f);
	fclose(f);
	if (n == 0 || n % 8) {
		fprintf(stderr, "%s: %zu bytes, not 8-byte records\n", path, n);
		return 1;
	}
	if (sysctlbyname(name, NULL, NULL, buf, n) != 0) {
		perror(name);
		return 1;
	}
	fprintf(stderr, "%zu records loaded\n", n / 8);
	return 0;
}

static int
load_seq(const char *path)
{
	return load_seq_to(path, "kern.sweet_cam_seq");
}

/* 3080: the kernel's stream header (kern.sweet_cam_live) */
struct cam_live_hdr {
	uint32_t magic;
	uint16_t version, hdr_size;
	uint32_t seq;
	uint16_t width, height, stride, format;
	uint16_t black, white;
	uint32_t exposure_lines, line_ns, again_x256, dgain_x256, lens, af_state;
	uint64_t timestamp_ns;
	uint32_t frame_us, flags;
};

static int
set_int(const char *name, int v)
{
	if (sysctlbyname(name, NULL, NULL, &v, sizeof(v)) != 0) {
		perror(name);
		return 1;
	}
	return 0;
}

/* camframe -l N OUT: stream, N frames through kern.sweet_cam_live (each waiting for a newer one), the last to OUT, stop;
 * own false (-g): the stream is somebody else's, left as it is, and every frame is said */
static int
live(int n, const char *out, int own)
{
	size_t cap = 0;
	if (own && set_int("kern.sweet_cam_stream", 1)) {
		return 1;
	}
	if (sysctlbyname("kern.sweet_cam_live", NULL, &cap, NULL, 0) != 0) {
		perror("kern.sweet_cam_live size");
		return 1;
	}
	char *buf = malloc(cap);
	uint32_t last = 0;
	uint64_t t0 = 0, tp = 0;
	unsigned got = 0, dup = 0, skipped = 0;
	for (int i = 0; buf && i < n; i++) {
		size_t len = cap;
		if (sysctlbyname("kern.sweet_cam_live", buf, &len, &last, sizeof(last)) != 0) {
			perror("kern.sweet_cam_live");
			break;
		}
		const struct cam_live_hdr *h = (const void *)buf;
		if (h->seq == last) {
			dup++;
			continue;
		}
		if (got && h->seq != last + 1) {
			skipped += h->seq - last - 1;
		}
		if (!t0) {
			t0 = h->timestamp_ns;
			fprintf(stderr, "frames: %ux%u, %u bytes a line, format %u, flags %#x (colour order %u, sensor %u), black %u\n", h->width,
			    h->height, h->stride, h->format, h->flags, h->flags & 3, (h->flags >> 8) & 3, h->black);
		}
		if (!own || i < 3 || i % 30 == 0 || i == n - 1) {
			fprintf(stderr, "seq %u t %+.1f ms (%+.1f) frame %u us, exposure %u lines x %.2f x %.2f, lens %u af %u\n", h->seq,
			    (h->timestamp_ns - t0) / 1e6, tp ? (h->timestamp_ns - tp) / 1e6 : 0.0, h->frame_us, h->exposure_lines,
			    h->again_x256 / 256.0, h->dgain_x256 / 256.0, h->lens, h->af_state);
		}
		tp = h->timestamp_ns;
		last = h->seq;
		got++;
	}
	if (got > 1) {
		fprintf(stderr, "%u frames read, %u skipped, %u repeated; %.2f frames/s read\n", got, skipped, dup,
		    (got - 1) * 1e9 / (double)(tp - t0));
	}
	if (out && got) {
		FILE *f = fopen(out, "wb");
		const struct cam_live_hdr *h = (const void *)buf;
		if (f) {
			fwrite(buf + h->hdr_size, 1, (size_t)h->stride * h->height, f);
			fclose(f);
		}
	}
	if (own) {
		set_int("kern.sweet_cam_stream", 0);
	}
	return got ? 0 : 1;
}

/* camframe -t N OUT: stream, N live frames, then a full-resolution still to OUT, stop */
static int
still(int n, const char *out)
{
	size_t cap = 0;
	if (set_int("kern.sweet_cam_stream", 1)) {
		return 1;
	}
	if (sysctlbyname("kern.sweet_cam_live", NULL, &cap, NULL, 0) != 0) {
		perror("kern.sweet_cam_live size");
		set_int("kern.sweet_cam_stream", 0);
		return 1;
	}
	char *buf = malloc(cap);
	uint32_t last = 0;
	for (int i = 0; buf && i < n; i++) {
		size_t len = cap;
		if (sysctlbyname("kern.sweet_cam_live", buf, &len, &last, sizeof(last)) != 0) {
			perror("kern.sweet_cam_live");
			break;
		}
		last = ((const struct cam_live_hdr *)buf)->seq;
	}
	const struct cam_live_hdr *lh = (const void *)buf;
	if (buf) {
		fprintf(stderr, "preview: seq %u, %u lines x %.2f x %.2f\n", lh->seq, lh->exposure_lines, lh->again_x256 / 256.0, lh->dgain_x256 / 256.0);
	}
	int rc = set_int("kern.sweet_cam_still", 1);
	size_t len = 0;
	if (!rc && sysctlbyname("kern.sweet_cam_still", NULL, &len, NULL, 0) == 0 && len) {
		char *b = malloc(len);
		if (b && sysctlbyname("kern.sweet_cam_still", b, &len, NULL, 0) == 0) {
			const struct cam_live_hdr *h = (const void *)b;
			fprintf(stderr, "still: seq %u, %ux%u stride %u, %u lines (line %u ns) x %.2f x %.2f, lens %u\n", h->seq, h->width, h->height,
			    h->stride, h->exposure_lines, h->line_ns, h->again_x256 / 256.0, h->dgain_x256 / 256.0, h->lens);
			FILE *f = fopen(out, "wb");
			if (f) {
				fwrite(b + h->hdr_size, 1, (size_t)h->stride * h->height, f);
				fclose(f);
			}
		} else {
			perror("kern.sweet_cam_still read");
			rc = 1;
		}
		free(b);
	}
	/* the preview after the still: does it run again */
	unsigned more = 0;
	for (int i = 0; buf && i < 10; i++) {
		size_t l2 = cap;
		if (sysctlbyname("kern.sweet_cam_live", buf, &l2, &last, sizeof(last)) != 0) {
			break;
		}
		if (((const struct cam_live_hdr *)buf)->seq != last) {
			more++;
		}
		last = ((const struct cam_live_hdr *)buf)->seq;
	}
	fprintf(stderr, "preview after the still: %u new frames of 10 reads\n", more);
	set_int("kern.sweet_cam_stream", 0);
	return rc;
}

int
main(int argc, char **argv)
{
	if (argc >= 3 && strcmp(argv[1], "-c") == 0) {
		if (set_int("kern.sweet_cam_sensor", atoi(argv[2]))) {
			return 1;
		}
		argv += 2;
		argc -= 2;
		if (argc < 2) {
			return 0;
		}
	}
	if (argc == 3 && strcmp(argv[1], "-S") == 0) {
		return load_seq_to(argv[2], "kern.sweet_cam_seq0");
	}
	if (argc == 4 && strcmp(argv[1], "-t") == 0) {
		return still(atoi(argv[2]), argv[3]);
	}
	if (argc == 3 && strcmp(argv[1], "-s") == 0) {
		return load_seq(argv[2]);
	}
	if (argc >= 3 && (strcmp(argv[1], "-l") == 0 || strcmp(argv[1], "-g") == 0)) {
		return live(atoi(argv[2]), argc > 3 ? argv[3] : NULL, argv[1][1] == 'l');
	}
	size_t len = 0;
	if (sysctlbyname("kern.sweet_cam_frame", NULL, &len, NULL, 0) != 0 || len == 0) {
		perror("size");
		return 1;
	}
	char *b = malloc(len);
	if (!b || sysctlbyname("kern.sweet_cam_frame", b, &len, NULL, 0) != 0) {
		perror("read");
		return 1;
	}
	size_t o = 0;
	while (o < len) {
		ssize_t w = write(1, b + o, len - o);
		if (w <= 0) {
			return 1;
		}
		o += (size_t)w;
	}
	fprintf(stderr, "%zu bytes\n", len);
	return 0;
}
