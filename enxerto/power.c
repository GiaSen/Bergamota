/*
 * Power off and low-power waits, see power.h.
 * No static pointer tables (build.sh rejects ABS64 relocations); MMU off or on.
 */
#include "power.h"
#include "board.h"
#include "charger.h"
#include "fdt.h"
#include "pmic.h"
#include "ufs.h"

#define PSCI_SYSTEM_OFF		0x84000008UL
#define EVNT_BIT		13	/* CNTVCT bit whose 0 -> 1 edge is an event: every 2^14 ticks */

static int idle_ok;
static int off_code;	/* a code, not a pointer: no absolute relocation (build.sh) */

static uint64_t ticks(void)
{
	uint64_t t;
	__asm__ volatile("isb; mrs %0, cntpct_el0" : "=r"(t) : : "memory");
	return t;
}

static uint64_t freq(void)
{
	uint64_t f;
	__asm__ volatile("mrs %0, cntfrq_el0" : "=r"(f));
	return f;
}

static void spin_ms(unsigned ms)
{
	uint64_t end = ticks() + freq() / 1000 * ms;
	while (ticks() < end)
		;
}

void power_idle_init(uintptr_t dtb)
{
	const char *v = dtb ? fdt_cmdline_opt(dtb, "bergamota.idle=") : 0;
	uint64_t k, t0, dt, f = freq();

	idle_ok = 0;
	if (v && *v == '0')
		return;
	if (f < 1000000)
		return;		/* no sane counter frequency: keep spinning */
	__asm__ volatile("mrs %0, cntkctl_el1" : "=r"(k));
	k &= ~(0xfUL << 4);		/* EVNTI */
	k &= ~(1UL << 3);		/* EVNTDIR: 0 -> 1 */
	k |= ((uint64_t)EVNT_BIT << 4) | (1UL << 2);	/* EVNTEN */
	__asm__ volatile("msr cntkctl_el1, %0; isb" : : "r"(k) : "memory");
	/* eight events are 6.8 ms at 19.2 MHz: accept 2..40 ms, anything else is not the stream we asked for */
	t0 = ticks();
	for (int i = 0; i < 8; i++)
		__asm__ volatile("wfe" ::: "memory");
	dt = (ticks() - t0) * 1000 / f;
	idle_ok = dt >= 2 && dt <= 40;
}

void power_storage_idle(int on)
{
	(void)ufs_auto_hibernate(on ? POWER_UFS_IDLE_MS : 0);	/* refused while a request is outstanding: then as it was */
}

int power_idle_ok(void)
{
	return idle_ok;
}

void power_nap(void)
{
	if (idle_ok)
		__asm__ volatile("wfe" ::: "memory");
}

void power_wait_ms(unsigned ms)
{
	if (!idle_ok) {
		spin_ms(ms);
		return;
	}
	uint64_t end = ticks() + freq() / 1000 * ms;
	while (ticks() < end)
		__asm__ volatile("wfe" ::: "memory");
}

const char *power_off_why(void)
{
	if (off_code == 1)
		return "PS_HOLD did not power off";
	if (off_code == 2)
		return "PMIC shutdown type not set";
	return "";
}

int power_off(void)
{
	int old = -1;
	register uint64_t x0 __asm__("x0");

	/* off-state charging is the PMIC's own: give it ABL's limits back, not our fast-charge ones */
	enxerto_charger_handoff();
	(void)pmic_init();
	if (pmic_pshold_type(PMIC_PSHOLD_SHUTDOWN, &old) == 0) {
		__asm__ volatile("dsb sy" ::: "memory");
		*(volatile uint32_t *)PSHOLD = 0;
		__asm__ volatile("dsb sy" ::: "memory");
		spin_ms(2000);
		off_code = 1;
	} else {
		/* PS_HOLD left alone: with the action still "warm reset" it would restart the phone */
		off_code = 2;
	}
	x0 = PSCI_SYSTEM_OFF;
	__asm__ volatile("smc #0" : "+r"(x0) : : "x1", "x2", "x3", "x4", "x5", "x6", "x7", "x8", "x9", "x10", "x11", "x12",
			 "x13", "x14", "x15", "x16", "x17", "memory");
	spin_ms(2000);
	if (old >= 0 && old != PMIC_PSHOLD_SHUTDOWN)
		(void)pmic_pshold_type((unsigned)old, 0);
	return -1;
}
