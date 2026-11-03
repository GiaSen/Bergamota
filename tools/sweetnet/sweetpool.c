/*
 * sweetpool: copy a file into the Mi 8's audio PCM window (kern.sweet_audio_pool, bsd/dev/dipper_audio.c) at an
 * offset, 60 KiB per call, then print the window's address. The PCM comes from tools/audio/mkpcm.py.
 *
 *   sweetpool FILE [OFFSET]
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>

int
main(int argc, char **argv)
{
	static uint8_t buf[4 + 61440];
	char text[128];
	if (argc < 2) {
		fprintf(stderr, "usage: sweetpool FILE [OFFSET]\n");
		return 2;
	}
	FILE *f = fopen(argv[1], "rb");
	if (!f) {
		perror(argv[1]);
		return 1;
	}
	uint32_t off = argc > 2 ? (uint32_t)strtoul(argv[2], NULL, 0) : 0, total = 0;
	for (;;) {
		size_t n = fread(buf + 4, 1, sizeof(buf) - 4, f);
		if (!n) {
			break;
		}
		memcpy(buf, &off, 4);
		size_t tl = sizeof(text);
		if (sysctlbyname("kern.sweet_audio_pool", text, &tl, buf, 4 + n) != 0) {
			perror("kern.sweet_audio_pool");
			return 1;
		}
		off += (uint32_t)n;
		total += (uint32_t)n;
	}
	fclose(f);
	size_t tl = sizeof(text);
	if (sysctlbyname("kern.sweet_audio_pool", text, &tl, NULL, 0) == 0) {
		printf("%u bytes written; %s", total, text);
	}
	return 0;
}
