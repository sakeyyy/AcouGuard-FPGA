/* Four independent rolling windows and state machines. Do not mix delayed
   microphone waveforms: averaging can cancel useful spectral components. */
#include "audio_pipeline.h"
#include "audio_mlp.h"
#include <math.h>
#include <string.h>
static float rolling[AUDIO_CHANNELS][AUDIO_CLIP_SAMPLES];
static float hop[AUDIO_CHANNELS][AUDIO_PC_HOP_SAMPLES];
static float model_input[AUDIO_CLIP_SAMPLES];
static unsigned hop_used;
static uint64_t seen;
static int ready, previous_channel;
static float gain;
static AudioDecisionState states[AUDIO_CHANNELS];

int audio_pipeline_init(void)
{
    unsigned ch;
    memset(rolling,0,sizeof(rolling));memset(hop,0,sizeof(hop));
    hop_used=0;seen=0;ready=0;gain=AUDIO_DEFAULT_GAIN;previous_channel=0;
    for(ch=0;ch<AUDIO_CHANNELS;++ch)audio_decision_init(&states[ch]);
    return audio_features_init();
}
int audio_pipeline_set_gain(float value)
{
    unsigned ch;
    if(!isfinite(value) || value<1.0f || value>8.0f)return -1;
    gain=value;
    for(ch=0;ch<AUDIO_CHANNELS;++ch)audio_decision_init(&states[ch]);
    return 0;
}
int audio_pipeline_feed_frame(const float samples[AUDIO_CHANNELS])
{
    unsigned ch;
    if(ready || !samples)return -1;
    for(ch=0;ch<AUDIO_CHANNELS;++ch) {
        if(!isfinite(samples[ch]))return -2;
        hop[ch][hop_used]=samples[ch];
    }
    if(++hop_used<AUDIO_PC_HOP_SAMPLES)return 0;
    for(ch=0;ch<AUDIO_CHANNELS;++ch) {
        memmove(rolling[ch],rolling[ch]+AUDIO_PC_HOP_SAMPLES,
                (AUDIO_CLIP_SAMPLES-AUDIO_PC_HOP_SAMPLES)*sizeof(float));
        memcpy(rolling[ch]+AUDIO_CLIP_SAMPLES-AUDIO_PC_HOP_SAMPLES,
               hop[ch],sizeof(hop[ch]));
    }
    hop_used=0;seen+=AUDIO_PC_HOP_SAMPLES;
    ready=(seen>=AUDIO_PC_WARMUP_SAMPLES);
    return ready;
}
int audio_pipeline_infer(AudioPipelineResult *result)
{
    float features[MLP_FEATURES];
    int ch,i,ret,selected=-1;
    if(!ready || !result)return -1;
    for(ch=0;ch<AUDIO_CHANNELS;++ch) {
        AudioChannelResult *r=&result->channels[ch];
        double energy=0.0;
        r->peak=0.0f;r->gain=gain;
        for(i=0;i<AUDIO_CLIP_SAMPLES;++i) {
            energy+=(double)(rolling[ch][i]*rolling[ch][i]);
            r->peak=fmaxf(r->peak,fabsf(rolling[ch][i]));
            model_input[i]=rolling[ch][i]*gain;
        }
        r->input_rms=sqrtf((float)(energy/AUDIO_CLIP_SAMPLES)+1e-12f);
        r->rms=r->input_rms*gain;
        /* A gated channel cannot raise an alarm. Continue its state machine
           with background scores so old events still release normally. */
        if(r->input_rms<AUDIO_MINIMUM_RMS) {
            memset(r->current_scores,0,sizeof(r->current_scores));
            r->current_scores[states[ch].background]=1.0f;
        } else {
            ret=audio_extract_features(model_input,features);
            if(ret!=0)return ret;
            audio_mlp_probabilities(features,r->current_scores);
        }
        audio_decision_update(&states[ch],r->current_scores,r->input_rms,&r->decision);
        memcpy(r->smoothed_scores,states[ch].smoothed,sizeof(r->smoothed_scores));
        if(r->decision.alarm && (selected<0 ||
           r->decision.active_confidence>result->channels[selected].decision.active_confidence ||
           (r->decision.active_confidence==result->channels[selected].decision.active_confidence &&
            ch==previous_channel)))selected=ch;
    }
    if(selected<0)selected=previous_channel;
    result->selected_channel=selected;
    result->decision=result->channels[selected].decision;
    previous_channel=selected;result->samples_seen=seen;ready=0;
    return 0;
}
