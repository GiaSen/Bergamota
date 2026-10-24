/*
 * SPDX-License-Identifier: MIT
 *
 * libdrm stand-in for Mesa's freedreno "msm" backend on Heartwood (Poco F1, Adreno 630).
 *
 * Mesa's src/freedreno/drm/msm backend talks to /dev/dri/renderD* through libdrm (drmCommandWriteRead,
 * drmIoctl, drmGetVersion) and mmap()s buffers at the offset GEM_INFO(GET_OFFSET) returns. On Heartwood the
 * same requests are selectors of the IOKit user client "SweetAdreno630" (xnu/gpu-abi/sweet_adreno_abi.h,
 * docs/GPU_KERNEL.md), so this file provides, under the libdrm names, exactly what the backend calls and
 * forwards each request to IOConnectCallStructMethod. No Mesa source change is needed:
 *
 *   - "device fds" are dups of /dev/null (so os_dupfd_cloexec, close and fstat keep working); every such
 *     fd means THE connection (one GPU, one connection per process);
 *   - mmap()/munmap() of such an fd are interposed (dyld __interpose) and turned into
 *     IOConnectMapMemory64 / IOConnectUnmapMemory64 with the BO handle as memoryType (msm "offset" = handle);
 *   - absolute CLOCK_MONOTONIC timeouts of WAIT_FENCE / GEM_CPU_PREP become relative ones (the kernel ABI);
 *   - the reported DRM version is msm 1.3: no softpin, no robustness params, relocations + kernel-assigned
 *     iovas (GET_IOVA), submit queues, GMEM_BASE. Newer versions would make Mesa assign GPU addresses itself.
 *
 * Build: gpu/freedreno-sweet/build.sh (arm64e dylib, install name libdrm.2.dylib so a Mesa linked against a
 * libdrm of the same name uses it; also libdrm_freedreno-free: Mesa's freedreno does not use libdrm_freedreno).
 * Status: compiles; never run. Mesa configuration: gpu/freedreno-sweet/README.md.
 */
#include <IOKit/IOKitLib.h>
#include <errno.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include "../../xnu/gpu-abi/sweet_adreno_abi.h"

#define EXPORT __attribute__((visibility("default")))
#define DRM_COMMAND_BASE 0x40
#define DRM_IOCTL_GEM_CLOSE_NR 0x09

typedef struct _drmVersion {
	int   version_major, version_minor, version_patchlevel;
	int   name_len;
	char *name;
	int   date_len;
	char *date;
	int   desc_len;
	char *desc;
} drmVersion, *drmVersionPtr;

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static io_connect_t g_conn;
static dev_t g_null_rdev;
static int g_trace;

/*
 * Buffer log (Chlorophyll, GPU fault hunting): when /private/var/tmp/drm-bolog exists at connect time, every BO this
 * process creates, imports, gets a GPU address for and closes, and every submit (its fence and BO handles), is appended
 * to /private/var/tmp/drmlog/<process>-<pid>.log, one line each, microseconds since boot first:
 *   T new h=H size=S | T sbo h=H surf=ID size=S iova=A | T iova h=H A | T close h=H | T submit fence=F bos=H,H,...
 * A kernel SMMU fault prints the faulting GPU address (FAR) and the last submitted fence: the log names the BO that
 * covered that address, when it was closed and which submit used it. The file starts over at 32 MiB (the old one is .old).
 */
static int g_bolog = -1;
static int g_bolog_fd = -1;
static char g_bolog_path[160];
static pthread_mutex_t g_bolog_lock = PTHREAD_MUTEX_INITIALIZER;

static void
bolog_open(void)
{
	struct stat st;

	g_bolog = stat("/private/var/tmp/drm-bolog", &st) == 0;
	if (!g_bolog) {
		return;
	}
	char name[64];
	const char *pn = getprogname();
	snprintf(name, sizeof(name), "%s", pn ? pn : "proc");
	mkdir("/private/var/tmp/drmlog", 0777);
	snprintf(g_bolog_path, sizeof(g_bolog_path), "/private/var/tmp/drmlog/%s-%d.log", name, (int)getpid());
	g_bolog_fd = open(g_bolog_path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
	if (g_bolog_fd < 0) {
		g_bolog = 0;
	}
}

static void
bolog_line(const char *line, size_t n)
{
	struct stat st;

	pthread_mutex_lock(&g_bolog_lock);
	if (g_bolog_fd >= 0 && fstat(g_bolog_fd, &st) == 0 && st.st_size > (32 << 20)) {
		char old[176];
		snprintf(old, sizeof(old), "%s.old", g_bolog_path);
		rename(g_bolog_path, old);
		close(g_bolog_fd);
		g_bolog_fd = open(g_bolog_path, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND | O_CLOEXEC, 0644);
	}
	if (g_bolog_fd >= 0) {
		(void)write(g_bolog_fd, line, n);
	}
	pthread_mutex_unlock(&g_bolog_lock);
}

static unsigned long long
bolog_us(void)
{
	return (unsigned long long)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000ull);
}

/* after a successful call: in = what was sent, out = what came back */
static void
bolog_call(uint32_t sel, const uint8_t *in, const uint8_t *out, size_t outsz)
{
	char b[4096];
	int n = 0;

	switch (sel) {
	case SWEET_GPU_SEL_GEM_NEW: {
		const struct sweet_msm_gem_new *i = (const void *)in, *o = (const void *)out;
		n = snprintf(b, sizeof(b), "%llu new h=%u size=%llu\n", bolog_us(), outsz >= sizeof(*o) ? o->handle : 0,
		    (unsigned long long)i->size);
		break;
	}
	case SWEET_GPU_SEL_SURFACE_BO: {
		const struct sweet_gpu_surface_bo *o = (const void *)out;
		if (outsz < sizeof(o->iova) + 16 || o->handle == 0) {
			return;
		}
		n = snprintf(b, sizeof(b), "%llu sbo h=%u surf=%u size=%llu iova=0x%llx w=%u h=%u bpr=%u off=%u fmt=0x%x planes=%u\n",
		    bolog_us(), o->handle, o->surface_id, (unsigned long long)o->size, (unsigned long long)o->iova, o->width, o->height,
		    o->bytes_per_row, o->offset, o->pixel_format, o->planes);
		break;
	}
	case SWEET_GPU_SEL_GEM_INFO: {
		const struct sweet_msm_gem_info *i = (const void *)in, *o = (const void *)out;
		if (i->info != SWEET_MSM_INFO_GET_IOVA || outsz < sizeof(*o)) {
			return;
		}
		n = snprintf(b, sizeof(b), "%llu iova h=%u 0x%llx\n", bolog_us(), i->handle, (unsigned long long)o->value);
		break;
	}
	case SWEET_GPU_SEL_GEM_CLOSE: {
		const struct sweet_gem_close *i = (const void *)in;
		n = snprintf(b, sizeof(b), "%llu close h=%u\n", bolog_us(), i->handle);
		break;
	}
	case SWEET_GPU_SEL_GEM_SUBMIT: {
		const struct sweet_msm_gem_submit *i = (const void *)in, *o = (const void *)out;
		const struct sweet_msm_gem_submit_bo *bos = (const void *)(uintptr_t)i->bos;
		n = snprintf(b, sizeof(b), "%llu submit fence=%u bos=", bolog_us(), outsz >= 8 ? o->fence : 0);
		for (uint32_t k = 0; k < i->nr_bos && n < (int)sizeof(b) - 16; k++) {
			n += snprintf(b + n, sizeof(b) - (size_t)n, k ? ",%u" : "%u", bos[k].handle);
		}
		if (n < (int)sizeof(b) - 1) {
			b[n++] = '\n';
		}
		break;
	}
	default:
		return;
	}
	if (n > 0) {
		bolog_line(b, (size_t)(n < (int)sizeof(b) ? n : (int)sizeof(b)));
	}
}

static struct {
	void    *addr;
	uint32_t handle;
	size_t   len;
} g_maps[16384];
static unsigned g_nmaps;

static int
io_errno(kern_return_t kr)
{
	switch (kr) {
	case kIOReturnSuccess: return 0;
	case kIOReturnNoMemory: case kIOReturnNoSpace: case kIOReturnNoResources: return ENOMEM;
	case kIOReturnBadArgument: return EINVAL;
	case kIOReturnTimeout: return ETIMEDOUT;
	case kIOReturnBusy: return EBUSY;
	case kIOReturnNotReady: case kIOReturnNotFound: return ENODEV;
	case kIOReturnUnsupported: return ENOSYS;
	case kIOReturnNotPermitted: return EPERM;
	default: return EIO;
	}
}

static int
connect_once(void)
{
	int ok = 0;

	pthread_mutex_lock(&g_lock);
	if (g_conn == IO_OBJECT_NULL) {
		struct stat st;
		if (stat("/dev/null", &st) == 0) {
			g_null_rdev = st.st_rdev;
		}
		g_trace = getenv("SWEET_DRM_TRACE") != NULL;
		bolog_open();
		io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(SWEET_GPU_SERVICE_NAME));
		if (svc != IO_OBJECT_NULL) {
			if (IOServiceOpen(svc, mach_task_self(), 0, &g_conn) != KERN_SUCCESS) {
				g_conn = IO_OBJECT_NULL;
			}
			IOObjectRelease(svc);
		}
	}
	ok = g_conn != IO_OBJECT_NULL;
	pthread_mutex_unlock(&g_lock);
	return ok;
}

static int
is_ours(int fd)
{
	struct stat st;

	if (g_conn == IO_OBJECT_NULL || fd < 0 || fstat(fd, &st) != 0) {
		return 0;
	}
	return S_ISCHR(st.st_mode) && st.st_rdev == g_null_rdev;
}

static size_t g_sbo_size = SWEET_GPU_SURFACE_BO_V1_SIZE;   /* minor 0 layout until INFO says abi_minor >= 1 */

/* Sizes of the kernel structures (what the user client requires at least). */
static size_t
sel_size(uint32_t sel)
{
	switch (sel) {
	case SWEET_GPU_SEL_GEM_CLOSE: return sizeof(struct sweet_gem_close);
	case SWEET_GPU_SEL_GET_PARAM: return sizeof(struct sweet_msm_param);
	case SWEET_GPU_SEL_GEM_NEW: return sizeof(struct sweet_msm_gem_new);
	case SWEET_GPU_SEL_GEM_INFO: return sizeof(struct sweet_msm_gem_info);
	case SWEET_GPU_SEL_GEM_CPU_PREP: return sizeof(struct sweet_msm_gem_cpu_prep);
	case SWEET_GPU_SEL_GEM_CPU_FINI: return sizeof(struct sweet_msm_gem_cpu_fini);
	case SWEET_GPU_SEL_GEM_SUBMIT: return sizeof(struct sweet_msm_gem_submit);
	case SWEET_GPU_SEL_WAIT_FENCE: return sizeof(struct sweet_msm_wait_fence);
	case SWEET_GPU_SEL_GEM_MADVISE: return sizeof(struct sweet_msm_gem_madvise);
	case SWEET_GPU_SEL_SUBMITQUEUE_NEW: return sizeof(struct sweet_msm_submitqueue);
	case SWEET_GPU_SEL_SUBMITQUEUE_CLOSE: return sizeof(uint32_t);
	case SWEET_GPU_SEL_INFO: return sizeof(struct sweet_gpu_info);
	case SWEET_GPU_SEL_SURFACE_BO: return g_sbo_size;
	case SWEET_GPU_SEL_BO_SYNC: return sizeof(struct sweet_gpu_bo_sync);
	default: return 0;
	}
}

static int64_t
abs_to_rel_ns(const struct sweet_msm_timespec *t)
{
	struct timespec now;
	clock_gettime(CLOCK_MONOTONIC, &now);
	int64_t d = (t->tv_sec - now.tv_sec) * 1000000000ll + (t->tv_nsec - now.tv_nsec);
	return d < 0 ? 0 : d;
}

static void
rel_timeout(struct sweet_msm_timespec *t)
{
	int64_t ns = abs_to_rel_ns(t);
	t->tv_sec = ns / 1000000000ll;
	t->tv_nsec = ns % 1000000000ll;
}

/* The last failed WAIT_FENCE, for whoever reports the failure (Chlorophyll's "fence timeout" also covers a fence the kernel
 * refuses as never submitted, and a GPU that is not ready): what the kernel said, and how long the call really took. */
static char g_wait_err[192];
static unsigned g_wait_err_n;

static void
wait_failed(const struct sweet_msm_wait_fence *w, kern_return_t kr, const struct timespec *t0)
{
	struct timespec t1;
	clock_gettime(CLOCK_MONOTONIC, &t1);
	int64_t took = (t1.tv_sec - t0->tv_sec) * 1000000000ll + (t1.tv_nsec - t0->tv_nsec);
	int64_t asked = w->timeout.tv_sec * 1000000000ll + w->timeout.tv_nsec;
	struct sweet_gpu_info info;
	size_t outsz = sizeof(info);
	memset(&info, 0, sizeof(info));
	kern_return_t ki = IOConnectCallStructMethod(g_conn, SWEET_GPU_SEL_INFO, NULL, 0, &info, &outsz);
	snprintf(g_wait_err, sizeof(g_wait_err), "WAIT_FENCE #%u fence %u queue %u: kr %#x (errno %d) after %lld of %lld ms; info kr %#x flags %#x last submitted %u",
	    ++g_wait_err_n, w->fence, w->queueid, kr, io_errno(kr), (long long)(took / 1000000), (long long)(asked / 1000000), ki, info.flags, info.last_fence);
}

/* Chlorophyll takes this when a fence wait fails: copies the last WAIT_FENCE failure into buf and forgets it, so an
 * empty answer means the wait failed without a WAIT_FENCE failing (Mesa's own wait for its submit thread). */
EXPORT void
sweet_drm_take_wait_error(char *buf, size_t size)
{
	if (size == 0) {
		return;
	}
	snprintf(buf, size, "%s", g_wait_err);
	g_wait_err[0] = 0;
}

/* One request: returns 0 or -errno. */
static int
sweet_call(uint32_t sel, void *data, size_t size)
{
	uint8_t in[256], out[256];
	size_t want = sel_size(sel), outsz = sizeof(out);

	if (!connect_once()) {
		return -ENODEV;
	}
	if (want == 0 || want > sizeof(in)) {
		return -ENOSYS;
	}
	if (sel == SWEET_GPU_SEL_GEM_MADVISE) {
		/* The kernel never purges a BO: its MADVISE only checks the handle and answers retained = 1. Mesa's BO cache
		 * calls it on every cached allocation and free (WILLNEED/DONTNEED), a kernel round trip each: 43 % of the
		 * GPU calls in backboardd's profile during a home-screen swipe. Answered here, as the kernel would. */
		((struct sweet_msm_gem_madvise *)data)->retained = 1;
		return 0;
	}
	memset(in, 0, sizeof(in));
	memcpy(in, data, size < want ? size : want);
	if (sel == SWEET_GPU_SEL_GEM_SUBMIT) {
		/* msm keeps the pipe id (MSM_PIPE_3D0 = 0x10) in the low bits of submit.flags; this kernel wants only NO_IMPLICIT there */
		((struct sweet_msm_gem_submit *)in)->flags &= ~0xffffu;
	}
	if (sel == SWEET_GPU_SEL_WAIT_FENCE) {
		rel_timeout(&((struct sweet_msm_wait_fence *)in)->timeout);
	} else if (sel == SWEET_GPU_SEL_GEM_CPU_PREP) {
		rel_timeout(&((struct sweet_msm_gem_cpu_prep *)in)->timeout);
	}
	struct timespec t0;
	if (sel == SWEET_GPU_SEL_WAIT_FENCE) {
		clock_gettime(CLOCK_MONOTONIC, &t0);
	}
	kern_return_t kr = IOConnectCallStructMethod(g_conn, sel, in, want, out, &outsz);
	if (sel == SWEET_GPU_SEL_WAIT_FENCE && kr != KERN_SUCCESS) {
		wait_failed((struct sweet_msm_wait_fence *)in, kr, &t0);
	}
	if (g_trace && kr != KERN_SUCCESS && sel != SWEET_GPU_SEL_WAIT_FENCE) {
		fprintf(stderr, "sweet_drm: selector %#x -> %#x\n", sel, kr);
	}
	if (kr == KERN_SUCCESS && g_bolog > 0) {
		bolog_call(sel, in, out, outsz);
	}
	if (kr == KERN_SUCCESS && outsz) {
		memcpy(data, out, outsz < size ? outsz : size);
	}
	return -io_errno(kr);
}

/* ---- libdrm API used by Mesa's freedreno msm backend ---- */

EXPORT int
drmCommandWriteRead(int fd, unsigned long idx, void *data, unsigned long size)
{
	(void)fd;
	return sweet_call((uint32_t)(DRM_COMMAND_BASE + idx), data, size);
}

EXPORT int
drmCommandWrite(int fd, unsigned long idx, void *data, unsigned long size)
{
	return drmCommandWriteRead(fd, idx, data, size);
}

EXPORT int
drmCommandRead(int fd, unsigned long idx, void *data, unsigned long size)
{
	return drmCommandWriteRead(fd, idx, data, size);
}

EXPORT int
drmIoctl(int fd, unsigned long request, void *arg)
{
	unsigned nr = (unsigned)(request & 0xff);
	size_t size = (request >> 16) & 0x3fff;
	int r;

	(void)fd;
	if (nr != DRM_IOCTL_GEM_CLOSE_NR && nr < DRM_COMMAND_BASE) {
		errno = ENOSYS;
		return -1;
	}
	r = sweet_call(nr, arg, size ? size : sel_size(nr));
	if (r) {
		errno = -r;
		return -1;
	}
	return 0;
}

EXPORT drmVersionPtr
drmGetVersion(int fd)
{
	drmVersionPtr v;

	if (!is_ours(fd) && !connect_once()) {
		errno = ENODEV;
		return NULL;
	}
	v = calloc(1, sizeof(*v));
	if (!v) {
		return NULL;
	}
	v->version_major = 1;
	/* 1.4 = FD_VERSION_SOFTPIN. Mesa 25.0.7's legacy (< 1.4) ringbuffer lacks attach_bo (NULL call in fd_batch_create, found on the phone), so the
	 * "sp" submit/ringbuffer path is the only one that works; gallium freedreno still takes the iova of every BO from GEM_INFO(GET_IOVA)
	 * (kernel-assigned) and passes it as `presumed`, which the kernel ignores. No relocations are emitted in this mode. */
	v->version_minor = 4;
	v->name = strdup("msm");
	v->name_len = 3;
	v->date = strdup("20261023");
	v->date_len = 8;
	v->desc = strdup("Heartwood SweetAdreno630");
	v->desc_len = (int)strlen(v->desc);
	return v;
}

EXPORT void
drmFreeVersion(drmVersionPtr v)
{
	if (v) {
		free(v->name);
		free(v->date);
		free(v->desc);
		free(v);
	}
}

/* "msm" (or any name) opens the one GPU connection; the fd is a dup of /dev/null. */
EXPORT int
drmOpenWithType(const char *name, const char *busid, int type)
{
	(void)name; (void)busid; (void)type;
	if (!connect_once()) {
		errno = ENODEV;
		return -1;
	}
	return open("/dev/null", O_RDWR | O_CLOEXEC);
}

EXPORT int
drmGetCap(int fd, uint64_t cap, uint64_t *value)
{
	(void)fd; (void)cap;
	*value = 0;             /* no syncobj, no prime */
	return 0;
}

EXPORT int
drmPrimeFDToHandle(int fd, int prime_fd, uint32_t *handle)
{
	(void)fd; (void)prime_fd; (void)handle;
	errno = ENOSYS;
	return -1;
}

EXPORT int
drmPrimeHandleToFD(int fd, uint32_t handle, uint32_t flags, int *prime_fd)
{
	(void)fd; (void)handle; (void)flags; (void)prime_fd;
	errno = ENOSYS;
	return -1;
}

EXPORT int drmSyncobjCreate(int fd, uint32_t flags, uint32_t *handle) { (void)fd; (void)flags; (void)handle; return -ENOSYS; }
EXPORT int drmSyncobjDestroy(int fd, uint32_t handle) { (void)fd; (void)handle; return -ENOSYS; }
EXPORT int drmSyncobjWait(int fd, uint32_t *h, unsigned n, int64_t t, unsigned f, uint32_t *first) { (void)fd; (void)h; (void)n; (void)t; (void)f; (void)first; return -ENOSYS; }
EXPORT int drmSyncobjSignal(int fd, const uint32_t *h, uint32_t n) { (void)fd; (void)h; (void)n; return -ENOSYS; }
EXPORT int drmSyncobjExportSyncFile(int fd, uint32_t handle, int *sync_file_fd) { (void)fd; (void)handle; (void)sync_file_fd; return -ENOSYS; }
EXPORT int drmSyncobjImportSyncFile(int fd, uint32_t handle, int sync_file_fd) { (void)fd; (void)handle; (void)sync_file_fd; return -ENOSYS; }
EXPORT int drmSyncobjFDToHandle(int fd, int obj_fd, uint32_t *handle) { (void)fd; (void)obj_fd; (void)handle; return -ENOSYS; }
EXPORT int drmSyncobjReset(int fd, const uint32_t *h, uint32_t n) { (void)fd; (void)h; (void)n; return -ENOSYS; }

/* ---- mmap of a BO: offset = BO handle (GEM_INFO GET_OFFSET) ---- */

static void *sweet_mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off);
static int sweet_munmap(void *addr, size_t len);

/* Direct entry points: the Mesa patch (freedreno_bo.c) calls these instead of relying on dyld interposing. */
EXPORT void *
sweet_drm_mmap(int fd, size_t len, uint64_t off)
{
	return sweet_mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t)off);
}

static void *
sweet_mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off)
{
	mach_vm_address_t a = 0;
	mach_vm_size_t s = 0;

	if (!is_ours(fd)) {
		return mmap(addr, len, prot, flags, fd, off);
	}
	kern_return_t kr = IOConnectMapMemory64(g_conn, (uint32_t)off, mach_task_self(), &a, &s,
	    kIOMapAnywhere | kIOMapWriteCombineCache);
	if (kr != KERN_SUCCESS || s < len) {
		if (kr == KERN_SUCCESS) {
			IOConnectUnmapMemory64(g_conn, (uint32_t)off, mach_task_self(), a);
		}
		errno = kr == KERN_SUCCESS ? EINVAL : io_errno(kr);
		return MAP_FAILED;
	}
	pthread_mutex_lock(&g_lock);
	if (g_nmaps < sizeof(g_maps) / sizeof(g_maps[0])) {
		g_maps[g_nmaps].addr = (void *)(uintptr_t)a;
		g_maps[g_nmaps].handle = (uint32_t)off;
		g_maps[g_nmaps].len = len;
		g_nmaps++;
	}
	pthread_mutex_unlock(&g_lock);
	return (void *)(uintptr_t)a;
}

static int
sweet_munmap(void *addr, size_t len)
{
	int found = 0;
	uint32_t handle = 0;

	pthread_mutex_lock(&g_lock);
	for (unsigned i = 0; i < g_nmaps; i++) {
		if (g_maps[i].addr == addr) {
			handle = g_maps[i].handle;
			g_maps[i] = g_maps[--g_nmaps];
			found = 1;
			break;
		}
	}
	pthread_mutex_unlock(&g_lock);
	if (found) {
		return IOConnectUnmapMemory64(g_conn, handle, mach_task_self(), (mach_vm_address_t)(uintptr_t)addr) == KERN_SUCCESS ? 0 : -1;
	}
	return munmap(addr, len);
}

EXPORT int
sweet_drm_munmap(void *addr, size_t len)
{
	return sweet_munmap(addr, len);
}

/* Heartwood additions (not msm): IOSurface memory as a BO, cache maintenance, device info. */
EXPORT int
sweet_drm_surface_bo(int fd, struct sweet_gpu_surface_bo *io)
{
	static int minor = -1;   /* INFO.abi_minor: the 112-byte (minor 1) struct only when the kernel has it, the 48-byte V1 struct otherwise */
	(void)fd;
	if (minor < 0) {
		struct sweet_gpu_info inf;
		memset(&inf, 0, sizeof(inf));
		minor = sweet_call(SWEET_GPU_SEL_INFO, &inf, sizeof(inf)) == 0 ? (int)inf.abi_minor : 0;
		if (minor >= 1)
			g_sbo_size = minor >= 2 ? SWEET_GPU_SURFACE_BO_MINOR2_SIZE : SWEET_GPU_SURFACE_BO_MINOR1_SIZE;
	}
	return sweet_call(SWEET_GPU_SEL_SURFACE_BO, io, g_sbo_size);
}

/* Close a BO handle (SURFACE_BO makes one per surface; a writable alias is unmapped by the kernel at this point). */
EXPORT int
sweet_drm_gem_close(int fd, uint32_t handle)
{
	struct sweet_gem_close a = { .handle = handle };

	(void)fd;
	return sweet_call(SWEET_GPU_SEL_GEM_CLOSE, &a, sizeof(a));
}

EXPORT int
sweet_drm_bo_sync(int fd, uint32_t handle, uint64_t offset, uint64_t size)
{
	struct sweet_gpu_bo_sync a = { .handle = handle, .offset = offset, .size = size };

	(void)fd;
	return sweet_call(SWEET_GPU_SEL_BO_SYNC, &a, sizeof(a));
}

EXPORT int
sweet_drm_info(int fd, struct sweet_gpu_info *out)
{
	(void)fd;
	return sweet_call(SWEET_GPU_SEL_INFO, out, sizeof(*out));
}

struct interpose_tuple { const void *replacement, *replacee; };
__attribute__((used)) static const struct interpose_tuple interpose_mmap
    __attribute__((section("__DATA,__interpose"))) = { (const void *)sweet_mmap, (const void *)mmap };
__attribute__((used)) static const struct interpose_tuple interpose_munmap
    __attribute__((section("__DATA,__interpose"))) = { (const void *)sweet_munmap, (const void *)munmap };
