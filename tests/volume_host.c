/* SPDX-License-Identifier: MIT
 *
 * The master volume's gain on the PC (firmware/include/tinynes.h): unity at
 * 100 percent, so the default leaves every sample bit for bit as it was;
 * silence at 0 and when muted; a gain that never falls as the slider rises;
 * and no sample that can leave the 16-bit range or change sign.
 */
#include <stdio.h>

#include "tinynes.h"

/* tinynes.h declares the host's register model; nothing here touches one. */
volatile uint32_t *tn_host_reg(uint32_t offset)
{
	static volatile uint32_t reg;
	(void)offset;
	return &reg;
}

static int checks, failed;

static void check(int ok, const char *what)
{
	checks++;
	if (!ok)
		failed++;
	printf("%s  %s\n", ok ? "ok  " : "FAIL", what);
}

int main(void)
{
	int unity = 1, bounded = 1, monotonic = 1;
	for (int32_t s = -32768; s <= 32767; s++)
		if (tn_volume_apply(s, tn_volume_gain(100, 0)) != s)
			unity = 0;
	check(tn_volume_gain(100, 0) == TN_VOLUME_UNITY, "100 percent is unity gain");
	check(unity, "100 percent leaves all 65,536 sample values unchanged");
	check(tn_volume_gain(0, 0) == 0, "0 percent is silent");
	check(tn_volume_gain(100, 1) == 0 && tn_volume_gain(50, 1) == 0,
	      "muted is silent at any volume");
	check(tn_volume_gain(150, 0) == TN_VOLUME_UNITY, "above 100 is unity, never more");
	check(tn_volume_gain(50, 0) == 64, "50 percent is a quarter, -12 dB");
	check(tn_volume_gain(5, 0) == 1, "5 percent is still heard");
	for (unsigned p = 0; p < 100; p += 5)
		if (tn_volume_gain(p + 5, 0) <= tn_volume_gain(p, 0))
			monotonic = 0;
	check(monotonic, "every 5 percent step is louder than the last");
	for (unsigned p = 0; p <= 100; p += 5) {
		const uint32_t g = tn_volume_gain(p, 0);
		const int32_t hi = tn_volume_apply(32767, g), lo = tn_volume_apply(-32768, g);
		if (hi < 0 || hi > 32767 || lo > 0 || lo < -32768)
			bounded = 0;
	}
	check(bounded, "no step leaves the 16-bit range or flips a sign");
	for (unsigned p = 0; p <= 100; p += 25)
		printf("      %3u%%  gain %3u/256\n", p, (unsigned)tn_volume_gain(p, 0));
	printf("%d checks, %d failed\n", checks, failed);
	return failed != 0;
}
