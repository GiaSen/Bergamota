/*
 * Writes kern.sweet_cam_frame (xnu 3076+, the camera step C3's buffer) to stdout; tools/camera/frame2png.py makes a PNG.
 *   xcrun -sdk iphoneos clang -arch arm64 -mios-version-min=18.0 camframe.c -o camframe && codesign -s - -f camframe
 *   cat camframe | ssh root@192.168.7.2 'cat > /var/root/camframe && chmod 755 /var/root/camframe'
 */
#include <stdio.h>
#include <stdlib.h>
#include <sys/sysctl.h>
#include <unistd.h>
int main(void) {
	size_t len = 0;
	if (sysctlbyname("kern.sweet_cam_frame", NULL, &len, NULL, 0) != 0 || len == 0) { perror("size"); return 1; }
	char *b = malloc(len);
	if (!b || sysctlbyname("kern.sweet_cam_frame", b, &len, NULL, 0) != 0) { perror("read"); return 1; }
	size_t o = 0;
	while (o < len) { ssize_t w = write(1, b + o, len - o); if (w <= 0) return 1; o += (size_t)w; }
	fprintf(stderr, "%zu bytes\n", len);
	return 0;
}
