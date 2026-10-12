/* SPDX-License-Identifier: MIT */
#include "uart.h"

#include "tinynes.h"

void tn_put_char(char c)
{
	while (!(TN_UART_STATUS & TN_UART_TX_READY))
		;
	TN_UART_DATA = (uint8_t)c;
}

void tn_put_str(const char *s)
{
	while (*s)
		tn_put_char(*s++);
}

void tn_put_hex(uint32_t value)
{
	for (int shift = 28; shift >= 0; shift -= 4)
		tn_put_char("0123456789abcdef"[(value >> shift) & 15]);
}

void tn_put_dec(uint32_t value)
{
	char digits[10];
	int count = 0;

	do {
		digits[count++] = (char)('0' + value % 10);
		value /= 10;
	} while (value);
	while (count)
		tn_put_char(digits[--count]);
}

void tn_wait_tx_idle(void)
{
	while (!(TN_UART_STATUS & TN_UART_TX_IDLE))
		;
}
