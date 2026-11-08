/*
 * Camera bring-up helper for the Mi 8 kernels (xnu 3076+).
 *   camframe              writes kern.sweet_cam_frame (the last kern.sweet_cam=3 / =4 buffer) to stdout;
 *                         tools/camera/frame2png.py makes a PNG of it
 *   camframe -s FILE      loads FILE into kern.sweet_cam_seq (3077+: the rear main sensor's register sequence, made on
 *                         the Mac by tools/camera/camx_v1.py --seq from the phone's own module file; never in git)
 *   xcrun -sdk iphoneos clang -arch arm64 -mios-version-min=18.0 camframe.c -o camframe && codesign -s - -f camframe
 *   cat camframe | ssh root@192.168.7.2 'cat > /var/root/camframe && chmod 755 /var/root/camframe'
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <unistd.h>

static int
load_seq(const char *path)
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
	if (sysctlbyname("kern.sweet_cam_seq", NULL, NULL, buf, n) != 0) {
		perror("kern.sweet_cam_seq");
		return 1;
	}
	fprintf(stderr, "%zu records loaded\n", n / 8);
	return 0;
}

int
main(int argc, char **argv)
{
	if (argc == 3 && strcmp(argv[1], "-s") == 0) {
		return load_seq(argv[2]);
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
