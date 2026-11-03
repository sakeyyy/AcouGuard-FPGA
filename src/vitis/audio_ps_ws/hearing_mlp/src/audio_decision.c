/* Port of detect_fsd50k_sensitive.py EventStateMachine as invoked by v2.
   All counts below are per inference update, NOT milliseconds.
   Called every 4000 model samples by the continuous rolling pipeline. */
#include "audio_decision.h"
#include "audio_mlp.h"
#include <string.h>

#if AUDIO_CONFIRM_FRAMES < 1 || AUDIO_CONFIRM_HITS < 1 || AUDIO_CONFIRM_HITS > AUDIO_CONFIRM_FRAMES
#error "Invalid PC confirmation history settings"
#endif

static int pc_select_event(const float scores[MLP_CLASSES],int background)
{
    int i,selected=-1;
    float best=-1.0f;
    for(i=0;i<MLP_CLASSES;++i) {
        float threshold=model_thresholds[i]*AUDIO_THRESHOLD_SCALE;
        if(i==background || scores[i]<threshold) continue;
        /* Python max((confidence,label,threshold)) resolves equal confidence
           by label text. Preserve that rule rather than class-index order. */
        if(scores[i]>best || (scores[i]==best && selected>=0 &&
                            strcmp(model_class_names[i],model_class_names[selected])>0)) {
            selected=i;best=scores[i];
        }
    }
    return selected>=0?selected:background;
}

void audio_decision_init(AudioDecisionState *state)
{
    int i;
    memset(state, 0, sizeof(*state));
    for (i=0;i<MLP_CLASSES;++i)
        if (!strcmp(model_class_names[i], "background")) state->background=i;
    state->active_label=state->background;
}

void audio_decision_update(AudioDecisionState *state,
                           const float current[MLP_CLASSES], float rms,
                           AudioDecisionResult *result)
{
    int i,j,observed,confirmed,most_common,best_hits=0;
    int counts[MLP_CLASSES]={0};
    float candidate_confidence;

    for(i=0;i<MLP_CLASSES;++i) {
        state->smoothed[i]=state->initialized ?
            (float)AUDIO_EMA_ALPHA*current[i]+(float)(1.0-AUDIO_EMA_ALPHA)*state->smoothed[i] : current[i];
    }
    state->initialized=1;
    result->gated=(rms<AUDIO_MINIMUM_RMS);
    /* Desktop updates EMA even during silence, then applies the RMS gate. */
    if(result->gated) {
        observed=state->background;
        candidate_confidence=0.0f;
    } else {
        /* v2 uses absolute class thresholds, no extra road_vehicle floor. */
        observed=pc_select_event(state->smoothed,state->background);
        candidate_confidence=state->smoothed[observed];
    }
    if(state->history_count==AUDIO_CONFIRM_FRAMES) {
        for(i=1;i<AUDIO_CONFIRM_FRAMES;++i) state->history[i-1]=state->history[i];
        --state->history_count;
    }
    state->history[state->history_count++]=observed;
    for(i=0;i<state->history_count;++i)
        if(state->history[i]!=state->background) ++counts[state->history[i]];
    most_common=state->background;
    /* Counter.most_common keeps first-seen order for ties. */
    for(j=0;j<state->history_count;++j) {
        i=state->history[j];
        if(i!=state->background && counts[i]>best_hits) {
            best_hits=counts[i];most_common=i;
        }
    }
    confirmed=best_hits>=AUDIO_CONFIRM_HITS ? most_common : state->background;
    if(confirmed!=state->background) {
        state->active_label=confirmed;
        if(observed==confirmed) state->active_confidence=candidate_confidence;
        state->release_count=0;
    } else if(state->active_label!=state->background) {
        if(observed==state->active_label) {
            state->release_count=0;
            state->active_confidence=candidate_confidence;
        } else {
            ++state->release_count;
            if(state->release_count>=AUDIO_RELEASE_FRAMES) {
                state->active_label=state->background;
                state->active_confidence=candidate_confidence;
                state->release_count=0;
            }
        }
    } else state->active_confidence=candidate_confidence;
    result->candidate_label=observed;
    result->candidate_confidence=candidate_confidence;
    result->active_label=state->active_label;
    result->active_confidence=state->active_confidence;
    result->alarm=(state->active_label!=state->background);
}
