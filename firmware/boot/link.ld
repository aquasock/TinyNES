/* SPDX-License-Identifier: MIT
 *
 * TinyNES AE350 boot ROM: code and constants in the 32 KiB block-RAM ROM on
 * the ROM port at the reset vector; .data, .bss and the stack in the 64 KiB
 * fabric RAM on the RAM (DDR_H) port. The RAM between .bss and the stack is
 * the region the RAM test overwrites.
 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
	rom (rx)  : ORIGIN = 0x80000000, LENGTH = 32K
	ram (rw)  : ORIGIN = 0x60000000, LENGTH = 64K
}

__stack_size = 4K;

SECTIONS
{
	.text : { KEEP(*(.text.start)) *(.text .text.*) } > rom
	.rodata : { *(.rodata .rodata.* .srodata .srodata.*) . = ALIGN(4); } > rom
	.data : ALIGN(4) {
		__data_start = .;
		*(.data .data.*)
		__global_pointer$ = . + 0x800;
		*(.sdata .sdata.*)
		. = ALIGN(4);
		__data_end = .;
	} > ram AT > rom
	__data_load = LOADADDR(.data);
	.bss (NOLOAD) : ALIGN(4) {
		__bss_start = .;
		*(.sbss .sbss.* .bss .bss.* COMMON)
		. = ALIGN(4);
		__bss_end = .;
	} > ram
	__stack_top = ORIGIN(ram) + LENGTH(ram);
	__ram_test_start = ALIGN(__bss_end, 0x1000);
	__ram_test_end = __stack_top - __stack_size;
	ASSERT(__ram_test_start < __ram_test_end, "no RAM left to test")
	/DISCARD/ : { *(.eh_frame*) *(.comment) *(.riscv.attributes) }
}
