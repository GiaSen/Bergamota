/*
 * sweetqmi: talk to the Mi 8 modem's QMI services through the kernel's pass-through (xnu 3057, kern.sweet_qmi).
 *   sweetqmi services                 the services the modem announced, with names
 *   sweetqmi status                   read-only summary: firmware, operating mode, whether an IMEI is set (never the
 *                                     number), SIM card and application state, registration, network, signal
 *   sweetqmi raw SVC MSG [TT=HEX ...] one request (numbers in hex or decimal); prints the response TLVs in hex
 *   sweetqmi ind                      the last indications the modem sent to the pass-through port
 * Message ids and TLV layouts follow libqmi's service definitions (qmi-service-dms/uim/nas.json): register facts only.
 * Identifiers (IMEI, ESN, MEID, ICCID, IMSI, phone number) are never printed by `status`; `raw` prints what comes back.
 * iOS 18+, arm64e + pacstrip (tools/sweetnet/build.sh).
 */
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>

static uint8_t rsp[8192];
static size_t rsp_len;

static const char *
svc_name(unsigned s)
{
	switch (s) {
	case 0x01: return "WDS (data)";
	case 0x02: return "DMS (device)";
	case 0x03: return "NAS (network)";
	case 0x04: return "QOS";
	case 0x05: return "WMS (SMS)";
	case 0x07: return "AUTH";
	case 0x08: return "AT";
	case 0x09: return "VOICE";
	case 0x0a: return "CAT (SIM toolkit)";
	case 0x0b: return "UIM (SIM)";
	case 0x0c: return "PBM (phonebook)";
	case 0x0f: return "TEST";
	case 0x10: return "LOC";
	case 0x11: return "SAR";
	case 0x12: return "IMSS";
	case 0x15: return "MFS";
	case 0x16: return "TIME";
	case 0x17: return "TS";
	case 0x18: return "TMD";
	case 0x1a: return "WDA";
	case 0x1d: return "CSVT";
	case 0x1f: return "IMSP";
	case 0x21: return "IMSA";
	case 0x22: return "COEX";
	case 0x24: return "PDC (carrier configs)";
	case 0x29: return "RFRPE";
	case 0x2a: return "DSD";
	case 0x2b: return "SSCTL";
	case 0x2f: return "DPM";
	case 0x42: return "SERVREG notifier";
	case 0x45: return "WLFW";
	default: return "";
	}
}

/* one request; 0 and the response in rsp[] on success */
static int
qmi(unsigned svc, unsigned msg, const uint8_t *tlvs, size_t tlen)
{
	uint8_t in[8 + 7 + 1024];
	uint32_t s = svc, inst = 0xffffffffu;
	uint16_t m = (uint16_t)msg, l = (uint16_t)tlen;
	if (tlen > 1024) {
		return EINVAL;
	}
	memcpy(in, &s, 4);
	memcpy(in + 4, &inst, 4);
	in[8] = 0;
	in[9] = in[10] = 0;
	memcpy(in + 11, &m, 2);
	memcpy(in + 13, &l, 2);
	if (tlen) {
		memcpy(in + 15, tlvs, tlen);
	}
	rsp_len = sizeof(rsp);
	if (sysctlbyname("kern.sweet_qmi", rsp, &rsp_len, in, 15 + tlen) != 0) {
		return errno;
	}
	return 0;
}

static const uint8_t *
tlv(unsigned type, uint16_t *len)
{
	uint16_t body;
	if (rsp_len < 7) {
		return NULL;
	}
	memcpy(&body, rsp + 5, 2);
	size_t end = 7u + body < rsp_len ? 7u + body : rsp_len;
	for (size_t o = 7; o + 3 <= end;) {
		uint16_t l;
		memcpy(&l, rsp + o + 1, 2);
		if (o + 3 + l > end) {
			return NULL;
		}
		if (rsp[o] == type) {
			*len = l;
			return rsp + o + 3;
		}
		o += 3u + l;
	}
	return NULL;
}

/* the mandatory result TLV 0x02: -1 when missing, else the QMI error (0 = success) */
static int
result(void)
{
	uint16_t l, r, e;
	const uint8_t *t = tlv(0x02, &l);
	if (!t || l < 4) {
		return -1;
	}
	memcpy(&r, t, 2);
	memcpy(&e, t + 2, 2);
	return r ? (e ? e : 0xffff) : 0;
}

static int
ask(const char *what, unsigned svc, unsigned msg, const uint8_t *tlvs, size_t tlen)
{
	int e = qmi(svc, msg, tlvs, tlen);
	if (e) {
		printf("%-14s request failed: %s\n", what, strerror(e));
		return -1;
	}
	int r = result();
	if (r) {
		printf("%-14s QMI error %#x\n", what, r);
		return -1;
	}
	return 0;
}

static void
cmd_services(void)
{
	char buf[4096];
	size_t n = sizeof(buf);
	if (sysctlbyname("kern.sweet_qmi_services", buf, &n, NULL, 0) != 0) {
		perror("kern.sweet_qmi_services (the kernel needs patch 3057)");
		exit(1);
	}
	char *line = strtok(buf, "\n");
	printf("%s\n", line ? line : "");
	while ((line = strtok(NULL, "\n"))) {
		unsigned svc = (unsigned)strtoul(line, NULL, 16);
		printf("  %-28s %s\n", line, svc_name(svc));
	}
}

static const char *
pick(const char *const *names, unsigned n, unsigned v)
{
	return v < n && names[v] ? names[v] : "?";
}

static void
cmd_status(void)
{
	static const char *const modes[] = { "online", "low power", "factory test", "offline", "resetting", "shutting down",
		                             "persistent low power", "mode-only low power", "network test" };
	static const char *const cards[] = { "absent", "present", "error" };
	static const char *const apptypes[] = { "unknown", "SIM", "USIM", "RUIM", "CSIM", "ISIM" };
	static const char *const appstates[] = { "unknown", "detected", "PIN required", "PUK required", "personalization check",
		                                 "PIN blocked", "illegal", "ready" };
	static const char *const pins[] = { "not initialised", "enabled, not verified", "enabled, verified", "disabled",
		                            "blocked", "permanently blocked" };
	static const char *const regs[] = { "not registered", "registered", "searching", "denied", "unknown" };
	static const char *const nets[] = { "unknown", "3GPP2", "3GPP" };
	uint16_t l;
	const uint8_t *t;

	if (ask("firmware", 0x02, 0x0023, NULL, 0) == 0 && (t = tlv(0x01, &l))) {
		printf("%-14s %.*s\n", "firmware", (int)l, (const char *)t);
	}
	if (ask("mode", 0x02, 0x002d, NULL, 0) == 0 && (t = tlv(0x01, &l)) && l >= 1) {
		printf("%-14s %s (%u)\n", "mode", pick(modes, 9, t[0]), t[0]);
	}
	if (ask("ids", 0x02, 0x0025, NULL, 0) == 0) {
		t = tlv(0x11, &l);
		printf("%-14s %s\n", "IMEI", t && l ? (l == 15 ? "set (15 digits, not shown)" : "set (not shown)") : "none");
	}
	if (ask("SIM", 0x0b, 0x002f, NULL, 0) == 0 && (t = tlv(0x10, &l)) && l >= 9) {
		const uint8_t *p = t + 8, *end = t + l;
		unsigned ncards = *p++;
		for (unsigned c = 0; c < ncards && p + 6 <= end; c++) {
			unsigned state = p[0], napps = p[5];
			printf("%-14s card %u %s (error code %u)\n", "SIM", c, pick(cards, 3, state), p[4]);
			p += 6;
			for (unsigned a = 0; a < napps && p + 7 <= end; a++) {
				unsigned type = p[0], ast = p[1], aidlen = p[6];
				p += 7 + aidlen;
				if (p + 8 > end) {
					break;
				}
				printf("%-14s   app %s: %s, PIN1 %s (%u tries left), PUK1 %u tries\n", "", pick(apptypes, 6, type),
				    pick(appstates, 8, ast), pick(pins, 6, p[1]), p[2], p[3]);
				p += 8;
			}
		}
	}
	if (ask("network", 0x03, 0x0024, NULL, 0) == 0 && (t = tlv(0x01, &l)) && l >= 5) {
		printf("%-14s %s, CS %s, PS %s, %s", "network", pick(regs, 5, t[0]), t[1] == 1 ? "attached" : "detached",
		    t[2] == 1 ? "attached" : "detached", pick(nets, 3, t[3]));
		for (unsigned i = 0; i < t[4] && 5u + i < l; i++) {
			unsigned r = t[5 + i];
			printf("%s%s", i ? "+" : ", radio ", r == 4 ? "GSM" : r == 5 ? "UMTS" : r == 8 ? "LTE" : r == 12 ? "5G NR" :
			    r == 9 ? "TD-SCDMA" : r == 1 ? "CDMA" : r == 2 ? "EVDO" : "none");
		}
		printf("\n");
		if ((t = tlv(0x12, &l)) && l >= 5) {
			uint16_t mcc, mnc;
			memcpy(&mcc, t, 2);
			memcpy(&mnc, t + 2, 2);
			unsigned dl = t[4];
			printf("%-14s MCC %u MNC %02u \"%.*s\"\n", "operator", mcc, mnc, (int)(dl <= l - 5u ? dl : 0), (const char *)t + 5);
		}
	}
	if (ask("signal", 0x03, 0x0020, NULL, 0) == 0 && (t = tlv(0x01, &l)) && l >= 2) {
		printf("%-14s %d dBm\n", "signal", (int8_t)t[0]);
	}
}

static void
cmd_raw(int argc, char **argv)
{
	uint8_t b[1024];
	size_t n = 0;
	unsigned svc = (unsigned)strtoul(argv[0], NULL, 0), msg = (unsigned)strtoul(argv[1], NULL, 0);
	for (int i = 2; i < argc; i++) {
		char *eq = strchr(argv[i], '=');
		if (!eq || n + 3 > sizeof(b)) {
			fprintf(stderr, "TLV must be TT=HEX\n");
			exit(2);
		}
		b[n] = (uint8_t)strtoul(argv[i], NULL, 16);
		size_t hl = strlen(eq + 1) / 2;
		uint16_t l = (uint16_t)hl;
		memcpy(b + n + 1, &l, 2);
		for (size_t k = 0; k < hl && n + 3 + k < sizeof(b); k++) {
			char h[3] = { eq[1 + 2 * k], eq[2 + 2 * k], 0 };
			b[n + 3 + k] = (uint8_t)strtoul(h, NULL, 16);
		}
		n += 3 + hl;
	}
	int e = qmi(svc, msg, b, n);
	if (e) {
		printf("request failed: %s\n", strerror(e));
		exit(1);
	}
	printf("response %zu bytes, result %#x\n", rsp_len, result());
	uint16_t body;
	memcpy(&body, rsp + 5, 2);
	for (size_t o = 7; o + 3 <= rsp_len && o < 7u + body;) {
		uint16_t l;
		memcpy(&l, rsp + o + 1, 2);
		printf("  TLV %#04x len %u:", rsp[o], l);
		for (unsigned k = 0; k < l && o + 3 + k < rsp_len; k++) {
			printf(" %02x", rsp[o + 3 + k]);
		}
		printf("\n");
		o += 3u + l;
	}
}

static void
cmd_ind(void)
{
	static uint8_t b[4 + 16 * (16 + 2048)];
	size_t n = sizeof(b);
	uint32_t cnt;
	if (sysctlbyname("kern.sweet_qmi_ind", b, &n, NULL, 0) != 0 || n < 4) {
		perror("kern.sweet_qmi_ind");
		exit(1);
	}
	memcpy(&cnt, b, 4);
	size_t o = 4;
	for (uint32_t i = 0; i < cnt && o + 16 <= n; i++) {
		uint64_t ms;
		uint32_t svc, len;
		uint16_t msg;
		memcpy(&ms, b + o, 8);
		memcpy(&svc, b + o + 8, 4);
		memcpy(&len, b + o + 12, 4);
		memcpy(&msg, b + o + 16 + 3, 2);
		printf("%llu ms  %#x %-16s msg %#06x  %u bytes\n", (unsigned long long)ms, svc, svc_name(svc), msg, len);
		o += 16 + len;
	}
}

int
main(int argc, char **argv)
{
	if (argc >= 2 && !strcmp(argv[1], "services")) {
		cmd_services();
	} else if (argc >= 2 && !strcmp(argv[1], "status")) {
		cmd_status();
	} else if (argc >= 4 && !strcmp(argv[1], "raw")) {
		cmd_raw(argc - 2, argv + 2);
	} else if (argc >= 2 && !strcmp(argv[1], "ind")) {
		cmd_ind();
	} else {
		fprintf(stderr, "usage: sweetqmi services | status | raw SVC MSG [TT=HEX ...] | ind\n");
		return 2;
	}
	return 0;
}
