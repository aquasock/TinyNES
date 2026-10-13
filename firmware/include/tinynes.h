/* SPDX-License-Identifier: MIT
 *
 * Registers the fabric decodes in the AE350's uncached EXTS window
 * (fpga/ae350_soc/exts_uart.sv, video.sv and wii_pads.sv), the memory map, the A25 cache controls and
 * the boot ROM's UART load protocol. Shared by the boot ROM and the runtime.
 */
#ifndef TINYNES_H
#define TINYNES_H

#include <stdint.h>

#ifdef __riscv
#define TN_REG(offset) (*(volatile uint32_t *)(0xe8000000u + (offset)))
#else
/* Host builds of firmware code (tests/test_loader_host.py) model the
 * registers, the cache controls and the cycle counter themselves. */
volatile uint32_t *tn_host_reg(uint32_t offset);
#define TN_REG(offset) (*tn_host_reg(offset))
#endif

#define TN_UART_DATA    TN_REG(0x00) /* write: byte to transmit */
#define TN_UART_STATUS  TN_REG(0x04) /* read; write 1s to clear bits 3, 4 */
#define TN_ID           TN_REG(0x08) /* read: TN_ID_VALUE */
#define TN_SCRATCH      TN_REG(0x0c) /* read and write */
#define TN_UART_RX      TN_REG(0x10) /* read: pops the oldest received byte */

#define TN_UART_TX_READY   0x01u /* the transmit holding register is free */
#define TN_UART_TX_IDLE    0x02u /* and the last byte has left the pin */
#define TN_UART_RX_WAITING 0x04u /* a received byte is waiting */
#define TN_UART_RX_OVERRUN 0x08u /* a byte arrived to a full buffer; sticky */
#define TN_UART_RX_FRAME   0x10u /* a byte had no stop bit; sticky */
#define TN_UART_RX_VALID   0x100u /* TN_UART_RX bits 7:0 hold a byte */
#define TN_ID_VALUE        0x544e3031u /* "TN01" */

/* HDMI video (fpga/ae350_soc/video.sv): 1280x720 60 Hz showing a 256x240
 * frame buffer at 3x, or fabric colour bars until TN_VIDEO_ENABLE is set.
 * CTRL changes take effect at the next vertical blank; STATUS reports what
 * is being shown. Palette and emphasis are write-only; the palette index of
 * a pixel is the pixel itself when its line's emphasis is 0, else 256 +
 * emphasis * 64 + (pixel & 63). The two frame buffers are the top 128 KiB
 * of the SDRAM, pixel (x, y) at TN_VIDEO_FB(b) + 256 * y + x, written
 * through the D-cache: write the D-cache back (tn_dcache_wbinval) before
 * asking for a buffer to be shown. Programs must not use that memory. */
#define TN_VIDEO_CTRL    TN_REG(0x10000) /* read and write */
#define TN_VIDEO_STATUS  TN_REG(0x10004) /* read */
#define TN_VIDEO_FRAMES  TN_REG(0x10008) /* read: vertical blanks */
#define TN_VIDEO_ID      TN_REG(0x1000c) /* read: TN_VIDEO_ID_VALUE */
#define TN_VIDEO_LATE    TN_REG(0x10010) /* read: lines shown before fetched */
#define TN_VIDEO_PIXELS  TN_REG(0x10014) /* read: non-zero pixels, last frame */
#define TN_VIDEO_BITS    TN_REG(0x10018) /* read: pixel bits seen 1 (7:0), 0 (15:8) */
#define TN_VIDEO_LB(i)   TN_REG(0x10800 + 4 * (i)) /* read: line-buffer halfword */
#define TN_VIDEO_PALETTE(i)     TN_REG(0x11000 + 4 * (i)) /* 0xRRGGBB */
#define TN_VIDEO_EMPHASIS(b, y) TN_REG(0x12000 + 4 * (256 * (b) + (y)))
#define TN_VIDEO_FB_BASE  0x41fe0000u
#define TN_VIDEO_FB_BYTES (128u << 10)
#define TN_VIDEO_FB(b) ((uint8_t *)(TN_VIDEO_FB_BASE + 0x10000u * (b)))

#define TN_VIDEO_ENABLE    0x1u /* CTRL: show the frame buffers */
#define TN_VIDEO_BUFFER    0x2u /* CTRL: the buffer to show (STATUS: shown) */
#define TN_VIDEO_VBLANK    0x1u /* STATUS */
#define TN_VIDEO_SHOWING   0x4u /* STATUS: the frame buffers are shown */
#define TN_VIDEO_ID_VALUE  0x544e5631u /* "TNV1" */
#define TN_VIDEO_WIDTH     256u
#define TN_VIDEO_HEIGHT    240u
#define TN_VIDEO_PALETTE_SIZE 768u

/* Wii Classic Controller inputs on PMOD0. Four separate I2C buses run in
 * fabric, one per adjacent PMOD signal pair. Reading DATA also captures its
 * upper two bytes for a subsequent DATA2 read. Buttons in bytes 4 and 5 are
 * active low. A pad may answer without identifying as a Classic Controller;
 * check both PRESENT and CLASSIC before decoding its data. */
#define TN_PAD_ID          TN_REG(0x40000) /* read: TN_PAD_ID_VALUE */
#define TN_PAD_CTRL        TN_REG(0x40004) /* read/write: quarter bit clocks; write restarts masters */
#define TN_PAD_STATUS(n)   TN_REG(0x40010 + 0x10u * (n))
#define TN_PAD_DATA(n)     TN_REG(0x40014 + 0x10u * (n))
#define TN_PAD_DATA2(n)    TN_REG(0x40018 + 0x10u * (n))
#define TN_PAD_IDENT(n)    TN_REG(0x4001c + 0x10u * (n))
#define TN_PAD_ID_VALUE    0x544e5031u /* "TNP1" */
#define TN_PAD_PRESENT     0x01u
#define TN_PAD_CLASSIC     0x02u
#define TN_PAD_READS(s)    (((s) >> 8) & 0xffffu)
#define TN_PAD_FAILS(s)    ((s) >> 24)
#define TN_PAD_QUARTER_100K 187u
#define TN_PAD_QUARTER_50K  375u

#define TN_UART_BAUD 2000000u
#define TN_CORE_HZ   750000000u

/* The boot ROM at the reset vector and the fabric block RAM. */
#define TN_ROM_BASE   0x80000000u
#define TN_BRAM_BASE  0x60000000u
#define TN_BRAM_BYTES (64u << 10)

/* The dock's SDRAM on the RAM port (fpga/ae350_soc/ahb_sdram.sv). */
#define TN_SDRAM_BASE  0x40000000u
#define TN_SDRAM_BYTES (32u << 20)

/* mcache_ctl bit 0 enables the L1 I-cache, bit 1 the L1 D-cache;
 * mcctlcommand 6 writes back and invalidates the whole L1 D-cache. */
#define CSR_MCACHE_CTL    0x7ca
#define CSR_MCCTLCOMMAND  0x7cc
#define MCCTL_L1D_WBINVAL_ALL 6u

/* The boot ROM loads a program into the SDRAM over the UART (all words
 * little-endian, CRCs IEEE CRC-32 as zlib.crc32):
 *
 *   header: TN_LOAD_MAGIC, load address, length, entry, CRC of the image,
 *           CRC of the first 20 header bytes
 *   then the image in TN_LOAD_BLOCK_BYTES blocks (the last may be shorter),
 *   each followed by its CRC.
 *
 * The ROM answers the header, each block and the whole image with
 * TN_LOAD_ACK, or TN_LOAD_NAK and a reason letter; a NAKed block is sent
 * again. After the last ACK it prints "TinyNES RUN <entry>" and jumps. */
#define TN_LOAD_MAGIC        0x314c4e54u /* "TNL1" */
#define TN_LOAD_HEADER_BYTES 24u
#define TN_LOAD_BLOCK_BYTES  8192u
#define TN_LOAD_ACK          0x06u
#define TN_LOAD_NAK          0x15u
#define TN_LOAD_TIMEOUT      'T' /* a byte took over 100 ms */
#define TN_LOAD_HEADER_CRC   'H'
#define TN_LOAD_ADDRESS      'A' /* the image is not inside the SDRAM */
#define TN_LOAD_BLOCK_CRC    'C'
#define TN_LOAD_OVERRUN      'O' /* the receive buffer overflowed */
#define TN_LOAD_IMAGE_CRC    'I' /* the image read back from the SDRAM */

#ifdef __riscv
#define CSR_STR(x) #x
#define CSR_SET(csr, value) \
	__asm__ volatile("csrs " CSR_STR(csr) ", %0" :: "r"(value) : "memory")
#define CSR_WRITE(csr, value) \
	__asm__ volatile("csrw " CSR_STR(csr) ", %0" :: "r"(value) : "memory")

static inline void tn_dcache_wbinval(void)
{
	CSR_WRITE(CSR_MCCTLCOMMAND, MCCTL_L1D_WBINVAL_ALL);
}

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
#else
void tn_dcache_wbinval(void);
uint32_t tn_cycles(void);
uint64_t tn_cycles64(void);
#endif

#endif
