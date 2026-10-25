/*
 * Off-mode charging screen, see charge.h. Palette/logo/text helpers are the Bergamota fastboot
 * screen's (fbui.c); everything below the 128 px notch area of the 1080-wide a8r8g8b8 FB.
 */
#include "artdraw.h"
#include "bootui.h"
#include "charge.h"
#include "console.h"
#include "fbui.h"

/* tools/identity/IDENTITY.md: wordmark, CHARGING, a battery in front of a giant white %, the percentage and the state
 * in mono, the portrait centred on the bottom edge. */
#define SUB_Y		350
#define NUM_Y		470
#define BATT_W		400
#define BATT_H		180
#define BATT_X		((FB_W - BATT_W) / 2 - 12)
#define BATT_Y		560
#define BORDER		10
#define RADIUS		34
#define NUB_W		20
#define NUB_H		56
#define IN_X		(BATT_X + BORDER + 8)
#define IN_Y		(BATT_Y + BORDER + 8)
#define IN_W		(BATT_W - 2 * (BORDER + 8))
#define IN_H		(BATT_H - 2 * (BORDER + 8))
#define PCT_Y		790
#define STATUS_Y	1010
#define NOTICE_Y	1066
#define HINT_Y		1112
#define DIAG_Y		1156
#define PORTRAIT_W	700

#define MUTED		0xff5d6638U	/* ink at 55 % over the lime */

#define STR_MAX		96

static int cur_valid;			/* icon/percent/status/bar cache valid */
static unsigned cur_soc;
static enum charge_state cur_state;
static int cur_charging, cur_avail;
static char cur_pct[8], cur_status[STR_MAX], cur_notice[STR_MAX], cur_diag[2][STR_MAX];
static uint32_t cur_notice_fg;

static void copy(char *d, const char *s)
{
	int i = 0;
	while (s && s[i] && i < STR_MAX - 1) {
		d[i] = s[i];
		i++;
	}
	d[i] = 0;
}

static int same(const char *a, const char *b)
{
	while (*a && *a == *b)
		a++, b++;
	return *a == *b;
}

/* ---- tiny string builder ---- */

struct sb {
	char *d;
	unsigned n, max;
};

static void sb_str(struct sb *b, const char *s)
{
	while (*s && b->n + 1 < b->max)
		b->d[b->n++] = *s++;
	b->d[b->n] = 0;
}

static void sb_u(struct sb *b, unsigned v)
{
	char t[12];
	int n = 0;
	do
		t[n++] = '0' + v % 10;
	while ((v /= 10) && n < 12);
	while (n && b->n + 1 < b->max)
		b->d[b->n++] = t[--n];
	b->d[b->n] = 0;
}

/* Repaint a band of the ground, with the part of the giant % that falls in it. */
static void band(int y, int h)
{
	art_ground(0, y, FB_W, h);
	art_image_rows(ART_NUM_PCT, (FB_W - art_image_w(ART_NUM_PCT)) / 2, NUM_Y, ID_WHITE, y, y + h);
}

/* "a | b | c" centred, in one mono size. */
static void parts_line(int y, enum art_font f, uint32_t fg, const char *const *p, int n)
{
	char buf[STR_MAX];
	struct sb b = { buf, 0, sizeof buf };
	buf[0] = 0;
	for (int i = 0; i < n; i++) {
		if (i)
			sb_str(&b, "  |  ");
		sb_str(&b, p[i]);
	}
	art_text_centered(f, y, fg, buf);
}

/* ---- battery: ink outline, paper inside, a fill growing left to right, a bolt while charging ---- */

/* Lightning bolt, polygon in a 20 x 32 grid scaled by BOLT_S, scan-converted with integers. */
#define BOLT_S		4
#define BOLT_N		7
static const int8_t bolt_x[BOLT_N] = { 11, 2, 9, 6, 18, 10, 14 };
static const int8_t bolt_y[BOLT_N] = { 0, 18, 18, 32, 11, 11, 0 };

/* One scanline of the bolt; the part left of fill_x (over the fill) in over_fill, the rest in over_empty. */
static void bolt_row(int py, int x0, int y0, int fill_x, uint32_t over_fill, uint32_t over_empty)
{
	int xs[BOLT_N], n = 0;

	for (int i = 0; i < BOLT_N; i++) {
		int j = (i + 1) % BOLT_N;
		int xa = bolt_x[i] * BOLT_S, ya = bolt_y[i] * BOLT_S, xb = bolt_x[j] * BOLT_S, yb = bolt_y[j] * BOLT_S;
		if (ya == yb)
			continue;
		if (ya > yb) {
			int t = xa; xa = xb; xb = t;
			t = ya; ya = yb; yb = t;
		}
		if (2 * ya <= 2 * py + 1 && 2 * py + 1 < 2 * yb)
			xs[n++] = xa + (xb - xa) * (2 * py + 1 - 2 * ya) / (2 * (yb - ya));
	}
	for (int i = 1; i < n; i++)
		for (int j = i; j > 0 && xs[j - 1] > xs[j]; j--) {
			int t = xs[j]; xs[j] = xs[j - 1]; xs[j - 1] = t;
		}
	for (int i = 0; i + 1 < n; i += 2) {
		int a = x0 + xs[i], b = x0 + xs[i + 1];
		if (a < fill_x)
			con_rect(a, y0 + py, (b < fill_x ? b : fill_x) - a, 1, over_fill);
		if (b > fill_x)
			con_rect(a > fill_x ? a : fill_x, y0 + py, b - (a > fill_x ? a : fill_x), 1, over_empty);
	}
}

static void draw_battery(int avail, unsigned soc, int charging)
{
	uint32_t fill = soc <= 15 && !charging ? ID_ALERT : ID_LEAF;

	art_rrect(BATT_X + BATT_W - 2, BATT_Y + (BATT_H - NUB_H) / 2, NUB_W + 2, NUB_H, 8, ID_INK);
	art_rrect(BATT_X, BATT_Y, BATT_W, BATT_H, RADIUS, ID_INK);
	art_rrect(BATT_X + BORDER, BATT_Y + BORDER, BATT_W - 2 * BORDER, BATT_H - 2 * BORDER, RADIUS - BORDER, ID_PAPER);
	int fw = 0;
	if (avail) {
		fw = IN_W * (int)soc / 100;
		if (soc && fw < 2 * 12)
			fw = 2 * 12;
		if (fw)
			art_rrect(IN_X, IN_Y, fw, IN_H, 12, fill);
	}
	if (!avail) {
		art_text(ART_MONO150, IN_X + (IN_W - art_text_w(ART_MONO150, "%")) / 2, IN_Y + (IN_H - art_text_h(ART_MONO150)) / 2, MUTED, "%");
	} else if (charging) {
		int bw = 20 * BOLT_S, bh = 32 * BOLT_S;
		int bx = IN_X + (IN_W - bw) / 2, by = IN_Y + (IN_H - bh) / 2;
		for (int py = 0; py < bh; py++)
			bolt_row(py, bx, by, IN_X + fw, ID_PAPER, ID_INK);
	}
}

/* ---- public ---- */

void charge_ui_init(void)
{
	const char *foot[2];	/* filled at run time: a static pointer table would need ABS64 relocations */
	int pw = PORTRAIT_W;

	foot[0] = "Vol - : fastboot";
	foot[1] = "hold Power : start iOS";
	art_ground(0, 0, FB_W, FB_H);
	art_image(ART_NUM_PCT, (FB_W - art_image_w(ART_NUM_PCT)) / 2, NUM_Y, ID_WHITE);
	art_portrait((FB_W - pw) / 2, FB_H - art_portrait_h(pw), pw);
	art_image(ART_WORDMARK, (FB_W - art_image_w(ART_WORDMARK)) / 2, 205, ID_INK);
	art_text_centered(ART_MONO30, SUB_Y, ID_INK, "CHARGING");
	parts_line(HINT_Y, ART_MONO22, ID_INK, foot, 2);
	cur_valid = 0;
	cur_pct[0] = cur_status[0] = cur_notice[0] = 0;
	cur_diag[0][0] = cur_diag[1][0] = 0;
	con_set_bg(BG_BOOT);
	con_set_scale(2);
	con_window(0, -1);	/* con_* log lines are recorded, not drawn */
}

/* The static picture of the logo partition's charging slot (ABL shows it before Enxerto runs): the scene and an empty
 * battery with the bolt, no numbers. */
void charge_ui_splash(void)
{
	charge_ui_init();
	band(HINT_Y, art_text_h(ART_MONO22));	/* the key hints are Enxerto's, not ABL's */
	draw_battery(1, 0, 1);
}

void charge_ui_update(const struct charge_view *v)
{
	char pct[8], status[STR_MAX], volt[12], amp[12];
	struct sb bp = { pct, 0, sizeof pct }, bs = { status, 0, sizeof status };
	struct sb bv = { volt, 0, sizeof volt }, ba = { amp, 0, sizeof amp };
	const char *parts[3];
	int np = 0, avail = v->state != CHARGE_UNAVAILABLE;
	unsigned soc = v->soc > 100 ? 100 : v->soc;
	int charging = v->state == CHARGE_CHARGING;
	uint32_t pcol = ID_INK;

	pct[0] = status[0] = volt[0] = amp[0] = 0;
	if (avail) {
		sb_u(&bp, soc);
		sb_str(&bp, "%");
		sb_u(&bv, v->mv / 1000);
		sb_str(&bv, ".");
		sb_u(&bv, (v->mv % 1000) / 100);
		sb_u(&bv, (v->mv % 1000) / 10 % 10);
		sb_str(&bv, " V");
		unsigned ma = (unsigned)(v->ma < 0 ? -v->ma : v->ma);
		unsigned dec = (ma + 50) / 100;
		sb_u(&ba, dec / 10);
		sb_str(&ba, ".");
		sb_u(&ba, dec % 10);
		sb_str(&ba, " A");
		parts[np++] = v->state == CHARGE_CHARGING ? "Charging" : v->state == CHARGE_FULL ? "Charged" : "Not charging";
		if (v->mv)
			parts[np++] = volt;
		if (v->ma_valid && charging)
			parts[np++] = amp;
		if (soc <= 15 && !charging)
			pcol = ID_ALERT;
	} else {
		sb_str(&bp, "%");
		parts[np++] = "Battery info unavailable";
		pcol = MUTED;
	}
	for (int i = 0; i < np; i++) {
		if (i)
			sb_str(&bs, "|");
		sb_str(&bs, parts[i]);
	}

	if (!cur_valid || soc != cur_soc || charging != cur_charging || avail != cur_avail)
		draw_battery(avail, soc, charging);
	if (!cur_valid || !same(pct, cur_pct) || v->state != cur_state) {
		band(PCT_Y, art_text_h(ART_MONO150));
		art_text_centered(ART_MONO150, PCT_Y, pcol, avail ? pct : "");
		copy(cur_pct, pct);
	}
	if (!cur_valid || !same(status, cur_status)) {
		band(STATUS_Y, art_text_h(ART_MONO30));
		parts_line(STATUS_Y, ART_MONO30, ID_INK, parts, np);
		copy(cur_status, status);
	}
	cur_soc = soc;
	cur_state = v->state;
	cur_charging = charging;
	cur_avail = avail;
	cur_valid = 1;
}

void charge_ui_notice(const char *s, uint32_t fg)
{
	if (!s)
		s = "";
	if (same(cur_notice, s) && fg == cur_notice_fg)
		return;
	cur_notice_fg = fg;
	band(NOTICE_Y, art_text_h(ART_MONO22));
	if (*s)
		art_text_centered(ART_MONO22, NOTICE_Y, fg == FBUI_OK_COLOR ? ID_LEAF : fg, s);
	copy(cur_notice, s);
}

void charge_ui_diag(const char *l0, const char *l1)
{
	const char *l[2] = { l0, l1 };

	for (int i = 0; i < 2; i++) {
		const char *s = l[i] ? l[i] : "";
		if (same(cur_diag[i], s))
			continue;
		band(DIAG_Y + i * 18, 16);
		con_text((FB_W - con_text_w(s, 1, 0)) / 2, DIAG_Y + i * 18, 1, 0, MUTED, s);
		copy(cur_diag[i], s);
	}
}

void charge_view_from(struct charge_view *v, const struct pmic_batt *b)
{
	v->soc = b->soc;
	v->mv = b->mv;
	v->ma = b->ma;
	v->ma_valid = b->ma_valid;
	if (!b->valid)
		v->state = CHARGE_UNAVAILABLE;
	else if (b->chg == PMIC_CHG_CHARGING)
		v->state = CHARGE_CHARGING;
	else if (b->chg == PMIC_CHG_FULL || (b->usb_present && b->soc >= 100))
		v->state = CHARGE_FULL;
	else
		v->state = CHARGE_NOT_CHARGING;
}
