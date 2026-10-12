/* SPDX-License-Identifier: MIT
 *
 * The cartridge image named by ROM= at build time, copied to NES_ROM_FILE.
 * GNU as on both the AE350 and the PC build.
 */
	.section .rodata.nes_rom, "a"
	.balign 16
	.globl nes_rom
	.globl nes_rom_end
nes_rom:
	.incbin NES_ROM_FILE
nes_rom_end:
	.section .note.GNU-stack, "", @progbits
