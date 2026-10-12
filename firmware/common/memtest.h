/* SPDX-License-Identifier: MIT
 *
 * Memory tests shared by the boot ROM and runtime programs. Each records the
 * number of mismatches and the first one in a struct tn_result. A cached test
 * writes back and invalidates the D-cache before reading back, so the data
 * crosses the bus as cache-line bursts.
 */
#ifndef TINYNES_MEMTEST_H
#define TINYNES_MEMTEST_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct tn_result {
	uint32_t failures;
	uint32_t addr;
	uint32_t expected;
	uint32_t got;
};

void tn_expect(struct tn_result *r, uintptr_t addr, uint32_t expected,
	       uint32_t got);

/* Distinct for every address under one seed, so aliasing shows. */
uint32_t tn_pattern(uint32_t addr, uint32_t seed);

/* Every word from start to end, with the pattern and then its inverse. */
void tn_test_words(struct tn_result *r, uint32_t seed, int cached,
		   volatile uint32_t *start, volatile uint32_t *end);

/* Byte and halfword stores to the 64 bytes at base change only their own
 * lanes, read back as bytes, halfwords and words. */
void tn_test_lanes(struct tn_result *r, uint32_t seed, int cached,
		   volatile uint32_t *base);

/* Each SDRAM address line from bit 2 up: the word at the base and at each
 * one-hot offset hold their own addresses, so a line that is stuck, swapped
 * or unconnected shows. */
void tn_test_address_lines(struct tn_result *r);

#ifdef __cplusplus
}
#endif

#endif
