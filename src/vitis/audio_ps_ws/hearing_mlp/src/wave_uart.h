#ifndef WAVE_UART_H
#define WAVE_UART_H
#include <stdint.h>
#ifndef WAVE_UART_BASE
#define WAVE_UART_BASE 0xE0001000U
#endif
#ifndef WAVE_UART_BAUD
#define WAVE_UART_BAUD 115200U
#endif
int wave_uart_init(void);
int wave_uart_try_read(uint8_t *byte);
void wave_uart_write(const uint8_t *data, unsigned size);
void wave_uart_poll(void);
void wave_uart_drain(void);
void wave_uart_write_blocking(const uint8_t *data, unsigned size);
void wave_uart_printf(const char *format, ...);
unsigned wave_uart_dropped(void);
unsigned wave_uart_high_water(void);
#endif
