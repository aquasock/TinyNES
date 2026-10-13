// SPDX-License-Identifier: MIT
// Report Wii Classic Controller inputs over the FPGA UART as they change.
#include <stdint.h>
#include <stdio.h>

#include "tinynes.h"

#define TEST_SECONDS 120u

static const struct {
	uint16_t bit;
	const char *name;
} buttons[] = {
	{1u << 15, "ZL"}, {1u << 14, "B"}, {1u << 13, "Y"},
	{1u << 12, "A"}, {1u << 11, "X"}, {1u << 10, "ZR"},
	{1u << 9, "LEFT"}, {1u << 8, "UP"}, {1u << 7, "RIGHT"},
	{1u << 6, "DOWN"}, {1u << 5, "L"}, {1u << 4, "SELECT"},
	{1u << 3, "HOME"}, {1u << 2, "START"}, {1u << 1, "R"},
};

static void report(unsigned pad, uint32_t lo, uint32_t hi)
{
	uint8_t b0 = lo, b1 = lo >> 8, b2 = lo >> 16, b3 = lo >> 24;
	uint8_t b4 = hi, b5 = hi >> 8;
	uint16_t pressed = ~((uint16_t)b5 << 8 | b4);
	unsigned lx = b0 & 63u, ly = b1 & 63u;
	unsigned rx = ((b0 >> 6) << 3) | ((b1 >> 6) << 1) | (b2 >> 7);
	unsigned ry = b2 & 31u;
	unsigned lt = ((b2 >> 5) & 3u) << 3 | (b3 >> 5);
	unsigned rt = b3 & 31u;

	printf("PAD%u LX=%u LY=%u RX=%u RY=%u LT=%u RT=%u BTN=", pad + 1,
	       lx, ly, rx, ry, lt, rt);
	int any = 0;
	for (unsigned i = 0; i < sizeof buttons / sizeof buttons[0]; i++) {
		if (pressed & buttons[i].bit) {
			printf("%s%s", any ? "," : "", buttons[i].name);
			any = 1;
		}
	}
	if (!any)
		printf("none");
	printf("\n");
}

int main(void)
{
	if (TN_PAD_ID != TN_PAD_ID_VALUE) {
		printf("BAD PAD ID=%08lx\n", (unsigned long)TN_PAD_ID);
		return 1;
	}
	if (TN_PAD_CTRL != PAD_QUARTER)
		TN_PAD_CTRL = PAD_QUARTER;
	printf("TinyNES PAD TEST Q=%lu (four buses, PMOD0)\n",
	       (unsigned long)TN_PAD_CTRL);
	uint32_t old_status[4] = {0};
	uint32_t old_reads[4] = {0};
	uint64_t old_data[4] = {0};
	uint32_t seen = 0, changes = 0;
	for (unsigned tick = 0; tick < TEST_SECONDS * 50u; tick++) {
		for (unsigned pad = 0; pad < 4; pad++) {
			uint32_t status = TN_PAD_STATUS(pad);
			uint32_t state = status & (TN_PAD_PRESENT | TN_PAD_CLASSIC);
			if (state != old_status[pad]) {
				uint32_t id0 = TN_PAD_IDENT(pad);
				uint32_t id1 = TN_PAD_DATA2(pad) >> 16;
				printf("PAD%u %s%s ID=%04lx%08lx FAIL=%lu\n", pad + 1,
				       state & TN_PAD_PRESENT ? "connected" : "absent",
				       state & TN_PAD_CLASSIC ? " classic" : "",
				       (unsigned long)id1, (unsigned long)id0,
				       (unsigned long)TN_PAD_FAILS(status));
				old_status[pad] = state;
				old_reads[pad] = 0;
			}
			if (state != (TN_PAD_PRESENT | TN_PAD_CLASSIC) ||
			    TN_PAD_READS(status) == old_reads[pad])
				continue;
			seen |= 1u << pad;
			uint32_t lo = TN_PAD_DATA(pad);
			uint32_t hi = TN_PAD_DATA2(pad) & 0xffffu;
			uint64_t sample = (uint64_t)hi << 32 | lo;
			old_reads[pad] = TN_PAD_READS(status);
			if (sample != old_data[pad]) {
				report(pad, lo, hi);
				old_data[pad] = sample;
				changes++;
			}
		}
		if (tick % 250u == 249u)
			printf("PAD STATUS %08lx %08lx %08lx %08lx\n",
			       (unsigned long)TN_PAD_STATUS(0),
			       (unsigned long)TN_PAD_STATUS(1),
			       (unsigned long)TN_PAD_STATUS(2),
			       (unsigned long)TN_PAD_STATUS(3));
		uint32_t start = tn_cycles();
		while ((uint32_t)(tn_cycles() - start) < TN_CORE_HZ / 50u)
			;
	}
	if (!seen || !changes) {
		printf("BAD PAD NONE SEEN=%lx CHANGES=%lu\n",
		       (unsigned long)seen, (unsigned long)changes);
		return 1;
	}
	printf("TinyNES PAD OK SEEN=%lx CHANGES=%lu\n",
	       (unsigned long)seen, (unsigned long)changes);
	return 0;
}
