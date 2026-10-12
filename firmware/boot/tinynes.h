/* SPDX-License-Identifier: MIT
 *
 * Registers the fabric decodes in the AE350's uncached EXTS window
 * (fpga/ae350_soc/exts_uart.sv), and the A25 cache controls.
 */
#ifndef TINYNES_H
#define TINYNES_H

#include <stdint.h>

#define TN_REG(offset) (*(volatile uint32_t *)(0xe8000000u + (offset)))

#define TN_UART_DATA    TN_REG(0x00) /* write: byte to transmit */
#define TN_UART_STATUS  TN_REG(0x04) /* read */
#define TN_ID           TN_REG(0x08) /* read: TN_ID_VALUE */
#define TN_SCRATCH      TN_REG(0x0c) /* read and write */

#define TN_UART_TX_READY 0x1u /* the transmit holding register is free */
#define TN_UART_TX_IDLE  0x2u /* and the last byte has left the pin */
#define TN_ID_VALUE      0x544e3031u /* "TN01" */

#define TN_CORE_HZ 750000000u

/* The dock's SDRAM on the RAM port (fpga/ae350_soc/ahb_sdram.sv). */
#define TN_SDRAM_BASE  0x40000000u
#define TN_SDRAM_BYTES (32u << 20)

/* mcache_ctl bit 0 enables the L1 I-cache, bit 1 the L1 D-cache;
 * mcctlcommand 6 writes back and invalidates the whole L1 D-cache. */
#define CSR_MCACHE_CTL    0x7ca
#define CSR_MCCTLCOMMAND  0x7cc
#define MCCTL_L1D_WBINVAL_ALL 6u

#define CSR_STR(x) #x
#define CSR_SET(csr, value) \
	__asm__ volatile("csrs " CSR_STR(csr) ", %0" :: "r"(value) : "memory")
#define CSR_WRITE(csr, value) \
	__asm__ volatile("csrw " CSR_STR(csr) ", %0" :: "r"(value) : "memory")

static inline uint32_t tn_cycles(void)
{
	uint32_t value;
	__asm__ volatile("csrr %0, mcycle" : "=r"(value));
	return value;
}

static inline uint64_t tn_cycles64(void)
{
	uint32_t high, low, again;
	do {
		__asm__ volatile("csrr %0, mcycleh" : "=r"(high));
		__asm__ volatile("csrr %0, mcycle" : "=r"(low));
		__asm__ volatile("csrr %0, mcycleh" : "=r"(again));
	} while (high != again);
	return (uint64_t)high << 32 | low;
}

#endif
