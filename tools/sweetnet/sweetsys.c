/*
 * sweetsys: read string or int sysctls, set int ones (there is no sysctl command on the phone).
 * Usage: sweetsys NAME... (a string, or an int if the value is 4 bytes) | sweetsys NAME=VALUE...
 * Build: tools/sweetnet/build.sh (arm64e, then `renegade strip --sign`).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>

int
main(int argc, char **argv)
{
	static char b[65536];
	int status = 0;
	for (int i = 1; i < argc; i++) {
		char *eq = strchr(argv[i], '=');
		size_t n = sizeof(b) - 1;
		if (eq) {
			int v = atoi(eq + 1);
			*eq = 0;
			if (sysctlbyname(argv[i], NULL, NULL, &v, sizeof(v))) {
				perror(argv[i]);
				status = 1;
			}
			continue;
		}
		if (sysctlbyname(argv[i], b, &n, NULL, 0)) {
			perror(argv[i]);
			status = 1;
			continue;
		}
		if (n == sizeof(int)) {
			printf("%s=%d\n", argv[i], *(int *)b);
		} else {
			b[n] = 0;
			printf("%s\n", b);
		}
	}
	return status;
}
