/*
 * sweethaptic [FILE.ahap]: CoreHaptics over SSH. Without a file: three transient taps 0.3 s apart and a continuous
 * 0.4 s buzz; with one, that AHAP pattern (e.g. /Library/Audio/Tunings/Generic/Haptics/Patterns/KeyboardInputText.ahap).
 * CoreHaptics renders through the audio HAL to its actuator device (VirtualAudioDevice_Actuator -> SweetSpeaker.driver's
 * "Actuator"); it needs closed-loop haptics in MobileGestalt (/product/haptics in the ADT, tools/adt-haptics.py).
 * iOS 18+, arm64e + pacstrip (tools/sweetnet/build.sh).
 */
#import <CoreHaptics/CoreHaptics.h>
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <unistd.h>

int
main(int argc, char **argv)
{
	@autoreleasepool {
		NSError *err = nil;
		id<CHHapticDeviceCapability> cap = [CHHapticEngine capabilitiesForHardware];
		printf("supportsHaptics %d supportsAudio %d\n", cap.supportsHaptics, cap.supportsAudio);
		CHHapticEngine *engine = [[CHHapticEngine alloc] initAndReturnError:&err];
		if (!engine) {
			printf("engine: %s\n", err.description.UTF8String);
			return 1;
		}
		engine.stoppedHandler = ^(CHHapticEngineStoppedReason reason) {
			printf("engine stopped, reason %ld\n", (long)reason);
		};
		if (![engine startAndReturnError:&err]) {
			printf("start: %s\n", err.description.UTF8String);
			return 1;
		}
		if (argc > 1) {
			BOOL ok = [engine playPatternFromURL:[NSURL fileURLWithPath:@(argv[1])] error:&err];
			printf("pattern %s: %s\n", argv[1], ok ? "playing" : err.description.UTF8String);
		} else {
			NSMutableArray<CHHapticEvent *> *events = [NSMutableArray array];
			for (int i = 0; i < 3; i++) {
				[events addObject:[[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticTransient parameters:@[
					[[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:1.0],
					[[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.5]]
				    relativeTime:0.3 * i]];
			}
			[events addObject:[[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous parameters:@[
				[[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:0.8]]
			    relativeTime:1.0 duration:0.4]];
			CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithEvents:events parameters:@[] error:&err];
			id<CHHapticPatternPlayer> player = pattern ? [engine createPlayerWithPattern:pattern error:&err] : nil;
			BOOL ok = player && [player startAtTime:CHHapticTimeImmediate error:&err];
			printf("taps + buzz: %s\n", ok ? "playing" : err.description.UTF8String);
		}
		sleep(3);
		[engine stopWithCompletionHandler:nil];
	}
	return 0;
}
