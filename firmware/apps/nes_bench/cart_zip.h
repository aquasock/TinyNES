// SPDX-License-Identifier: MIT
//
// A cartridge sent as a .zip holding one .nes (cart_zip.c).
#ifndef CART_ZIP_H
#define CART_ZIP_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// True if the bytes begin with a zip local file header.
bool cart_is_zip(const uint8_t *data, size_t len);

// Inflate the zip's one .nes entry, of at most max bytes, into a new buffer
// from malloc, *out, of *out_len bytes, and copy the entry's name into name.
// NULL on success, else why it was refused.
const char *cart_unzip(const uint8_t *zip, size_t len, size_t max,
		       uint8_t **out, size_t *out_len, char *name, size_t name_size);

#ifdef __cplusplus
}
#endif

#endif
