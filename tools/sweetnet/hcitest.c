/*
 * hcitest: talk H4 to the kernel's Bluetooth control (bsd/dev/beryllium_bt_hci.c, boot-arg sweetbt=1)
 * the way bluetoothd and BlueTool do, with no Apple code in the loop:
 *
 *   socket(PF_SYSTEM, SOCK_STREAM, SYSPROTO_CONTROL), CTLIOCGINFO "com.apple.uart.bluetooth",
 *   connect, termios through get/setsockopt(SYSPROTO_CONTROL, TIOCGETA / TIOCSETA),
 *   then HCI Reset, Read Local Version, Read BD_ADDR and the events decoded.
 *
 *   hcitest [-n CTLNAME] [-b BAUD] [-l SECONDS] [-i SECONDS] [-e SECONDS]
 *     -n  control name (default com.apple.uart.bluetooth)
 *     -b  baud in the termios set (default 3000000, what bluetoothd passes)
 *     -l  afterwards print every packet that arrives for SECONDS seconds
 *     -i  a classic inquiry of about SECONDS (general access code, extended results asked for): one line per device
 *         heard, with its class, its strongest signal and its name when the answer carries one. What the radio hears
 *         with no bluetoothd in the way (2026-11-13: a speaker in pairing mode that Settings never listed).
 *     -e  an LE scan of SECONDS (active, 60 ms / 30 ms): advertisers heard, strongest signal, name; "class 1TA" there
 *         means address type T (0 public, 1 random) and advertising type A (0 connectable undirected ... 4 scan response)
 *     -p  DBM  before -i: Write Inquiry Transmit Power Level (-70..20 dBm); -L uses the limited inquiry access code;
 *         -m MODE the inquiry mode (0 standard, 1 with RSSI, 2 extended = default)
 *     -c  AA:BB:CC:DD:EE:FF  a classic connection to that address (Create Connection, role switch allowed unless -S),
 *         its Connection Complete status, the remote's LMP version, then Disconnect: does the device let us in?
 *         -o HEX the clock offset field, -E 1|2 with an LE extended scan running meanwhile, -x "OPCODE PARAMS.." raw
 *         commands first (hex, up to 48), -N no HCI Reset: the controller as bluetoothd left it.
 *         MIND THE ADDRESS: a page finds a device by the lower four bytes alone (LAP and UAP); the upper two (NAP)
 *         are not in the access code. A speaker's LE advertising address with other top bytes than its BR/EDR
 *         address therefore connects, names itself and answers SDP, and then every pairing ends with Simple Pairing
 *         Complete status 5: both sides put the address into the final check (2026-11-13, an hour lost to it).
 *         -P IOCAP after it: Secure Simple Pairing as a minimal host would do it (Write Simple Pairing Mode,
 *         Authentication Requested, no stored key, IO capability IOCAP (1 display yes/no as iOS says, 3 no input no
 *         output), general bonding, every confirmation accepted): the Simple Pairing Complete status and whether a link
 *         key came (never printed). The pairing events need the event mask first: -x '0c01 ff ff ff ff ff ff ff 3f'
 *         -x '0c56 01' (after a reset the controller falls back to a PIN request otherwise).
 *         -A HEX the authentication requirements of our reply (default 04), -W MS a wait before the pairing starts.
 *         -s UUID16 before the pairing: the remote's SDP records holding that UUID (0100 = everything on L2CAP,
 *         1002 = the public browse group), every attribute flattened: is it an audio sink (110b) at all?
 *     -r  AA:BB:CC:DD:EE:FF  a classic Remote Name Request to that address (a page, then the name): whether the
 *         classic link reaches a device that an inquiry did not find
 *
 * Only one client can be connected: stop bluetoothd first
 *   launchctl bootout system/com.apple.bluetoothd     (or: launchctl remove com.apple.bluetoothd)
 * The iOS SDK has no <sys/kern_control.h>: the few definitions are repeated here.
 * Exit status 0 when all three commands completed with status 0.
 */
#include <errno.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <termios.h>
#include <unistd.h>

#define SYSPROTO_CONTROL        2
#define AF_SYS_CONTROL          2
#define CTLIOCGINFO             0xC0644E03UL            /* _IOWR('N', 3, struct ctl_info) */

struct ctl_info {
	uint32_t ctl_id;
	char ctl_name[96];
};

struct sockaddr_ctl {
	uint8_t sc_len;
	uint8_t sc_family;
	uint16_t ss_sysaddr;
	uint32_t sc_id;
	uint32_t sc_unit;
	uint32_t sc_reserved[5];
};

static uint8_t rxb[8192];
static unsigned rxn;

static double
now(void)
{
	struct timeval tv;
	gettimeofday(&tv, NULL);
	return tv.tv_sec + tv.tv_usec / 1e6;
}

static void
hex(const char *what, const uint8_t *p, unsigned n)
{
	printf("%s:", what);
	for (unsigned i = 0; i < n; i++) {
		printf(" %02x", p[i]);
	}
	printf("\n");
}

/* bytes needed for one H4 packet at the head of rxb: 0 = unknown type, else total (may exceed rxn) */
static unsigned
pkt_len(void)
{
	if (rxn < 1) {
		return 0;
	}
	switch (rxb[0]) {
	case 4:
		return rxn >= 3 ? 3u + rxb[2] : 3;
	case 2:
		return rxn >= 5 ? 5u + (rxb[3] | (rxb[4] << 8)) : 5;
	case 3:
		return rxn >= 4 ? 4u + rxb[3] : 4;
	case 5:
		return rxn >= 5 ? 5u + ((rxb[3] | (rxb[4] << 8)) & 0x3fff) : 5;
	default:
		return 0;
	}
}

/* read until one whole packet is buffered; false on timeout/error. The packet stays at rxb[0..len). */
static int
get_packet(int fd, double deadline, unsigned *len)
{
	for (;;) {
		unsigned n = pkt_len();
		if (rxn && n == 0) {
			printf("garbage byte %02x dropped\n", rxb[0]);
			memmove(rxb, rxb + 1, --rxn);
			continue;
		}
		if (n && rxn >= n) {
			*len = n;
			return 1;
		}
		double left = deadline - now();
		if (left <= 0) {
			return 0;
		}
		struct pollfd p = { fd, POLLIN, 0 };
		if (poll(&p, 1, (int)(left * 1000) + 1) <= 0) {
			return 0;
		}
		ssize_t r = read(fd, rxb + rxn, sizeof(rxb) - rxn);
		if (r <= 0) {
			printf("read: %s\n", r == 0 ? "EOF" : strerror(errno));
			return 0;
		}
		rxn += (unsigned)r;
	}
}

static void
drop(unsigned n)
{
	memmove(rxb, rxb + n, rxn - n);
	rxn -= n;
}

/* send a command, print what comes back until its Command Complete/Status; returns the status (-1 no answer) */
static int
command(int fd, unsigned opcode, const uint8_t *par, unsigned plen, uint8_t *ret, unsigned *retlen)
{
	uint8_t pkt[4 + 255];
	pkt[0] = 1;
	pkt[1] = opcode & 0xff;
	pkt[2] = opcode >> 8;
	pkt[3] = plen;
	if (plen) {
		memcpy(pkt + 4, par, plen);
	}
	char what[40];
	snprintf(what, sizeof(what), "TX cmd %#06x", opcode);
	hex(what, pkt, 4 + plen);
	double t0 = now();
	if (write(fd, pkt, 4 + plen) != (ssize_t)(4 + plen)) {
		printf("write: %s\n", strerror(errno));
		return -1;
	}
	double deadline = t0 + 5;
	unsigned n;
	while (get_packet(fd, deadline, &n)) {
		uint8_t *e = rxb;
		hex(e[0] == 4 ? "RX evt" : "RX pkt", e, n);
		if (e[0] == 4 && e[1] == 0x0e && n >= 7 && (e[4] | (e[5] << 8)) == (int)opcode) {
			printf("  Command Complete for %#06x, status %#x, %.1f ms\n", opcode, e[6], (now() - t0) * 1e3);
			if (ret) {
				memcpy(ret, e + 6, n - 6);
				*retlen = n - 6;
			}
			int st = e[6];
			drop(n);
			return st;
		}
		if (e[0] == 4 && e[1] == 0x0f && n >= 7 && (e[5] | (e[6] << 8)) == (int)opcode) {
			printf("  Command Status for %#06x: %#x\n", opcode, e[3]);
			int st = e[3];
			drop(n);
			return st;
		}
		drop(n);
	}
	printf("  no reply to %#06x within 5 s\n", opcode);
	return -1;
}

/* ---- what the radio hears: devices by address, strongest signal, name, how often ---- */
struct heard {
	uint8_t addr[6];
	int rssi, n, have_rssi;
	unsigned cod;
	char name[64];
};
/*
 * -s: the services the remote lists (SDP, L2CAP PSM 1), with no host stack: one L2CAP channel by hand.
 * What kind of device answers at an address: an audio sink (110b), a hands-free unit (111e), or something else.
 */
static void
l2_send(int fd, unsigned handle, unsigned cid, const uint8_t *p, unsigned len)
{
	uint8_t m[9 + 256];

	if (len > 256) {
		return;
	}
	m[0] = 2; m[1] = (uint8_t)handle; m[2] = (uint8_t)((handle >> 8) & 0x0f);     /* first fragment, as bluetoothd sends it */
	m[3] = (uint8_t)(len + 4); m[4] = (uint8_t)((len + 4) >> 8);
	m[5] = (uint8_t)len; m[6] = (uint8_t)(len >> 8); m[7] = (uint8_t)cid; m[8] = (uint8_t)(cid >> 8);
	memcpy(m + 9, p, len);
	(void)!write(fd, m, 9 + len);
}

/* one whole L2CAP PDU of this connection (ACL fragments joined): payload length + 1, or 0 on timeout / disconnection */
static unsigned
l2_recv(int fd, unsigned handle, double deadline, uint8_t *out, unsigned max, unsigned *cid)
{
	static uint8_t buf[4096];
	unsigned have = 0, n;

	while (get_packet(fd, deadline, &n)) {
		if (rxb[0] == 4 && rxb[1] == 0x05) {
			printf("  disconnected, reason %#x\n", n >= 7 ? rxb[6] : 0);
			drop(n);
			return 0;
		}
		if (rxb[0] == 2 && n >= 5 && ((rxb[1] | (rxb[2] << 8)) & 0x0fff) == handle) {
			unsigned pb = (rxb[2] >> 4) & 3, dl = n - 5;
			if (pb != 1) {
				have = 0;
			}
			if (have + dl <= sizeof(buf)) {
				memcpy(buf + have, rxb + 5, dl);
				have += dl;
			}
			drop(n);
			if (have >= 4 && have >= 4u + (buf[0] | (buf[1] << 8))) {
				unsigned l = buf[0] | (buf[1] << 8);
				*cid = buf[2] | (buf[3] << 8);
				if (l > max) {
					l = max;
				}
				memcpy(out, buf + 4, l);
				return l + 1;
			}
			continue;
		}
		drop(n);
	}
	return 0;
}

static const uint8_t *
de_flat(const uint8_t *p, const uint8_t *end)
{
	if (p >= end) {
		return end;
	}
	unsigned type = p[0] >> 3, si = p[0] & 7, len = 0;
	p++;
	if (si <= 4) {
		len = type == 0 ? 0 : 1u << si;
	} else if (si == 5 && end - p >= 1) {
		len = p[0]; p += 1;
	} else if (si == 6 && end - p >= 2) {
		len = (unsigned)(p[0] << 8 | p[1]); p += 2;
	} else if (si == 7 && end - p >= 4) {
		len = (unsigned)p[2] << 8 | p[3]; p += 4;
	} else {
		return end;
	}
	if (len > (unsigned)(end - p)) {
		len = (unsigned)(end - p);
	}
	const uint8_t *e = p + len;
	switch (type) {
	case 1: case 2: {
		unsigned long long v = 0;
		for (unsigned i = 0; i < len && i < 8; i++) {
			v = v << 8 | p[i];
		}
		printf("%#llx ", v);
		break;
	}
	case 3:
		printf("uuid ");
		for (unsigned i = 0; i < len; i++) {
			printf("%02x", p[i]);
		}
		printf(" ");
		break;
	case 4: case 8:
		printf("\"%.*s\" ", (int)len, (const char *)p);
		break;
	case 5:
		printf("%s ", len && p[0] ? "true" : "false");
		break;
	case 6: case 7:
		printf("{ ");
		while (p < e) {
			p = de_flat(p, e);
		}
		printf("} ");
		break;
	default:
		break;
	}
	return e;
}

static void
sdp_browse(int fd, unsigned handle, unsigned pattern)
{
	static uint8_t all[8192];
	uint8_t r[2048], q[64], cont[17];
	unsigned cid = 0, l, rcid = 0, alln = 0, mine = 0, theirs = 0, contn = 0, tid = 1;
	double t0 = now();
	int asked = 0, done = 0;
	const uint8_t creq[8] = { 0x02, 0x01, 0x04, 0x00, 0x01, 0x00, 0x40, 0x00 };   /* Connection Request: PSM 1, our CID 0x40 */

	l2_send(fd, handle, 1, creq, 8);
	while (!done && (l = l2_recv(fd, handle, t0 + 8, r, sizeof(r), &cid)) != 0) {
		l--;
		if (cid == 1 && l >= 4) {               /* signalling */
			switch (r[0]) {
			case 0x03:
				if (l >= 12 && (r[8] | (r[9] << 8)) == 0) {
					rcid = r[4] | (r[5] << 8);
					uint8_t c[8] = { 0x04, 0x02, 0x04, 0x00, (uint8_t)rcid, (uint8_t)(rcid >> 8), 0, 0 };
					l2_send(fd, handle, 1, c, 8);
				} else if (l >= 12 && (r[8] | (r[9] << 8)) != 1) {
					printf("  SDP channel refused: result %u\n", r[8] | (r[9] << 8));
					done = 1;
				}
				break;
			case 0x04: {
				uint8_t c[10] = { 0x05, r[1], 0x06, 0x00, (uint8_t)rcid, (uint8_t)(rcid >> 8), 0, 0, 0, 0 };
				l2_send(fd, handle, 1, c, 10);
				theirs = 1;
				break;
			}
			case 0x05:
				mine = 1;
				break;
			case 0x0a: {
				uint8_t c[8] = { 0x0b, r[1], 0x04, 0x00, r[4], r[5], 0x01, 0x00 };   /* not supported */
				l2_send(fd, handle, 1, c, 8);
				break;
			}
			case 0x02: {                    /* the remote opens a channel to us: PSM, its CID */
				uint8_t c[12] = { 0x03, r[1], 0x08, 0x00, 0, 0, r[6], r[7], 0x02, 0x00, 0, 0 };   /* PSM not supported */
				printf("  (the remote asks for a channel to PSM %#x here: refused)\n", r[4] | (r[5] << 8));
				l2_send(fd, handle, 1, c, 12);
				break;
			}
			default:
				break;
			}
		} else if (cid == 0x40 && l >= 5) {     /* SDP */
			if (r[0] == 0x01) {
				printf("  SDP error %#x\n", l >= 7 ? (r[5] << 8 | r[6]) : 0);
				done = 1;
			} else if (r[0] == 0x07 && l >= 8) {
				unsigned bc = (unsigned)(r[5] << 8 | r[6]);
				if (7 + bc + 1 > l) {
					bc = l - 8;
				}
				if (alln + bc <= sizeof(all)) {
					memcpy(all + alln, r + 7, bc);
					alln += bc;
				}
				contn = r[7 + bc];
				if (contn == 0 || contn > 16 || 8 + bc + contn > l) {
					done = 1;
				} else {
					memcpy(cont, r + 8 + bc, contn);
					asked = 0;
				}
			}
		}
		if (!done && mine && theirs && !asked) {
			unsigned n = 0;
			q[n++] = 0x06; q[n++] = 0; q[n++] = (uint8_t)tid++; q[n++] = 0; q[n++] = 0;     /* Service Search Attribute */
			q[n++] = 0x35; q[n++] = 0x03; q[n++] = 0x19; q[n++] = (uint8_t)(pattern >> 8); q[n++] = (uint8_t)pattern;
			q[n++] = 0x02; q[n++] = 0x00;                                                   /* 512 bytes a turn */
			q[n++] = 0x35; q[n++] = 0x05; q[n++] = 0x0a; q[n++] = 0; q[n++] = 0; q[n++] = 0xff; q[n++] = 0xff;
			q[n++] = (uint8_t)contn;
			memcpy(q + n, cont, contn);
			n += contn;
			q[4] = (uint8_t)(n - 5);
			l2_send(fd, handle, rcid, q, n);
			asked = 1;
		}
	}
	if (!mine || !theirs) {
		printf("  SDP: no channel (ours configured %u, theirs %u) in %.1f s\n", mine, theirs, now() - t0);
		return;
	}
	printf("  SDP, pattern %#06x: %u bytes of records\n", pattern, alln);
	const uint8_t *p = all, *end = all + alln;
	if (alln >= 2 && (p[0] >> 3) == 6) {            /* the list of records */
		unsigned si = p[0] & 7;
		p += si == 5 ? 2 : si == 6 ? 3 : 5;
		unsigned rec = 0;
		while (p < end && (p[0] >> 3) == 6) {
			unsigned s2 = p[0] & 7, rl;
			if (s2 == 5) { rl = p[1]; p += 2; } else if (s2 == 6) { rl = (unsigned)(p[1] << 8 | p[2]); p += 3; } else { break; }
			const uint8_t *re = p + rl > end ? end : p + rl;
			printf("  record %u:\n", ++rec);
			while (p + 3 <= re && p[0] == 0x09) {           /* attribute id, value */
				printf("    %02x%02x: ", p[1], p[2]);
				p = de_flat(p + 3, re);
				printf("\n");
			}
			p = re;
		}
	}
}

static struct heard heard[256];
static unsigned nheard;

static struct heard *
heard_get(const uint8_t *addr)
{
	for (unsigned i = 0; i < nheard; i++) {
		if (!memcmp(heard[i].addr, addr, 6)) {
			return &heard[i];
		}
	}
	if (nheard >= 256) {
		return NULL;
	}
	memset(&heard[nheard], 0, sizeof(heard[0]));
	memcpy(heard[nheard].addr, addr, 6);
	return &heard[nheard++];
}

/* a name out of EIR / advertising data: AD structures {len, type, data}; types 0x09 complete, 0x08 shortened name */
static void
ad_name(const uint8_t *d, unsigned n, char *out, unsigned max)
{
	for (unsigned i = 0; i + 1 < n && d[i];) {
		unsigned l = d[i], t = d[i + 1];
		if (i + 1 + l > n) {
			break;
		}
		if ((t == 0x09 || (t == 0x08 && !out[0])) && l > 1) {
			unsigned k = l - 1 < max - 1 ? l - 1 : max - 1;
			memcpy(out, d + i + 2, k);
			out[k] = 0;
		}
		i += 1 + l;
	}
}

static void
heard_note(const uint8_t *addr, int have_rssi, int rssi, unsigned cod, const uint8_t *ad, unsigned adn)
{
	struct heard *h = heard_get(addr);
	if (!h) {
		return;
	}
	h->n++;
	if (have_rssi && (!h->have_rssi || rssi > h->rssi)) {
		h->rssi = rssi;
		h->have_rssi = 1;
	}
	if (cod) {
		h->cod = cod;
	}
	if (ad && adn) {
		ad_name(ad, adn, h->name, sizeof(h->name));
	}
}

static void
heard_print(const char *what, double secs)
{
	printf("%s: %u device(s) heard in %.1f s\n", what, nheard, secs);
	for (unsigned i = 0; i < nheard; i++) {
		struct heard *h = &heard[i];
		printf("  %02x:%02x:%02x:%02x:%02x:%02x  x%-3d ", h->addr[5], h->addr[4], h->addr[3], h->addr[2], h->addr[1],
		    h->addr[0], h->n);
		if (h->have_rssi) {
			printf("%4d dBm  ", h->rssi);
		} else {
			printf("   ? dBm  ");
		}
		if (h->cod) {
			printf("class %06x  ", h->cod);
		}
		printf("%s\n", h->name[0] ? h->name : "(no name in the answer)");
	}
	nheard = 0;
}

/* one event of an inquiry or an LE scan into the table; returns 1 on Inquiry Complete */
static int
scan_event(const uint8_t *e, unsigned n)
{
	if (e[0] != 4 || n < 3) {
		return 0;
	}
	const uint8_t *p = e + 3;
	unsigned pl = e[2];
	switch (e[1]) {
	case 0x01:                              /* Inquiry Complete */
		return 1;
	case 0x02:                              /* Inquiry Result: n x {addr 6, psrm 1, rsvd 2, cod 3, clock 2} */
		for (unsigned k = 0; pl >= 1 && k < p[0] && 1 + (k + 1) * 14 <= pl; k++) {
			const uint8_t *r = p + 1 + k * 14;
			heard_note(r, 0, 0, r[9] | (r[10] << 8) | (r[11] << 16), NULL, 0);
		}
		break;
	case 0x22:                              /* with RSSI: n x {addr 6, psrm 1, rsvd 1, cod 3, clock 2, rssi 1} */
		for (unsigned k = 0; pl >= 1 && k < p[0] && 1 + (k + 1) * 14 <= pl; k++) {
			const uint8_t *r = p + 1 + k * 14;
			heard_note(r, 1, (int8_t)r[13], r[8] | (r[9] << 8) | (r[10] << 16), NULL, 0);
		}
		break;
	case 0x2f:                              /* Extended: 1, addr 6, psrm 1, rsvd 1, cod 3, clock 2, rssi 1, EIR 240 */
		if (pl >= 15) {
			heard_note(p + 1, 1, (int8_t)p[14], p[9] | (p[10] << 8) | (p[11] << 16), p + 15, pl - 15);
		}
		break;
	case 0x3e:                              /* LE Meta: 0x02 Advertising Report */
		if (pl >= 2 && p[0] == 0x02) {
			const uint8_t *r = p + 2;
			for (unsigned k = 0; k < p[1] && r + 9 <= p + pl; k++) {
				unsigned dl = r[8];
				if (r + 9 + dl + 1 > p + pl) {
					break;
				}
				if (getenv("HCI_RAW")) {         /* every report: address, event type, address type, data */
					printf("ADV %02x:%02x:%02x:%02x:%02x:%02x t%u a%u", r[7], r[6], r[5], r[4], r[3], r[2], r[0], r[1]);
					hex("", r + 9, dl);
				}
				heard_note(r + 2, 1, (int8_t)r[9 + dl], 0x100u | (unsigned)(r[1] & 0xf) << 4 | (r[0] & 0xf), r + 9, dl);
				r += 9 + dl + 1;
			}
		}
		break;
	default:
		break;
	}
	return 0;
}

static void
scan_collect(int fd, double secs, int until_complete)
{
	double end = now() + secs;
	unsigned n, other = 0;
	while (get_packet(fd, end, &n)) {
		if (scan_event(rxb, n) && until_complete) {
			drop(n);
			break;
		}
		other += !(rxb[0] == 4 && (rxb[1] == 0x02 || rxb[1] == 0x22 || rxb[1] == 0x2f || rxb[1] == 0x3e || rxb[1] == 0x01));
		drop(n);
	}
	if (other) {
		printf("  (%u other packets in that time)\n", other);
	}
}

int
main(int argc, char **argv)
{
	const char *name = "com.apple.uart.bluetooth";
	unsigned long baud = 3000000;
	int listen_s = 0, inq_s = 0, le_s = 0, ch;
	const char *name_of = NULL, *conn_to = NULL;
	int inq_dbm = 127, liac = 0, inq_mode = 2, role_switch = 1;
	unsigned clk_off = 0;
	int ext_scan = 0;
	const char *raw[48];
	unsigned nraw = 0;
	int no_reset = 0, pair_io = -1, pair_auth = 0x04, pair_wait_ms = 0;
	unsigned sdp_pattern = 0;

	while ((ch = getopt(argc, argv, "n:b:l:i:e:r:p:Lm:c:So:E:x:NP:A:W:s:")) != -1) {
		switch (ch) {
		case 'n': name = optarg; break;
		case 'b': baud = strtoul(optarg, NULL, 0); break;
		case 'l': listen_s = atoi(optarg); break;
		case 'i': inq_s = atoi(optarg); break;
		case 'e': le_s = atoi(optarg); break;
		case 'r': name_of = optarg; break;
		case 'p': inq_dbm = atoi(optarg); break;
		case 'L': liac = 1; break;
		case 'm': inq_mode = atoi(optarg); break;
		case 'c': conn_to = optarg; break;
		case 'S': role_switch = 0; break;
		case 'o': clk_off = (unsigned)strtoul(optarg, NULL, 16); break;   /* -c: clock offset field, hex (8000 = "valid, 0") */
		case 'E': ext_scan = atoi(optarg); break;       /* -c: an LE extended scan running meanwhile; 1 = 40/30 ms, 2 = 965/30 ms */
		case 's': sdp_pattern = (unsigned)strtoul(optarg, NULL, 16); break;     /* SDP: records with this UUID (0100 = all on L2CAP) */
		case 'P': pair_io = atoi(optarg); break;
		case 'A': pair_auth = (int)strtoul(optarg, NULL, 16); break;   /* authentication requirements of the reply */
		case 'W': pair_wait_ms = atoi(optarg); break;                   /* wait before Authentication Requested */
		case 'N': no_reset = 1; break;                  /* no HCI Reset: the controller as the last client (bluetoothd) left it */
		case 'x':                                       /* a raw command before the tests: "0c7a 01" = opcode, parameter bytes */
			if (nraw < 48) {
				raw[nraw++] = optarg;
			}
			break;
		default:
			fprintf(stderr, "usage: hcitest [-n ctlname] [-b baud] [-l seconds] [-i seconds] [-e seconds]\n");
			return 2;
		}
	}
	int fd = socket(32 /* PF_SYSTEM */, SOCK_STREAM, SYSPROTO_CONTROL);
	if (fd < 0) {
		perror("socket(PF_SYSTEM, SOCK_STREAM, SYSPROTO_CONTROL)");
		return 1;
	}
	struct ctl_info info;
	memset(&info, 0, sizeof(info));
	strlcpy(info.ctl_name, name, sizeof(info.ctl_name));
	if (ioctl(fd, CTLIOCGINFO, &info) < 0) {
		fprintf(stderr, "CTLIOCGINFO %s: %s (is sweetbt=1 up? look for 'SWEET BT: transport up' in the kernel log)\n",
		    name, strerror(errno));
		return 1;
	}
	struct sockaddr_ctl sc;
	memset(&sc, 0, sizeof(sc));
	sc.sc_len = sizeof(sc);
	sc.sc_family = 32 /* AF_SYSTEM */;
	sc.ss_sysaddr = AF_SYS_CONTROL;
	sc.sc_id = info.ctl_id;
	sc.sc_unit = 0;
	if (connect(fd, (struct sockaddr *)&sc, sizeof(sc)) < 0) {
		fprintf(stderr, "connect %s (id %u): %s%s\n", name, info.ctl_id, strerror(errno),
		    errno == EBUSY ? " (another client is connected: stop bluetoothd)" : "");
		return 1;
	}
	printf("connected to %s (ctl id %u)\n", name, info.ctl_id);

	struct termios t;
	socklen_t tl = sizeof(t);
	if (getsockopt(fd, SYSPROTO_CONTROL, 0x40487413 /* TIOCGETA */, &t, &tl) < 0) {
		printf("TIOCGETA: %s\n", strerror(errno));
	} else {
		printf("TIOCGETA: %u bytes, cflag %#lx, speed %lu/%lu\n", tl, t.c_cflag, t.c_ispeed, t.c_ospeed);
	}
	/* what bluetoothd does for mode 0: cfmakeraw, cfsetspeed, c_iflag |= 4, c_cflag = 0x38B00 */
	cfmakeraw(&t);
	cfsetspeed(&t, baud);
	t.c_iflag |= 4;
	t.c_cflag = 0x38B00;
	if (setsockopt(fd, SYSPROTO_CONTROL, 0x80487414 /* TIOCSETA */, &t, sizeof(t)) < 0) {
		printf("TIOCSETA %lu baud: %s\n", baud, strerror(errno));
	} else {
		printf("TIOCSETA %lu baud ok\n", baud);
	}
	tl = sizeof(t);
	if (getsockopt(fd, SYSPROTO_CONTROL, 0x40487413, &t, &tl) == 0) {
		printf("TIOCGETA after set: speed %lu/%lu cflag %#lx\n", t.c_ispeed, t.c_ospeed, t.c_cflag);
	}

	int bad = 0;
	uint8_t r[64];
	unsigned rl = 0;

	if (!no_reset && command(fd, 0x0c03, NULL, 0, NULL, NULL) != 0) {       /* Reset */
		bad++;
	}
	if (command(fd, 0x1001, NULL, 0, r, &rl) != 0 || rl < 9) {               /* Read_Local_Version_Information */
		bad++;
	} else {
		printf("  HCI version %u revision %#06x, LMP version %u, manufacturer %#06x, LMP subversion %#06x\n",
		    r[1], r[2] | (r[3] << 8), r[4], r[5] | (r[6] << 8), r[7] | (r[8] << 8));
	}
	if (command(fd, 0x1009, NULL, 0, r, &rl) != 0 || rl < 7) {               /* Read_BD_ADDR */
		bad++;
	} else {
		printf("  BD_ADDR %02x:%02x:%02x:%02x:%02x:%02x\n", r[6], r[5], r[4], r[3], r[2], r[1]);
	}
	for (unsigned k = 0; k < nraw; k++) {
		uint8_t par[255];
		unsigned op = 0, pl = 0, v;
		const char *q = raw[k];
		int used = 0;
		if (sscanf(q, "%x%n", &op, &used) != 1) {
			continue;
		}
		for (q += used; pl < sizeof(par) && sscanf(q, "%x%n", &v, &used) == 1; q += used) {
			par[pl++] = (uint8_t)v;
		}
		printf("raw %#06x (%u parameter bytes): status %#x\n", op, pl, command(fd, op, par, pl, NULL, NULL));
	}
	if (inq_s > 0 || le_s > 0) {
		/* after a reset the event mask leaves out Extended Inquiry Result (bit 46) and LE Meta (bit 61) */
		static const uint8_t mask[8] = { 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x3f };
		(void)command(fd, 0x0c01, mask, 8, NULL, NULL);
	}
	if (inq_s > 0) {
		uint8_t mode = (uint8_t)inq_mode;                               /* -m: 0 standard, 1 with RSSI, 2 extended (default) */
		unsigned len = (unsigned)((inq_s * 100 + 127) / 128);
		len = len < 1 ? 1 : len > 0x30 ? 0x30 : len;
		uint8_t inq[5] = { (uint8_t)(liac ? 0x00 : 0x33), 0x8b, 0x9e, (uint8_t)len, 0 };   /* GIAC or LIAC, length x 1.28 s, any number */
		(void)command(fd, 0x0c45, &mode, 1, NULL, NULL);                /* Write_Inquiry_Mode */
		if (inq_dbm != 127) {
			uint8_t pw = (uint8_t)(int8_t)inq_dbm;
			int st = command(fd, 0x0c59, &pw, 1, NULL, NULL);       /* Write_Inquiry_Transmit_Power_Level */
			printf("inquiry transmit power %d dBm: status %#x\n", inq_dbm, st);
		}
		double t0 = now();
		if (command(fd, 0x0401, inq, 5, NULL, NULL) == 0) {             /* Inquiry */
			scan_collect(fd, len * 1.28 + 3, 1);
		}
		heard_print("classic inquiry", now() - t0);
	}
	if (le_s > 0) {
		uint8_t par[7] = { 1, 0x60, 0x00, 0x30, 0x00, 0, 0 };           /* active, 60 ms / 30 ms, public, all */
		uint8_t on[2] = { 1, 1 }, off[2] = { 0, 0 };
		(void)command(fd, 0x200b, par, 7, NULL, NULL);                  /* LE_Set_Scan_Parameters */
		double t0 = now();
		if (command(fd, 0x200c, on, 2, NULL, NULL) == 0) {              /* LE_Set_Scan_Enable */
			scan_collect(fd, le_s, 0);
		}
		(void)command(fd, 0x200c, off, 2, NULL, NULL);
		heard_print("LE scan", now() - t0);
	}
	if (name_of) {
		unsigned a[6];
		if (sscanf(name_of, "%x:%x:%x:%x:%x:%x", &a[5], &a[4], &a[3], &a[2], &a[1], &a[0]) != 6) {
			printf("-r wants AA:BB:CC:DD:EE:FF\n");
		} else {
			for (int mode = 0; mode <= 2; mode++) {         /* page scan repetition mode R0, R1, R2 */
				uint8_t rn[10] = { (uint8_t)a[0], (uint8_t)a[1], (uint8_t)a[2], (uint8_t)a[3], (uint8_t)a[4],
					           (uint8_t)a[5], (uint8_t)mode, 0, 0, 0 };
				double t0 = now();
				unsigned n;
				int done = 0;
				if (command(fd, 0x0419, rn, 10, NULL, NULL) != 0) {     /* Remote_Name_Request */
					continue;
				}
				while (!done && get_packet(fd, t0 + 12, &n)) {
					if (rxb[0] == 4 && rxb[1] == 0x07 && n >= 10) { /* Remote Name Request Complete */
						char nm[249] = { 0 };
						memcpy(nm, rxb + 10, n - 10 < 248 ? n - 10 : 248);
						printf("remote name (page scan mode R%d): status %#x after %.1f s%s%s\n", mode, rxb[3],
						    now() - t0, rxb[3] ? "" : ", name ", rxb[3] ? (rxb[3] == 4 ? " (page timeout: no answer)" : "") : nm);
						done = 1 + (rxb[3] == 0);
					}
					drop(n);
				}
				if (!done) {
					printf("remote name: no completion event in 12 s\n");
				}
				if (done == 2) {
					break;
				}
			}
		}
	}
	if (conn_to) {
		unsigned a[6];
		if (sscanf(conn_to, "%x:%x:%x:%x:%x:%x", &a[5], &a[4], &a[3], &a[2], &a[1], &a[0]) != 6) {
			printf("-c wants AA:BB:CC:DD:EE:FF\n");
		} else {
			uint8_t cc[13] = { (uint8_t)a[0], (uint8_t)a[1], (uint8_t)a[2], (uint8_t)a[3], (uint8_t)a[4], (uint8_t)a[5],
				           0x18, 0xcc, 1, 0, (uint8_t)clk_off, (uint8_t)(clk_off >> 8), (uint8_t)role_switch };
			if (ext_scan) {
				static const uint8_t mask[8] = { 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x3f };
				uint8_t xp[8] = { 0, 0, 1, 1, 0x40, 0x00, 0x30, 0x00 }, xe[6] = { 1, 0, 0, 0, 0, 0 };
				if (ext_scan == 2) {
					xp[3] = 0; xp[4] = 0x09; xp[5] = 0x06;
				}
				(void)command(fd, 0x0c01, mask, 8, NULL, NULL);
				printf("LE extended scan on (%s): parameters %#x, enable %#x\n", ext_scan == 2 ? "965/30 ms passive" : "40/30 ms active",
				    command(fd, 0x2041, xp, 8, NULL, NULL), command(fd, 0x2042, xe, 6, NULL, NULL));
			}
			double t0 = now();
			unsigned n, handle = 0xffff;
			int st = -1;
			if (command(fd, 0x0405, cc, 13, NULL, NULL) == 0) {             /* Create_Connection */
				while (get_packet(fd, t0 + 12, &n)) {
					if (rxb[0] == 4 && rxb[1] == 0x03 && n >= 14) {         /* Connection Complete */
						st = rxb[3];
						handle = rxb[4] | (rxb[5] << 8);
						drop(n);
						break;
					}
					if (rxb[0] == 4 && rxb[1] == 0x04) {                    /* a Connection Request the other way */
						printf("  (connection request from the remote while paging)\n");
					}
					drop(n);
				}
			}
			printf("connection (role switch %s): status %#x after %.1f s%s\n", role_switch ? "allowed" : "not allowed", st,
			    now() - t0, st == 0 ? ": connected" : st == 0x0d ? " (rejected: limited resources)" : st == 4 ?
			    " (page timeout)" : st == 0x0e ? " (rejected: security)" : st == 0x0f ? " (rejected: unacceptable address)" : "");
			if (st == 0) {
				uint8_t h[3] = { (uint8_t)handle, (uint8_t)(handle >> 8), 0x13 };
				double t1 = now();
				(void)command(fd, 0x041d, h, 2, NULL, NULL);                    /* Read_Remote_Version_Information */
				while (get_packet(fd, t1 + 3, &n)) {
					if (rxb[0] == 4 && rxb[1] == 0x0c && n >= 11) {
						printf("  remote LMP version %u, manufacturer %#06x, subversion %#06x\n", rxb[6], rxb[7] | (rxb[8] << 8),
						    rxb[9] | (rxb[10] << 8));
						drop(n);
						break;
					}
					if (rxb[0] == 4 && rxb[1] == 0x05) {
						printf("  the remote disconnected, reason %#x\n", n >= 7 ? rxb[6] : 0);
						handle = 0xffff;
					}
					drop(n);
				}
				if (handle != 0xffff && sdp_pattern) {
					sdp_browse(fd, handle, sdp_pattern);
				}
				if (handle != 0xffff && pair_io >= 0) {
					uint8_t on = 1, m[16];
					double tp = now();
					int done = 0;
					if (!no_reset) {
						(void)command(fd, 0x0c56, &on, 1, NULL, NULL);  /* Write_Simple_Pairing_Mode */
					}
#define SEND(op, body, blen) do { m[0] = 1; m[1] = (uint8_t)(op); m[2] = (uint8_t)((op) >> 8); m[3] = (uint8_t)(blen); \
		memcpy(m + 4, (body), (blen)); (void)!write(fd, m, 4 + (blen)); } while (0)
					{       /* what the remote says it can do: features page 0 and the host's page 1 */
						uint8_t q[3] = { h[0], h[1], 1 };
						double tf = now();
						int got = 0;
						SEND(0x041b, h, 2);                     /* Read_Remote_Supported_Features */
						while (got < 2 && get_packet(fd, tf + 3, &n)) {
							uint8_t *e = rxb;
							if (e[0] == 4 && e[1] == 0x0b && n >= 14) {
								printf("  remote features: %02x %02x %02x %02x %02x %02x %02x %02x: Simple Pairing in the controller %s\n",
								    e[6], e[7], e[8], e[9], e[10], e[11], e[12], e[13], (e[12] & 0x08) ? "yes" : "no");
								got = 1;
								SEND(0x041c, q, 3);     /* Read_Remote_Extended_Features, page 1 */
							} else if (e[0] == 4 && e[1] == 0x23 && n >= 16) {
								printf("  remote host features (page %u of %u): %02x %02x: Simple Pairing host %s, Secure Connections host %s\n",
								    e[6], e[7], e[8], e[9], (e[8] & 0x01) ? "yes" : "no", (e[8] & 0x08) ? "yes" : "no");
								got = 2;
							} else if (e[0] == 4 && e[1] == 0x05) {
								printf("  disconnected, reason %#x\n", n >= 7 ? e[6] : 0);
								handle = 0xffff;
								got = 2;
							}
							drop(n);
						}
					}
					if (pair_wait_ms > 0) {
						usleep((useconds_t)pair_wait_ms * 1000);
					}
					tp = now();
					if (handle != 0xffff) {
						SEND(0x0411, h, 2);                     /* Authentication_Requested */
					} else {
						done = 1;
					}
					while (!done && get_packet(fd, tp + 20, &n)) {
						uint8_t *e = rxb, b[9];
						if (e[0] == 4 && e[1] == 0x17 && n >= 9) {      /* Link Key Request: we have none */
							SEND(0x040c, e + 3, 6);
						} else if (e[0] == 4 && e[1] == 0x31 && n >= 9) {       /* IO Capability Request */
							memcpy(b, e + 3, 6);
							b[6] = (uint8_t)pair_io; b[7] = 0; b[8] = (uint8_t)pair_auth;
							SEND(0x042b, b, 9);
						} else if (e[0] == 4 && e[1] == 0x32 && n >= 12) {
							printf("  the remote: IO capability %u, OOB %u, authentication requirements %#x\n", e[9], e[10], e[11]);
						} else if (e[0] == 4 && e[1] == 0x33 && n >= 9) {       /* User Confirmation Request */
							printf("  user confirmation asked after %.0f ms: accepted\n", (now() - tp) * 1000);
							SEND(0x042c, e + 3, 6);
						} else if (e[0] == 4 && e[1] == 0x34 && n >= 9) {
							printf("  a passkey is asked for: refused\n");
							SEND(0x042f, e + 3, 6);
						} else if (e[0] == 4 && e[1] == 0x16 && n >= 9) {
							printf("  a PIN code is asked for (legacy pairing): refused\n");
							SEND(0x040e, e + 3, 6);
						} else if (e[0] == 4 && e[1] == 0x36 && n >= 4) {
							printf("  Simple Pairing Complete after %.0f ms: status %#x%s\n", (now() - tp) * 1000, e[3],
							    e[3] == 0 ? " (paired)" : e[3] == 5 ? " (authentication failure)" : "");
						} else if (e[0] == 4 && e[1] == 0x18 && n >= 26) {
							printf("  link key received, type %u\n", e[25]);
						} else if (e[0] == 4 && e[1] == 0x06 && n >= 6) {
							printf("  Authentication Complete: status %#x after %.1f s\n", e[3], now() - tp);
							done = 1;
						} else if (e[0] == 4 && e[1] == 0x05) {
							printf("  disconnected, reason %#x\n", n >= 7 ? e[6] : 0);
							handle = 0xffff;
							done = 1;
						} else if (e[0] == 4 && e[1] == 0x0f && n >= 7 && e[3] != 0) {
							printf("  command %#06x refused: status %#x\n", e[5] | (e[6] << 8), e[3]);
						}
						drop(n);
					}
					if (!done) {
						printf("  no Authentication Complete in 20 s\n");
					}
				}
				if (handle != 0xffff) {
					(void)command(fd, 0x0406, h, 3, NULL, NULL);            /* Disconnect */
				}
			}
		}
	}
	if (listen_s > 0) {
		printf("listening for %d s\n", listen_s);
		double end = now() + listen_s;
		unsigned n;
		while (get_packet(fd, end, &n)) {
			hex("RX", rxb, n);
			drop(n);
		}
	}
	printf("%s\n", bad ? "FAILED" : "all commands completed with status 0");
	close(fd);
	return bad ? 1 : 0;
}
