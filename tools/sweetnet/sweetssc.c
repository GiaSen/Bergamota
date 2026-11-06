/*
 * sweetssc: the Mi 8's sensors through the SLPI's SNS client service (QMI 400), via the kernel pass-through (xnu 3071,
 * kern.sweet_ssc_qmi / _ind / _services). The SLPI must be running: `sweetsys kern.sweet_ssc=2` first.
 *   sweetssc services                    the SLPI's QMI services and the pass-through counters
 *   sweetssc lookup [TYPE ...]           SUIDs of the default sensor of each data type (default: a list of common ones)
 *   sweetssc attr TYPE                   that sensor's attributes (name, vendor, rates, stream type, ...)
 *   sweetssc stream TYPE [HZ] [SECONDS]  enable it, print its samples, disable it (on-change sensors: HZ is ignored)
 *   sweetssc stop TYPE                   disable a stream left running
 *   sweetssc ind                         the indications in the kernel's ring, raw
 * Protocol (libssc, postmarketOS, codeberg.org/DylanVanAssche/libssc 033e2a3, data/ssc-*.proto): every request is a QMI
 * message 0x20 to service 400 with TLV 0x01 = u16 length + protobuf SscClientRequest {uid {low, high}, fixed32 msg_id,
 * config {processor 1 = APSS, suspend_mode 0 = wakeup}, request {bytes msg}} and TLV 0x10 = report type (1 = large).
 * Reports are indications 0x21 / 0x22 whose TLV 0x02 = u16 length + SscClientResponse {uid, repeated {fixed32 msg_id,
 * fixed64 timestamp, bytes msg}}. SUID lookup: uid 0xabab... both halves, msg 512 SscSuidRequest {data_type,
 * enable_updates, only_default_values}, answer 768 SscSuidResponse {data_type, repeated uid}. Attributes: msg 1, answer
 * 128. Stream: 513 {float sample_rate} or 514 (on change), samples 1025 {repeated float, status} (proximity 769
 * {near, distance, status}), stop: 10. iOS 18+, arm64e + pacstrip (tools/sweetnet/build.sh).
 */
#include <errno.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <unistd.h>

#define SNS_SVC                 400u
#define MSG_SUID_REQ            512u
#define MSG_SUID_EVENT          768u
#define MSG_ATTR_REQ            1u
#define MSG_ATTR_EVENT          128u
#define MSG_STREAM              513u
#define MSG_ON_CHANGE           514u
#define MSG_CONFIG_EVENT        768u
#define MSG_DISABLE             10u
#define MSG_SAMPLE              1025u
#define MSG_PROX_EVENT          769u
#define SUID_LOOKUP             0xababababababababull

static uint8_t rsp[4096];
static size_t rsp_len;
static uint8_t ind[8 + 64 * (12 + 2048)];
static volatile sig_atomic_t stop_now;

struct suid {
	uint64_t low, high;
};

/* ---- protobuf, the few wire types these messages use */
static size_t
pb_varint(uint8_t *o, uint64_t v)
{
	size_t n = 0;
	do {
		o[n] = (uint8_t)(v & 0x7f);
		v >>= 7;
		o[n++] |= v ? 0x80 : 0;
	} while (v);
	return n;
}

static size_t
pb_key(uint8_t *o, unsigned field, unsigned wt)
{
	return pb_varint(o, (uint64_t)field << 3 | wt);
}

static size_t
pb_bytes(uint8_t *o, unsigned field, const void *d, size_t n)
{
	size_t k = pb_key(o, field, 2);
	k += pb_varint(o + k, n);
	memcpy(o + k, d, n);
	return k + n;
}

static size_t
pb_fixed64(uint8_t *o, unsigned field, uint64_t v)
{
	size_t k = pb_key(o, field, 1);
	memcpy(o + k, &v, 8);
	return k + 8;
}

static size_t
pb_fixed32(uint8_t *o, unsigned field, uint32_t v)
{
	size_t k = pb_key(o, field, 5);
	memcpy(o + k, &v, 4);
	return k + 4;
}

static size_t
pb_uint(uint8_t *o, unsigned field, uint64_t v)
{
	size_t k = pb_key(o, field, 0);
	return k + pb_varint(o + k, v);
}

struct pb {
	const uint8_t *p, *end;
};
struct pbf {
	unsigned field, wt;
	uint64_t v;
	const uint8_t *d;
	size_t n;
};

static bool
pb_get_varint(struct pb *b, uint64_t *v)
{
	*v = 0;
	for (unsigned s = 0; b->p < b->end && s < 64; s += 7) {
		uint8_t c = *b->p++;
		*v |= (uint64_t)(c & 0x7f) << s;
		if (!(c & 0x80)) {
			return true;
		}
	}
	return false;
}

static bool
pb_next(struct pb *b, struct pbf *f)
{
	uint64_t k;
	if (b->p >= b->end || !pb_get_varint(b, &k)) {
		return false;
	}
	f->field = (unsigned)(k >> 3);
	f->wt = (unsigned)(k & 7);
	f->d = NULL;
	f->n = 0;
	f->v = 0;
	switch (f->wt) {
	case 0:
		return pb_get_varint(b, &f->v);
	case 1:
		if (b->end - b->p < 8) {
			return false;
		}
		memcpy(&f->v, b->p, 8);
		b->p += 8;
		return true;
	case 5:
		if (b->end - b->p < 4) {
			return false;
		}
		memcpy(&f->v, b->p, 4);
		b->p += 4;
		return true;
	case 2: {
		uint64_t n;
		if (!pb_get_varint(b, &n) || n > (uint64_t)(b->end - b->p)) {
			return false;
		}
		f->d = b->p;
		f->n = (size_t)n;
		b->p += n;
		return true;
	}
	default:
		return false;
	}
}

static float
pb_float(uint64_t v)
{
	uint32_t u = (uint32_t)v;
	float f;
	memcpy(&f, &u, 4);
	return f;
}

static struct suid
pb_suid(const uint8_t *d, size_t n)
{
	struct suid s = { 0, 0 };
	struct pb b = { d, d + n };
	struct pbf f;
	while (pb_next(&b, &f)) {
		if (f.field == 1 && f.wt == 1) {
			s.low = f.v;
		} else if (f.field == 2 && f.wt == 1) {
			s.high = f.v;
		}
	}
	return s;
}

/* ---- QMI through the kernel */
static int
qmi_tlv(const uint8_t *m, size_t len, unsigned type, const uint8_t **v, uint16_t *vlen)
{
	uint16_t body;
	if (len < 7) {
		return -1;
	}
	memcpy(&body, m + 5, 2);
	size_t end = 7u + body < len ? 7u + body : len;
	for (size_t o = 7; o + 3 <= end;) {
		uint16_t l;
		memcpy(&l, m + o + 1, 2);
		if (o + 3 + l > end) {
			return -1;
		}
		if (m[o] == type) {
			*v = m + o + 3;
			*vlen = l;
			return 0;
		}
		o += 3u + l;
	}
	return -1;
}

static uint32_t
ind_head(void)
{
	size_t n = sizeof(ind);
	uint32_t h = 0;
	if (sysctlbyname("kern.sweet_ssc_ind", ind, &n, NULL, 0) == 0 && n >= 8) {
		memcpy(&h, ind, 4);
	}
	return h;
}

/* one SNS request: SscClientRequest to uid with msg_id and payload; 0 = the service accepted it */
static int
sns_send(struct suid uid, uint32_t msg_id, const uint8_t *payload, size_t plen, bool quiet)
{
	uint8_t u[32], cfg[8], body[1100], pbm[1200], in[8 + 7 + 1300];
	size_t un = 0, cn = 0, bn = 0, n = 0;
	if (plen > 1000) {
		return EINVAL;
	}
	un += pb_fixed64(u + un, 1, uid.low);
	un += pb_fixed64(u + un, 2, uid.high);
	cn += pb_uint(cfg + cn, 1, 1);          /* processor: APSS */
	cn += pb_uint(cfg + cn, 2, 0);          /* suspend mode: wakeup */
	if (payload) {
		bn += pb_bytes(body + bn, 2, payload, plen);
	}
	n += pb_bytes(pbm + n, 1, u, un);
	n += pb_fixed32(pbm + n, 2, msg_id);
	n += pb_bytes(pbm + n, 3, cfg, cn);
	n += pb_bytes(pbm + n, 4, body, bn);
	/* QMI: u32 service, u32 instance, type 0, txn, msg 0x20, length, TLV 0x01 {u16 len, protobuf}, TLV 0x10 {u8 1} */
	uint32_t svc = SNS_SVC, inst = 0xffffffffu;
	uint16_t msg = 0x20, t1 = (uint16_t)(2 + n), pl = (uint16_t)n, t10 = 1, total = (uint16_t)(3 + t1 + 3 + t10);
	size_t o = 0;
	memcpy(in + o, &svc, 4);
	memcpy(in + o + 4, &inst, 4);
	o += 8;
	in[o] = 0;
	in[o + 1] = in[o + 2] = 0;
	memcpy(in + o + 3, &msg, 2);
	memcpy(in + o + 5, &total, 2);
	o += 7;
	in[o] = 0x01;
	memcpy(in + o + 1, &t1, 2);
	memcpy(in + o + 3, &pl, 2);
	memcpy(in + o + 5, pbm, n);
	o += 5 + n;
	in[o] = 0x10;
	memcpy(in + o + 1, &t10, 2);
	in[o + 3] = 1;                          /* report type: large */
	o += 4;
	rsp_len = sizeof(rsp);
	if (sysctlbyname("kern.sweet_ssc_qmi", rsp, &rsp_len, in, o) != 0) {
		int e = errno;
		fprintf(stderr, "request %u: %s%s\n", msg_id, strerror(e), e == ENXIO ? " (is the SLPI up? sweetsys kern.sweet_ssc=2)" : "");
		return e;
	}
	const uint8_t *v;
	uint16_t vl;
	uint16_t res = 0xffff, err = 0xffff;
	if (qmi_tlv(rsp, rsp_len, 0x02, &v, &vl) == 0 && vl >= 4) {
		memcpy(&res, v, 2);
		memcpy(&err, v + 2, 2);
	}
	if (!quiet || res) {
		uint64_t client = 0;
		uint32_t r11 = 0;
		bool hc = qmi_tlv(rsp, rsp_len, 0x10, &v, &vl) == 0 && vl >= 8, h11 = false;
		if (hc) {
			memcpy(&client, v, 8);
		}
		if (qmi_tlv(rsp, rsp_len, 0x11, &v, &vl) == 0 && vl >= 4) {
			memcpy(&r11, v, 4);
			h11 = true;
		}
		fprintf(stderr, "request %u: QMI result %u error %u%s", msg_id, res, err, hc ? "" : ", no client id");
		if (hc) {
			fprintf(stderr, ", client %llu", (unsigned long long)client);
		}
		if (h11) {
			fprintf(stderr, ", response %u", r11);
		}
		fprintf(stderr, "\n");
	}
	return res ? EIO : 0;
}

/* each report in the ring from sequence `from` on: calls fn(uid, msg_id, timestamp, payload); returns the next sequence */
typedef bool (*report_fn)(void *ctx, struct suid uid, uint32_t msg_id, uint64_t ts, const uint8_t *d, size_t n, uint32_t ms);

static uint32_t
reports(uint32_t from, report_fn fn, void *ctx, bool *done)
{
	size_t n = sizeof(ind);
	uint32_t head = from, cnt = 0;
	if (sysctlbyname("kern.sweet_ssc_ind", ind, &n, NULL, 0) != 0 || n < 8) {
		return from;
	}
	memcpy(&head, ind, 4);
	memcpy(&cnt, ind + 4, 4);
	size_t o = 8;
	for (uint32_t k = 0; k < cnt && o + 12 <= n; k++) {
		uint32_t seq, ms, len;
		memcpy(&seq, ind + o, 4);
		memcpy(&ms, ind + o + 4, 4);
		memcpy(&len, ind + o + 8, 4);
		const uint8_t *m = ind + o + 12;
		o += 12 + len;
		if (seq < from || o > n) {
			continue;
		}
		const uint8_t *v;
		uint16_t vl, pl;
		if (qmi_tlv(m, len, 0x02, &v, &vl) != 0 || vl < 2) {
			continue;
		}
		memcpy(&pl, v, 2);
		if (pl > vl - 2) {
			continue;
		}
		struct pb b = { v + 2, v + 2 + pl };
		struct pbf f;
		struct suid uid = { 0, 0 };
		while (pb_next(&b, &f)) {
			if (f.field == 1 && f.wt == 2) {
				uid = pb_suid(f.d, f.n);
			} else if (f.field == 2 && f.wt == 2) {
				struct pb e = { f.d, f.d + f.n };
				struct pbf g;
				uint32_t id = 0;
				uint64_t ts = 0;
				const uint8_t *pd = NULL;
				size_t pn = 0;
				while (pb_next(&e, &g)) {
					if (g.field == 1) {
						id = (uint32_t)g.v;
					} else if (g.field == 2) {
						ts = g.v;
					} else if (g.field == 3 && g.wt == 2) {
						pd = g.d;
						pn = g.n;
					}
				}
				if (fn(ctx, uid, id, ts, pd ? pd : (const uint8_t *)"", pn, ms) && done) {
					*done = true;
				}
			}
		}
	}
	return head;
}

/* ---- lookup */
struct lookup_ctx {
	const char *type;
	struct suid found[8];
	unsigned n;
	bool answered;
};

static bool
lookup_fn(void *c, struct suid uid, uint32_t id, uint64_t ts, const uint8_t *d, size_t n, uint32_t ms)
{
	struct lookup_ctx *x = c;
	(void)ts;
	(void)ms;
	if (uid.low != SUID_LOOKUP || uid.high != SUID_LOOKUP || id != MSG_SUID_EVENT) {
		return false;
	}
	struct pb b = { d, d + n };
	struct pbf f;
	char type[64] = "";
	struct suid tmp[8];
	unsigned k = 0;
	while (pb_next(&b, &f)) {
		if (f.field == 1 && f.wt == 2) {
			snprintf(type, sizeof(type), "%.*s", (int)f.n, (const char *)f.d);
		} else if (f.field == 2 && f.wt == 2 && k < 8) {
			tmp[k++] = pb_suid(f.d, f.n);
		}
	}
	if (strcmp(type, x->type) != 0) {
		return false;
	}
	memcpy(x->found, tmp, sizeof(tmp[0]) * k);
	x->n = k;
	x->answered = true;
	return true;
}

static int
lookup(const char *type, struct lookup_ctx *x, bool print)
{
	uint8_t req[96];
	size_t n = 0, tl = strlen(type);
	if (tl > 60) {
		return EINVAL;
	}
	memset(x, 0, sizeof(*x));
	x->type = type;
	n += pb_bytes(req + n, 1, type, tl);
	n += pb_uint(req + n, 2, 0);            /* enable_updates */
	n += pb_uint(req + n, 3, 1);            /* only_default_values */
	uint32_t from = ind_head();
	int e = sns_send((struct suid){ SUID_LOOKUP, SUID_LOOKUP }, MSG_SUID_REQ, req, n, true);
	if (e) {
		return e;
	}
	bool done = false;
	for (int t = 0; t < 40 && !done; t++) {
		usleep(50000);
		from = reports(from, lookup_fn, x, &done);
	}
	if (print) {
		if (!x->answered) {
			printf("%-20s no answer in 2 s\n", type);
		} else if (!x->n) {
			printf("%-20s none\n", type);
		}
		for (unsigned i = 0; i < x->n; i++) {
			printf("%-20s %016llx%016llx\n", type, (unsigned long long)x->found[i].high, (unsigned long long)x->found[i].low);
		}
	}
	return x->answered && x->n ? 0 : ENOENT;
}

/* ---- attributes */
static const char *const attr_names[] = { "name", "vendor", "type", "available", "version", "api", "rates",
	"resolutions", "fifo_size", "active_current", "sleep_current", "ranges", "op_modes", "dri", "stream_sync",
	"event_size", "stream_type", "dynamic", "hw_id", "rigid_body", "placement", "physical_sensor", "physical_tests",
	"selected_resolution", "selected_range", "low_latency_rates", "passive_request" };

struct attr_ctx {
	struct suid uid;
	bool answered, print;
	int stream_type;
	float max_rate;
};

static void attr_array(const uint8_t *d, size_t n, char *out, size_t cap, int *ival, float *fval);

/* one SscAttrValue {a = 1 nested array, s = 2, f = 3, i = 4 (fixed64 or zigzag varint), b = 5} */
static void
attr_value(const uint8_t *d, size_t n, char *out, size_t cap, int *ival, float *fval)
{
	struct pb b = { d, d + n };
	struct pbf f;
	size_t o = strlen(out);
	while (pb_next(&b, &f) && o + 40 < cap) {
		if (f.field == 1 && f.wt == 2) {
			o += (size_t)snprintf(out + o, cap - o, "[");
			attr_array(f.d, f.n, out, cap, ival, fval);
			o = strlen(out);
			if (o && out[o - 1] == ' ') {
				out[--o] = 0;
			}
			o += (size_t)snprintf(out + o, cap - o, "] ");
		} else if (f.field == 2 && f.wt == 2) {
			o += (size_t)snprintf(out + o, cap - o, "\"%.*s\" ", (int)(f.n < 60 ? f.n : 60), (const char *)f.d);
		} else if (f.field == 3 && f.wt == 5) {
			float v = pb_float(f.v);
			if (fval && v > *fval) {
				*fval = v;
			}
			o += (size_t)snprintf(out + o, cap - o, "%g ", v);
		} else if (f.field == 4) {
			int64_t v = f.wt == 0 ? (int64_t)((f.v >> 1) ^ (~(f.v & 1) + 1)) : (int64_t)f.v;
			if (ival) {
				*ival = (int)v;
			}
			o += (size_t)snprintf(out + o, cap - o, "%lld%s ", (long long)v, f.wt == 0 ? "" : "(f64)");
		} else if (f.field == 5 && f.wt == 0) {
			o += (size_t)snprintf(out + o, cap - o, "%s ", f.v ? "true" : "false");
		}
	}
}

/* SscAttrArrayValue / SscAttrValueArray: repeated SscAttrValue in field 1 */
static void
attr_array(const uint8_t *d, size_t n, char *out, size_t cap, int *ival, float *fval)
{
	struct pb b = { d, d + n };
	struct pbf f;
	while (pb_next(&b, &f) && strlen(out) + 40 < cap) {
		if (f.field == 1 && f.wt == 2) {
			attr_value(f.d, f.n, out, cap, ival, fval);
		}
	}
}

static bool
attr_fn(void *c, struct suid uid, uint32_t id, uint64_t ts, const uint8_t *d, size_t n, uint32_t ms)
{
	struct attr_ctx *x = c;
	(void)ts;
	(void)ms;
	if (uid.low != x->uid.low || uid.high != x->uid.high || id != MSG_ATTR_EVENT) {
		return false;
	}
	struct pb b = { d, d + n };
	struct pbf f;
	while (pb_next(&b, &f)) {
		if (f.field != 1 || f.wt != 2) {
			continue;
		}
		struct pb a = { f.d, f.d + f.n };
		struct pbf g;
		int aid = -1, iv = -1;
		float fv = 0;
		char val[512] = "";
		while (pb_next(&a, &g)) {
			if (g.field == 1 && g.wt == 0) {
				aid = (int)g.v;
			} else if (g.field == 2 && g.wt == 2) {
				attr_array(g.d, g.n, val, sizeof(val), &iv, &fv);
			}
		}
		if (aid == 16) {
			x->stream_type = iv;
		}
		if (aid == 6) {
			x->max_rate = fv;
		}
		if (x->print) {
			printf("  %-20s %s\n", aid >= 0 && aid < (int)(sizeof(attr_names) / sizeof(attr_names[0])) ? attr_names[aid] : "?", val);
		}
	}
	x->answered = true;
	return true;
}

static int
attributes(struct suid uid, struct attr_ctx *x, bool print)
{
	uint8_t req[8];
	size_t n = pb_uint(req, 2, 0);          /* SscAttrRequest.enable_updates = false */
	memset(x, 0, sizeof(*x));
	x->uid = uid;
	x->print = print;
	x->stream_type = -1;
	uint32_t from = ind_head();
	int e = sns_send(uid, MSG_ATTR_REQ, req, n, true);
	if (e) {
		return e;
	}
	bool done = false;
	for (int t = 0; t < 40 && !done; t++) {
		usleep(50000);
		from = reports(from, attr_fn, x, &done);
	}
	if (!x->answered) {
		printf("  no attributes in 2 s\n");
	}
	return x->answered ? 0 : ETIMEDOUT;
}

/* ---- streaming */
struct stream_ctx {
	struct suid uid;
	unsigned samples, others;
	uint32_t first_ms, last_ms;
	bool prox;
};

static bool
stream_fn(void *c, struct suid uid, uint32_t id, uint64_t ts, const uint8_t *d, size_t n, uint32_t ms)
{
	struct stream_ctx *x = c;
	if (uid.low != x->uid.low || uid.high != x->uid.high) {
		return false;
	}
	struct pb b = { d, d + n };
	struct pbf f;
	if (id == MSG_SAMPLE) {
		float v[16];
		unsigned k = 0;
		int status = -1;
		while (pb_next(&b, &f)) {
			if (f.field == 1 && f.wt == 2) {             /* packed floats */
				for (size_t o = 0; o + 4 <= f.n && k < 16; o += 4) {
					uint32_t u;
					memcpy(&u, f.d + o, 4);
					v[k++] = pb_float(u);
				}
			} else if (f.field == 1 && f.wt == 5 && k < 16) {
				v[k++] = pb_float(f.v);
			} else if (f.field == 2 && f.wt == 0) {
				status = (int)f.v;
			}
		}
		if (!x->samples) {
			x->first_ms = ms;
		}
		x->samples++;
		x->last_ms = ms;
		printf("%8.3f s  ts %llu  status %d  ", ms / 1000.0, (unsigned long long)ts, status);
		for (unsigned i = 0; i < k; i++) {
			printf("%s%.4f", i ? " " : "", v[i]);
		}
		if (!k && n) {
			printf("(%zu bytes, no float field 1)", n);
		}
		printf("\n");
	} else if (id == MSG_PROX_EVENT) {
		int64_t near = -1, dist = -1, status = -1;
		while (pb_next(&b, &f)) {
			if (f.field == 1 && f.wt == 0) {
				near = (int64_t)f.v;
			} else if (f.field == 2 && f.wt == 0) {
				dist = (int64_t)f.v;
			} else if (f.field == 3 && f.wt == 0) {
				status = (int64_t)f.v;
			}
		}
		x->samples++;
		printf("%8.3f s  ts %llu  proximity %s (%lld) distance %lld status %lld\n", ms / 1000.0, (unsigned long long)ts,
		    near == 1 ? "NEAR" : near == 0 ? "far" : "?", (long long)near, (long long)dist, (long long)status);
	} else {
		x->others++;
		printf("%8.3f s  ts %llu  event %u, %zu bytes:", ms / 1000.0, (unsigned long long)ts, id, n);
		for (size_t i = 0; i < n && i < 32; i++) {
			printf(" %02x", d[i]);
		}
		printf("\n");
	}
	fflush(stdout);
	return false;
}

static void
on_signal(int s)
{
	(void)s;
	stop_now = 1;
}

static int
stream(const char *type, float hz, unsigned seconds)
{
	struct lookup_ctx lk;
	struct attr_ctx at;
	if (lookup(type, &lk, true)) {
		return 1;
	}
	struct suid uid = lk.found[0];
	(void)attributes(uid, &at, false);
	bool on_change = at.stream_type == 1;
	printf("%s: stream type %d (%s), max rate %g Hz\n", type, at.stream_type,
	    at.stream_type == 0 ? "streaming" : at.stream_type == 1 ? "on change" : at.stream_type == 2 ? "single output" : "?",
	    at.max_rate);
	uint8_t req[8];
	size_t n = 0;
	if (!on_change) {
		uint32_t u;
		memcpy(&u, &hz, 4);
		n = pb_fixed32(req, 1, u);
	}
	struct stream_ctx sx = { uid, 0, 0, 0, 0, false };
	uint32_t from = ind_head();
	signal(SIGINT, on_signal);
	signal(SIGTERM, on_signal);
	if (sns_send(uid, on_change ? MSG_ON_CHANGE : MSG_STREAM, on_change ? NULL : req, n, false)) {
		return 1;
	}
	for (unsigned t = 0; t < seconds * 20 && !stop_now; t++) {
		usleep(50000);
		from = reports(from, stream_fn, &sx, NULL);
	}
	(void)sns_send(uid, MSG_DISABLE, NULL, 0, false);
	printf("%s: %u samples", type, sx.samples);
	if (sx.samples > 1 && sx.last_ms > sx.first_ms) {
		printf(" (%.1f per second)", (sx.samples - 1) * 1000.0 / (sx.last_ms - sx.first_ms));
	}
	printf(", %u other events; stream disabled\n", sx.others);
	return 0;
}

static int
dump_ind(void)
{
	size_t n = sizeof(ind);
	if (sysctlbyname("kern.sweet_ssc_ind", ind, &n, NULL, 0) != 0) {
		perror("kern.sweet_ssc_ind");
		return 1;
	}
	uint32_t head, cnt;
	memcpy(&head, ind, 4);
	memcpy(&cnt, ind + 4, 4);
	printf("next %u, %u in the ring\n", head, cnt);
	size_t o = 8;
	for (uint32_t k = 0; k < cnt && o + 12 <= n; k++) {
		uint32_t seq, ms, len;
		memcpy(&seq, ind + o, 4);
		memcpy(&ms, ind + o + 4, 4);
		memcpy(&len, ind + o + 8, 4);
		uint16_t msg = 0;
		memcpy(&msg, ind + o + 12 + 3, 2);
		printf("#%u %u ms msg %#x %u bytes:", seq, ms, msg, len);
		for (uint32_t i = 0; i < len && i < 48; i++) {
			printf(" %02x", ind[o + 12 + i]);
		}
		printf("\n");
		o += 12 + len;
	}
	return 0;
}

int
main(int argc, char **argv)
{
	static const char *const common[] = { "accel", "gyro", "mag", "ambient_light", "proximity", "pressure",
		"sensor_temperature", "gravity", "game_rv", "rotv", "geomag_rv", "device_orient", "sig_motion", "pedometer" };
	if (argc >= 2 && strcmp(argv[1], "services") == 0) {
		char buf[2048];
		size_t n = sizeof(buf);
		if (sysctlbyname("kern.sweet_ssc_services", buf, &n, NULL, 0) != 0) {
			perror("kern.sweet_ssc_services");
			return 1;
		}
		fputs(buf, stdout);
		return 0;
	}
	if (argc >= 2 && strcmp(argv[1], "lookup") == 0) {
		struct lookup_ctx lk;
		if (argc == 2) {
			for (unsigned i = 0; i < sizeof(common) / sizeof(common[0]); i++) {
				(void)lookup(common[i], &lk, true);
			}
		}
		for (int i = 2; i < argc; i++) {
			(void)lookup(argv[i], &lk, true);
		}
		return 0;
	}
	if (argc == 3 && strcmp(argv[1], "attr") == 0) {
		struct lookup_ctx lk;
		struct attr_ctx at;
		if (lookup(argv[2], &lk, true)) {
			return 1;
		}
		for (unsigned i = 0; i < lk.n; i++) {
			(void)attributes(lk.found[i], &at, true);
		}
		return 0;
	}
	if (argc >= 3 && strcmp(argv[1], "stream") == 0) {
		float hz = argc >= 4 ? strtof(argv[3], NULL) : 10.0f;
		unsigned s = argc >= 5 ? (unsigned)strtoul(argv[4], NULL, 0) : 5;
		return stream(argv[2], hz > 0 ? hz : 10.0f, s ? s : 5);
	}
	if (argc == 3 && strcmp(argv[1], "stop") == 0) {
		struct lookup_ctx lk;
		if (lookup(argv[2], &lk, false)) {
			return 1;
		}
		return sns_send(lk.found[0], MSG_DISABLE, NULL, 0, false) ? 1 : 0;
	}
	if (argc == 2 && strcmp(argv[1], "ind") == 0) {
		return dump_ind();
	}
	fprintf(stderr, "usage: sweetssc services | lookup [TYPE...] | attr TYPE | stream TYPE [HZ] [SECONDS] | stop TYPE | ind\n");
	return 2;
}
