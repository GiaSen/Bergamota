/*
 * sweetax: iOS's Reduce Motion and Reduce Transparency over SSH, through libAccessibility's own setters (what Settings >
 * Accessibility calls: they write the mobile user's com.apple.Accessibility and tell the running UI).
 *   sweetax                       show both
 *   sweetax motion 0|1            Reduce Motion (app open/close and other zooms become cross-fades, no parallax)
 *   sweetax transparency 0|1      Reduce Transparency (glass and blurs become plain fills)
 * Both may be given at once. Run as root: it drops to mobile (501) first, the user whose settings these are.
 * Used to measure what the effects cost on the Mi 8 (tools/dipper-scenes.py A/B). iOS 18+, arm64e + pacstrip
 * (tools/sweetnet/build.sh).
 */
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern bool _AXSReduceMotionEnabled(void);
extern void _AXSSetReduceMotionEnabled(bool);
extern bool _AXSEnhanceBackgroundContrastEnabled(void);
extern void _AXSSetEnhanceBackgroundContrastEnabled(bool);

int
main(int argc, char **argv)
{
	if (getuid() == 0 && (setgid(501) != 0 || setuid(501) != 0)) {
		perror("sweetax: cannot become mobile");
		return 1;
	}
	setenv("HOME", "/var/mobile", 1);
	for (int i = 1; i + 1 < argc; i += 2) {
		bool on = atoi(argv[i + 1]) != 0;
		if (!strcmp(argv[i], "motion")) {
			_AXSSetReduceMotionEnabled(on);
		} else if (!strcmp(argv[i], "transparency")) {
			_AXSSetEnhanceBackgroundContrastEnabled(on);
		} else {
			fprintf(stderr, "usage: sweetax [motion 0|1] [transparency 0|1]\n");
			return 2;
		}
	}
	if (argc > 1) {
		usleep(300000);         /* let the setters' notifications go out before the process ends */
	}
	printf("reduce motion %d, reduce transparency %d\n", _AXSReduceMotionEnabled(), _AXSEnhanceBackgroundContrastEnabled());
	return 0;
}
