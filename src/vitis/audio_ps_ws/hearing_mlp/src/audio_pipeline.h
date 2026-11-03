#ifndef AUDIO_PIPELINE_H
#define AUDIO_PIPELINE_H
#include <stdint.h>
#include "audio_decision.h"
typedef struct {
    float rms;
    float input_rms;
    float peak;
    float gain;
    float smoothed_scores[MLP_CLASSES];
    float current_scores[MLP_CLASSES];
    AudioDecisionResult decision;
} AudioChannelResult;
typedef struct {
    uint64_t samples_seen;
    AudioChannelResult channels[AUDIO_CHANNELS];
    int selected_channel;
    AudioDecisionResult decision;
} AudioPipelineResult;
int audio_pipeline_init(void);
/* Feed one synchronized four-channel model-rate frame. Return 1 each 4000
   frames after the first 16000; then call infer once for all four channels. */
int audio_pipeline_feed_frame(const float samples[AUDIO_CHANNELS]);
int audio_pipeline_infer(AudioPipelineResult *result);
int audio_pipeline_set_gain(float gain);
#endif
