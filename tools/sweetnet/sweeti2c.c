/*
 * sweeti2c: play an I2C script on the Mi 8's speaker amp bus (kern.sweet_audio_i2c, bsd/dev/dipper_audio.c) and print
 * what came back: the ops done, the error, the bytes read. Scripts come from tools/audio/tas2557fw.py --script.
 *
 *   sweeti2c SCRIPT
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>

int
main(int argc, char **argv)
{
	static uint8_t in[65536], out[8 + 4096];
	if (argc != 2) {
		fprintf(stderr, "usage: sweeti2c SCRIPT\n");
		return 2;
	}
	FILE *f = fopen(argv[1], "rb");
	if (!f) {
		perror(argv[1]);
		return 1;
	}
	size_t n = fread(in, 1, sizeof(in), f);
	fclose(f);
	size_t outlen = sizeof(out);
	if (sysctlbyname("kern.sweet_audio_i2c", out, &outlen, in, n) != 0) {
		perror("kern.sweet_audio_i2c");
		return 1;
	}
	uint32_t done;
	int32_t e;
	memcpy(&done, out, 4);
	memcpy(&e, out + 4, 4);
	static const char *const what[] = { "ok", "NACK on the address", "NACK on data", "SCL held low", "bad script" };
	printf("ops %u, %s", done, e >= 0 && e <= 4 ? what[e] : "?");
	if (outlen > 8) {
		printf(", read:");
		for (size_t i = 8; i < outlen; i++) {
			printf(" %02x", out[i]);
		}
	}
	printf("\n");
	return e ? 1 : 0;
}
