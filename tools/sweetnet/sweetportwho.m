/*
 * sweetportwho NAME RETADDR [SECONDS]: wait (default 60 s) for a thread of process NAME blocked in mach_msg2 whose frame chain
 * holds RETADDR (an unslid shared-cache address: the return address after the mach_msg call, from a crash report or stackshot),
 * then say where its message went: the remote port's kernel object type, the processes that hold its receive right
 * (mach_port_space_info objects compared across tasks), and the launchd names, looked up through the process's own bootstrap
 * port, that resolve to it. For requests that never get an answer: launchd holding the receive right means the job never runs.
 * Found lskdd behind mediaplaybackd's HLS hang (2026-11-03). iOS 18+, arm64e + pacstrip; sample.entitlements (task_for_pid-allow).
 */
#import <Foundation/Foundation.h>
#include <mach/mach.h>
#include <mach-o/dyld_images.h>
#include <sys/sysctl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern kern_return_t bootstrap_look_up(mach_port_t bp, const char *name, mach_port_t *sp);
#define ADDR(x) ((uint64_t)(x) & 0x0000000FFFFFFFFFull)

static int
rd(task_t t, uint64_t a, void *buf, size_t n)
{
	vm_size_t got = 0;
	return vm_read_overwrite(t, (vm_address_t)a, n, (vm_address_t)buf, &got) == KERN_SUCCESS && got == n ? 0 : -1;
}

static struct kinfo_proc *
procs(size_t *n)
{
	int mib[3] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL };
	size_t len = 0;
	if (sysctl(mib, 3, NULL, &len, NULL, 0) != 0) return NULL;
	len += 64 * sizeof(struct kinfo_proc);
	struct kinfo_proc *kp = malloc(len);
	if (sysctl(mib, 3, kp, &len, NULL, 0) != 0) { free(kp); return NULL; }
	*n = len / sizeof(*kp);
	return kp;
}

static pid_t
find_pid(const char *s)
{
	size_t n = 0;
	struct kinfo_proc *kp = procs(&n);
	pid_t pid = -1;
	for (size_t i = 0; kp && i < n; i++)
		if (strncmp(kp[i].kp_proc.p_comm, s, MAXCOMLEN) == 0) { pid = kp[i].kp_proc.p_pid; break; }
	free(kp);
	return pid;
}

static void
collect_names(id o, NSMutableArray *out)
{
	if ([o isKindOfClass:[NSDictionary class]]) {
		NSDictionary *d = o;
		for (id k in d) {
			id v = d[k];
			if ([k isEqual:@"MachServices"] && [v isKindOfClass:[NSDictionary class]])
				for (id name in v) [out addObject:[NSString stringWithFormat:@"%@\t%@", name, d[@"Label"] ?: @"?"]];
			else
				collect_names(v, out);
		}
	} else if ([o isKindOfClass:[NSArray class]]) {
		for (id v in o) collect_names(v, out);
	}
}

static natural_t
object_of(task_t t, mach_port_name_t name, natural_t *type)
{
	ipc_info_space_t info;
	ipc_info_name_array_t table = NULL;
	ipc_info_tree_name_array_t tree = NULL;
	mach_msg_type_number_t tc = 0, trc = 0;
	natural_t obj = 0;
	if (mach_port_space_info(t, &info, &table, &tc, &tree, &trc) != KERN_SUCCESS) return 0;
	for (mach_msg_type_number_t i = 0; i < tc; i++)
		if (table[i].iin_name == name) { obj = table[i].iin_object; *type = table[i].iin_type; }
	vm_deallocate(mach_task_self(), (vm_address_t)table, tc * sizeof(*table));
	if (tree) vm_deallocate(mach_task_self(), (vm_address_t)tree, trc * sizeof(*tree));
	return obj;
}

int
main(int argc, char **argv)
{
	if (argc < 3) { fprintf(stderr, "usage: sweetportwho NAME RETADDR [SECONDS]\n"); return 2; }
	uint64_t want = strtoull(argv[2], NULL, 0);
	int secs = argc > 3 ? atoi(argv[3]) : 60;
	task_t task = MACH_PORT_NULL;
	thread_act_array_t th = NULL;
	mach_msg_type_number_t nth = 0;
	uint64_t msgp = 0, opt = 0, x3 = 0;
	pid_t pid = -1;
	int found = -1;

	for (int tick = 0; tick < secs * 5 && found < 0; tick++) {
		usleep(200000);
		pid_t p = find_pid(argv[1]);
		if (p <= 0) continue;
		if (p != pid) {
			if (task != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), task);
			task = MACH_PORT_NULL;
			if (task_for_pid(mach_task_self(), p, &task) != KERN_SUCCESS) { fprintf(stderr, "task_for_pid %d failed\n", p); continue; }
			pid = p;
		}
		struct task_dyld_info di;
		mach_msg_type_number_t cnt = TASK_DYLD_INFO_COUNT;
		struct dyld_all_image_infos aii;
		if (task_info(task, TASK_DYLD_INFO, (task_info_t)&di, &cnt) != KERN_SUCCESS || rd(task, di.all_image_info_addr, &aii, sizeof(aii))) continue;
		if (task_threads(task, &th, &nth) != KERN_SUCCESS) continue;
		for (mach_msg_type_number_t i = 0; i < nth && found < 0; i++) {
			arm_thread_state64_t st;
			mach_msg_type_number_t sc = ARM_THREAD_STATE64_COUNT;
			if (thread_get_state(th[i], ARM_THREAD_STATE64, (thread_state_t)&st, &sc) != KERN_SUCCESS) continue;
			if ((uint32_t)st.__x[16] != (uint32_t)-47) continue;      /* mach_msg2_trap */
			uint64_t fp = ADDR(__darwin_arm_thread_state64_get_fp(st));
			for (int d = 0; d < 16 && fp; d++) {
				uint64_t fr[2];
				if (rd(task, fp, fr, sizeof(fr))) break;
				if (ADDR(fr[1]) - aii.sharedCacheSlide == want) { found = (int)i; break; }
				fp = ADDR(fr[0]);
			}
			if (found >= 0) { msgp = st.__x[0]; opt = st.__x[1]; x3 = st.__x[3]; }
		}
		if (found < 0) {
			for (mach_msg_type_number_t i = 0; i < nth; i++) mach_port_deallocate(mach_task_self(), th[i]);
			vm_deallocate(mach_task_self(), (vm_address_t)th, nth * sizeof(*th));
		}
	}
	if (found < 0) { printf("no thread of %s waiting under 0x%llx in %d s\n", argv[1], want, secs); return 1; }

	mach_msg_header_t h;
	memset(&h, 0, sizeof(h));
	rd(task, msgp, &h, sizeof(h));
	printf("pid %d thread %d: msg 0x%llx option64 0x%llx x3 0x%llx | header bits 0x%x size %u remote 0x%x local 0x%x id %d\n",
	    pid, found, msgp, opt, x3, h.msgh_bits, h.msgh_size, h.msgh_remote_port, h.msgh_local_port, h.msgh_id);
	mach_port_name_t names[2] = { h.msgh_remote_port, (mach_port_name_t)(x3 & 0xffffffff) };
	for (int k = 0; k < 2; k++) {
		mach_port_name_t rn = names[k];
		if (k == 1 && rn == names[0]) break;
		natural_t kt = 0;
		mach_vm_address_t ka = 0;
		kern_return_t kr = mach_port_kobject(task, rn, &kt, &ka);
		natural_t type = 0, obj = object_of(task, rn, &type);
		printf("name 0x%x: kobject %s type %u | space type 0x%x object 0x%x\n", rn, mach_error_string(kr), kt, type, obj);
		size_t np = 0;
		struct kinfo_proc *kp = procs(&np);
		for (size_t i = 0; obj && kp && i < np; i++) {
			pid_t q = kp[i].kp_proc.p_pid;
			task_t qt = MACH_PORT_NULL;
			if (task_for_pid(mach_task_self(), q, &qt) != KERN_SUCCESS) {
				if (q == 1 || q == 0) printf("  (no task port for pid %d)\n", q);
				continue;
			}
			ipc_info_space_t info;
			ipc_info_name_array_t table = NULL;
			ipc_info_tree_name_array_t tree = NULL;
			mach_msg_type_number_t tc = 0, trc = 0;
			if (mach_port_space_info(qt, &info, &table, &tc, &tree, &trc) == KERN_SUCCESS) {
				for (mach_msg_type_number_t j = 0; j < tc; j++)
					if (table[j].iin_object == obj && (table[j].iin_type & MACH_PORT_TYPE_RECEIVE))
						printf("  receive right: pid %d %.16s name 0x%x type 0x%x\n", q, kp[i].kp_proc.p_comm, table[j].iin_name, table[j].iin_type);
				vm_deallocate(mach_task_self(), (vm_address_t)table, tc * sizeof(*table));
				if (tree) vm_deallocate(mach_task_self(), (vm_address_t)tree, trc * sizeof(*tree));
			}
			mach_port_deallocate(mach_task_self(), qt);
		}
		free(kp);
		mach_port_t mine = MACH_PORT_NULL;
		mach_msg_type_name_t got = 0;
		kr = mach_port_extract_right(task, rn, MACH_MSG_TYPE_COPY_SEND, &mine, &got);
		if (kr != KERN_SUCCESS) { printf("  extract: %s\n", mach_error_string(kr)); continue; }
		mach_port_t bp = MACH_PORT_NULL;
		task_get_special_port(task, TASK_BOOTSTRAP_PORT, &bp);
		NSMutableArray *all = [NSMutableArray array];
		collect_names([NSDictionary dictionaryWithContentsOfFile:@"/System/Library/xpc/launchd.plist"], all);
		int hits = 0;
		for (NSString *line in all) {
			NSString *name = [line componentsSeparatedByString:@"\t"][0];
			mach_port_t p = MACH_PORT_NULL;
			if (bootstrap_look_up(bp, name.UTF8String, &p) == KERN_SUCCESS) {
				if (p == mine) { printf("  launchd name: %s\n", line.UTF8String); hits++; }
				else mach_port_deallocate(mach_task_self(), p);
			}
		}
		printf("  %d launchd names of %lu match\n", hits, (unsigned long)all.count);
		for (int s = 0; s < 32; s++) {
			mach_port_t sp = MACH_PORT_NULL;
			if (host_get_special_port(mach_host_self(), HOST_LOCAL_NODE, s, &sp) == KERN_SUCCESS && sp == mine) printf("  host special port %d\n", s);
		}
	}
	return 0;
}
