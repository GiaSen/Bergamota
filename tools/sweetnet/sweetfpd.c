/*
 * sweetfpd: FairPlay's Mach services, answering every request with an error.
 *
 * fairplayd.H2 exits at once on this hardware (status 0, about once a minute under launchd's KeepAlive), and launchd keeps its
 * names, so a request stays in the port's queue and its sender waits for ever. locationd does that in a silo thread (MIG 1203
 * on com.apple.fairplayd.versioned), then every CoreLocation client waits for locationd: News' main thread at launch.
 * This takes the job's place (root_tweaks18.py, FAIRPLAY_JOB): a MIG client gets MIG_BAD_ID, anything else loses its message and
 * sees the reply right die. The first requests are logged to /private/var/tmp/sweetfpd.log with their sender.
 */
#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>

extern kern_return_t bootstrap_check_in(mach_port_t bp, const char *name, mach_port_t *sp);
extern mach_port_t bootstrap_port;

#define LOG_FIRST 64

static const char *const names[] = {
	"com.apple.fairplayd",
	"com.apple.fairplayd.versioned",
	"com.apple.fairplayd.xpc",
	"com.apple.unfreed",
};

int
main(void)
{
	static union {
		mach_msg_header_t h;
		char b[64 * 1024];
	} m;
	mach_port_t set = MACH_PORT_NULL;
	unsigned seen = 0;
	FILE *log = fopen("/private/var/tmp/sweetfpd.log", "a");

	if (log != NULL) {
		setvbuf(log, NULL, _IOLBF, 0);
	}
	if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_PORT_SET, &set) != KERN_SUCCESS) {
		return 1;
	}
	for (unsigned i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
		mach_port_t p = MACH_PORT_NULL;
		kern_return_t kr = bootstrap_check_in(bootstrap_port, names[i], &p);
		if (kr == KERN_SUCCESS) {
			kr = mach_port_move_member(mach_task_self(), p, set);
		}
		if (log != NULL) {
			fprintf(log, "check in %s: %s\n", names[i], mach_error_string(kr));
		}
	}
	for (;;) {
		mach_msg_option_t opt = MACH_RCV_MSG | MACH_RCV_TRAILER_TYPE(MACH_MSG_TRAILER_FORMAT_0) |
		    MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_AUDIT);
		if (mach_msg(&m.h, opt, 0, sizeof(m), set, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL) != MACH_MSG_SUCCESS) {
			continue;       /* too large: the kernel has destroyed it, and its reply right with it */
		}
		if (log != NULL && seen < LOG_FIRST) {
			mach_msg_audit_trailer_t *t = (mach_msg_audit_trailer_t *)((char *)&m.h + ((m.h.msgh_size + 3u) & ~3u));
			fprintf(log, "id %d size %u from pid %d\n", m.h.msgh_id, m.h.msgh_size, (int)t->msgh_audit.val[5]);
		}
		seen++;
		if (m.h.msgh_remote_port != MACH_PORT_NULL && m.h.msgh_id >= 0 && m.h.msgh_id < 0x10000) {
			mig_reply_error_t r = {
				.Head = {
					.msgh_bits = MACH_MSGH_BITS(MACH_MSGH_BITS_REMOTE(m.h.msgh_bits), 0),
					.msgh_size = sizeof(r),
					.msgh_remote_port = m.h.msgh_remote_port,
					.msgh_id = m.h.msgh_id + 100,
				},
				.NDR = NDR_record,
				.RetCode = MIG_BAD_ID,
			};
			if (mach_msg(&r.Head, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof(r), 0, MACH_PORT_NULL, 0, MACH_PORT_NULL) == MACH_MSG_SUCCESS) {
				m.h.msgh_remote_port = MACH_PORT_NULL;
			}
		}
		mach_msg_destroy(&m.h);
	}
}
