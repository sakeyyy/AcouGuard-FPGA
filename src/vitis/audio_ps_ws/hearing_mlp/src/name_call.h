#ifndef NAME_CALL_H
#define NAME_CALL_H
#include <stdint.h>
#define NC_MODE_BIT (1U<<14)
#define NC_ALERT_BIT (1U<<15)
#define NC_RECORD_BIT (1U<<16)
#define NC_READY_BIT (1U<<17)
/* [21:18] guided stage, [23:22] template number; internal GPIO only. */
#define NC_STAGE_MASK (15U<<18)
#define NC_STEP_MASK (3U<<22)
#define NC_CONTROL_MASK (NC_MODE_BIT|NC_ALERT_BIT|NC_RECORD_BIT|NC_READY_BIT|NC_STAGE_MASK|NC_STEP_MASK)
/* A single instance, 16 kHz normalized float PCM. No ASR or speaker identity. */
int nc_init(void (*service)(void));
void nc_command(const char *line);
void nc_key(int long_press);
void nc_dispatch_key(void);
void nc_tick(uint32_t ms);
void nc_feed(const float channels[4]);
int nc_mode(void);
uint32_t nc_control_bits(void);
/* Public numerical functions for host reference and regression checks. */
#define NC_MAX_FRAMES 240
#define NC_DIM 24
int nc_mfcc(const float *pcm, unsigned samples, float *features);
float nc_dtw(const float *a, int na, const float *b, int nb);
#endif
