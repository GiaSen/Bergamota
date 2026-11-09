/*
 * Runs sweetcam's rotation self-test on the phone, outside cameracaptured (sweetcam.m, sweetcam_rot_selftest): the
 * entries of VideoToolbox's two pixel rotation functions rewritten, a test picture turned on the CPU.
 *   rottest [DYLIB [OUT]]     defaults /usr/local/lib/sweetcam.dylib, /var/root/rot.out (writes OUT.0 and OUT.1)
 * Build as the library (arm64e, then tools/renegade/pacstrip.py --sign); tools/camera/yuv2png.py makes PNGs of the outputs.
 */
#include <dlfcn.h>
#include <stdio.h>

int
main(int argc, char **argv)
{
	void *h = dlopen(argc > 1 ? argv[1] : "/usr/local/lib/sweetcam.dylib", RTLD_NOW);
	if (!h) {
		fprintf(stderr, "%s\n", dlerror());
		return 1;
	}
	int (*test)(const char *) = dlsym(h, "sweetcam_rot_selftest");
	if (!test) {
		fprintf(stderr, "no sweetcam_rot_selftest in the library\n");
		return 1;
	}
	return test(argc > 2 ? argv[2] : "/var/root/rot.out");
}
