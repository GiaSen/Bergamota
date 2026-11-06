/* sweetcx N: run kern.sweet_codec stage N (0-14) as a one-character string (the handler reads one digit: '0' + N) */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
int main(int argc, char **argv) {
	if (argc < 2) return 2;
	char c[2] = { (char)('0' + atoi(argv[1])), 0 };
	if (sysctlbyname("kern.sweet_codec", NULL, NULL, c, 1) != 0) { printf("stage %s: %s\n", argv[1], strerror(errno)); return 1; }
	return 0;
}
