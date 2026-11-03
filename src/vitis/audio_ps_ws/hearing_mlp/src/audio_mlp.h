#ifndef AUDIO_MLP_H
#define AUDIO_MLP_H

#include "model_data.h"

/* One instance per CPU: the implementation reuses static FFT workspace. */
int audio_features_init(void);
void audio_features_set_service(void (*service)(void));
int audio_extract_features(const float *samples, float features[MLP_FEATURES]);
void audio_mlp_probabilities(const float features[MLP_FEATURES], float scores[MLP_CLASSES]);
int audio_select_event(const float scores[MLP_CLASSES], float threshold_scale,
                       float vehicle_minimum);

#endif
