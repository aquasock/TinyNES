/* SPDX-License-Identifier: MIT
 *
 * TinyNES AE350 boot ROM program. It checks the fabric registers in the EXTS
 * window, tests the RAM-port RAM with the A25 caches off and then on (each
 * cached check after writing back and invalidating the D-cache, so the data
 * crosses the bus as cache-line bursts), and then reports once a second:
 *
 *   TinyNES AE350 C OK UNC=<cycles> CAC=<cycles>
 *
 * with the core cycles each RAM test took, or a line starting with BAD for
 * the first test that failed or for any trap.
 */
#include <stddef.h>
#include <stdint.h>

#include "tinynes.h"

extern uint32_t __ram_test_start[], __ram_test_end[];

void trap_report(uint32_t cause, uint32_t epc, uint32_t tval)
	__attribute__((noreturn));
int main(void);

struct result {
	uint32_t failures;
	uint32_t addr;
	uint32_t expected;
	uint32_t got;
};

#define LANE_BYTES 64
static uint8_t shadow[LANE_BYTES];

static void put_char(char c)
{
	while (!(TN_UART_STATUS & TN_UART_TX_READY))
		;
	TN_UART_DATA = (uint8_t)c;
}

static void put_str(const char *s)
{
	while (*s)
		put_char(*s++);
}

static void put_hex(uint32_t value)
{
	for (int shift = 28; shift >= 0; shift -= 4)
		put_char("0123456789abcdef"[(value >> shift) & 15]);
}

static void wait_cycles(uint32_t count)
{
	uint32_t start = tn_cycles();
	while (tn_cycles() - start < count)
		;
}

static void expect(struct result *r, uintptr_t addr, uint32_t expected,
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

static void dcache_writeback_invalidate(void)
{
	CSR_WRITE(CSR_MCCTLCOMMAND, MCCTL_L1D_WBINVAL_ALL);
}

/* Distinct for every address under one seed, so aliasing shows. */
static uint32_t pattern(uint32_t addr, uint32_t seed)
{
	uint32_t x = (addr ^ seed) * 0x9e3779b1u;
	return x ^ (x >> 15);
}

static void test_words(struct result *r, uint32_t seed, int cached)
{
	volatile uint32_t *start = __ram_test_start;
	volatile uint32_t *end = __ram_test_end;
	volatile uint32_t *p;

	for (int pass = 0; pass < 2; pass++) {
		uint32_t invert = pass ? 0xffffffffu : 0;
		for (p = start; p < end; p++)
			*p = pattern((uint32_t)(uintptr_t)p, seed) ^ invert;
		if (cached)
			dcache_writeback_invalidate();
		for (p = start; p < end; p++)
			expect(r, (uintptr_t)p,
			       pattern((uint32_t)(uintptr_t)p, seed) ^ invert, *p);
	}
}

/* Compare the first LANE_BYTES of the test region with the shadow copy,
 * read as bytes, halfwords and words. */
static void check_lanes(struct result *r, int cached)
{
	volatile uint8_t *b = (volatile uint8_t *)__ram_test_start;
	volatile uint16_t *h = (volatile uint16_t *)__ram_test_start;
	volatile uint32_t *w = __ram_test_start;

	if (cached)
		dcache_writeback_invalidate();
	for (int i = 0; i < LANE_BYTES / 4; i++)
		expect(r, (uintptr_t)&w[i],
		       (uint32_t)shadow[4 * i] | (uint32_t)shadow[4 * i + 1] << 8 |
		       (uint32_t)shadow[4 * i + 2] << 16 |
		       (uint32_t)shadow[4 * i + 3] << 24, w[i]);
	for (int i = 0; i < LANE_BYTES / 2; i++)
		expect(r, (uintptr_t)&h[i],
		       (uint32_t)shadow[2 * i] | (uint32_t)shadow[2 * i + 1] << 8,
		       h[i]);
	for (int i = 0; i < LANE_BYTES; i++)
		expect(r, (uintptr_t)&b[i], shadow[i], b[i]);
}

/* Byte and halfword stores must change only their own lanes. */
static void test_lanes(struct result *r, uint32_t seed, int cached)
{
	volatile uint8_t *b = (volatile uint8_t *)__ram_test_start;
	volatile uint16_t *h = (volatile uint16_t *)__ram_test_start;
	volatile uint32_t *w = __ram_test_start;

	for (int i = 0; i < LANE_BYTES / 4; i++) {
		uint32_t value = pattern(i, seed);
		w[i] = value;
		for (int k = 0; k < 4; k++)
			shadow[4 * i + k] = (uint8_t)(value >> (8 * k));
	}
	check_lanes(r, cached);
	for (int odd = 1; odd >= 0; odd--) {
		for (int i = odd; i < LANE_BYTES; i += 2) {
			uint8_t value = (uint8_t)(i * 37 + seed);
			b[i] = value;
			shadow[i] = value;
		}
		check_lanes(r, cached);
	}
	for (int odd = 1; odd >= 0; odd--) {
		for (int i = odd; i < LANE_BYTES / 2; i += 2) {
			uint16_t value = (uint16_t)(i * 0x0f1d + seed);
			h[i] = value;
			shadow[2 * i] = (uint8_t)value;
			shadow[2 * i + 1] = (uint8_t)(value >> 8);
		}
		check_lanes(r, cached);
	}
}

static void test_registers(struct result *r)
{
	expect(r, (uintptr_t)&TN_ID, TN_ID_VALUE, TN_ID);
	for (int bit = 0; bit < 32; bit++) {
		uint32_t value = 1u << bit;
		TN_SCRATCH = value;
		expect(r, (uintptr_t)&TN_SCRATCH, value, TN_SCRATCH);
		TN_SCRATCH = ~value;
		expect(r, (uintptr_t)&TN_SCRATCH, ~value, TN_SCRATCH);
	}
}

static int report_bad(const char *name, const struct result *r)
{
	if (r->failures == 0)
		return 0;
	put_str("BAD ");
	put_str(name);
	put_str(" N=");
	put_hex(r->failures);
	put_str(" A=");
	put_hex(r->addr);
	put_str(" E=");
	put_hex(r->expected);
	put_str(" G=");
	put_hex(r->got);
	put_str("\r\n");
	return 1;
}

int main(void)
{
	struct result regs = {0}, uncached = {0}, cached = {0};
	uint32_t start, uncached_cycles, cached_cycles;

	put_str("\r\nTinyNES AE350 boot ROM\r\n");
	test_registers(&regs);

	start = tn_cycles();
	test_lanes(&uncached, 0x5au, 0);
	test_words(&uncached, 0x01234567u, 0);
	uncached_cycles = tn_cycles() - start;

	CSR_SET(CSR_MCACHE_CTL, 3u);
	__asm__ volatile("fence.i" ::: "memory");
	start = tn_cycles();
	test_lanes(&cached, 0xa5u, 1);
	test_words(&cached, 0x89abcdefu, 1);
	cached_cycles = tn_cycles() - start;

	for (;;) {
		int bad = report_bad("REG", &regs);
		bad |= report_bad("UNC", &uncached);
		bad |= report_bad("CAC", &cached);
		if (!bad) {
			put_str("TinyNES AE350 C OK UNC=");
			put_hex(uncached_cycles);
			put_str(" CAC=");
			put_hex(cached_cycles);
			put_str("\r\n");
		}
		wait_cycles(TN_CORE_HZ);
	}
}

void trap_report(uint32_t cause, uint32_t epc, uint32_t tval)
{
	for (;;) {
		put_str("BAD TRAP C=");
		put_hex(cause);
		put_str(" P=");
		put_hex(epc);
		put_str(" V=");
		put_hex(tval);
		put_str("\r\n");
		wait_cycles(TN_CORE_HZ);
	}
}
