#pragma once
#include <stdint.h>

/*
 * Bergamota fastboot screen (tools/identity/IDENTITY.md): wordmark, a leaf green FASTBOOT pill, a paper plate with the
 * status line, detail, progress bar, charge line and muted diagnostics, hints on the ground, and the Newton portrait
 * in front of the giant iOS numerals. Only the plate's lines are redrawn after fbui_init; all stores are aligned
 * 32-bit (MMU off safe). con_* log lines are muted (but recorded) while it is up and shown on a paper band on
 * fbui_error.
 */
#define FBUI_NOBAR	(-1)

#define FBUI_OK_COLOR	0xff161616U	/* ink (ID_INK) */
#define FBUI_ERR_COLOR	0xffb3261eU	/* ID_ALERT */

/* Full redraw. `entry` = why fastboot was entered (shown small in the footer), may be 0. */
void fbui_init(const char *entry);
/* Big status line (colour fg), small detail line, bar at permille (0..1000) or FBUI_NOBAR. Redraws only changes. */
void fbui_status(const char *text, const char *detail, int permille, uint32_t fg);
/* One muted line above the footer (the charger state); "" or 0 hides it. Redraws only changes. */
void fbui_charge(const char *s);
/* Muted diagnostic lines at the very bottom; all 0 hides them. */
void fbui_diag(const char *l0, const char *l1, const char *l2);
/* Error: red status, bar hidden, the recorded console log replayed small underneath. */
void fbui_error(const char *why, const char *detail);
