/* SPDX-License-Identifier: MIT
 *
 * Reset entry at 0x80000000. The caches are left as they come out of reset
 * (disabled); main turns them on. Sets the global and stack pointers and the
 * trap vector, copies .data from the ROM, clears .bss and calls main.
 */
	.section .text.start, "ax"
	.globl	_start
_start:
	.option push
	.option norelax
	la	gp, __global_pointer$
	.option pop
	la	sp, __stack_top
	la	t0, trap_entry
	csrw	mtvec, t0

	la	t0, __data_load
	la	t1, __data_start
	la	t2, __data_end
1:	bgeu	t1, t2, 2f
	lw	t3, 0(t0)
	sw	t3, 0(t1)
	addi	t0, t0, 4
	addi	t1, t1, 4
	j	1b
2:	la	t1, __bss_start
	la	t2, __bss_end
3:	bgeu	t1, t2, 4f
	sw	zero, 0(t1)
	addi	t1, t1, 4
	j	3b
4:	call	main
5:	j	5b

	/* Every trap is reported on the UART, repeatedly; it does not return. */
	.text
	.align	2
trap_entry:
	la	sp, __stack_top
	csrr	a0, mcause
	csrr	a1, mepc
	csrr	a2, mtval
	call	trap_report
6:	j	6b
