/* SPDX-License-Identifier: MIT
 *
 * Polled output on the fabric UART, for the boot ROM and the runtime.
 */
#ifndef TINYNES_UART_H
#define TINYNES_UART_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

void tn_put_char(char c);
void tn_put_str(const char *s);
void tn_put_hex(uint32_t value); /* eight digits */
void tn_put_dec(uint32_t value);
void tn_wait_tx_idle(void); /* until the last byte has left the pin */

#ifdef __cplusplus
}
#endif

#endif
