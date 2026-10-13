// SPDX-License-Identifier: MIT
// Play 1 kHz on the left and 2 kHz on the right through the Pmod I2S2 on
// PMOD1 (fpga/ae350_soc/i2s_out.sv), and check the unit: its ID, its frame
// rate measured against the A25's cycle counter, and that the FIFO never ran
// dry or overflowed while the CPU kept it filled.
//
//   TinyNES AUDIO RATE=<Hz> WANT=<Hz>
//   TinyNES AUDIO OK SECONDS=<n> FRAMES=<n> UNDER=<n> DROPS=<n> MIN=<pairs>
// or a line starting BAD.
#include <math.h>
#include <stdint.h>
#include <stdio.h>

#include "tinynes.h"

#ifndef TEST_SECONDS
#define TEST_SECONDS 5u
#endif
#define AMPLITUDE 8192.0f   // -12 dBFS
#define TABLE_BITS 10u

static int16_t sine[1u << TABLE_BITS];

int main(void)
{
	if (TN_AUDIO_ID != TN_AUDIO_ID_VALUE) {
		printf("BAD AUDIO ID=%08lx\n", (unsigned long)TN_AUDIO_ID);
		return 1;
	}
	TN_AUDIO_CTRL = TN_AUDIO_FLUSH;

	// The frame rate against the core clock, over a quarter of a second.
	uint32_t f0 = TN_AUDIO_FRAMES;
	uint64_t c0 = tn_cycles64();
	while (tn_cycles64() - c0 < TN_CORE_HZ / 4u)
		;
	uint32_t f1 = TN_AUDIO_FRAMES;
	uint64_t c1 = tn_cycles64();
	uint64_t milli_hz = (uint64_t)(f1 - f0) * TN_CORE_HZ * 1000u / (c1 - c0);
	uint64_t want_milli = (uint64_t)TN_AUDIO_RATE_NUM * 1000u / TN_AUDIO_RATE_DEN;
	printf("TinyNES AUDIO RATE=%lu.%03lu WANT=%lu.%03lu\n",
	       (unsigned long)(milli_hz / 1000u), (unsigned long)(milli_hz % 1000u),
	       (unsigned long)(want_milli / 1000u), (unsigned long)(want_milli % 1000u));
	// The count is whole frames over a quarter second, so +-8 Hz is one
	// frame's quantisation; more is a wrong divider.
	if (milli_hz + 8000u < want_milli || milli_hz > want_milli + 8000u) {
		printf("BAD AUDIO RATE\n");
		return 1;
	}

	for (unsigned i = 0; i < (1u << TABLE_BITS); i++)
		sine[i] = (int16_t)lrintf(AMPLITUDE *
			sinf(6.2831853f * (float)i / (float)(1u << TABLE_BITS)));

	// Phase steps in 1/2^32 of a cycle per frame.
	const double rate = (double)TN_AUDIO_RATE_NUM / TN_AUDIO_RATE_DEN;
	const uint32_t step_l = (uint32_t)(1000.0 / rate * 4294967296.0);
	const uint32_t step_r = (uint32_t)(2000.0 / rate * 4294967296.0);
	const uint32_t total = (uint32_t)(rate * TEST_SECONDS);
	uint32_t phase_l = 0, phase_r = 0, sent = 0;
	uint32_t min_level = TN_AUDIO_DEPTH;

	const uint32_t under0 = TN_AUDIO_UNDERRUNS(TN_AUDIO_STATUS);
	const uint32_t drops0 = TN_AUDIO_DROPS;
	const uint32_t frames0 = TN_AUDIO_FRAMES;
	int enabled = 0;
	while (sent < total) {
		uint32_t level = TN_AUDIO_LEVEL(TN_AUDIO_STATUS);
		if (enabled && level < min_level)
			min_level = level;
		// Keep the FIFO between half and nearly full.
		for (uint32_t room = TN_AUDIO_DEPTH - 64u - level;
		     room != 0 && sent < total && level < TN_AUDIO_DEPTH / 2u + 64u;
		     room--, sent++, level++) {
			uint16_t l = (uint16_t)sine[phase_l >> (32u - TABLE_BITS)];
			uint16_t r = (uint16_t)sine[phase_r >> (32u - TABLE_BITS)];
			TN_AUDIO_DATA = (uint32_t)l << 16 | r;
			phase_l += step_l;
			phase_r += step_r;
		}
		if (!enabled) {
			TN_AUDIO_CTRL = TN_AUDIO_ENABLE;
			enabled = 1;
		}
	}
	while (TN_AUDIO_LEVEL(TN_AUDIO_STATUS) != 0)
		;
	const uint32_t frames = TN_AUDIO_FRAMES - frames0;
	TN_AUDIO_CTRL = 0;
	const uint32_t under = TN_AUDIO_UNDERRUNS(TN_AUDIO_STATUS) - under0;
	const uint32_t drops = TN_AUDIO_DROPS - drops0;
	// The frame that found the FIFO empty at the end counts as one underrun.
	const int ok = under <= 1u && drops == 0;
	printf("TinyNES AUDIO %s SECONDS=%u FRAMES=%lu UNDER=%lu DROPS=%lu MIN=%lu\n",
	       ok ? "OK" : "BAD", TEST_SECONDS, (unsigned long)frames,
	       (unsigned long)under, (unsigned long)drops,
	       (unsigned long)min_level);
	return ok ? 0 : 1;
}
