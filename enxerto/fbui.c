/*
 * Bergamota fastboot screen, see fbui.h. Style follows bootui.c (same palette, logo helper).
 * Layout for a 1080-wide a8r8g8b8 framebuffer, everything below the 128 px notch area.
 */
#include "artdraw.h"
#include "bootui.h"
#include "console.h"
#include "fbui.h"

/* tools/identity/IDENTITY.md: wordmark and a FASTBOOT pill at the top, a paper plate with the state, hints on the
 * ground, the portrait bottom-left in front of the giant numerals. */
#define PILL_Y		350
#define PLATE_X		96
#define PLATE_W		(FB_W - 2 * PLATE_X)
#define PLATE_Y		470
#define PLATE_H		420
#define PLATE_BORDER	4
#define IN_X		(PLATE_X + 44)
#define IN_W		(PLATE_W - 88)
#define STATUS_Y	(PLATE_Y + 40)
#define DETAIL_Y	(STATUS_Y + 52)
#define BAR_Y		(DETAIL_Y + 52)
#define BAR_W		IN_W
#define BAR_H		12
#define BAR_X		IN_X
#define CHG_Y		(BAR_Y + 36)
#define DIAG_Y		(CHG_Y + 48)
#define HINT_Y		(PLATE_Y + PLATE_H + 34)
#define ENTRY_Y		(HINT_Y + 40)
#define LOG_Y		(PLATE_Y + PLATE_H + 24)
#define LOG_ROWS	24
#define PORTRAIT_W	800
#define PORTRAIT_X	(-90)

#define BAR_TRACK	0xffdfdcd3U	/* ink at 8 % over the paper */
#define MUTED		0xff7a7976U	/* ink at 55 % over the paper */
#define MUTED_GROUND	0xff5d6638U	/* ink at 55 % over the lime */

#define STR_MAX		96

static char cur_text[STR_MAX], cur_detail[STR_MAX], cur_diag[3][STR_MAX], cur_chg[STR_MAX];
static int cur_color_set;
static uint32_t cur_fg;
static int bar_px = -1;	/* -1: hidden */
static char entry_txt[48];

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

/* Paper inside the plate, from y for h rows. */
static void plate_clear(int y, int h)
{
	con_rect(PLATE_X + PLATE_BORDER + 2, y, PLATE_W - 2 * (PLATE_BORDER + 2), h, ID_PAPER);
}

/* A line of mono text inside the plate, cut to its width. */
static void plate_text(enum art_font f, int y, uint32_t fg, const char *s)
{
	char buf[STR_MAX];
	int max = IN_W / art_text_w(f, "M"), i = 0;
	for (; s[i] && i < max && i < STR_MAX - 1; i++)
		buf[i] = s[i];
	buf[i] = 0;
	plate_clear(y, art_text_h(f));
	art_text(f, IN_X, y, fg, buf);
}

static void draw_bar(int permille)
{
	if (permille < 0) {
		if (bar_px >= 0)
			plate_clear(BAR_Y, BAR_H);
		bar_px = -1;
		return;
	}
	if (permille > 1000)
		permille = 1000;
	int px = BAR_W * permille / 1000;
	if (px == bar_px)
		return;
	plate_clear(BAR_Y, BAR_H);
	art_rrect(BAR_X, BAR_Y, BAR_W, BAR_H, BAR_H / 2, BAR_TRACK);
	if (px >= BAR_H)
		art_rrect(BAR_X, BAR_Y, px, BAR_H, BAR_H / 2, ID_LEAF);
	bar_px = px;
}

void fbui_init(const char *entry)
{
	enum art_image num = art_ios_numerals();
	bootui_scene(PORTRAIT_X, PORTRAIT_W, FB_W - art_image_w(num) + 40, 110, num);
	/* the FASTBOOT pill */
	int tw = art_text_w(ART_MONO30, "FASTBOOT"), pw = tw + 56, ph = art_text_h(ART_MONO30) + 20;
	art_rrect((FB_W - pw) / 2, PILL_Y, pw, ph, ph / 2, ID_LEAF);
	art_text(ART_MONO30, (FB_W - tw) / 2, PILL_Y + 10, ID_PAPER, "FASTBOOT");
	/* the plate */
	art_rrect(PLATE_X, PLATE_Y, PLATE_W, PLATE_H, 28, ID_INK);
	art_rrect(PLATE_X + PLATE_BORDER, PLATE_Y + PLATE_BORDER, PLATE_W - 2 * PLATE_BORDER, PLATE_H - 2 * PLATE_BORDER,
		  28 - PLATE_BORDER, ID_PAPER);
	art_text_centered(ART_MONO22, HINT_Y, ID_INK, "Hold Power + Volume Down for the bootloader");
	entry_txt[0] = 0;
	if (entry) {
		int i = 0;
		for (const char *p = "entered via: "; *p; p++)
			entry_txt[i++] = *p;
		for (; *entry && i < (int)sizeof(entry_txt) - 1; entry++)
			entry_txt[i++] = *entry;
		entry_txt[i] = 0;
		art_text_centered(ART_MONO22, ENTRY_Y, MUTED_GROUND, entry_txt);
	}
	cur_text[0] = cur_detail[0] = 0;
	cur_diag[0][0] = cur_diag[1][0] = cur_diag[2][0] = cur_chg[0] = 0;
	cur_color_set = 0;
	bar_px = -1;
	con_set_bg(BG_BOOT);
	con_set_scale(2);
	con_window(0, -1);	/* log lines are recorded, not drawn */
}

void fbui_status(const char *text, const char *detail, int permille, uint32_t fg)
{
	if (!cur_color_set || fg != cur_fg || !same(cur_text, text)) {
		plate_text(ART_MONO30, STATUS_Y, fg, text);
		copy(cur_text, text);
		cur_fg = fg;
		cur_color_set = 1;
	}
	if (!detail)
		detail = "";
	if (!same(cur_detail, detail)) {
		plate_text(ART_MONO22, DETAIL_Y, ID_LEAF, detail);
		copy(cur_detail, detail);
	}
	draw_bar(permille);
}

void fbui_charge(const char *s)
{
	if (!s)
		s = "";
	if (same(cur_chg, s))
		return;
	plate_text(ART_MONO22, CHG_Y, MUTED, s);
	copy(cur_chg, s);
}

void fbui_diag(const char *l0, const char *l1, const char *l2)
{
	const char *l[3] = { l0, l1, l2 };
	for (int i = 0; i < 3; i++) {
		const char *s = l[i] ? l[i] : "";
		if (same(cur_diag[i], s))
			continue;
		plate_clear(DIAG_Y + i * 18, 16);
		con_text(IN_X, DIAG_Y + i * 18, 1, 0, MUTED, s);
		copy(cur_diag[i], s);
	}
}

void fbui_error(const char *why, const char *detail)
{
	char buf[STR_MAX];
	int i = 0;
	for (const char *p = "BOOT FAILED: "; *p; p++)
		buf[i++] = *p;
	for (; *why && i < STR_MAX - 1; why++)
		buf[i++] = *why;
	buf[i] = 0;
	fbui_status(buf, detail, FBUI_NOBAR, FBUI_ERR_COLOR);
	/* the log tail on a full-width paper band over the portrait, ink rules above and below (console.c draws its
	 * rows across the whole width, on BG_BOOT: the paper) */
	con_rect(0, LOG_Y - 20, FB_W, LOG_ROWS * 32 + 40, ID_PAPER);
	con_rect(0, LOG_Y - 24, FB_W, 4, ID_INK);
	con_rect(0, LOG_Y + LOG_ROWS * 32 + 20, FB_W, 4, ID_INK);
	con_set_scale(2);
	con_window(LOG_Y, LOG_ROWS);
	con_replay_tail(LOG_ROWS - 1);
	con_window(0, -1);
}
