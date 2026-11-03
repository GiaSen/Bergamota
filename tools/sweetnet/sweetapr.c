/*
 * sweetapr: one APR command to the Mi 8's audio DSP over SSH, and the DSP's answers (kern.sweet_audio_apr, a test
 * boot with sweetaudio>=3, bsd/dev/dipper_audio.c).
 *
 *   sweetapr SVC OPCODE [TOKEN [WAIT_MS [FIELD...]]]   send, wait (default 1000 ms or the command's basic result)
 *   sweetapr -r                                       only what the DSP sent since the last read
 *   sweetapr --apps2 ...                              on the apr_apps2 channel instead of apr_audio_svc
 *   sweetapr --port N ...                             src and dest port (ASM: session << 8 | stream; ADM: AFE port)
 *
 * FIELD: b:N (u8), h:N (u16), w:N (u32), little-endian, in order; N in C notation (0x...). SVC 3 = AVCS core,
 * 4 = AFE, 7 = ASM, 8 = ADM. Each answer prints its header and payload words.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>

static void
dump(const uint8_t *b, size_t n)
{
	for (size_t o = 0; o + 2 <= n;) {
		uint16_t len;
		memcpy(&len, b + o, 2);
		o += 2;
		if (o + len > n || len < 20) {
			break;
		}
		const uint8_t *p = b + o;
		uint16_t field, size, sport, dport;
		uint32_t token, opcode;
		memcpy(&field, p, 2);
		memcpy(&size, p + 2, 2);
		memcpy(&sport, p + 6, 2);
		memcpy(&dport, p + 10, 2);
		memcpy(&token, p + 12, 4);
		memcpy(&opcode, p + 16, 4);
		unsigned hlen = ((field >> 4) & 0xfu) * 4u;
		if (hlen < 20) {
			hlen = 20;
		}
		printf("svc %u.%u:%u -> %u.%u:%u opcode %#010x token %#x size %u (header %u):", p[4], p[5], sport, p[8], p[9],
		    dport, opcode, token, size, hlen);
		for (unsigned i = hlen; i + 4 <= len; i += 4) {
			uint32_t w;
			memcpy(&w, p + i, 4);
			printf(" %08x", w);
		}
		if (opcode == 0x000110e8u && len >= hlen + 8) {
			uint32_t r[2];
			memcpy(r, p + hlen, 8);
			printf("  [result of %#x: status %#x]", r[0], r[1]);
		}
		printf("\n");
		o += len;
	}
}

int
main(int argc, char **argv)
{
	uint8_t in[16 + 128], out[16 * 258];
	size_t outlen = sizeof(out), n = 0;
	int a = 1, chan = 0;
	uint16_t port = 0;
	for (; a < argc && argv[a][0] == '-' && argv[a][1] == '-'; a++) {
		if (!strcmp(argv[a], "--apps2")) {
			chan = 1;
		} else if (!strcmp(argv[a], "--port") && a + 1 < argc) {
			port = (uint16_t)strtoul(argv[++a], NULL, 0);
		}
	}
	if (a < argc && !strcmp(argv[a], "-r")) {
		if (sysctlbyname("kern.sweet_audio_apr", out, &outlen, NULL, 0) != 0) {
			perror("kern.sweet_audio_apr");
			return 1;
		}
		dump(out, outlen);
		return 0;
	}
	if (argc - a < 2) {
		fprintf(stderr, "usage: sweetapr [--apps2] [--port N] SVC OPCODE [TOKEN [WAIT_MS [b:N|h:N|w:N ...]]] | sweetapr -r\n");
		return 2;
	}
	uint8_t svc = (uint8_t)strtoul(argv[a], NULL, 0);
	uint32_t opcode = (uint32_t)strtoul(argv[a + 1], NULL, 0);
	uint32_t token = argc - a > 2 ? (uint32_t)strtoul(argv[a + 2], NULL, 0) : 0;
	uint16_t wait = argc - a > 3 ? (uint16_t)strtoul(argv[a + 3], NULL, 0) : 1000;
	in[0] = svc;
	in[1] = (uint8_t)chan;
	memcpy(in + 2, &wait, 2);
	memcpy(in + 4, &port, 2);
	memset(in + 6, 0, 2);
	memcpy(in + 8, &token, 4);
	memcpy(in + 12, &opcode, 4);
	n = 16;
	for (int i = a + 4; i < argc; i++) {
		unsigned long v = strtoul(argv[i] + 2, NULL, 0);
		unsigned w = argv[i][0] == 'b' ? 1 : argv[i][0] == 'h' ? 2 : argv[i][0] == 'w' ? 4 : 0;
		if (!w || argv[i][1] != ':' || n + w > sizeof(in)) {
			fprintf(stderr, "bad field %s\n", argv[i]);
			return 2;
		}
		memcpy(in + n, &v, w);
		n += w;
	}
	if (sysctlbyname("kern.sweet_audio_apr", out, &outlen, in, n) != 0) {
		perror("kern.sweet_audio_apr");
		return 1;
	}
	dump(out, outlen);
	return 0;
}
