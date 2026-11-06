/*
 * sweetalsa: a tiny ALSA client for Linux arm64 with no libc (raw syscalls), for TWRP on the Mi 8, which has no
 * tinyalsa. Used to play through the WCD9340 earpiece under Xiaomi's own kernel and compare the codec's registers.
 *   sweetalsa [-c CARD] list                     every control: numid, name, type, values (enum: the item's name)
 *   sweetalsa [-c CARD] get NAME                 one control, with its range or enum items
 *   sweetalsa [-c CARD] set NAME VALUE...        enum: item name or index; int/bool: numbers (one value sets all)
 *   sweetalsa [-c CARD] apply FILE               lines "NAME<TAB>VALUE" (# comments), as set; unknown names are reported
 *   sweetalsa [-c CARD] play DEV SECS HZ DBFS [CH] [RATE]
 *                                                a sine (DBFS an integer, e.g. -30) on /dev/snd/pcmC<CARD>D<DEV>p,
 *                                                S16_LE, CH channels (2), RATE (48000), period 1024 x 4
 * Build: tools/audio/sweetalsa/build.sh (aarch64-elf-gcc, static, no libc).
 */
typedef unsigned long size_t;
typedef long ssize_t;

#define SYS_ioctl 29
#define SYS_openat 56
#define SYS_close 57
#define SYS_read 63
#define SYS_write 64
#define SYS_exit_group 94
#define SYS_nanosleep 101
#define AT_FDCWD (-100)
#define O_RDONLY 0
#define O_RDWR 2
#define EPIPE 32
#define EAGAIN 11

static long
sc6(long n, long a, long b, long c, long d, long e, long f)
{
	register long x8 __asm__("x8") = n;
	register long x0 __asm__("x0") = a;
	register long x1 __asm__("x1") = b;
	register long x2 __asm__("x2") = c;
	register long x3 __asm__("x3") = d;
	register long x4 __asm__("x4") = e;
	register long x5 __asm__("x5") = f;
	__asm__ volatile("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5) : "memory");
	return x0;
}
#define sc(n, a, b, c) sc6(n, (long)(a), (long)(b), (long)(c), 0, 0, 0)

void *
memset(void *d, int c, size_t n)
{
	volatile unsigned char *p = d;
	while (n--) {
		*p++ = (unsigned char)c;
	}
	return d;
}

void *
memcpy(void *d, const void *s, size_t n)
{
	volatile unsigned char *p = d;
	const unsigned char *q = s;
	while (n--) {
		*p++ = *q++;
	}
	return d;
}

static int
seq(const char *a, const char *b)
{
	while (*a && *a == *b) {
		a++;
		b++;
	}
	return *a == *b;
}

static int
sieq(const char *a, const char *b)
{
	for (;; a++, b++) {
		char x = *a >= 'A' && *a <= 'Z' ? *a + 32 : *a, y = *b >= 'A' && *b <= 'Z' ? *b + 32 : *b;
		if (x != y) {
			return 0;
		}
		if (!x) {
			return 1;
		}
	}
}

static char obuf[4096];
static size_t olen;

static void
flush(void)
{
	size_t o = 0;
	while (o < olen) {
		long r = sc(SYS_write, 1, obuf + o, olen - o);
		if (r <= 0) {
			break;
		}
		o += (size_t)r;
	}
	olen = 0;
}

static void
ps(const char *s)
{
	while (*s) {
		if (olen == sizeof(obuf)) {
			flush();
		}
		obuf[olen++] = *s++;
	}
}

static void
pn(long v)
{
	char b[24];
	int i = 23;
	int neg = v < 0;
	unsigned long u = neg ? (unsigned long)(-v) : (unsigned long)v;
	b[i] = 0;
	do {
		b[--i] = (char)('0' + u % 10);
		u /= 10;
	} while (u);
	if (neg) {
		b[--i] = '-';
	}
	ps(b + i);
}

static void
px(unsigned long v, int w)
{
	char b[20];
	int i = 19;
	b[i] = 0;
	do {
		b[--i] = "0123456789abcdef"[v & 15];
		v >>= 4;
		w--;
	} while (v || w > 0);
	ps(b + i);
}

static int
parse_num(const char *s, long *out)
{
	int neg = 0, base = 10;
	long v = 0;
	if (*s == '-') {
		neg = 1;
		s++;
	}
	if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
		base = 16;
		s += 2;
	}
	if (!*s) {
		return 0;
	}
	for (; *s; s++) {
		int d;
		if (*s >= '0' && *s <= '9') {
			d = *s - '0';
		} else if (base == 16 && *s >= 'a' && *s <= 'f') {
			d = *s - 'a' + 10;
		} else if (base == 16 && *s >= 'A' && *s <= 'F') {
			d = *s - 'A' + 10;
		} else {
			return 0;
		}
		v = v * base + d;
	}
	*out = neg ? -v : v;
	return 1;
}

/* ---- ALSA uapi (arm64 LP64 layouts, checked below) ---- */
#define IOC(d, t, n, s) (((unsigned long)(d) << 30) | ((unsigned long)(s) << 16) | ((unsigned long)(t) << 8) | (n))

struct ctl_id {
	unsigned numid;
	int iface;
	unsigned device, subdevice;
	unsigned char name[44];
	unsigned index;
};
struct ctl_list {
	unsigned offset, space, used, count;
	struct ctl_id *pids;
	unsigned char reserved[50];
};
struct ctl_info {
	struct ctl_id id;
	int type;
	unsigned access, count;
	int owner;
	union {
		struct {
			long min, max, step;
		} integer;
		struct {
			long long min, max, step;
		} integer64;
		struct {
			unsigned items, item;
			char name[64];
			unsigned long long names_ptr;
			unsigned names_length;
		} enumerated;
		unsigned char reserved[128];
	} value;
	union {
		unsigned short d[4];
		unsigned short *d_ptr;
	} dimen;
	unsigned char reserved[56];
};
struct ctl_value {
	struct ctl_id id;
	unsigned indirect : 1;
	union {
		long integer[128];
		long long integer64[64];
		unsigned enumerated[128];
		unsigned char bytes[512];
	} value;
	struct {
		long sec, nsec;
	} tstamp;
	unsigned char reserved[112];
};
_Static_assert(sizeof(struct ctl_id) == 64, "ctl_id");
_Static_assert(sizeof(struct ctl_list) == 80, "ctl_list");
_Static_assert(sizeof(struct ctl_info) == 272, "ctl_info");
_Static_assert(sizeof(struct ctl_value) == 1224, "ctl_value");
#define CTL_ELEM_LIST IOC(3, 'U', 0x10, sizeof(struct ctl_list))
#define CTL_ELEM_INFO IOC(3, 'U', 0x11, sizeof(struct ctl_info))
#define CTL_ELEM_READ IOC(3, 'U', 0x12, sizeof(struct ctl_value))
#define CTL_ELEM_WRITE IOC(3, 'U', 0x13, sizeof(struct ctl_value))
enum { T_NONE, T_BOOL, T_INT, T_ENUM, T_BYTES, T_IEC958, T_INT64 };

struct interval {
	unsigned min, max;
	unsigned flags;                                 /* bit 0 openmin, 1 openmax, 2 integer, 3 empty */
};
struct mask {
	unsigned bits[8];
};
struct hw_params {
	unsigned flags;
	struct mask masks[3];
	struct mask mres[5];
	struct interval intervals[12];
	struct interval ires[9];
	unsigned rmask, cmask, info, msbits, rate_num, rate_den;
	unsigned long fifo_size;
	unsigned char reserved[64];
};
struct xferi {
	long result;
	void *buf;
	unsigned long frames;
};
_Static_assert(sizeof(struct hw_params) == 608, "hw_params");
_Static_assert(sizeof(struct xferi) == 24, "xferi");
#define PCM_HW_PARAMS IOC(3, 'A', 0x11, sizeof(struct hw_params))
#define PCM_PREPARE IOC(0, 'A', 0x40, 0)
#define PCM_DRAIN IOC(0, 'A', 0x44, 0)
#define PCM_WRITEI IOC(1, 'A', 0x50, sizeof(struct xferi))
/* masks: 0 access, 1 format, 2 subformat; intervals (param - 8): 0 sample bits, 1 frame bits, 2 channels, 3 rate,
 * 5 period size, 7 periods, 9 buffer size */

static int card;
static int cfd = -1;
static struct ctl_id ids[8192];
static unsigned nids;

static void
mkpath(char *p, const char *pre, int a, const char *mid, int b, const char *suf)
{
	size_t n = 0;
	for (const char *s = pre; *s; s++) {
		p[n++] = *s;
	}
	if (a >= 10) {
		p[n++] = (char)('0' + a / 10);
	}
	p[n++] = (char)('0' + a % 10);
	if (mid) {
		for (const char *s = mid; *s; s++) {
			p[n++] = *s;
		}
		if (b >= 10) {
			p[n++] = (char)('0' + b / 10);
		}
		p[n++] = (char)('0' + b % 10);
	}
	for (const char *s = suf; *s; s++) {
		p[n++] = *s;
	}
	p[n] = 0;
}

static int
ctl_open(void)
{
	char p[64];
	mkpath(p, "/dev/snd/controlC", card, 0, 0, "");
	cfd = (int)sc6(SYS_openat, AT_FDCWD, (long)p, O_RDWR, 0, 0, 0);
	if (cfd < 0) {
		ps(p);
		ps(": open error ");
		pn(-cfd);
		ps("\n");
		return 0;
	}
	struct ctl_list l;
	memset(&l, 0, sizeof(l));
	long r = sc(SYS_ioctl, cfd, CTL_ELEM_LIST, &l);
	if (r < 0) {
		ps("ELEM_LIST error ");
		pn(-r);
		ps("\n");
		return 0;
	}
	unsigned want = l.count < 8192 ? l.count : 8192;
	memset(&l, 0, sizeof(l));
	l.space = want;
	l.pids = ids;
	r = sc(SYS_ioctl, cfd, CTL_ELEM_LIST, &l);
	if (r < 0) {
		ps("ELEM_LIST error ");
		pn(-r);
		ps("\n");
		return 0;
	}
	nids = l.used;
	return 1;
}

static int
info_of(unsigned i, struct ctl_info *inf)
{
	memset(inf, 0, sizeof(*inf));
	inf->id.numid = ids[i].numid;
	return sc(SYS_ioctl, cfd, CTL_ELEM_INFO, inf) >= 0;
}

static int
enum_name(unsigned i, unsigned item, char *out)
{
	struct ctl_info e;
	memset(&e, 0, sizeof(e));
	e.id.numid = ids[i].numid;
	e.value.enumerated.item = item;
	if (sc(SYS_ioctl, cfd, CTL_ELEM_INFO, &e) < 0) {
		out[0] = 0;
		return 0;
	}
	memcpy(out, e.value.enumerated.name, 64);
	out[63] = 0;
	return 1;
}

static long
read_val(unsigned i, struct ctl_value *v)
{
	memset(v, 0, sizeof(*v));
	v->id.numid = ids[i].numid;
	return sc(SYS_ioctl, cfd, CTL_ELEM_READ, v);
}

static int
find(const char *name)
{
	for (unsigned i = 0; i < nids; i++) {
		if (seq((const char *)ids[i].name, name)) {
			return (int)i;
		}
	}
	return -1;
}

static const char *
tname(int t)
{
	static const char *n[] = { "none", "bool", "int", "enum", "bytes", "iec958", "int64" };
	return t >= 0 && t <= 6 ? n[t] : "?";
}

static void
show(unsigned i, int detail)
{
	struct ctl_info inf;
	struct ctl_value v;
	pn(ids[i].numid);
	ps("\t");
	ps((const char *)ids[i].name);
	if (!info_of(i, &inf)) {
		ps("\t(no info)\n");
		return;
	}
	ps("\t");
	ps(tname(inf.type));
	ps(" x");
	pn(inf.count);
	ps("\t");
	long r = (inf.access & 1) ? read_val(i, &v) : -1;   /* access bit 0 = readable */
	if (r < 0) {
		ps("(unreadable)");
	} else {
		unsigned n = inf.count;
		if (inf.type == T_BYTES) {
			n = n > 32 ? 32 : n;
		} else if (n > 16) {
			n = 16;
		}
		for (unsigned k = 0; k < n; k++) {
			if (k) {
				ps(" ");
			}
			if (inf.type == T_ENUM) {
				char nm[64];
				enum_name(i, v.value.enumerated[k], nm);
				ps(nm);
			} else if (inf.type == T_BYTES) {
				px(v.value.bytes[k], 2);
			} else if (inf.type == T_INT64) {
				pn((long)v.value.integer64[k]);
			} else {
				pn(v.value.integer[k]);
			}
		}
		if (n < inf.count) {
			ps(" ...");
		}
	}
	if (detail) {
		if (inf.type == T_INT) {
			ps("\t[");
			pn(inf.value.integer.min);
			ps("..");
			pn(inf.value.integer.max);
			ps("]");
		} else if (inf.type == T_ENUM) {
			ps("\t{");
			for (unsigned k = 0; k < inf.value.enumerated.items; k++) {
				char nm[64];
				enum_name(i, k, nm);
				if (k) {
					ps(", ");
				}
				ps(nm);
			}
			ps("}");
		}
	}
	ps("\n");
}

/* vals: argument strings (set) or one string with the whole value (apply) */
static int
set_ctl(const char *name, int nv, char **vals)
{
	int i = find(name);
	if (i < 0) {
		ps("no control: ");
		ps(name);
		ps("\n");
		return 0;
	}
	struct ctl_info inf;
	struct ctl_value v;
	if (!info_of((unsigned)i, &inf)) {
		ps("no info: ");
		ps(name);
		ps("\n");
		return 0;
	}
	read_val((unsigned)i, &v);
	v.id.numid = ids[i].numid;
	unsigned cnt = inf.count > 128 ? 128 : inf.count;
	if (inf.type == T_ENUM) {
		long item = -1;
		for (unsigned k = 0; k < inf.value.enumerated.items; k++) {
			char nm[64];
			enum_name((unsigned)i, k, nm);
			if (seq(nm, vals[0])) {
				item = k;
				break;
			}
		}
		if (item < 0 && !parse_num(vals[0], &item)) {
			ps("bad enum value for ");
			ps(name);
			ps(": ");
			ps(vals[0]);
			ps("\n");
			return 0;
		}
		for (unsigned k = 0; k < cnt; k++) {
			v.value.enumerated[k] = (unsigned)item;
		}
	} else if (inf.type == T_INT || inf.type == T_BOOL || inf.type == T_INT64 || inf.type == T_BYTES) {
		long last = 0;
		for (unsigned k = 0; k < cnt; k++) {
			if ((int)k < nv) {
				const char *s = vals[k];
				if (inf.type == T_BOOL && (sieq(s, "on") || sieq(s, "true"))) {
					last = 1;
				} else if (inf.type == T_BOOL && (sieq(s, "off") || sieq(s, "false"))) {
					last = 0;
				} else if (!parse_num(s, &last)) {
					ps("bad number for ");
					ps(name);
					ps(": ");
					ps(s);
					ps("\n");
					return 0;
				}
			}
			if (inf.type == T_INT64) {
				v.value.integer64[k] = last;
			} else if (inf.type == T_BYTES) {
				v.value.bytes[k] = (unsigned char)last;
			} else {
				v.value.integer[k] = last;
			}
		}
	} else {
		ps("type not supported: ");
		ps(name);
		ps("\n");
		return 0;
	}
	long r = sc(SYS_ioctl, cfd, CTL_ELEM_WRITE, &v);
	if (r < 0) {
		ps("write error ");
		pn(-r);
		ps(": ");
		ps(name);
		ps("\n");
		return 0;
	}
	show((unsigned)i, 0);
	return 1;
}

static char fbuf[1 << 20];

static int
apply(const char *path)
{
	int fd = (int)sc6(SYS_openat, AT_FDCWD, (long)path, O_RDONLY, 0, 0, 0);
	if (fd < 0) {
		ps(path);
		ps(": open error\n");
		return 1;
	}
	size_t n = 0;
	for (;;) {
		long r = sc(SYS_read, fd, fbuf + n, sizeof(fbuf) - 1 - n);
		if (r <= 0) {
			break;
		}
		n += (size_t)r;
	}
	sc(SYS_close, fd, 0, 0);
	fbuf[n] = 0;
	int bad = 0;
	char *line = fbuf;
	while (*line) {
		char *e = line;
		while (*e && *e != '\n') {
			e++;
		}
		char *next = *e ? e + 1 : e;
		*e = 0;
		if (*line && *line != '#') {
			char *tab = line;
			while (*tab && *tab != '\t') {
				tab++;
			}
			if (*tab) {
				*tab = 0;
				char *vals[128];
				int nv = 0;
				char *val = tab + 1;
				struct ctl_info inf;
				int i = find(line);
				int isenum = i >= 0 && info_of((unsigned)i, &inf) && inf.type == T_ENUM;
				if (isenum) {
					vals[nv++] = val;
				} else {
					char *s = val;
					while (*s && nv < 128) {
						while (*s == ' ') {
							*s++ = 0;
						}
						if (!*s) {
							break;
						}
						vals[nv++] = s;
						while (*s && *s != ' ') {
							s++;
						}
					}
				}
				if (!nv || !set_ctl(line, nv, vals)) {
					bad++;
				}
			}
		}
		line = next;
	}
	ps("apply: ");
	pn(bad);
	ps(" failed\n");
	return bad ? 1 : 0;
}

static void
mask_set(struct mask *m, unsigned bit)
{
	memset(m, 0, sizeof(*m));
	m->bits[bit >> 5] = 1u << (bit & 31);
}

static void
iv_set(struct hw_params *p, int idx, unsigned v)
{
	p->intervals[idx].min = v;
	p->intervals[idx].max = v;
	p->intervals[idx].flags = 4;                   /* integer */
}

static short pbuf[1024 * 8];

static int
play(int dev, int secs, int hz, int dbfs, int ch, int rate)
{
	char p[64];
	mkpath(p, "/dev/snd/pcmC", card, "D", dev, "p");
	int fd = (int)sc6(SYS_openat, AT_FDCWD, (long)p, O_RDWR, 0, 0, 0);
	if (fd < 0) {
		ps(p);
		ps(": open error ");
		pn(-fd);
		ps("\n");
		return 1;
	}
	struct hw_params hp;
	memset(&hp, 0, sizeof(hp));
	for (int i = 0; i < 3; i++) {
		memset(&hp.masks[i], 0xff, sizeof(hp.masks[i]));
	}
	for (int i = 0; i < 12; i++) {
		hp.intervals[i].min = 0;
		hp.intervals[i].max = ~0u;
	}
	hp.rmask = ~0u;
	hp.info = ~0u;
	mask_set(&hp.masks[0], 3);                     /* RW_INTERLEAVED */
	mask_set(&hp.masks[1], 2);                     /* S16_LE */
	mask_set(&hp.masks[2], 0);                     /* STD */
	hp.intervals[5].min = 1024;                    /* period size >= 1024 */
	iv_set(&hp, 0, 16);
	iv_set(&hp, 1, 16 * (unsigned)ch);
	iv_set(&hp, 2, (unsigned)ch);
	iv_set(&hp, 7, 4);
	iv_set(&hp, 3, (unsigned)rate);
	long r = sc(SYS_ioctl, fd, PCM_HW_PARAMS, &hp);
	if (r < 0) {
		ps("HW_PARAMS error ");
		pn(-r);
		ps("\n");
		return 1;
	}
	unsigned period = hp.intervals[5].min, periods = hp.intervals[7].min, buffer = hp.intervals[9].min;
	ps(p);
	ps(": period ");
	pn(period);
	ps(" x ");
	pn(periods);
	ps(", buffer ");
	pn(buffer);
	ps(", ");
	pn(ch);
	ps(" ch, ");
	pn(rate);
	ps(" Hz\n");
	flush();
	if (period * (unsigned)ch > sizeof(pbuf) / sizeof(pbuf[0])) {
		ps("period too large\n");
		return 1;
	}
	r = sc(SYS_ioctl, fd, PCM_PREPARE, 0);
	if (r < 0) {
		ps("PREPARE error ");
		pn(-r);
		ps("\n");
		return 1;
	}
	/* sine by rotation: (c, s) turned by w = 2 pi hz / rate each frame */
	double w = 2 * 3.14159265358979323846 * hz / rate, t = w, cw = 1, sw = 0;
	double term = 1;
	for (int k = 1; k < 30; k++) {                  /* cos, sin by Taylor series */
		term *= t / k;
		if (k % 4 == 1) {
			sw += term;
		} else if (k % 4 == 2) {
			cw -= term;
		} else if (k % 4 == 3) {
			sw -= term;
		} else {
			cw += term;
		}
	}
	double amp = 32767;
	for (int k = 0; k < -dbfs; k++) {
		amp *= 0.8912509381337456;                 /* -1 dB */
	}
	double c = 1, s = 0;
	unsigned long total = (unsigned long)secs * (unsigned long)rate, done = 0;
	int underruns = 0;
	while (done < total) {
		for (unsigned f = 0; f < period; f++) {
			short x = (short)(amp * s);
			for (int k = 0; k < ch; k++) {
				pbuf[f * (unsigned)ch + (unsigned)k] = x;
			}
			double c2 = c * cw - s * sw;
			s = s * cw + c * sw;
			c = c2;
		}
		double m = (3 - (c * c + s * s)) / 2;  /* keep |(c, s)| = 1 */
		c *= m;
		s *= m;
		struct xferi x = { 0, pbuf, period };
		r = sc(SYS_ioctl, fd, PCM_WRITEI, &x);
		if (r == -EPIPE) {
			underruns++;
			sc(SYS_ioctl, fd, PCM_PREPARE, 0);
			continue;
		}
		if (r < 0 && r != -EAGAIN) {
			ps("WRITEI error ");
			pn(-r);
			ps("\n");
			return 1;
		}
		done += period;
	}
	sc(SYS_ioctl, fd, PCM_DRAIN, 0);
	sc(SYS_close, fd, 0, 0);
	ps("played ");
	pn((long)done);
	ps(" frames, ");
	pn(underruns);
	ps(" underruns\n");
	return 0;
}

static int
main2(int argc, char **argv)
{
	int a = 1;
	if (a + 1 < argc && seq(argv[a], "-c")) {
		long v;
		if (parse_num(argv[a + 1], &v)) {
			card = (int)v;
		}
		a += 2;
	}
	if (a >= argc) {
		ps("usage: sweetalsa [-c CARD] list | get NAME | set NAME VALUE... | apply FILE | "
		    "play DEV SECS HZ DBFS [CH] [RATE]\n");
		return 2;
	}
	const char *cmd = argv[a++];
	if (seq(cmd, "play")) {
		long v[6] = { 0, 3, 1000, -30, 2, 48000 };
		for (int k = 0; k < 6 && a + k < argc; k++) {
			parse_num(argv[a + k], &v[k]);
		}
		return play((int)v[0], (int)v[1], (int)v[2], (int)v[3], (int)v[4], (int)v[5]);
	}
	if (!ctl_open()) {
		return 1;
	}
	if (seq(cmd, "list")) {
		for (unsigned i = 0; i < nids; i++) {
			show(i, 0);
		}
		return 0;
	}
	if (seq(cmd, "get") && a < argc) {
		int i = find(argv[a]);
		if (i < 0) {
			ps("no control: ");
			ps(argv[a]);
			ps("\n");
			return 1;
		}
		show((unsigned)i, 1);
		return 0;
	}
	if (seq(cmd, "set") && a + 1 < argc) {
		return set_ctl(argv[a], argc - a - 1, argv + a + 1) ? 0 : 1;
	}
	if (seq(cmd, "apply") && a < argc) {
		return apply(argv[a]);
	}
	ps("unknown command\n");
	return 2;
}

void
cstart(long *sp)
{
	int argc = (int)sp[0];
	char **argv = (char **)(sp + 1);
	int r = main2(argc, argv);
	flush();
	sc(SYS_exit_group, r, 0, 0);
	for (;;) {
	}
}

__asm__(".text\n.global _start\n_start:\n\tmov x29, #0\n\tmov x30, #0\n\tmov x0, sp\n\tbl cstart\n");
