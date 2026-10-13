// SPDX-License-Identifier: MIT
//
// The one setting nes_bench's driver needs from inside FCEUmm's FSettings,
// which has no setter: FCEUI_Initialize() clears the structure, so the five
// APU channel volumes start at 0 and the core mixes silence. FCEUmm's
// libretro driver sets them from its fceumm_apu_1 to _5 options, all on by
// default, as 256 (src/drivers/libretro/libretro.c, set_apu_channels).
// Built with the core's own flags, so the structure's layout is the core's.
#include "fceu.h"

void nes_bench_apu_volumes(int volume)
{
	FSettings.SquareVolume[0] = volume;
	FSettings.SquareVolume[1] = volume;
	FSettings.TriangleVolume = volume;
	FSettings.NoiseVolume = volume;
	FSettings.PCMVolume = volume;
}
