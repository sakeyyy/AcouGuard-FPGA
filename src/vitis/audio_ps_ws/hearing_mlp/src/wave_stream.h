#ifndef WAVE_STREAM_H
#define WAVE_STREAM_H
#include <stdint.h>
typedef void (*wave_write_fn)(const uint8_t *, unsigned);
/* channels=1 selects selected_channel; channels=4 sends FRONT/LEFT/RIGHT/BACK. */
int wave_init(uint32_t rate_num, uint32_t rate_den, unsigned decimation,
              unsigned channels, unsigned selected_channel, wave_write_fn writer);
void wave_begin(unsigned flags);
void wave_push_pcm24(const int32_t *interleaved, unsigned frames);
void wave_push_float(const float *mono, unsigned frames);
void wave_flush(void);
#endif
