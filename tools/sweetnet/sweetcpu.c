/*
 * sweetcpu: where the CPU time goes over a window, the kernel's threads included (toybox ps does not list kernel_task).
 * Usage: sweetcpu [SECONDS, default 10]: per-CPU user/system/idle, then the busiest processes. sweetcpu --kernel [SECONDS]: the kernel's threads;
 * sweetcpu --task PID [SECONDS]: one process's threads, with priority and policy (1 timeshare, 2 fixed/real-time, 4 round robin).
 * Read-only.
 * Build: tools/sweetnet/build.sh (arm64e, then `renegade strip --sign`).
 */
#include <mach/mach.h>
#include <mach/mach_error.h>
#include <mach/mach_time.h>
#include <mach/processor_info.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* the iOS SDK has no libproc.h / sys/proc_info.h: the libSystem calls and the ABI of the two structs (macOS SDK, same kernel) */
#define PROC_PIDTASKINFO 4
#define PROC_PIDTHREADINFO 5
#define PROC_PIDLISTTHREADS 6
int proc_pidinfo(int pid, int flavor, uint64_t arg, void *buffer, int buffersize);
int proc_listallpids(void *buffer, int buffersize);
int proc_name(int pid, void *buffer, uint32_t buffersize);
struct proc_taskinfo {
	uint64_t pti_virtual_size, pti_resident_size, pti_total_user, pti_total_system, pti_threads_user, pti_threads_system;
	int32_t pti_policy, pti_faults, pti_pageins, pti_cow_faults, pti_messages_sent, pti_messages_received;
	int32_t pti_syscalls_mach, pti_syscalls_unix, pti_csw, pti_threadnum, pti_numrunning, pti_priority;
};
struct proc_threadinfo {
	uint64_t pth_user_time, pth_system_time;
	int32_t pth_cpu_usage, pth_policy, pth_run_state, pth_flags, pth_sleep_time, pth_curpri, pth_priority, pth_maxpriority;
	char pth_name[64];
};

#define MAX_THREADS 4096
#define MAX_PIDS 2048

struct cpu_ticks {
	natural_t t[CPU_STATE_MAX];
};

/* proc_pidinfo reports Mach ticks on arm64 */
static uint64_t
ticks_to_ns(uint64_t t)
{
	static mach_timebase_info_data_t tb;
	if (!tb.denom)
		mach_timebase_info(&tb);
	return t * tb.numer / tb.denom;
}

struct kthread {
	uint64_t id, ns;
	char name[64];
	int pri;
};

struct proc_time {
	int pid;
	uint64_t ns;
	char name[64];
};

static unsigned
cpu_sample(struct cpu_ticks *out, unsigned max)
{
	natural_t n = 0;
	processor_info_array_t info;
	mach_msg_type_number_t cnt;
	if (host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &n, &info, &cnt) != KERN_SUCCESS)
		return 0;
	for (natural_t i = 0; i < n && i < max; i++)
		memcpy(out[i].t, &info[i * CPU_STATE_MAX], sizeof(out[i].t));
	vm_deallocate(mach_task_self(), (vm_address_t)info, cnt * sizeof(*info));
	return n < max ? n : max;
}

static unsigned
kthread_sample(struct kthread *out, unsigned max)
{
	static uint64_t ids[MAX_THREADS];
	int bytes = proc_pidinfo(0, PROC_PIDLISTTHREADS, 0, ids, sizeof(ids));
	if (bytes <= 0)
		return 0;
	unsigned n = 0, count = bytes / sizeof(ids[0]);
	for (unsigned i = 0; i < count && n < max; i++) {
		struct proc_threadinfo ti;
		if (proc_pidinfo(0, PROC_PIDTHREADINFO, ids[i], &ti, sizeof(ti)) != sizeof(ti))
			continue;
		out[n].id = ids[i];
		out[n].ns = ticks_to_ns(ti.pth_user_time + ti.pth_system_time);
		out[n].pri = ti.pth_curpri;
		snprintf(out[n].name, sizeof(out[n].name), "%s", ti.pth_name[0] ? ti.pth_name : "(unnamed)");
		n++;
	}
	return n;
}

static unsigned
proc_sample(struct proc_time *out, unsigned max)
{
	static int pids[MAX_PIDS];
	int bytes = proc_listallpids(pids, sizeof(pids));
	if (bytes <= 0)
		return 0;
	unsigned n = 0;
	for (int i = 0; i < bytes && n < max; i++) {
		struct proc_taskinfo ti;
		if (proc_pidinfo(pids[i], PROC_PIDTASKINFO, 0, &ti, sizeof(ti)) != sizeof(ti))
			continue;
		out[n].pid = pids[i];
		out[n].ns = ticks_to_ns(ti.pti_total_user + ti.pti_total_system);
		proc_name(pids[i], out[n].name, sizeof(out[n].name));
		n++;
	}
	return n;
}

static int
by_ns_desc(const void *a, const void *b)
{
	uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
	return x < y ? 1 : x > y ? -1 : 0;
}

/* A task's threads through the privileged processor set (proc_pidinfo lists none for pid 0, the kernel): the busiest over the window. */
struct kt {
	uint64_t id, us;
	int pri, base, policy, run;
	char name[64];
};

static unsigned
task_thread_list(int want_pid, struct kt *out, unsigned max)
{
	host_priv_t priv = MACH_PORT_NULL;
	processor_set_name_array_t names;
	mach_msg_type_number_t nnames = 0, ntasks = 0, nth = 0;
	processor_set_t pset = MACH_PORT_NULL;
	task_array_t tasks;
	thread_act_array_t th;
	if (host_get_host_priv_port(mach_host_self(), &priv) != KERN_SUCCESS || host_processor_sets(priv, &names, &nnames) != KERN_SUCCESS || !nnames ||
	    host_processor_set_priv(priv, names[0], &pset) != KERN_SUCCESS || processor_set_tasks(pset, &tasks, &ntasks) != KERN_SUCCESS)
		return 0;
	for (unsigned t = 0; t < ntasks; t++) {
		int pid = -1;
		pid_for_task(tasks[t], &pid);
		if (pid == want_pid && task_threads(tasks[t], &th, &nth) == KERN_SUCCESS)
			break;
		nth = 0;
	}
	unsigned n = 0;
	for (unsigned i = 0; i < nth && n < max; i++) {
		struct thread_basic_info bi;
		struct thread_extended_info ei;
		struct thread_identifier_info ii;
		mach_msg_type_number_t c = THREAD_BASIC_INFO_COUNT;
		if (thread_info(th[i], THREAD_BASIC_INFO, (thread_info_t)&bi, &c) != KERN_SUCCESS)
			continue;
		memset(&ei, 0, sizeof(ei));
		c = THREAD_EXTENDED_INFO_COUNT;
		(void)thread_info(th[i], THREAD_EXTENDED_INFO, (thread_info_t)&ei, &c);
		c = THREAD_IDENTIFIER_INFO_COUNT;
		ii.thread_id = 0;
		(void)thread_info(th[i], THREAD_IDENTIFIER_INFO, (thread_info_t)&ii, &c);
		out[n].id = ii.thread_id;
		out[n].us = (uint64_t)bi.user_time.seconds * 1000000 + bi.user_time.microseconds + (uint64_t)bi.system_time.seconds * 1000000 + bi.system_time.microseconds;
		out[n].pri = ei.pth_curpri;
		out[n].base = ei.pth_priority;
		out[n].policy = bi.policy;
		out[n].run = bi.run_state == TH_STATE_RUNNING;
		snprintf(out[n].name, sizeof(out[n].name), "%s", ei.pth_name[0] ? ei.pth_name : "(unnamed)");
		n++;
	}
	return n;
}

static void
task_threads_window(int pid, int secs)
{
	static struct kt a[MAX_THREADS], b[MAX_THREADS];
	unsigned na = task_thread_list(pid, a, MAX_THREADS);
	sleep(secs);
	unsigned nb = task_thread_list(pid, b, MAX_THREADS);
	printf("pid %d threads: %u, then %u, over %d s\n", pid, na, nb, secs);
	for (unsigned shown = 0; shown < 16; shown++) {
		uint64_t best = 0;
		int bi = -1;
		for (unsigned i = 0; i < nb; i++) {
			uint64_t before = 0;
			for (unsigned j = 0; j < na; j++)
				if (a[j].id == b[i].id) {
					before = a[j].us;
					break;
				}
			uint64_t d = b[i].us > before ? b[i].us - before : 0;
			if (d > best) {
				best = d;
				bi = (int)i;
			}
		}
		if (bi < 0)
			break;
		printf("  %8.3f s  %5.1f%%  pri %3d base %3d policy %d %s id %#llx  %s  (total %.1f s)\n", best / 1e6, best / 1e4 / secs, b[bi].pri, b[bi].base, b[bi].policy,
		    b[bi].run ? "run " : "wait", (unsigned long long)b[bi].id, b[bi].name, b[bi].us / 1e6);
		b[bi].us = 0;
	}
}

int
main(int argc, char **argv)
{
	if (argc > 1 && !strcmp(argv[1], "--kernel")) {
		task_threads_window(0, argc > 2 ? atoi(argv[2]) : 10);
		return 0;
	}
	if (argc > 2 && !strcmp(argv[1], "--task")) {
		task_threads_window(atoi(argv[2]), argc > 3 ? atoi(argv[3]) : 10);
		return 0;
	}
	int secs = argc > 1 ? atoi(argv[1]) : 10;
	if (secs < 1)
		secs = 10;
	static struct cpu_ticks c0[16], c1[16];
	static struct kthread k0[MAX_THREADS], k1[MAX_THREADS];
	static struct proc_time p0[MAX_PIDS], p1[MAX_PIDS];
	unsigned nc0 = cpu_sample(c0, 16), nk0 = kthread_sample(k0, MAX_THREADS), np0 = proc_sample(p0, MAX_PIDS);
	sleep(secs);
	unsigned nc1 = cpu_sample(c1, 16), nk1 = kthread_sample(k1, MAX_THREADS), np1 = proc_sample(p1, MAX_PIDS);

	printf("window %d s\n", secs);
	for (unsigned i = 0; i < nc0 && i < nc1; i++) {
		uint64_t u = c1[i].t[CPU_STATE_USER] - c0[i].t[CPU_STATE_USER] + c1[i].t[CPU_STATE_NICE] - c0[i].t[CPU_STATE_NICE];
		uint64_t s = c1[i].t[CPU_STATE_SYSTEM] - c0[i].t[CPU_STATE_SYSTEM];
		uint64_t d = c1[i].t[CPU_STATE_IDLE] - c0[i].t[CPU_STATE_IDLE];
		uint64_t all = u + s + d;
		printf("cpu%u: user %3llu%% system %3llu%% idle %3llu%%\n", i, all ? u * 100 / all : 0, all ? s * 100 / all : 0, all ? d * 100 / all : 0);
	}

	struct row {
		uint64_t ns;
		const char *name;
		uint64_t id;
		int pri;
	};
	static struct row rows[MAX_THREADS];
	unsigned nr = 0;
	uint64_t ktotal = 0;
	for (unsigned i = 0; i < nk1; i++) {
		uint64_t before = 0;
		for (unsigned j = 0; j < nk0; j++)
			if (k0[j].id == k1[i].id) {
				before = k0[j].ns;
				break;
			}
		if (k1[i].ns <= before)
			continue;
		rows[nr++] = (struct row){ k1[i].ns - before, k1[i].name, k1[i].id, k1[i].pri };
		ktotal += k1[i].ns - before;
	}
	qsort(rows, nr, sizeof(rows[0]), by_ns_desc);
	printf("kernel threads: %u ran, %.2f CPU seconds (idle threads included, if the kernel accounts them)\n", nr, ktotal / 1e9);
	for (unsigned i = 0; i < nr && i < 16; i++)
		printf("  %7.3f s  pri %3d  %#llx  %s\n", rows[i].ns / 1e9, rows[i].pri, (unsigned long long)rows[i].id, rows[i].name);

	nr = 0;
	uint64_t ptotal = 0;
	for (unsigned i = 0; i < np1; i++) {
		uint64_t before = 0;
		for (unsigned j = 0; j < np0; j++)
			if (p0[j].pid == p1[i].pid) {
				before = p0[j].ns;
				break;
			}
		if (p1[i].ns <= before)
			continue;
		rows[nr++] = (struct row){ p1[i].ns - before, p1[i].name, (uint64_t)p1[i].pid, 0 };
		ptotal += p1[i].ns - before;
	}
	qsort(rows, nr, sizeof(rows[0]), by_ns_desc);
	printf("processes: %u ran, %.2f CPU seconds (pid 0 is kernel_task)\n", nr, ptotal / 1e9);
	for (unsigned i = 0; i < nr && i < 16; i++)
		printf("  %7.3f s  %5llu  %s\n", rows[i].ns / 1e9, (unsigned long long)rows[i].id, rows[i].name);
	return 0;
}
