/* Match scipy.signal.resample_poly(x, 1024, 3125,
   window=("kaiser",5.0), padtype="constant") for this board's raw sample rate.
   First AUDIO_CLIP_SAMPLES outputs are retained. No arbitrary 6.5 kHz cutoff.
   Coefficients are generated once; work area is 1024*63*4 = 258048 bytes. */
#include "audio_resample.h"
#include <math.h>
#include <stddef.h>

#define PI 3.14159265358979323846
#define HALF_FILTER 31250L
static float coeff[AUDIO_RESAMPLE_PHASES][AUDIO_RESAMPLE_TAPS];
static int initialized;

static double bessel_i0(double x)
{
    double sum=1.0,term=1.0,y=x*x/4.0;
    unsigned k;
    for(k=1;k<60;++k) {
        term*=y/((double)k*k);sum+=term;
        if(term<sum*1e-16) break;
    }
    return sum;
}

static double kernel(long j,double i0beta)
{
    double ratio,sinc,inside;
    if(j < -HALF_FILTER || j > HALF_FILTER) return 0.0;
    ratio=(double)j/HALF_FILTER;
    inside=fmax(1.0-ratio*ratio,0.0);
    sinc=(j==0)?1.0/3125.0:sin(PI*(double)j/3125.0)/(PI*(double)j);
    return sinc*bessel_i0(5.0*sqrt(inside))/i0beta;
}

int audio_resampler_init(void)
{
    long j;
    unsigned phase,tap;
    double sum=0.0,i0beta=bessel_i0(5.0);
    if(initialized) return 0;
    if(AUDIO_RESAMPLE_PHASES!=1024 || AUDIO_RESAMPLE_STEP_NUM!=3125 ||
       AUDIO_RESAMPLE_TAPS!=63 || AUDIO_SAMPLE_RATE!=16000) return -1;
    for(j=-HALF_FILTER;j<=HALF_FILTER;++j) sum+=kernel(j,i0beta);
    if(!(sum>0.0)) return -2;
    for(phase=0;phase<1024;++phase)
        for(tap=0;tap<63;++tap) {
            j=((long)tap-31)*1024-(long)phase;
            coeff[phase][tap]=(float)(kernel(j,i0beta)/sum*1024.0);
        }
    initialized=1;
    return 0;
}

int audio_resample_mono(const int32_t *interleaved,unsigned input_frames,
                        float *output,float *rms)
{
    unsigned i,tap;
    double sum=0.0,energy=0.0;
    if(!initialized || !interleaved || !output || !rms ||
       input_frames<AUDIO_CAPTURE_FRAMES) return -1;
    for(i=0;i<AUDIO_CLIP_SAMPLES;++i) {
        uint64_t position=(uint64_t)i*AUDIO_RESAMPLE_STEP_NUM;
        long center=(long)(position/AUDIO_RESAMPLE_PHASES);
        unsigned phase=(unsigned)(position%AUDIO_RESAMPLE_PHASES);
        float value=0.0f;
        for(tap=0;tap<AUDIO_RESAMPLE_TAPS;++tap) {
            long n=center+(long)tap-31;
            if(n>=0 && (unsigned long)n<input_frames) {
                int32_t raw=interleaved[(unsigned long)n*AUDIO_CHANNELS+AUDIO_CLASSIFY_CHANNEL];
                raw >>= AUDIO_PCM_RIGHT_SHIFT;
                value+=((float)raw/AUDIO_PCM_FULL_SCALE)*coeff[phase][tap];
            }
        }
        output[i]=value;
        sum+=value;energy+=(double)value*value;
    }
    /* Same RMS expression as desktop InputStream inference (before DC removal). */
    *rms=(float)sqrt(energy/AUDIO_CLIP_SAMPLES+1e-12);
    return 0;
}

#include <string.h>
int audio_resample_stream_init(AudioResampleStream *state)
{
    int ret=audio_resampler_init();
    if(ret!=0 || !state) return -1;
    memset(state,0,sizeof(*state));
    return 0;
}

int audio_resample_stream_push(AudioResampleStream *state,int32_t raw,float *output)
{
    uint64_t position,center;
    unsigned phase,tap;
    float value=0.0f;
    if(!initialized || !state || !output) return -1;
    raw >>= AUDIO_PCM_RIGHT_SHIFT;
    state->history[state->input_count&127U]=(float)raw/AUDIO_PCM_FULL_SCALE;
    ++state->input_count;
    position=state->output_count*AUDIO_RESAMPLE_STEP_NUM;
    center=position/AUDIO_RESAMPLE_PHASES;
    if(center+31>=state->input_count) return 0;
    phase=(unsigned)(position%AUDIO_RESAMPLE_PHASES);
    for(tap=0;tap<63;++tap) {
        int64_t n=(int64_t)center+(int64_t)tap-31;
        if(n>=0) value+=state->history[(uint64_t)n&127U]*coeff[phase][tap];
    }
    *output=value;++state->output_count;
    return 1;
}
