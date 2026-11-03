#ifndef AUDIO_DECISION_H
#define AUDIO_DECISION_H
#include "app_config.h"

typedef struct {
    float smoothed[MLP_CLASSES];
    int initialized;
    int history[AUDIO_CONFIRM_FRAMES];
    int history_count;
    int active_label;
    float active_confidence;
    int release_count;
    int background;
} AudioDecisionState;

typedef struct {
    int candidate_label;
    float candidate_confidence;
    int active_label;
    float active_confidence;
    int alarm;
    int gated;
} AudioDecisionResult;

void audio_decision_init(AudioDecisionState *state);
void audio_decision_update(AudioDecisionState *state,
                           const float current[MLP_CLASSES], float rms,
                           AudioDecisionResult *result);
#endif
