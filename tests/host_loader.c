/* SPDX-License-Identifier: MIT
 *
 * The boot ROM loader (firmware/boot/load.c) built for the host, for
 * tests/test_loader_host.py. The UART is a pseudo-terminal whose name is
 * printed first; the SDRAM is mapped at its real address. Like the ROM it
 * prints "TinyNES LOAD" once a second and waits for a program; after a load
 * the whole SDRAM is written to the dump file, cleared, and "TinyNES EXIT 0"
 * printed in place of running the program.
 *
 *   host_loader <dump> [drop|flip|overrun <index>] ...
 *
 * drop and flip lose or corrupt the received byte with that index (counting
 * every byte since start), overrun raises the overrun flag as it arrives,
 * each the first time only, to exercise the NAKs.
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#include "load.h"
#include "tinynes.h"
#include "uart.h"

#define MAX_FAULTS 16

enum fault { DROP, FLIP, OVERRUN };

static int uart;
static uint32_t regs[8];
static uint32_t given[8];
static int last = -1;
static unsigned long received;
static int overrun;
static struct {
	enum fault kind;
	unsigned long index;
} faults[MAX_FAULTS];
static int fault_count;

static int rx_byte(void)
{
	struct pollfd fd = {.fd = uart, .events = POLLIN};
	uint8_t byte;

	for (;;) {
		int dropped = 0;
		unsigned long index;

		if (poll(&fd, 1, 0) <= 0 || read(uart, &byte, 1) != 1)
			return -1;
		index = received++;
		for (int i = 0; i < fault_count; i++) {
			if (faults[i].index != index)
				continue;
			faults[i].index = (unsigned long)-1;
			if (faults[i].kind == DROP)
				dropped = 1;
			else if (faults[i].kind == FLIP)
				byte ^= 0x40;
			else
				overrun = 1;
		}
		if (!dropped)
			return byte;
	}
}

/* Each access hands back a slot holding what a read returns; a store
 * changes the slot, which the next access notices. The loader always makes
 * another access before it waits for anything. */
volatile uint32_t *tn_host_reg(uint32_t offset)
{
	if (last >= 0 && regs[last] != given[last]) {
		if (last == 0) {
			uint8_t byte = (uint8_t)regs[0];
			if (write(uart, &byte, 1) != 1)
				exit(2);
		} else if (last == 1 && (regs[1] & TN_UART_RX_OVERRUN)) {
			overrun = 0;
		} else if (last != 1) {
			fprintf(stderr, "store to register %#x\n", 4 * last);
			exit(2);
		}
	}
	switch (offset) {
	case 0x00:
		regs[0] = 0xffffffffu;
		break;
	case 0x04:
		regs[1] = TN_UART_TX_READY | TN_UART_TX_IDLE |
			  (overrun ? TN_UART_RX_OVERRUN : 0);
		break;
	case 0x10: {
		int byte = rx_byte();
		regs[4] = byte < 0 ? 0 : TN_UART_RX_VALID | (uint32_t)byte;
		break;
	}
	default:
		fprintf(stderr, "unexpected register %#x\n", offset);
		exit(2);
	}
	last = (int)(offset / 4);
	given[last] = regs[last];
	return &regs[last];
}

void tn_dcache_wbinval(void)
{
}

uint64_t tn_cycles64(void)
{
	struct timespec now;

	clock_gettime(CLOCK_MONOTONIC, &now);
	return ((uint64_t)now.tv_sec * 1000000000u + (uint64_t)now.tv_nsec) *
	       (TN_CORE_HZ / 1000000u) / 1000u;
}

uint32_t tn_cycles(void)
{
	return (uint32_t)tn_cycles64();
}

int main(int argc, char **argv)
{
	struct termios raw;
	int slave;

	if (argc < 2 || argc % 2) {
		fprintf(stderr, "usage: %s <dump> [drop|flip|overrun <index>] ...\n",
			argv[0]);
		return 2;
	}
	for (int i = 2; i < argc; i += 2) {
		if (fault_count == MAX_FAULTS)
			return 2;
		faults[fault_count].kind = !strcmp(argv[i], "drop") ? DROP :
					   !strcmp(argv[i], "flip") ? FLIP : OVERRUN;
		faults[fault_count++].index = strtoul(argv[i + 1], NULL, 0);
	}
	if (mmap((void *)(uintptr_t)TN_SDRAM_BASE, TN_SDRAM_BYTES,
		 PROT_READ | PROT_WRITE,
		 MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE, -1, 0) !=
	    (void *)(uintptr_t)TN_SDRAM_BASE) {
		perror("mmap SDRAM");
		return 2;
	}
	uart = posix_openpt(O_RDWR | O_NOCTTY);
	if (uart < 0 || grantpt(uart) || unlockpt(uart)) {
		perror("pty");
		return 2;
	}
	/* Keep the far end open and raw, so nothing is echoed or lost before
	 * the test opens it. */
	slave = open(ptsname(uart), O_RDWR | O_NOCTTY);
	if (slave < 0 || tcgetattr(slave, &raw)) {
		perror("pty slave");
		return 2;
	}
	cfmakeraw(&raw);
	tcsetattr(slave, TCSANOW, &raw);
	printf("%s\n", ptsname(uart));
	fflush(stdout);

	tn_load_reset();
	for (;;) {
		FILE *dump;

		tn_put_str("TinyNES LOAD\r\n");
		if (!tn_load_poll(TN_CORE_HZ))
			continue;
		dump = fopen(argv[1], "wb");
		if (!dump ||
		    fwrite((void *)(uintptr_t)TN_SDRAM_BASE, 1, TN_SDRAM_BYTES,
			   dump) != TN_SDRAM_BYTES ||
		    fclose(dump))
			return 2;
		memset((void *)(uintptr_t)TN_SDRAM_BASE, 0, TN_SDRAM_BYTES);
		tn_put_str("TinyNES EXIT 0\r\n");
	}
}
