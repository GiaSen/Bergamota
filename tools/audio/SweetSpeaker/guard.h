/*
 * The speaker's guard (SweetSpeaker.driver): what every sample goes through before the amp, in place of the speaker
 * protection that Android runs in the TAS2557's tuning program. Without the amp's current and voltage feedback and the
 * speaker's parameters, it holds the signal to levels a small phone speaker takes, measured from the samples alone.
 * The design follows HakiOS's guard (oosexgang/hakios-xnu-kernel drivers/audio/hakios.guard.c, described in
 * docs/FORKS_SURVEY.md G9); this is our own code, in floating point:
 *
 *   make-up    a fixed gain in front, for Apple's iPhone 11 speaker chain (n104_speaker_general), which VirtualAudio
 *              runs on our port and which leaves even a full-scale tone 10.7 to 14 dB under full scale
 *   high-pass  second-order Butterworth at 200 Hz: below it the speaker gives out next to nothing, and what it gets
 *              there only moves the cone further and heats the coil
 *   power      the power that reaches the speaker, averaged over 0.2 s (cone and coil), 3 s (the coil warming) and
 *              60 s (magnet and frame): the gain is the largest that keeps all three at or under their limits, 3, 6
 *              and 9 dB under a full-scale sine, for the signal's power smoothed over 10 ms (so the gain does not
 *              reshape the waveform within a cycle); it drops at once and comes back over 100 ms, and the averages fall
 *              while nothing plays too
 *   peaks      no sample above 3 dB under full scale: the gain drops at the sample that would exceed and recovers with
 *              a 43 ms time constant
 *
 * Full scale is that of the amp at its current gain (DAC gain 2 of 15; Android's programs run it at 15), taken as if it
 * were the loudest the speaker ever gets: stricter than HakiOS at Android's level.
 */
#ifndef SWEETSPEAKER_GUARD_H
#define SWEETSPEAKER_GUARD_H

struct ss_guard {
	float makeup;
	float b0, b1, b2, a1, a2;               /* the high-pass, normalised (a0 = 1) */
	float x1[2], x2[2], y1[2], y2[2];
	float coef[3], avg[3], limit[3];        /* the power averages of what reaches the speaker, and their limits */
	float tau[3];
	float p_short, c_short;                 /* the signal's power over 10 ms, before the power stage */
	float power_gain, power_release;
	float peak_gain, release, ceiling;
	float min_gain;                         /* the lowest power x peak gain since guard_take_min() */
};

void guard_init(struct ss_guard *g, float rate, float makeup_db);
/* interleaved stereo Float32, in place */
void guard_run(struct ss_guard *g, float *io, unsigned frames);
/* nothing played for seconds: the averages fall as the speaker cools */
void guard_rest(struct ss_guard *g, float seconds);
/* the lowest gain applied since the last call, in dB (0 = untouched), then reset */
float guard_take_min_db(struct ss_guard *g);

#endif
