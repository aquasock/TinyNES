/* SPDX-License-Identifier: MIT
 *
 * The newlib system calls for runtime programs: standard output and error go
 * to the UART (\n sent as \r\n), standard input reads it, the heap runs from
 * _end to the top of the SDRAM, time is the core cycle counter. There are no
 * files. _exit and traps report on the UART and restart the boot ROM, which
 * waits for the next program.
 */
#include <errno.h>
#include <stdint.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>

#include "tinynes.h"
#include "uart.h"

#undef errno
extern int errno;

extern char _end[], __heap_end[];

void tn_rt_reboot(void) __attribute__((noreturn));
void tn_rt_trap(uint32_t cause, uint32_t epc, uint32_t tval)
	__attribute__((noreturn));

int _close(int fd);
int _fstat(int fd, struct stat *st);
int _getpid(void);
int _gettimeofday(struct timeval *tv, void *tz);
int _isatty(int fd);
int _kill(int pid, int sig);
int _lseek(int fd, int offset, int whence);
int _open(const char *name, int flags, int mode);
int _read(int fd, char *buf, int len);
void *_sbrk(ptrdiff_t increment);
int _write(int fd, const char *buf, int len);
void _exit(int code) __attribute__((noreturn));

int _write(int fd, const char *buf, int len)
{
	if (fd != 1 && fd != 2) {
		errno = EBADF;
		return -1;
	}
	for (int i = 0; i < len; i++) {
		if (buf[i] == '\n')
			tn_put_char('\r');
		tn_put_char(buf[i]);
	}
	return len;
}

/* Blocks for the first byte, then takes what has already arrived. */
int _read(int fd, char *buf, int len)
{
	int count = 0;
	uint32_t value;

	if (fd != 0) {
		errno = EBADF;
		return -1;
	}
	while (count < len) {
		value = TN_UART_RX;
		if (value & TN_UART_RX_VALID)
			buf[count++] = (char)value;
		else if (count)
			break;
	}
	return count;
}

void *_sbrk(ptrdiff_t increment)
{
	static char *brk = _end;
	char *old = brk;

	if (increment > __heap_end - brk || increment < _end - brk) {
		errno = ENOMEM;
		return (void *)-1;
	}
	brk += increment;
	return old;
}

int _close(int fd)
{
	(void)fd;
	errno = EBADF;
	return -1;
}

int _fstat(int fd, struct stat *st)
{
	if (fd < 0 || fd > 2) {
		errno = EBADF;
		return -1;
	}
	st->st_mode = S_IFCHR;
	return 0;
}

int _isatty(int fd)
{
	return fd >= 0 && fd <= 2;
}

int _lseek(int fd, int offset, int whence)
{
	(void)fd;
	(void)offset;
	(void)whence;
	errno = ESPIPE;
	return -1;
}

int _open(const char *name, int flags, int mode)
{
	(void)name;
	(void)flags;
	(void)mode;
	errno = ENOENT;
	return -1;
}

int _getpid(void)
{
	return 1;
}

int _kill(int pid, int sig)
{
	(void)pid;
	(void)sig;
	errno = EINVAL;
	return -1;
}

int _gettimeofday(struct timeval *tv, void *tz)
{
	uint64_t cycles = tn_cycles64();

	(void)tz;
	if (tv) {
		tv->tv_sec = (time_t)(cycles / TN_CORE_HZ);
		tv->tv_usec = (suseconds_t)(cycles % TN_CORE_HZ /
					    (TN_CORE_HZ / 1000000));
	}
	return 0;
}

void _exit(int code)
{
	tn_put_str("TinyNES EXIT ");
	if (code < 0) {
		tn_put_char('-');
		tn_put_dec(-(uint32_t)code);
	} else {
		tn_put_dec((uint32_t)code);
	}
	tn_put_str("\r\n");
	tn_wait_tx_idle();
	tn_rt_reboot();
}

void tn_rt_trap(uint32_t cause, uint32_t epc, uint32_t tval)
{
	tn_put_str("\r\nBAD TRAP C=");
	tn_put_hex(cause);
	tn_put_str(" P=");
	tn_put_hex(epc);
	tn_put_str(" V=");
	tn_put_hex(tval);
	tn_put_str("\r\n");
	tn_wait_tx_idle();
	tn_rt_reboot();
}
