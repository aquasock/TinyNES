/* SPDX-License-Identifier: MIT
 *
 * The boot ROM's side of the UART load protocol in tinynes.h.
 */
#ifndef TINYNES_LOAD_H
#define TINYNES_LOAD_H

#include <stdint.h>

/* Forget any partial header and clear the receive error flags. */
void tn_load_reset(void);

/* Watch the UART for up to cycles core cycles. If a header starts, receive
 * the program it describes into the SDRAM, then print "TinyNES RUN <entry>"
 * and return the entry once the line is sent; the caller must fence.i and
 * jump. Returns 0 if nothing was loaded. */
uint32_t tn_load_poll(uint32_t cycles);

#endif
