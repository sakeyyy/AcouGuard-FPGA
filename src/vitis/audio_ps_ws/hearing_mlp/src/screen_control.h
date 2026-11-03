#ifndef SCREEN_CONTROL_H
#define SCREEN_CONTROL_H
#include <stdint.h>
/* -1 incomplete/ignored; 0 direction; 1 icon; 2 query. */
int screen_command_feed(uint8_t byte);
#endif
