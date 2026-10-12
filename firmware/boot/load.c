/* SPDX-License-Identifier: MIT */
#include "load.h"

#include "tinynes.h"
#include "uart.h"

#define SDRAM_END (TN_SDRAM_BASE + TN_SDRAM_BYTES)

#define BYTE_TIMEOUT (TN_CORE_HZ / 10)   /* within a header or block */
#define IDLE_TIMEOUT (2 * TN_CORE_HZ)    /* before a block: give up */
#define QUIET_CYCLES (TN_CORE_HZ / 100)  /* line silent after a NAK */

static uint32_t window;

/* IEEE CRC-32 kept inverted between bytes: start at ~0, finish with ~. */
static uint32_t crc32_byte(uint32_t crc, uint8_t byte)
{
	crc ^= byte;
	for (int k = 0; k < 8; k++)
		crc = (crc >> 1) ^ (0xedb88320u & -(crc & 1));
	return crc;
}

/* The next received byte, or -1 after timeout core cycles without one. */
static int get_byte(uint32_t timeout)
{
	uint32_t start = tn_cycles();

	do {
		uint32_t value = TN_UART_RX;
		if (value & TN_UART_RX_VALID)
			return (int)(value & 0xff);
	} while (tn_cycles() - start < timeout);
	return -1;
}

/* Receive count bytes to dst, adding them to *crc; -1 on a timeout. */
static int get_bytes(uint8_t *dst, uint32_t count, uint32_t *crc)
{
	while (count--) {
		int byte = get_byte(BYTE_TIMEOUT);
		if (byte < 0)
			return -1;
		*dst++ = (uint8_t)byte;
		*crc = crc32_byte(*crc, (uint8_t)byte);
	}
	return 0;
}

static int get_word(uint32_t *word, uint32_t *crc)
{
	uint8_t bytes[4];

	if (get_bytes(bytes, 4, crc))
		return -1;
	*word = (uint32_t)bytes[0] | (uint32_t)bytes[1] << 8 |
		(uint32_t)bytes[2] << 16 | (uint32_t)bytes[3] << 24;
	return 0;
}

static int overrun(void)
{
	return (TN_UART_STATUS & TN_UART_RX_OVERRUN) != 0;
}

void tn_load_reset(void)
{
	window = 0;
	TN_UART_STATUS = TN_UART_RX_OVERRUN | TN_UART_RX_FRAME;
}

/* Wait for the sender to stop, discarding what it sent, so the NAK is
 * read after the rest of a bad header or block. */
static void nak(char reason)
{
	uint32_t start = tn_cycles();

	while (tn_cycles() - start < QUIET_CYCLES)
		if (TN_UART_RX & TN_UART_RX_VALID)
			start = tn_cycles();
	tn_load_reset();
	tn_put_char((char)TN_LOAD_NAK);
	tn_put_char(reason);
}

/* Called once the magic has arrived; the entry, or 0 if the load failed. */
static uint32_t load(void)
{
	uint32_t header[TN_LOAD_HEADER_BYTES / 4];
	uint32_t crc = ~0u, unused = 0, address, length, entry, done;

	for (int i = 0; i < 4; i++)
		crc = crc32_byte(crc, (uint8_t)(TN_LOAD_MAGIC >> (8 * i)));
	for (int i = 1; i < 5; i++)
		if (get_word(&header[i], &crc)) {
			nak(TN_LOAD_TIMEOUT);
			return 0;
		}
	if (get_word(&header[5], &unused)) {
		nak(TN_LOAD_TIMEOUT);
		return 0;
	}
	if (overrun()) {
		nak(TN_LOAD_OVERRUN);
		return 0;
	}
	if (~crc != header[5]) {
		nak(TN_LOAD_HEADER_CRC);
		return 0;
	}
	address = header[1];
	length = header[2];
	entry = header[3];
	if (address < TN_SDRAM_BASE || address >= SDRAM_END || length == 0 ||
	    length > SDRAM_END - address || entry < address ||
	    entry - address >= length || (entry & 1)) {
		nak(TN_LOAD_ADDRESS);
		return 0;
	}
	tn_put_char((char)TN_LOAD_ACK);

	for (done = 0; done < length;) {
		uint32_t count = length - done;
		uint8_t *dst = (uint8_t *)(uintptr_t)(address + done);
		uint32_t block_crc;
		int first;

		if (count > TN_LOAD_BLOCK_BYTES)
			count = TN_LOAD_BLOCK_BYTES;
		first = get_byte(IDLE_TIMEOUT);
		if (first < 0)
			return 0;
		*dst = (uint8_t)first;
		crc = crc32_byte(~0u, (uint8_t)first);
		if (get_bytes(dst + 1, count - 1, &crc) ||
		    get_word(&block_crc, &unused)) {
			nak(TN_LOAD_TIMEOUT);
			continue;
		}
		if (overrun()) {
			nak(TN_LOAD_OVERRUN);
			continue;
		}
		if (~crc != block_crc) {
			nak(TN_LOAD_BLOCK_CRC);
			continue;
		}
		tn_put_char((char)TN_LOAD_ACK);
		done += count;
	}

	/* Check what reached the SDRAM, not what is in the D-cache. */
	tn_dcache_wbinval();
	crc = ~0u;
	for (done = 0; done < length; done++)
		crc = crc32_byte(crc,
				 *(volatile uint8_t *)(uintptr_t)(address + done));
	if (~crc != header[4]) {
		nak(TN_LOAD_IMAGE_CRC);
		return 0;
	}
	tn_put_char((char)TN_LOAD_ACK);
	tn_put_str("TinyNES RUN ");
	tn_put_hex(entry);
	tn_put_str("\r\n");
	tn_wait_tx_idle();
	return entry;
}

uint32_t tn_load_poll(uint32_t cycles)
{
	uint32_t start = tn_cycles();

	while (tn_cycles() - start < cycles) {
		uint32_t value = TN_UART_RX;
		if (!(value & TN_UART_RX_VALID))
			continue;
		window = window >> 8 | (value & 0xff) << 24;
		if (window == TN_LOAD_MAGIC) {
			uint32_t entry;

			tn_load_reset();
			entry = load();
			tn_load_reset();
			return entry;
		}
	}
	return 0;
}
