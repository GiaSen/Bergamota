/*
 * sweetreg: WCD9340 codec registers over SLIMbus through kern.sweet_codec_reg (xnu 3067b, the codec up first).
 *   sweetreg REG ...          read codec registers (hex, e.g. 0x60a)
 *   sweetreg REG=VAL ...      write, then read back
 *   prefix i (i0x34, i0x40=05) for the interface device's registers (SLIMbus ports)
 * iOS 18+, arm64e + pacstrip (tools/sweetnet/build.sh).
 */
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>

int
main(int argc, char **argv)
{
	if (argc < 2) {
		fprintf(stderr, "usage: sweetreg [i]REG[=VAL] ...\n");
		return 2;
	}
	int bad = 0;
	for (int i = 1; i < argc; i++) {
		const char *a = argv[i];
		int ifd = a[0] == 'i';
		if (ifd) {
			a++;
		}
		char *end = NULL;
		unsigned long reg = strtoul(a, &end, 16);
		int wr = end && *end == '=';
		unsigned long val = wr ? strtoul(end + 1, NULL, 16) : 0;
		struct {
			uint16_t reg;
			uint8_t val, op;
		} in = { (uint16_t)reg, (uint8_t)val, (uint8_t)((ifd ? 2 : 0) + (wr ? 1 : 0)) };
		uint8_t out[2] = { 0, 0 };
		size_t len = sizeof(out);
		if (sysctlbyname("kern.sweet_codec_reg", out, &len, &in, sizeof(in)) != 0) {
			printf("%s%#06lx: %s\n", ifd ? "if " : "", reg, strerror(errno));
			bad = 1;
			continue;
		}
		printf("%s%#06lx%s = %02x%s\n", ifd ? "if " : "", reg, wr ? " (written)" : "", out[0], out[1] ? " ERR" : "");
	}
	return bad;
}
