/*
 * sweetping: ICMP echo and a DNS query, for testing a network interface (iOS has no ping).
 *   sweetping [-I IFNAME] [-c COUNT] ADDRESS          echo requests, one a second, replies and round-trip times
 *   sweetping [-I IFNAME] -d SERVER NAME              one DNS A query over UDP: the answer's addresses
 * -I binds the socket to the interface (IP_BOUND_IF); otherwise the routing table decides.
 * Build: as tools/sweetnet/build.sh builds sweetsys (arm64e, then renegade's pacstrip --sign).
 */
#include <arpa/inet.h>
#include <errno.h>
#include <net/if.h>
#include <netinet/in.h>
#include <netinet/ip.h>
#include <netinet/ip_icmp.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

static double
now_ms(void)
{
	struct timeval tv;
	gettimeofday(&tv, NULL);
	return tv.tv_sec * 1000.0 + tv.tv_usec / 1000.0;
}

static uint16_t
cksum(const void *p, size_t n)
{
	const uint16_t *w = p;
	uint32_t s = 0;
	for (; n > 1; n -= 2) {
		s += *w++;
	}
	if (n) {
		s += *(const uint8_t *)w;
	}
	s = (s >> 16) + (s & 0xffff);
	s += s >> 16;
	return (uint16_t)~s;
}

static int
bind_if(int fd, const char *ifname)
{
	if (!ifname) {
		return 0;
	}
	unsigned idx = if_nametoindex(ifname);
	if (!idx || setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &idx, sizeof(idx))) {
		fprintf(stderr, "cannot bind to %s: %s\n", ifname, strerror(errno));
		return -1;
	}
	return 0;
}

static int
echo(const char *ifname, struct in_addr to, int count)
{
	int fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP), got = 0;
	if (fd < 0 || bind_if(fd, ifname)) {
		perror("socket");
		return 1;
	}
	struct timeval tv = { 1, 0 };
	setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
	struct sockaddr_in sa = { .sin_len = sizeof(sa), .sin_family = AF_INET, .sin_addr = to };
	for (int seq = 1; seq <= count; seq++) {
		uint8_t pkt[64] = { 0 };
		struct icmp *ic = (struct icmp *)pkt;
		ic->icmp_type = ICMP_ECHO;
		ic->icmp_id = htons((uint16_t)getpid());
		ic->icmp_seq = htons((uint16_t)seq);
		memcpy(pkt + 8, "sweetping", 9);
		ic->icmp_cksum = cksum(pkt, sizeof(pkt));
		double t0 = now_ms();
		if (sendto(fd, pkt, sizeof(pkt), 0, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
			printf("seq %d: send: %s\n", seq, strerror(errno));
			sleep(1);
			continue;
		}
		for (;;) {
			uint8_t in[1500];
			ssize_t n = recv(fd, in, sizeof(in), 0);
			if (n < 0) {
				printf("seq %d: no reply in 1 s\n", seq);
				break;
			}
			/* the datagram socket hands over the IP header too on Darwin */
			size_t hl = (n >= 20 && (in[0] >> 4) == 4) ? (size_t)(in[0] & 0xf) * 4 : 0;
			if ((size_t)n < hl + 8) {
				continue;
			}
			struct icmp *r = (struct icmp *)(in + hl);
			if (r->icmp_type == ICMP_ECHOREPLY && ntohs(r->icmp_seq) == seq) {
				printf("seq %d: reply, %zd bytes, %.1f ms\n", seq, n - (ssize_t)hl, now_ms() - t0);
				got++;
				break;
			}
		}
		if (seq < count) {
			sleep(1);
		}
	}
	printf("%d of %d answered\n", got, count);
	close(fd);
	return got ? 0 : 1;
}

static int
dns(const char *ifname, struct in_addr server, const char *name)
{
	uint8_t q[512], a[1500];
	size_t n = 0;
	uint16_t id = (uint16_t)getpid();
	q[n++] = (uint8_t)(id >> 8);
	q[n++] = (uint8_t)id;
	q[n++] = 1;                     /* recursion desired */
	q[n++] = 0;
	q[n++] = 0; q[n++] = 1;         /* one question */
	memset(q + n, 0, 6);
	n += 6;
	for (const char *p = name; *p;) {
		const char *dot = strchr(p, '.');
		size_t l = dot ? (size_t)(dot - p) : strlen(p);
		if (l == 0 || l > 63 || n + l + 6 > sizeof(q)) {
			fprintf(stderr, "bad name\n");
			return 1;
		}
		q[n++] = (uint8_t)l;
		memcpy(q + n, p, l);
		n += l;
		p += l + (dot ? 1 : 0);
	}
	q[n++] = 0;
	q[n++] = 0; q[n++] = 1;         /* A */
	q[n++] = 0; q[n++] = 1;         /* IN */
	int fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
	if (fd < 0 || bind_if(fd, ifname)) {
		perror("socket");
		return 1;
	}
	struct timeval tv = { 3, 0 };
	setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
	struct sockaddr_in sa = { .sin_len = sizeof(sa), .sin_family = AF_INET, .sin_port = htons(53), .sin_addr = server };
	double t0 = now_ms();
	if (sendto(fd, q, n, 0, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
		printf("send: %s\n", strerror(errno));
		return 1;
	}
	ssize_t r = recv(fd, a, sizeof(a), 0);
	if (r < 12) {
		printf("no answer in 3 s\n");
		return 1;
	}
	unsigned rcode = a[3] & 0xf, an = (unsigned)a[6] << 8 | a[7];
	printf("answer in %.1f ms: rcode %u, %u records\n", now_ms() - t0, rcode, an);
	size_t o = n;                   /* the question is echoed: answers start after it */
	for (unsigned i = 0; i < an && o + 12 <= (size_t)r; i++) {
		if ((a[o] & 0xc0) == 0xc0) {
			o += 2;
		} else {
			while (o < (size_t)r && a[o]) {
				o += a[o] + 1;
			}
			o++;
		}
		unsigned type = (unsigned)a[o] << 8 | a[o + 1], rdlen = (unsigned)a[o + 8] << 8 | a[o + 9];
		o += 10;
		if (type == 1 && rdlen == 4 && o + 4 <= (size_t)r) {
			printf("  A %u.%u.%u.%u\n", a[o], a[o + 1], a[o + 2], a[o + 3]);
		}
		o += rdlen;
	}
	close(fd);
	return rcode == 0 && an ? 0 : 1;
}

int
main(int argc, char **argv)
{
	const char *ifname = NULL, *server = NULL;
	int count = 4, c;
	while ((c = getopt(argc, argv, "I:c:d:")) != -1) {
		switch (c) {
		case 'I': ifname = optarg; break;
		case 'c': count = atoi(optarg); break;
		case 'd': server = optarg; break;
		default: goto usage;
		}
	}
	if (optind != argc - 1) {
		goto usage;
	}
	struct in_addr addr;
	if (inet_pton(AF_INET, server ? server : argv[optind], &addr) != 1) {
		goto usage;
	}
	return server ? dns(ifname, addr, argv[optind]) : echo(ifname, addr, count > 0 ? count : 4);
usage:
	fprintf(stderr, "usage: sweetping [-I IFNAME] [-c COUNT] ADDRESS | sweetping [-I IFNAME] -d SERVER NAME\n");
	return 2;
}
