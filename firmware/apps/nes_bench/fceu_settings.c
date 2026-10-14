// SPDX-License-Identifier: MIT
//
// The one setting nes_bench's driver needs from inside FCEUmm's FSettings,
// which has no setter: FCEUI_Initialize() clears the structure, so the five
// APU channel volumes start at 0 and the core mixes silence. FCEUmm's
// libretro driver sets them from its fceumm_apu_1 to _5 options, all on by
// default, as 256 (src/drivers/libretro/libretro.c, set_apu_channels).
// The battery-backed save RAM of the loaded cartridge comes from the same
// place: the CartInfo the loaded iNES fills in (src/cart.h, ines.c), which
// cart.h declares the type of but not the object, so it is declared here as
// FCEUmm's libretro driver declares it (src/drivers/libretro/libretro.c).
// Built with the core's own flags, so the structure's layout is the core's.
#include "fceu.h"
#include "cart.h"

extern CartInfo iNESCart;

void nes_bench_apu_volumes(int volume)
{
	FSettings.SquareVolume[0] = volume;
	FSettings.SquareVolume[1] = volume;
	FSettings.TriangleVolume = volume;
	FSettings.NoiseVolume = volume;
	FSettings.PCMVolume = volume;
}

/* The battery-backed save RAM the loaded cartridge has, or NULL if it has
 * none: its bytes and how many, for saving it and for asking for a saved
 * one. A battery-backed mapper 1 board points SaveGame[0] into the 8 KiB
 * WRAM it allocated and gives it as 8192 bytes (boards/mmc1.c,
 * Mapper1_Init). */
uint8_t *nes_bench_battery(uint32_t *len)
{
	if (!iNESCart.battery || !iNESCart.SaveGame[0] ||
	    !iNESCart.SaveGameLen[0])
		return 0;
	*len = iNESCart.SaveGameLen[0];
	return iNESCart.SaveGame[0];
}
