/* The identity's drawing primitives, see artdraw.h. */
#include "artdraw.h"
#include "art.h"
#include "console.h"

#ifndef ENXERTO_IOS
#define ENXERTO_IOS	26
#endif

#define GRID		14	/* ground dot pitch, px */
#define DOT_R4		10	/* ground dot radius in quarter pixels (2.5 px) */

static inline uint32_t mix(uint32_t bg, uint32_t fg, unsigned a15)
{
	if (a15 >= 15)
		return fg;
	unsigned r = ((bg >> 16 & 255) * (15 - a15) + (fg >> 16 & 255) * a15) / 15;
	unsigned g = ((bg >> 8 & 255) * (15 - a15) + (fg >> 8 & 255) * a15) / 15;
	unsigned b = ((bg & 255) * (15 - a15) + (fg & 255) * a15) / 15;
	return 0xff000000U | r << 16 | g << 8 | b;
}

static inline volatile uint32_t *px(int x, int y)
{
	return con_fb + y * (FB_STRIDE / 4) + x;
}

/* One GRID x GRID tile of the ground, the dot anti-aliased by 4x4 supersampling. */
static uint32_t tile[GRID * GRID];
static int tile_ready;

static void make_tile(void)
{
	for (int y = 0; y < GRID; y++)
		for (int x = 0; x < GRID; x++) {
			unsigned in = 0;
			for (int sy = 0; sy < 4; sy++)
				for (int sx = 0; sx < 4; sx++) {
					int dx = (x * 4 + sx) * 2 + 1 - GRID * 4, dy = (y * 4 + sy) * 2 + 1 - GRID * 4;	/* eighth px from centre */
					if (dx * dx + dy * dy <= (DOT_R4 * 2) * (DOT_R4 * 2))
						in++;
				}
			tile[y * GRID + x] = mix(ID_LIME, ID_DOT, in * 15 / 16);
		}
	tile_ready = 1;
}

void art_ground(int x, int y, int w, int h)
{
	if (!tile_ready)
		make_tile();
	if (x < 0) { w += x; x = 0; }
	if (y < 0) { h += y; y = 0; }
	if (x + w > FB_W) w = FB_W - x;
	if (y + h > FB_H) h = FB_H - y;
	for (int j = y; j < y + h; j++) {
		const uint32_t *row = tile + (j % GRID) * GRID;
		volatile uint32_t *d = px(x, j);
		int tx = x % GRID;
		for (int i = 0; i < w; i++) {
			d[i] = row[tx];
			if (++tx == GRID)
				tx = 0;
		}
	}
}

/* Rows of (count-1) << 4 | alpha4 bytes, blended over what is on screen. */
static void blit_rle4(const unsigned char *p, int w, int h, int x0, int y0, uint32_t color, int clip0, int clip1)
{
	for (int y = 0; y < h; y++) {
		int x = 0, sy = y0 + y;
		while (x < w) {
			unsigned b = *p++, n = (b >> 4) + 1, a = b & 15;
			if (a && sy >= clip0 && sy < clip1 && sy >= 0 && sy < FB_H)
				for (unsigned k = 0; k < n; k++) {
					int sx = x0 + x + (int)k;
					if (sx >= 0 && sx < FB_W) {
						volatile uint32_t *d = px(sx, sy);
						*d = mix(*d, color, a);
					}
				}
			x += (int)n;
		}
	}
}

/* Looked up with switches, not a table of pointers: the image runs where ABL loads it with no relocation pass, and a
 * static pointer table would need ABS64 relocations (build.sh refuses them). */
struct img { const unsigned char *rle; int w, h; };

static struct img image_of(enum art_image im)
{
	struct img r;	/* if/else, not a switch: gcc turns that into a table of pointers too */
	if (im == ART_NUM_26) {
		r.rle = art_num_26; r.w = ART_NUM_26_W; r.h = ART_NUM_26_H;
	} else if (im == ART_NUM_18) {
		r.rle = art_num_18; r.w = ART_NUM_18_W; r.h = ART_NUM_18_H;
	} else if (im == ART_NUM_PCT) {
		r.rle = art_num_pct; r.w = ART_NUM_PCT_W; r.h = ART_NUM_PCT_H;
	} else {
		r.rle = art_wordmark; r.w = ART_WORDMARK_W; r.h = ART_WORDMARK_H;
	}
	return r;
}

void art_image(enum art_image im, int x, int y, uint32_t color)
{
	struct img i = image_of(im);
	blit_rle4(i.rle, i.w, i.h, x, y, color, 0, FB_H);
}

void art_image_rows(enum art_image im, int x, int y, uint32_t color, int row0, int row1)
{
	struct img i = image_of(im);
	blit_rle4(i.rle, i.w, i.h, x, y, color, row0, row1);
}

int art_image_w(enum art_image im) { return image_of(im).w; }
int art_image_h(enum art_image im) { return image_of(im).h; }

enum art_image art_ios_numerals(void)
{
	return ENXERTO_IOS == 18 ? ART_NUM_18 : ART_NUM_26;
}

int art_portrait_h(int w)
{
	return w * ART_NEWTON_ROWS / ART_NEWTON_COLS;
}

/* Round dots again at this size: a pixel inks when its spot threshold is below the cell's density. */
void art_portrait(int x0, int y0, int w)
{
	int h = art_portrait_h(w);
	uint32_t step = ((uint32_t)ART_NEWTON_COLS << 16) / (uint32_t)w;	/* cells per pixel, 16.16 */
	for (int y = 0; y < h; y++) {
		int sy = y0 + y;
		if (sy < 0 || sy >= FB_H)
			continue;
		uint32_t cyf = (uint32_t)y * step;
		int row = cyf >> 16, fy = (cyf >> 12) & 15;
		if (row >= ART_NEWTON_ROWS)
			break;
		int mrow = (int)((cyf >> 15));
		const unsigned char *mrow_p = art_newton_mask + mrow * ((ART_NEWTON_MCOLS + 7) / 8);
		const unsigned char *cells = art_newton + row * ART_NEWTON_COLS;
		const unsigned char *spot = art_spot16 + fy * 16;
		volatile uint32_t *d = px(0, sy);
		for (int x = 0; x < w; x++) {
			int sx = x0 + x;
			if (sx < 0 || sx >= FB_W)
				continue;
			uint32_t cxf = (uint32_t)x * step;
			int col = cxf >> 16, mcol = cxf >> 15;
			if (col >= ART_NEWTON_COLS)
				break;
			if (!(mrow_p[mcol >> 3] >> (mcol & 7) & 1))
				continue;
			d[sx] = spot[(cxf >> 12) & 15] < cells[col] ? ID_INK : ID_PAPER;
		}
	}
}

struct fnt { const unsigned char *g; const char *chars; int w, h; };

static struct fnt font_of(enum art_font f)
{
	struct fnt r;
	if (f == ART_MONO22) {
		r.g = art_mono22; r.chars = art_mono22_chars; r.w = ART_MONO22_W; r.h = ART_MONO22_H;
	} else if (f == ART_MONO150) {
		r.g = art_mono150; r.chars = art_mono150_chars; r.w = ART_MONO150_W; r.h = ART_MONO150_H;
	} else {
		r.g = art_mono30; r.chars = art_mono30_chars; r.w = ART_MONO30_W; r.h = ART_MONO30_H;
	}
	return r;
}

static int glyph_index(const struct fnt *f, char c)
{
	for (int i = 0; f->chars[i]; i++)
		if (f->chars[i] == c)
			return i;
	return -1;
}

int art_text_w(enum art_font f, const char *s)
{
	int n = 0;
	while (*s++)
		n++;
	return n * font_of(f).w;
}

int art_text_h(enum art_font f)
{
	return font_of(f).h;
}

void art_text(enum art_font f, int x, int y, uint32_t color, const char *s)
{
	struct fnt ft = font_of(f);
	int gw = ft.w, gh = ft.h, bytes = (gw * gh + 1) / 2;
	for (; *s; s++, x += gw) {
		int gi = glyph_index(&ft, *s);
		if (gi < 0 || *s == ' ')
			continue;
		const unsigned char *g = ft.g + gi * bytes;
		for (int yy = 0; yy < gh; yy++) {
			int sy = y + yy;
			if (sy < 0 || sy >= FB_H)
				continue;
			for (int xx = 0; xx < gw; xx++) {
				int i = yy * gw + xx, sx = x + xx;
				unsigned a = (g[i >> 1] >> ((i & 1) * 4)) & 15;
				if (a && sx >= 0 && sx < FB_W) {
					volatile uint32_t *d = px(sx, sy);
					*d = mix(*d, color, a);
				}
			}
		}
	}
}

void art_text_centered(enum art_font f, int y, uint32_t color, const char *s)
{
	art_text(f, (FB_W - art_text_w(f, s)) / 2, y, color, s);
}

void art_rrect(int x, int y, int w, int h, int r, uint32_t color)
{
	for (int j = 0; j < h; j++) {
		int sy = y + j;
		if (sy < 0 || sy >= FB_H)
			continue;
		int dy = j < r ? r - j : (j >= h - r ? j - (h - r - 1) : 0);
		for (int i = 0; i < w; i++) {
			int sx = x + i;
			if (sx < 0 || sx >= FB_W)
				continue;
			int dx = i < r ? r - i : (i >= w - r ? i - (w - r - 1) : 0);
			volatile uint32_t *d = px(sx, sy);
			if (!dx || !dy) {
				*d = color;
				continue;
			}
			/* corner: 4x4 supersampled coverage of the quarter circle */
			unsigned in = 0;
			for (int sj = 0; sj < 4; sj++)
				for (int si = 0; si < 4; si++) {
					int ex = dx * 8 - si * 2 - 1, ey = dy * 8 - sj * 2 - 1;
					if (ex * ex + ey * ey <= r * r * 64)
						in++;
				}
			if (in)
				*d = mix(*d, color, in * 15 / 16);
		}
	}
}
