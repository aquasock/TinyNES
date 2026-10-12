/* SPDX-License-Identifier: MIT */
#include "memtest.h"

#include "tinynes.h"

#define LANE_BYTES 64
static uint8_t shadow[LANE_BYTES];

void tn_expect(struct tn_result *r, uintptr_t addr, uint32_t expected,
	       uint32_t got)
{
	if (expected == got)
		return;
	if (r->failures++ == 0) {
		r->addr = addr;
		r->expected = expected;
		r->got = got;
	}
}

uint32_t tn_pattern(uint32_t addr, uint32_t seed)
{
	uint32_t x = (addr ^ seed) * 0x9e3779b1u;
	return x ^ (x >> 15);
}

void tn_test_words(struct tn_result *r, uint32_t seed, int cached,
		   volatile uint32_t *start, volatile uint32_t *end)
{
	volatile uint32_t *p;

	for (int pass = 0; pass < 2; pass++) {
		uint32_t invert = pass ? 0xffffffffu : 0;
		for (p = start; p < end; p++)
			*p = tn_pattern((uint32_t)(uintptr_t)p, seed) ^ invert;
		if (cached)
			tn_dcache_wbinval();
		for (p = start; p < end; p++)
			tn_expect(r, (uintptr_t)p,
				  tn_pattern((uint32_t)(uintptr_t)p, seed) ^ invert,
				  *p);
	}
}

/* Compare the first LANE_BYTES at base with the shadow copy. */
static void check_lanes(struct tn_result *r, int cached,
			volatile uint32_t *base)
{
	volatile uint8_t *b = (volatile uint8_t *)base;
	volatile uint16_t *h = (volatile uint16_t *)base;
	volatile uint32_t *w = base;

	if (cached)
		tn_dcache_wbinval();
	for (int i = 0; i < LANE_BYTES / 4; i++)
		tn_expect(r, (uintptr_t)&w[i],
			  (uint32_t)shadow[4 * i] |
			  (uint32_t)shadow[4 * i + 1] << 8 |
			  (uint32_t)shadow[4 * i + 2] << 16 |
			  (uint32_t)shadow[4 * i + 3] << 24, w[i]);
	for (int i = 0; i < LANE_BYTES / 2; i++)
		tn_expect(r, (uintptr_t)&h[i],
			  (uint32_t)shadow[2 * i] |
			  (uint32_t)shadow[2 * i + 1] << 8, h[i]);
	for (int i = 0; i < LANE_BYTES; i++)
		tn_expect(r, (uintptr_t)&b[i], shadow[i], b[i]);
}

void tn_test_lanes(struct tn_result *r, uint32_t seed, int cached,
		   volatile uint32_t *base)
{
	volatile uint8_t *b = (volatile uint8_t *)base;
	volatile uint16_t *h = (volatile uint16_t *)base;
	volatile uint32_t *w = base;

	for (int i = 0; i < LANE_BYTES / 4; i++) {
		uint32_t value = tn_pattern((uint32_t)i, seed);
		w[i] = value;
		for (int k = 0; k < 4; k++)
			shadow[4 * i + k] = (uint8_t)(value >> (8 * k));
	}
	check_lanes(r, cached, base);
	for (int odd = 1; odd >= 0; odd--) {
		for (int i = odd; i < LANE_BYTES; i += 2) {
			uint8_t value = (uint8_t)(i * 37 + seed);
			b[i] = value;
			shadow[i] = value;
		}
		check_lanes(r, cached, base);
	}
	for (int odd = 1; odd >= 0; odd--) {
		for (int i = odd; i < LANE_BYTES / 2; i += 2) {
			uint16_t value = (uint16_t)(i * 0x0f1d + seed);
			h[i] = value;
			shadow[2 * i] = (uint8_t)value;
			shadow[2 * i + 1] = (uint8_t)(value >> 8);
		}
		check_lanes(r, cached, base);
	}
}

void tn_test_address_lines(struct tn_result *r)
{
	volatile uint32_t *base = (volatile uint32_t *)TN_SDRAM_BASE;
	volatile uint32_t *p;

	*base = TN_SDRAM_BASE;
	for (uint32_t bit = 4; bit < TN_SDRAM_BYTES; bit <<= 1) {
		p = (volatile uint32_t *)(TN_SDRAM_BASE + bit);
		*p = TN_SDRAM_BASE + bit;
	}
	tn_expect(r, TN_SDRAM_BASE, TN_SDRAM_BASE, *base);
	for (uint32_t bit = 4; bit < TN_SDRAM_BYTES; bit <<= 1) {
		p = (volatile uint32_t *)(TN_SDRAM_BASE + bit);
		tn_expect(r, (uintptr_t)p, TN_SDRAM_BASE + bit, *p);
	}
}
