/*
 * Command-mode panel refresh, see display.h.
 *
 * The Mi 8's Samsung EA8074 is a DSI command-mode panel (live DT: qcom,mdss-dsi-panel-type = dsi_cmd_mode, TE on
 * gpio10). ABL leaves the MDP set up to read our framebuffer (cont_splash), but in command mode the MDP sends a
 * frame into the panel's own RAM only when the CTL is kicked with CTL_START, so nothing Enxerto draws would ever
 * reach the screen. The ping-pong block can kick itself instead: autorefresh (PP_AUTOREFRESH_CONFIG bit 31, frame
 * count in [15:0]) sends a new frame every <count> TE pulses. With count 1 and one CTL_START to get it going the
 * panel behaves like a video-mode one: Enxerto's drawing (and later xnu's framebuffer, which inherits the setting)
 * shows up within a 60 Hz frame. Downstream does the same: _sde_encoder_phys_cmd_config_autorefresh(), then
 * sde_hw_ctl_trigger_start().
 *
 * Which CTL and ping-pong ABL used is read back, not assumed: the CTL whose CTL_TOP has the command-mode bit (17)
 * and an interface, and the ping-pong whose tear check is on (ABL enables it for the TE pin). If no tear check is
 * on, the ping-pong of the first layer mixer the CTL blends into (LM0-2 -> PP0-2, LM5 -> PP3: sdm845 has no LM3/4).
 * Nothing is written when there is no command-mode CTL. `fastboot oem display` prints what was found (bergamota.c).
 *
 * Offsets: MDP at 0x0ae00000, live DT qcom,sde-ctl-off / qcom,sde-pp-off / qcom,sde-sspp-off. Register names and
 * bits: downstream sde_hw_ctl.c, sde_hw_pingpong.c, sde_hw_sspp.c (LineageOS android_kernel_xiaomi_sdm845).
 */
#include "display.h"
#include "board.h"
#include "console.h"

struct ln {
	char *p;
	unsigned n, len;
};

static void ln_str(struct ln *l, const char *s)
{
	while (*s && l->len + 1 < l->n)
		l->p[l->len++] = *s++;
	l->p[l->len] = 0;
}

#ifdef FB_CMD_MODE

static void ln_hex(struct ln *l, uint32_t v, int digits)
{
	for (int s = (digits - 1) * 4; s >= 0 && l->len + 1 < l->n; s -= 4)
		l->p[l->len++] = "0123456789abcdef"[(v >> s) & 15];
	l->p[l->len] = 0;
}

static void ln_u(struct ln *l, uint32_t v)
{
	char t[10];
	int k = 0;
	do
		t[k++] = '0' + v % 10;
	while ((v /= 10) && k < 10);
	while (k && l->len + 1 < l->n)
		l->p[l->len++] = t[--k];
	l->p[l->len] = 0;
}

static inline uint32_t rd32(uintptr_t a) { return *(volatile uint32_t *)a; }
static inline void wr32(uintptr_t a, uint32_t v) { *(volatile uint32_t *)a = v; }

#define MDP_BASE		0x0ae00000UL
#define NR_CTL			5
#define NR_PP			4	/* PP4 (0x73000) is the DSC slave */
#define NR_SSPP			8	/* vig0-3, dma0-3 */
#define MDP_CTL(i)		(MDP_BASE + 0x2000UL + (uintptr_t)(i) * 0x200UL)
#define MDP_PP(i)		(MDP_BASE + 0x71000UL + (uintptr_t)(i) * 0x800UL)
#define MDP_SSPP(i)		(MDP_BASE + ((i) < 4 ? 0x5000UL + (uintptr_t)(i) * 0x2000UL : \
					     0x25000UL + (uintptr_t)((i) - 4) * 0x2000UL))

#define CTL_LAYER(lm)		((lm) == 5 ? 0x024u : (unsigned)(lm) * 4u)
#define CTL_LAYER_EXT(lm)	(0x40u + (unsigned)(lm) * 4u)
#define CTL_LAYER_EXT2(lm)	(0x70u + (unsigned)(lm) * 4u)
#define CTL_LAYER_EXT3(lm)	(0xa0u + (unsigned)(lm) * 4u)
#define CTL_TOP			0x014u
#define CTL_FLUSH		0x018u
#define CTL_START		0x01cu
#define CTL_TOP_CMD		(1u << 17)
#define CTL_TOP_INTF(t)		(((t) >> 4) & 0xfu)

#define PP_TEAR_CHECK_EN	0x000u
#define PP_INT_COUNT_VAL	0x014u	/* [31:16] read-pointer (TE) frame count, [15:0] its line */
#define PP_LINE_COUNT		0x02cu	/* [15:0] write-pointer line: moves while a frame is sent */
#define PP_AUTOREFRESH_CONFIG	0x030u
#define PP_AUTOREFRESH_EN	(1u << 31)
#define AUTOREFRESH_FRAMES	1u	/* a frame on every TE */

#define SSPP_SRC_SIZE		0x000u
#define SSPP_SRC0_ADDR		0x014u
#define SSPP_SRC_YSTRIDE0	0x024u
#define SSPP_SRC_FORMAT		0x030u

static struct {
	int ctl, pp, pp_guessed;
	uint32_t top, flush, te, ar_before, ar_after;
	uint32_t frames0, frames1;	/* TE frame count, 100 ms apart */
	uint32_t wr[3];			/* write-pointer line, 4 ms apart */
} st = { -1, -1, 0, 0, 0, 0, 0, 0, 0, 0, { 0, 0, 0 } };

static void delay_ms(unsigned ms)
{
	uint64_t t, f, end;
	__asm__ volatile("isb; mrs %0, cntpct_el0" : "=r"(t) : : "memory");
	__asm__ volatile("mrs %0, cntfrq_el0" : "=r"(f));
	end = t + f / 1000 * ms;
	do
		__asm__ volatile("isb; mrs %0, cntpct_el0" : "=r"(t) : : "memory");
	while (t < end);
}

static int find_ctl(void)
{
	for (int i = 0; i < NR_CTL; i++) {
		uint32_t top = rd32(MDP_CTL(i) + CTL_TOP);
		if ((top & CTL_TOP_CMD) && CTL_TOP_INTF(top))
			return i;
	}
	return -1;
}

static int find_pp(uintptr_t ctl, int *guessed)
{
	*guessed = 0;
	for (int i = 0; i < NR_PP; i++)
		if (rd32(MDP_PP(i) + PP_TEAR_CHECK_EN) & 1)
			return i;
	*guessed = 1;
	for (int lm = 0; lm <= 5; lm++) {
		if (lm == 3 || lm == 4)
			continue;
		if (rd32(ctl + CTL_LAYER(lm)) | rd32(ctl + CTL_LAYER_EXT(lm)) |
		    rd32(ctl + CTL_LAYER_EXT2(lm)) | rd32(ctl + CTL_LAYER_EXT3(lm)))
			return lm == 5 ? 3 : lm;
	}
	return -1;
}

void display_init(void)
{
	st.ctl = find_ctl();
	if (st.ctl < 0) {
		con_str("DISPLAY", "no command-mode CTL: left alone");
		return;
	}
	uintptr_t ctl = MDP_CTL(st.ctl);
	st.top = rd32(ctl + CTL_TOP);
	st.flush = rd32(ctl + CTL_FLUSH);
	st.pp = find_pp(ctl, &st.pp_guessed);
	if (st.pp < 0) {
		con_str("DISPLAY", "no ping-pong for the CTL: left alone");
		return;
	}
	uintptr_t pp = MDP_PP(st.pp);
	st.te = rd32(pp + PP_TEAR_CHECK_EN);
	st.ar_before = rd32(pp + PP_AUTOREFRESH_CONFIG);
	if (!(st.ar_before & PP_AUTOREFRESH_EN)) {
		wr32(pp + PP_AUTOREFRESH_CONFIG, PP_AUTOREFRESH_EN | AUTOREFRESH_FRAMES);
		__asm__ volatile("dsb sy" ::: "memory");
		wr32(ctl + CTL_START, 1);
		__asm__ volatile("dsb sy" ::: "memory");
	}
	st.ar_after = rd32(pp + PP_AUTOREFRESH_CONFIG);
	st.frames0 = rd32(pp + PP_INT_COUNT_VAL) >> 16;
	for (int i = 0; i < 3; i++) {
		st.wr[i] = rd32(pp + PP_LINE_COUNT) & 0xffff;
		delay_ms(4);
	}
	delay_ms(88);
	st.frames1 = rd32(pp + PP_INT_COUNT_VAL) >> 16;
	con_hex2("DISPLAY", "ctl=", (uint32_t)st.ctl, "pp=", (uint32_t)st.pp);
	con_hex2(" autoref", "was=", st.ar_before, "now=", st.ar_after);
}

int display_report(unsigned i, char *buf, unsigned n)
{
	struct ln l = { buf, n, 0 };

	buf[0] = 0;
	if (i == 0) {
		ln_str(&l, "panel cmd mode: ");
		if (st.ctl < 0) {
			ln_str(&l, "no command-mode CTL, left alone");
		} else if (st.pp < 0) {
			ln_str(&l, "ctl"); ln_u(&l, (uint32_t)st.ctl); ln_str(&l, ", no ping-pong, left alone");
		} else {
			ln_str(&l, "ctl"); ln_u(&l, (uint32_t)st.ctl);
			ln_str(&l, " pp"); ln_u(&l, (uint32_t)st.pp);
			ln_str(&l, st.pp_guessed ? " (from mixer, no TE)" : " (tear check on)");
		}
		return 1;
	}
	if (st.ctl < 0)
		return 0;
	if (i == 1) {
		ln_str(&l, "ctl top "); ln_hex(&l, st.top, 8);
		ln_str(&l, " flush "); ln_hex(&l, st.flush, 8);
		return 1;
	}
	if (st.pp >= 0) {
		if (i == 2) {
			ln_str(&l, "autorefresh "); ln_hex(&l, st.ar_before, 8);
			ln_str(&l, " -> "); ln_hex(&l, st.ar_after, 8);
			return 1;
		}
		if (i == 3) {
			ln_str(&l, "te "); ln_hex(&l, st.te, 1);
			ln_str(&l, " frames "); ln_u(&l, st.frames0);
			ln_str(&l, " -> "); ln_u(&l, st.frames1); ln_str(&l, " in 100 ms");
			return 1;
		}
		if (i == 4) {
			ln_str(&l, "write line "); ln_u(&l, st.wr[0]);
			ln_str(&l, " "); ln_u(&l, st.wr[1]);
			ln_str(&l, " "); ln_u(&l, st.wr[2]);
			ln_str(&l, " (4 ms apart)");
			return 1;
		}
	}
	/* then one line per source pipe that has an address: what ABL scans out, and in which format */
	unsigned k = st.pp >= 0 ? 5 : 2;
	for (unsigned p = 0; p < NR_SSPP; p++) {
		uint32_t addr = rd32(MDP_SSPP(p) + SSPP_SRC0_ADDR);
		if (!addr)
			continue;
		if (k++ != i)
			continue;
		ln_str(&l, p < 4 ? "vig" : "dma"); ln_u(&l, p & 3);
		ln_str(&l, " "); ln_hex(&l, addr, 8);
		ln_str(&l, " stride "); ln_u(&l, rd32(MDP_SSPP(p) + SSPP_SRC_YSTRIDE0) & 0xffff);
		uint32_t sz = rd32(MDP_SSPP(p) + SSPP_SRC_SIZE);
		ln_str(&l, " "); ln_u(&l, sz & 0xffff); ln_str(&l, "x"); ln_u(&l, sz >> 16);
		ln_str(&l, " fmt "); ln_hex(&l, rd32(MDP_SSPP(p) + SSPP_SRC_FORMAT), 8);
		return 1;
	}
	return 0;
}

#else

void display_init(void)
{
}

int display_report(unsigned i, char *buf, unsigned n)
{
	struct ln l = { buf, n, 0 };

	buf[0] = 0;
	if (i)
		return 0;
	ln_str(&l, "video-mode panel: nothing to do");
	return 1;
}

#endif
