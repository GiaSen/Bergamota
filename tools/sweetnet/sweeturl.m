/*
 * sweeturl: open a URL over SSH as a tap on a link would (Safari for http/https), unlocking if needed.
 * Usage: sweeturl URL. SpringBoardServices' SBSOpenSensitiveURLAndUnlock, by name; needs
 * com.apple.springboard.opensensitiveurl (url.entitlements).
 */
#import <Foundation/Foundation.h>
#include <dlfcn.h>

int
main(int argc, char **argv)
{
	if (argc < 2) {
		fprintf(stderr, "usage: sweeturl URL\n");
		return 2;
	}
	dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);
	Boolean (*open_url)(CFURLRef, Boolean) = dlsym(RTLD_DEFAULT, "SBSOpenSensitiveURLAndUnlock");
	if (open_url == NULL) {
		fprintf(stderr, "sweeturl: SBSOpenSensitiveURLAndUnlock missing\n");
		return 1;
	}
	NSURL *u = [NSURL URLWithString:[NSString stringWithUTF8String:argv[1]]];
	if (u == nil) {
		fprintf(stderr, "sweeturl: not a URL\n");
		return 2;
	}
	Boolean ok = open_url((__bridge CFURLRef)u, 1);
	printf("open %s -> %d\n", argv[1], ok);
	return ok ? 0 : 1;
}
