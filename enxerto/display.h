#pragma once
/*
 * The panel ABL left on (display.c). On a command-mode panel (board.h FB_CMD_MODE, the Mi 8) display_init()
 * makes the MDP refresh the panel from the framebuffer by itself, so everything drawn into it shows up as on a
 * video-mode panel. Elsewhere it does nothing.
 */
#include <stdint.h>

/* Call before anything is drawn. Reads (and on a command-mode board, writes) MDP registers only. */
void display_init(void);
/* Line i (from 0) of the MDP state report into buf, NUL terminated; returns 0 when there is no line i. */
int display_report(unsigned i, char *buf, unsigned n);
