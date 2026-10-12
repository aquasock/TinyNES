/* SPDX-License-Identifier: MIT
 *
 * TinyNES AE350 runtime programs, loaded into the SDRAM by the boot ROM:
 * code, data, .bss and the heap (from _end to __heap_end) in the SDRAM, the
 * stack in the 64 KiB fabric block RAM, whose bottom edge is a bus error.
 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
	sdram (rwx) : ORIGIN = 0x40000000, LENGTH = 32M
	ram (rw)    : ORIGIN = 0x60000000, LENGTH = 64K
}

SECTIONS
{
	.text : {
		KEEP(*(.text.start))
		KEEP(*(SORT_NONE(.init)))
		KEEP(*(SORT_NONE(.fini)))
		*(.text.unlikely .text.unlikely.*)
		*(.text.startup .text.startup.*)
		*(.text .text.*)
	} > sdram
	.rodata : { *(.rodata .rodata.*) } > sdram
	.eh_frame : { KEEP(*(.eh_frame)) } > sdram
	.gcc_except_table : { *(.gcc_except_table .gcc_except_table.*) } > sdram
	/* The linker's own; a static link leaves it empty. */
	.rela.dyn : { *(.rela.*) } > sdram
	ASSERT(SIZEOF(.rela.dyn) == 0, "dynamic relocations")
	.preinit_array : {
		PROVIDE_HIDDEN(__preinit_array_start = .);
		KEEP(*(.preinit_array))
		PROVIDE_HIDDEN(__preinit_array_end = .);
	} > sdram
	.init_array : {
		PROVIDE_HIDDEN(__init_array_start = .);
		KEEP(*(SORT_BY_INIT_PRIORITY(.init_array.*)))
		KEEP(*(.init_array))
		PROVIDE_HIDDEN(__init_array_end = .);
	} > sdram
	.fini_array : {
		PROVIDE_HIDDEN(__fini_array_start = .);
		KEEP(*(SORT_BY_INIT_PRIORITY(.fini_array.*)))
		KEEP(*(.fini_array))
		PROVIDE_HIDDEN(__fini_array_end = .);
	} > sdram
	.data : { *(.data .data.*) } > sdram
	.sdata : {
		__global_pointer$ = . + 0x800;
		*(.srodata.cst16) *(.srodata.cst8) *(.srodata.cst4)
		*(.srodata.cst2) *(.srodata .srodata.*)
		*(.sdata .sdata.*)
	} > sdram
	.sbss : {
		__bss_start = .;
		*(.sbss .sbss.*)
	} > sdram
	.bss : {
		*(.bss .bss.*) *(COMMON)
		. = ALIGN(4);
		__bss_end = .;
	} > sdram
	_end = ALIGN(16);
	__heap_end = ORIGIN(sdram) + LENGTH(sdram);
	__stack_top = ORIGIN(ram) + LENGTH(ram);

	.comment 0 : { *(.comment) }
	.riscv.attributes 0 : { KEEP(*(.riscv.attributes)) }
	.debug_info 0 : { *(.debug_info .gnu.linkonce.wi.*) }
	.debug_abbrev 0 : { *(.debug_abbrev) }
	.debug_line 0 : { *(.debug_line .debug_line.* .debug_line_end) }
	.debug_line_str 0 : { *(.debug_line_str) }
	.debug_str 0 : { *(.debug_str) }
	.debug_str_offsets 0 : { *(.debug_str_offsets) }
	.debug_addr 0 : { *(.debug_addr) }
	.debug_aranges 0 : { *(.debug_aranges) }
	.debug_rnglists 0 : { *(.debug_rnglists) }
	.debug_loclists 0 : { *(.debug_loclists) }
	.debug_frame 0 : { *(.debug_frame) }
	.debug_ranges 0 : { *(.debug_ranges) }
	.debug_loc 0 : { *(.debug_loc) }
	/DISCARD/ : { *(.note.GNU-stack) *(.gnu_debuglink) }
}
