/*
 * sweetdump NAME: write a sysctl's raw value (string or opaque) to stdout, e.g. kern.sweet_log_prev (xnu 3058d,
 * the previous boot's console log) or kern.sweet_codec. iOS 18+, arm64e + pacstrip (tools/sweetnet/build.sh).
 */
#include <stdio.h>
#include <stdlib.h>
#include <sys/sysctl.h>

int
main(int argc, char **argv)
{
	size_t n = 0;
	if (argc != 2) {
		fprintf(stderr, "usage: sweetdump SYSCTL\n");
		return 2;
	}
	if (sysctlbyname(argv[1], NULL, &n, NULL, 0) != 0) {
		perror(argv[1]);
		return 1;
	}
	char *b = malloc(n + 1);
	if (!b || sysctlbyname(argv[1], b, &n, NULL, 0) != 0) {
		perror(argv[1]);
		return 1;
	}
	fwrite(b, 1, n, stdout);
	return 0;
}
