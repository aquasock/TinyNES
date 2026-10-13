// SPDX-License-Identifier: MIT
//
// TinyNES HDMI video test. Loads its own palette and per-line emphasis,
// then for FRAMES frames copies a 256x240 test picture into the frame
// buffer not being shown, draws a moving 8x8 white square on it, asks for
// it at the next vertical blank and waits until it is shown. Reports:
//
//   TinyNES VIDEO OK FRAMES=<n> PERIOD=<us> COPY=<us> FB=<KB/s> VBL=<n>
//
// PERIOD is the mean time per frame (16,667 us at 60 Hz), COPY the mean time
// to write a whole frame buffer with 32-bit stores, FB that write rate and
// VBL the vertical blanks the fabric counted meanwhile. The picture stays
// up after the program ends. A failed check prints BAD VIDEO <name> and the
// program exits with 1.
//
// The picture, top to bottom inside a white border: eight colour bars, red,
// green and blue ramps, then seven strips drawn with emphasis 1 to 7, each
// a ramp in its own colour (red, green, yellow, blue, magenta, cyan, white).
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "tinynes.h"

#define FRAMES 600u
#define W TN_VIDEO_WIDTH
#define H TN_VIDEO_HEIGHT

static uint32_t picture[W * H / 4];

static uint32_t rgb(uint32_t r, uint32_t g, uint32_t b)
{
	return r << 16 | g << 8 | b;
}

static void load_palette(void)
{
	static const uint32_t bars[8] = {
		0xffffff, 0xffff00, 0x00ffff, 0x00ff00,
		0xff00ff, 0xff0000, 0x0000ff, 0x404040,
	};
	for (uint32_t i = 0; i < TN_VIDEO_PALETTE_SIZE; i++) {
		uint32_t c = 0;
		if (i == 1)
			c = 0xffffff;
		else if (i >= 2 && i < 10)
			c = bars[i - 2];
		else if (i >= 64 && i < 128)
			c = rgb((i - 64) * 4 + 3, 0, 0);
		else if (i >= 128 && i < 192)
			c = rgb(0, (i - 128) * 4 + 3, 0);
		else if (i >= 192 && i < 256)
			c = rgb(0, 0, (i - 192) * 4 + 3);
		else if (i >= 256) {
			uint32_t e = (i - 256) >> 6, v = (i & 63) * 4 + 3;
			c = rgb(e & 1 ? v : 0, e & 2 ? v : 0, e & 4 ? v : 0);
		}
		TN_VIDEO_PALETTE(i) = c;
	}
}

static uint32_t strip_emphasis(uint32_t y)
{
	return y >= 176 && y < 225 ? 1 + (y - 176) / 7 : 0;
}

static void draw_picture(void)
{
	uint8_t *p = (uint8_t *)picture;
	for (uint32_t y = 0; y < H; y++) {
		for (uint32_t x = 0; x < W; x++) {
			uint8_t c = 0;
			if (x == 0 || x == W - 1 || y == 0 || y == H - 1)
				c = 1;
			else if (y >= 8 && y < 64)
				c = 2 + x / 32;
			else if (y >= 72 && y < 104)
				c = 64 + x / 4;
			else if (y >= 104 && y < 136)
				c = 128 + x / 4;
			else if (y >= 136 && y < 168)
				c = 192 + x / 4;
			else if (strip_emphasis(y))
				c = 64 + x / 4;
			p[y * W + x] = c;
		}
	}
	for (uint32_t b = 0; b < 2; b++)
		for (uint32_t y = 0; y < H; y++)
			TN_VIDEO_EMPHASIS(b, y) = strip_emphasis(y);
}

static void fail(const char *name)
{
	printf("BAD VIDEO %s\n", name);
	exit(1);
}

int main(void)
{
	if (TN_VIDEO_ID != TN_VIDEO_ID_VALUE)
		fail("ID");
	load_palette();
	draw_picture();

	uint32_t sx = 20, sy = 20;
	int32_t dx = 1, dy = 1;
	uint64_t copy_cycles = 0;
	uint32_t vbl0 = 0;
	uint64_t start = 0;
	for (uint32_t frame = 0; frame <= FRAMES; frame++) {
		uint32_t back = (TN_VIDEO_STATUS & TN_VIDEO_BUFFER) ? 0 : 1;
		volatile uint32_t *fb32 = TN_VIDEO_FB32(back);
		volatile uint8_t *fb = TN_VIDEO_FB(back);

		uint64_t t0 = tn_cycles64();
		for (uint32_t i = 0; i < W * H / 4; i++)
			fb32[i] = picture[i];
		if (frame > 0)
			copy_cycles += tn_cycles64() - t0;

		for (uint32_t y = 0; y < 8; y++)
			for (uint32_t x = 0; x < 8; x++)
				fb[(sy + y) * W + sx + x] = 1;
		if (sx + dx < 1 || sx + dx + 8 > W - 1)
			dx = -dx;
		if (sy + dy < 1 || sy + dy + 8 > H - 1)
			dy = -dy;
		sx += dx;
		sy += dy;

		TN_VIDEO_CTRL = TN_VIDEO_ENABLE | (back ? TN_VIDEO_BUFFER : 0);
		uint32_t want = TN_VIDEO_SHOWING | (back ? TN_VIDEO_BUFFER : 0);
		uint64_t wait = tn_cycles64();
		while ((TN_VIDEO_STATUS & (TN_VIDEO_SHOWING | TN_VIDEO_BUFFER)) != want)
			if (tn_cycles64() - wait > TN_CORE_HZ / 10)
				fail("flip");
		// Frame 0 only lines up with the vertical blank.
		if (frame == 0) {
			start = tn_cycles64();
			vbl0 = TN_VIDEO_FRAMES;
		}
	}
	uint64_t total = tn_cycles64() - start;
	uint32_t vbl = TN_VIDEO_FRAMES - vbl0;
	uint32_t period_us = (uint32_t)(total / FRAMES / (TN_CORE_HZ / 1000000u));
	uint32_t copy_us = (uint32_t)(copy_cycles / FRAMES / (TN_CORE_HZ / 1000000u));
	uint32_t rate = copy_us ? W * H * 1000u / copy_us : 0;
	if (vbl < FRAMES - 1 || vbl > FRAMES + 1)
		fail("FRAMES");
	printf("TinyNES VIDEO OK FRAMES=%u PERIOD=%u COPY=%u FB=%u VBL=%u\n",
	       (unsigned)FRAMES, (unsigned)period_us, (unsigned)copy_us,
	       (unsigned)rate, (unsigned)vbl);
	return 0;
}
