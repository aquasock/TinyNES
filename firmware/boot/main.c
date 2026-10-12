/* SPDX-License-Identifier: MIT
 *
 * TinyNES AE350 boot ROM program. It checks the fabric registers in the EXTS
 * window, tests the block RAM and the SDRAM on the RAM port with the A25
 * caches off and then on (each cached check after writing back and
 * invalidating the D-cache, so the data crosses the bus as cache-line
 * bursts), measures the SDRAM, and then reports once a second:
 *
 *   TinyNES AE350 C OK UNC=<cycles> CAC=<cycles>
 *   TinyNES SDRAM OK 32M MISS=<cycles> RD=<KB/s> WR=<KB/s> FULL=<ms>
 *
 * UNC and CAC are the core cycles (hex) each block RAM test took. MISS is
 * the core cycles per cache line read from the SDRAM one word per line, RD
 * and WR the rates reading and writing 1 MiB with the caches on, and FULL
 * the time the cached pattern test of all 32 MiB took, all in decimal. A
 * line starting with BAD reports the first test that failed, or any trap.
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

static void put_dec(uint32_t value)
{
	char digits[10];
	int count = 0;

	do {
		digits[count++] = (char)('0' + value % 10);
		value /= 10;
	} while (value);
	while (count)
		put_char(digits[--count]);
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

static void test_words(struct result *r, uint32_t seed, int cached,
		       volatile uint32_t *start, volatile uint32_t *end)
{
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

/* Compare the first LANE_BYTES at base with the shadow copy, read as
 * bytes, halfwords and words. */
static void check_lanes(struct result *r, int cached, volatile uint32_t *base)
{
	volatile uint8_t *b = (volatile uint8_t *)base;
	volatile uint16_t *h = (volatile uint16_t *)base;
	volatile uint32_t *w = base;

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
static void test_lanes(struct result *r, uint32_t seed, int cached,
		       volatile uint32_t *base)
{
	volatile uint8_t *b = (volatile uint8_t *)base;
	volatile uint16_t *h = (volatile uint16_t *)base;
	volatile uint32_t *w = base;

	for (int i = 0; i < LANE_BYTES / 4; i++) {
		uint32_t value = pattern(i, seed);
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

#define SDRAM ((volatile uint32_t *)TN_SDRAM_BASE)
#define SDRAM_END ((volatile uint32_t *)(TN_SDRAM_BASE + TN_SDRAM_BYTES))
#define MEASURE_BYTES (1u << 20)

/* Each address line from bit 2 up: the word at the base and the word at
 * each one-hot offset hold their own addresses, so a line that is stuck,
 * swapped with another or unconnected shows. */
static void test_address_lines(struct result *r)
{
	volatile uint32_t *p;

	SDRAM[0] = TN_SDRAM_BASE;
	for (uint32_t bit = 4; bit < TN_SDRAM_BYTES; bit <<= 1) {
		p = (volatile uint32_t *)(TN_SDRAM_BASE + bit);
		*p = TN_SDRAM_BASE + bit;
	}
	expect(r, TN_SDRAM_BASE, TN_SDRAM_BASE, SDRAM[0]);
	for (uint32_t bit = 4; bit < TN_SDRAM_BYTES; bit <<= 1) {
		p = (volatile uint32_t *)(TN_SDRAM_BASE + bit);
		expect(r, (uintptr_t)p, TN_SDRAM_BASE + bit, *p);
	}
}

struct sdram_speed {
	uint32_t miss_cycles;
	uint32_t read_kbps;
	uint32_t write_kbps;
};

static uint32_t kbps(uint32_t bytes, uint32_t cycles)
{
	return (uint32_t)((uint64_t)(bytes / 1024) * TN_CORE_HZ / cycles);
}

/* With the caches on: the core cycles per line for reads that each miss,
 * and the rates for reading and writing MEASURE_BYTES word by word. */
static void measure_sdram(struct sdram_speed *speed)
{
	volatile uint32_t *p;
	volatile uint32_t *end = SDRAM + MEASURE_BYTES / 4;
	uint32_t sum = 0, start, cycles;

	dcache_writeback_invalidate();
	start = tn_cycles();
	for (p = SDRAM; p < end; p += 8)
		sum += *p;
	cycles = tn_cycles() - start;
	speed->miss_cycles = cycles / (MEASURE_BYTES / 32);

	dcache_writeback_invalidate();
	start = tn_cycles();
	for (p = SDRAM; p < end; p++)
		sum += *p;
	cycles = tn_cycles() - start;
	speed->read_kbps = kbps(MEASURE_BYTES, cycles);

	dcache_writeback_invalidate();
	start = tn_cycles();
	for (p = SDRAM; p < end; p++)
		*p = sum;
	dcache_writeback_invalidate();
	cycles = tn_cycles() - start;
	speed->write_kbps = kbps(MEASURE_BYTES, cycles);
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
	struct result sd_uncached = {0}, sd_cached = {0}, sd_full = {0};
	struct sdram_speed speed;
	uint32_t start, uncached_cycles, cached_cycles, full_ms;
	uint64_t full_start;

	put_str("\r\nTinyNES AE350 boot ROM\r\n");
	test_registers(&regs);

	start = tn_cycles();
	test_lanes(&uncached, 0x5au, 0, __ram_test_start);
	test_words(&uncached, 0x01234567u, 0, __ram_test_start, __ram_test_end);
	uncached_cycles = tn_cycles() - start;

	test_lanes(&sd_uncached, 0x3cu, 0, SDRAM);
	test_address_lines(&sd_uncached);

	CSR_SET(CSR_MCACHE_CTL, 3u);
	__asm__ volatile("fence.i" ::: "memory");
	start = tn_cycles();
	test_lanes(&cached, 0xa5u, 1, __ram_test_start);
	test_words(&cached, 0x89abcdefu, 1, __ram_test_start, __ram_test_end);
	cached_cycles = tn_cycles() - start;

	test_lanes(&sd_cached, 0xc3u, 1, SDRAM + 4096);
	measure_sdram(&speed);
	full_start = tn_cycles64();
	test_words(&sd_full, 0x13579bdfu, 1, SDRAM, SDRAM_END);
	full_ms = (uint32_t)((tn_cycles64() - full_start) / (TN_CORE_HZ / 1000));

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
		bad = report_bad("SDU", &sd_uncached);
		bad |= report_bad("SDC", &sd_cached);
		bad |= report_bad("SDF", &sd_full);
		if (!bad) {
			put_str("TinyNES SDRAM OK 32M MISS=");
			put_dec(speed.miss_cycles);
			put_str(" RD=");
			put_dec(speed.read_kbps);
			put_str(" WR=");
			put_dec(speed.write_kbps);
			put_str(" FULL=");
			put_dec(full_ms);
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
