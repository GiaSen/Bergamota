/*
 * sweetvibe [ID [COUNT [GAP_MS]]]: play iOS system sounds over SSH, by default the vibration (kSystemSoundID_Vibrate,
 * 4095), COUNT times GAP_MS apart (default once). With closed-loop haptics (/product/haptics in the ADT) iOS plays
 * vibrations and feedbacks as waveforms on the audio HAL's "Actuator" device (SweetSpeaker.driver logs what arrives:
 * `sweetlog 30 SweetSpeaker`). Haptic-only system sounds of a Taptic Engine phone: 1519 peek, 1520 pop, 1521 nope.
 * iOS 18+, arm64e + pacstrip (tools/sweetnet/build.sh).
 */
#include <AudioToolbox/AudioToolbox.h>
#include <dispatch/dispatch.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int
main(int argc, char **argv)
{
	SystemSoundID id = argc > 1 ? (SystemSoundID)strtoul(argv[1], NULL, 0) : kSystemSoundID_Vibrate;
	int count = argc > 2 ? atoi(argv[2]) : 1;
	int gap = argc > 3 ? atoi(argv[3]) : 1500;
	for (int i = 0; i < count; i++) {
		dispatch_semaphore_t done = dispatch_semaphore_create(0);
		AudioServicesPlaySystemSoundWithCompletion(id, ^{
			dispatch_semaphore_signal(done);
		});
		long timed_out = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
		printf("system sound %u: %s\n", (unsigned)id, timed_out ? "no completion in 5 s" : "completed");
		if (i + 1 < count) {
			usleep((useconds_t)gap * 1000);
		}
	}
	return 0;
}
