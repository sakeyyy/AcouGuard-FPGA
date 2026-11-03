#ifndef AUDIO_RESAMPLE_H
#define AUDIO_RESAMPLE_H
#include <stdint.h>
#include "app_config.h"

/* Raw input: interleaved FRONT, LEFT, RIGHT, BACK signed 24-in-32 PCM.
   Output: AUDIO_CLIP_SAMPLES mono float samples at the model's 16 kHz rate.
   Includes an anti-alias low-pass FIR; does NOT retime or modify PL DOA audio. */
int audio_resampler_init(void);
int audio_resample_mono(const int32_t *interleaved, unsigned input_frames,
                        float *output, float *rms);

/* Stateful input adapter: no zero padding, phase reset or lost context at DMA
   boundaries. 31 future raw samples are retained as FIR lookahead (~0.635ms). */
typedef struct {
    uint64_t input_count;
    uint64_t output_count;
    float history[128];
} AudioResampleStream;
int audio_resample_stream_init(AudioResampleStream *state);
int audio_resample_stream_push(AudioResampleStream *state,int32_t raw,float *output);
#endif
