/* SPDX-License-Identifier: MIT
 *
 * Stands in for newlib's <sys/dirent.h>, which refuses to build, so that
 * <dirent.h> declares the directory calls. Runtime programs have no
 * directories: opendir (syscalls.c) fails with ENOENT.
 */
#ifndef TINYNES_SYS_DIRENT_H
#define TINYNES_SYS_DIRENT_H

#include <sys/types.h>

typedef struct tn_dir DIR;

struct dirent {
	char d_name[256];
};

#endif
