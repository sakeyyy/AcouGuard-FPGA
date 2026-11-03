#include "name_call.h"
#include <stdio.h>
#include <stdarg.h>
static char messages[131072];
static unsigned message_count;
static unsigned sample_clock;

void wave_uart_printf(const char *format, ...)
{
    int count;
    va_list arguments;
    va_start(arguments, format);
    count = vsnprintf(messages + message_count, sizeof(messages) - message_count, format, arguments);
    va_end(arguments);
    if (count > 0)
        message_count += (unsigned)count < sizeof(messages) - message_count ?
                         (unsigned)count : sizeof(messages) - message_count - 1;
}

const char *test_log(void) { return messages; }
void test_clear_log(void) { message_count = 0; messages[0] = 0; }
void test_reset(void) { nc_init(0); sample_clock = 0; test_clear_log(); }
void test_feed(const float *samples, unsigned count, unsigned channel)
{
    unsigned index;
    float frame[4] = {0, 0, 0, 0};
    for (index = 0; index < count; ++index) {
        frame[channel] = samples[index];
        nc_tick(sample_clock++ / 16);
        nc_feed(frame);
    }
}
