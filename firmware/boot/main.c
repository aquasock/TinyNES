/* SPDX-License-Identifier: MIT
 *
 * TinyNES AE350 boot ROM program. It checks the fabric registers in the EXTS
 * window and tests the block RAM and the SDRAM on the RAM port with the A25
 * caches off and then on, leaves the caches on, and then waits for a program
 * on the UART (the load protocol in tinynes.h), reporting once a second until
 * one starts to arrive:
 *
 *   TinyNES AE350 C OK UNC=<cycles> CAC=<cycles>
 *   TinyNES SDRAM OK 32M
 *   TinyNES LOAD
 *
 * UNC and CAC are the core cycles (hex) each block RAM test took. The SDRAM
 * check covers the byte lanes, cached and not, and every address line; the
 * full pattern test and the speed measurements belong to a loaded program
 * (firmware/apps/rt_test). A line starting with BAD reports the first test
 * that failed, or any trap, and the ROM then does not load programs.
 */
#include <stddef.h>
#include <stdint.h>

#include "load.h"
#include "memtest.h"
#include "tinynes.h"
#include "uart.h"

extern uint32_t __ram_test_start[], __ram_test_end[];

void trap_report(uint32_t cause, uint32_t epc, uint32_t tval)
	__attribute__((noreturn));
int main(void);

#define SDRAM ((volatile uint32_t *)TN_SDRAM_BASE)

static void wait_cycles(uint32_t count)
{
	uint32_t start = tn_cycles();
	while (tn_cycles() - start < count)
		;
}

static void test_registers(struct tn_result *r)
{
	tn_expect(r, (uintptr_t)&TN_ID, TN_ID_VALUE, TN_ID);
	for (int bit = 0; bit < 32; bit++) {
		uint32_t value = 1u << bit;
		TN_SCRATCH = value;
		tn_expect(r, (uintptr_t)&TN_SCRATCH, value, TN_SCRATCH);
		TN_SCRATCH = ~value;
		tn_expect(r, (uintptr_t)&TN_SCRATCH, ~value, TN_SCRATCH);
	}
}

static void report_bad(const char *name, const struct tn_result *r)
{
	if (r->failures == 0)
		return;
	tn_put_str("BAD ");
	tn_put_str(name);
	tn_put_str(" N=");
	tn_put_hex(r->failures);
	tn_put_str(" A=");
	tn_put_hex(r->addr);
	tn_put_str(" E=");
	tn_put_hex(r->expected);
	tn_put_str(" G=");
	tn_put_hex(r->got);
	tn_put_str("\r\n");
}

int main(void)
{
	struct tn_result regs = {0}, uncached = {0}, cached = {0};
	struct tn_result sd_uncached = {0}, sd_cached = {0};
	uint32_t start, uncached_cycles, cached_cycles;
	int bad;

	tn_put_str("\r\nTinyNES AE350 boot ROM\r\n");
	test_registers(&regs);

	start = tn_cycles();
	tn_test_lanes(&uncached, 0x5au, 0, __ram_test_start);
	tn_test_words(&uncached, 0x01234567u, 0, __ram_test_start,
		      __ram_test_end);
	uncached_cycles = tn_cycles() - start;

	tn_test_lanes(&sd_uncached, 0x3cu, 0, SDRAM);
	tn_test_address_lines(&sd_uncached);

	CSR_SET(CSR_MCACHE_CTL, 3u);
	__asm__ volatile("fence.i" ::: "memory");
	start = tn_cycles();
	tn_test_lanes(&cached, 0xa5u, 1, __ram_test_start);
	tn_test_words(&cached, 0x89abcdefu, 1, __ram_test_start,
		      __ram_test_end);
	cached_cycles = tn_cycles() - start;

	tn_test_lanes(&sd_cached, 0xc3u, 1, SDRAM + 4096);

	bad = regs.failures || uncached.failures || cached.failures ||
	      sd_uncached.failures || sd_cached.failures;
	tn_load_reset();
	for (;;) {
		uint32_t entry;

		report_bad("REG", &regs);
		report_bad("UNC", &uncached);
		report_bad("CAC", &cached);
		report_bad("SDU", &sd_uncached);
		report_bad("SDC", &sd_cached);
		if (bad) {
			wait_cycles(TN_CORE_HZ);
			continue;
		}
		tn_put_str("TinyNES AE350 C OK UNC=");
		tn_put_hex(uncached_cycles);
		tn_put_str(" CAC=");
		tn_put_hex(cached_cycles);
		tn_put_str("\r\nTinyNES SDRAM OK 32M\r\nTinyNES LOAD\r\n");
		entry = tn_load_poll(TN_CORE_HZ);
		if (entry) {
			__asm__ volatile("fence.i" ::: "memory");
			((void (*)(void))(uintptr_t)entry)();
		}
	}
}

void trap_report(uint32_t cause, uint32_t epc, uint32_t tval)
{
	for (;;) {
		tn_put_str("BAD TRAP C=");
		tn_put_hex(cause);
		tn_put_str(" P=");
		tn_put_hex(epc);
		tn_put_str(" V=");
		tn_put_hex(tval);
		tn_put_str("\r\n");
		wait_cycles(TN_CORE_HZ);
	}
}
