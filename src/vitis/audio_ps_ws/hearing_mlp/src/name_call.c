/* Experimental acoustic templates, deliberately separate from SenseVoice. */
#include "name_call.h"
#include "kiss_fft.h"
#include "wave_uart.h"
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#define RATE 16000U
#define BLOCK 320U
#define MAX_PCM 38400U
#define PRE_BLOCKS 6U
#define TEMPLATES 3
#define INF 1.0e20f
#define PI 3.14159265358979323846f
typedef struct { int n; float x[NC_MAX_FRAMES*NC_DIM]; } Template;
static Template positive[TEMPLATES],negative[TEMPLATES],query;
static unsigned np,nn,channel,chunk_used,pre_count,pre_pos,used,voiced,quiet,wait_blocks;
static unsigned level_blocks;
static unsigned wizard, cal_blocks, gap_blocks, gap_quiet, attempt_blocks;
static unsigned attack, retries, ui_phase, ui_step;
static float cal_energy, dc_x, dc_y;
static int dc_initialized;
#define UI_SET 0U
#define UI_CAL 1U
#define UI_POS 2U
#define UI_POS_REC 3U
#define UI_NEG 4U
#define UI_NEG_REC 5U
#define UI_GAP 6U
#define UI_LISTEN 7U
#define UI_ALERT 8U
#define UI_RETRY 9U
#define UI_FAIL 10U
#define CAL_BLOCKS 100U
#define ATTEMPT_BLOCKS 500U
#define QUIET_BLOCKS 18U
/* 16 kHz continuous DC blocker, about 13 Hz corner. Name branch only. */
#define DC_POLE 0.995f
static int mode4,recording,kind,ready,overlong;
static int pending_key;
static uint32_t now_ms,alert_end,last_hit;
static int had_hit;
static float gate=0.0015f,noise=0.0001f,threshold=1.8f,ratio_limit=0.82f;
static float chunk[BLOCK],pre[PRE_BLOCKS][BLOCK],pcm[MAX_PCM];
static char tag[32]="name";
static void (*service_fn)(void);
static kiss_fft_cfg fft;
static kiss_fft_cpx fin[512],fout[512];
static float hann[400],mel[26][257],dct[12][26];
static float power_spectrum[257],logmel[26],mean[12];
static float rows[2][NC_MAX_FRAMES+1];
static unsigned short steps[2][NC_MAX_FRAMES+1];
static unsigned min_u(unsigned a,unsigned b) {return a<b?a:b;}
static void service(void) {if(service_fn)service_fn();}
static float hzmel(float f) {return 2595.0f*log10f(1.0f+f/700.0f);}
int nc_mfcc(const float *x,unsigned n,float *features)
{
    unsigned f,k,m,c,t;
    int frames;
    if(!fft || !x || !features || n<400 || n>MAX_PCM)return -1;
    frames=1+(int)((n-400)/160);
    if(frames>NC_MAX_FRAMES)return -1;
    memset(mean,0,sizeof(mean));
    for(f=0;f<(unsigned)frames;++f) {
        for(k=0;k<512;++k) {
            unsigned at=f*160+k;
            fin[k].r=k<400?(x[at]-0.97f*(at?x[at-1]:0))*hann[k]:0;
            fin[k].i=0;
        }
        kiss_fft(fft,fin,fout);
        for(k=0;k<257;++k)power_spectrum[k]=fout[k].r*fout[k].r+fout[k].i*fout[k].i;
        for(m=0;m<26;++m) {
            float sum=0;
            for(k=0;k<257;++k)if(mel[m][k]>0)sum+=mel[m][k]*power_spectrum[k];
            logmel[m]=logf(fmaxf(sum,1e-12f));
        }
        for(c=0;c<12;++c) {
            float sum=0;
            for(m=0;m<26;++m)sum+=logmel[m]*dct[c][m];
            features[f*NC_DIM+c]=sum;mean[c]+=sum;
        }
        service();
    }
    /* Cepstral mean normalization removes stationary channel coloration.
       Keep absolute variation; per-utterance variance can amplify noise. */
    for(c=0;c<12;++c)mean[c]/=frames;
    for(f=0;f<(unsigned)frames;++f)
        for(c=0;c<12;++c)features[f*NC_DIM+c]-=mean[c];
    for(f=0;f<(unsigned)frames;++f)for(c=0;c<12;++c) {
        float delta=0;
        for(t=1;t<=2;++t) {
            unsigned lo=f<t?0:f-t,hi=min_u(f+t,frames-1);
            delta+=t*(features[hi*NC_DIM+c]-features[lo*NC_DIM+c]);
        }
        features[f*NC_DIM+12+c]=delta/10.0f;
    }
    return frames;
}
float nc_dtw(const float *a,int na,const float *b,int nb)
{
    int i,j,k;
    if(!a || !b || na<1 || nb<1 || na>NC_MAX_FRAMES || nb>NC_MAX_FRAMES ||
       na>nb*2 || nb>na*2)return INF;
    for(j=0;j<=nb;++j){rows[0][j]=INF;steps[0][j]=0;}
    rows[0][0]=0;
    for(i=1;i<=na;++i) {
        int cur=i&1,prev=cur^1,center=i*nb/na,band=nb/3+8;
        for(j=0;j<=nb;++j){rows[cur][j]=INF;steps[cur][j]=0;}
        for(j=1;j<=nb;++j)if(abs(j-center)<=band) {
            float cost=0,best=rows[prev][j-1];
            unsigned count=steps[prev][j-1];
            if(rows[prev][j]<best){best=rows[prev][j];count=steps[prev][j];}
            if(rows[cur][j-1]<best){best=rows[cur][j-1];count=steps[cur][j-1];}
            for(k=0;k<NC_DIM;++k){float d=a[(i-1)*NC_DIM+k]-b[(j-1)*NC_DIM+k];cost+=d*d/NC_DIM;}
            rows[cur][j]=best+cost;steps[cur][j]=(unsigned short)(count+1);
        }
        service();
    }
    if(rows[na&1][nb]>=INF/2 || !steps[na&1][nb])return INF;
    return sqrtf(rows[na&1][nb]/steps[na&1][nb]);
}
static void reset_segment(void)
{
    recording=overlong=0;
    used=voiced=quiet=chunk_used=pre_count=pre_pos=wait_blocks=0;
    attempt_blocks=attack=0;
}
static void reset_dc(void)
{
    dc_initialized=0;dc_x=dc_y=0;
}
static float nearest(const Template *q,const Template *bank,unsigned count)
{
    float best=INF;unsigned i;
    for(i=0;i<count;++i){float d=nc_dtw(q->x,q->n,bank[i].x,bank[i].n);if(d<best)best=d;}
    return best;
}
static int calibrate(void)
{
    unsigned i,j;float max_pos=0,min_neg=INF;
    ready=0;
    if(np<TEMPLATES || nn<TEMPLATES){wave_uart_printf("Name: need 3 positive and 3 negative templates\r\n");return 0;}
    for(i=0;i<np;++i) {
        float best=INF;
        for(j=0;j<np;++j)if(j!=i){float d=nc_dtw(positive[i].x,positive[i].n,positive[j].x,positive[j].n);if(d<best)best=d;}
        if(best>max_pos)max_pos=best;
    }
    for(i=0;i<nn;++i){float d=nearest(&negative[i],positive,np);if(d<min_neg)min_neg=d;}
    threshold=fmaxf(0.35f,max_pos*1.25f);
    /* Refuse overlapping enrollment instead of silently choosing a lax gate. */
    if(threshold>2.8f || threshold>=min_neg*ratio_limit) {
        wave_uart_printf("Name: calibration_failed pos_max_milli=%u neg_min_milli=%u; CLEAR and re-record\r\n",
                         (unsigned)(max_pos*1000),(unsigned)(fminf(min_neg,1000)*1000));return 0;
    }
    ready=1;
    wave_uart_printf("Name: ready=1 threshold_milli=%u positives=%u negatives=%u\r\n",(unsigned)(threshold*1000),np,nn);
    return 1;
}

static void set_wait_phase(void)
{
    ui_phase=kind==2?UI_NEG:UI_POS;
    ui_step=(kind==2?nn:np)+1U;
}
static void begin_attempt(int next)
{
    kind=next;reset_segment();set_wait_phase();
    wave_uart_printf("Name: %s %u/3 -- speak ONCE, then stay quiet\r\n",
                     next==1?"SAY_NAME":"SAY_OTHER",ui_step);
}
static void abort_attempt(const char *reason)
{
    wave_uart_printf("Name: rejected=%s; no template saved\r\n",reason);
    kind=0;reset_segment();gap_blocks=gap_quiet=0;
    if(wizard && ++retries<=3U)ui_phase=UI_RETRY;
    else {
        wizard=0;ui_phase=UI_FAIL;
        wave_uart_printf("Name: stopped; long KEY1 or NAME:START to restart\r\n");
    }
}
static void arm_next(void)
{
    if(np<TEMPLATES)begin_attempt(1);
    else if(nn<TEMPLATES)begin_attempt(2);
    else {
        wizard=0;kind=0;
        ui_phase=calibrate()?UI_LISTEN:UI_FAIL;
        if(ready)wave_uart_printf("Name: LISTEN -- call the enrolled name\r\n");
    }
}
static void start_wizard(void)
{
    mode4=1;ready=kind=had_hit=0;np=nn=0;alert_end=0;
    wizard=1;cal_blocks=gap_blocks=gap_quiet=retries=0;cal_energy=0;
    noise=.0001f;reset_segment();reset_dc();
    ui_phase=UI_CAL;ui_step=0;
    wave_uart_printf("Name: SETUP -- keep quiet 2 seconds; then 3 NAME + 3 OTHER\r\n");
}
static void finish_segment(void)
{
    int saved_kind=kind;
    if(overlong || voiced<8 || used<2400) {
        abort_attempt(overlong?"too_long":"too_short");return;
    }
    if(quiet>3)used-=(quiet-3)*BLOCK;
    query.n=nc_mfcc(pcm,used,query.x);
    if(query.n<1){abort_attempt("features");return;}
    if(kind) {
        Template *dst=kind==1?positive:negative;
        unsigned *count=kind==1?&np:&nn;
        if(*count>=TEMPLATES){abort_attempt("bank_full");return;}
        dst[*count]=query;++*count;ready=0;ui_step=*count;
        wave_uart_printf("Name: enrolled=%s positive=%u negative=%u frames=%d\r\n",
                         kind==1?"positive":"negative",np,nn,query.n);
        kind=0;reset_segment();retries=0;
        if(wizard) {
            ui_phase=UI_GAP;gap_blocks=gap_quiet=0;
            if(np==TEMPLATES && nn==TEMPLATES)arm_next();
        } else {
            ui_phase=UI_SET;
            if(np==TEMPLATES && nn==TEMPLATES)
                ui_phase=calibrate()?UI_LISTEN:UI_FAIL;
        }
        (void)saved_kind;
        return;
    }
    if(ready) {
        float p=nearest(&query,positive,np),n=nearest(&query,negative,nn);
        int hit=p<=threshold && p<ratio_limit*n;
        if(had_hit && (uint32_t)(now_ms-last_hit)<3000U)hit=0;
        wave_uart_printf("NameScore: pos_milli=%u neg_milli=%u threshold_milli=%u hit=%d channel=%u\r\n",
                         (unsigned)(fminf(p,1000)*1000),(unsigned)(fminf(n,1000)*1000),
                         (unsigned)(threshold*1000),hit,channel);
        if(hit) {
            had_hit=1;last_hit=now_ms;alert_end=now_ms+2000U;
            wave_uart_printf("NameAlert: tag=%s channel=%u acoustic_template_match\r\n",tag,channel);
        }
        reset_segment();ui_phase=UI_LISTEN;
    }
}
static void status(void)
{
    wave_uart_printf("NameStatus: mode=%d ready=%d positive=%u negative=%u recording_kind=%d channel=%u gate_u=%u tag=%s wizard=%u phase=%u step=%u\r\n",
        mode4?4:123,ready,np,nn,kind,channel,(unsigned)(gate*1000000),tag,wizard,ui_phase,ui_step);
}
int nc_init(void (*service_cb)(void))
{
    unsigned i,m,k,c;float points[28];
    service_fn=service_cb;
    if(!fft)fft=kiss_fft_alloc(512,0,0,0);
    if(!fft)return -1;
    for(i=0;i<400;++i)hann[i]=0.5f-0.5f*cosf(2*PI*i/399);
    for(i=0;i<28;++i){float v=hzmel(300)+(hzmel(7600)-hzmel(300))*i/27;points[i]=700*(powf(10,v/2595)-1);}
    for(m=0;m<26;++m)for(k=0;k<257;++k) {
        float hz=(float)k*RATE/512;
        mel[m][k]=fmaxf(0,fminf((hz-points[m])/(points[m+1]-points[m]),(points[m+2]-hz)/(points[m+2]-points[m+1])));
    }
    for(c=0;c<12;++c)for(m=0;m<26;++m)dct[c][m]=sqrtf(2.0f/26)*cosf(PI*(c+1)*(m+0.5f)/26);
    mode4=kind=ready=had_hit=pending_key=0;np=nn=channel=level_blocks=0;
    now_ms=alert_end=0;noise=.0001f;gate=.0015f;
    wizard=cal_blocks=gap_blocks=gap_quiet=retries=0;
    ui_phase=UI_SET;ui_step=0;strcpy(tag,"name");
    reset_segment();reset_dc();return 0;
}
int nc_mode(void){return mode4;}
void nc_tick(uint32_t ms){now_ms=ms;}
uint32_t nc_control_bits(void)
{
    uint32_t bits,phase=ui_phase;
    if(!mode4)return 0;
    bits=NC_MODE_BIT | (ready?NC_READY_BIT:0) | (kind?NC_RECORD_BIT:0);
    if(alert_end && (int32_t)(alert_end-now_ms)>0){bits|=NC_ALERT_BIT;phase=UI_ALERT;}
    return bits | ((phase&15U)<<18) | ((ui_step&3U)<<22);
}
void nc_command(const char *line)
{
    if(!strcmp(line,"NAME:START")){start_wizard();return;}
    if(!strcmp(line,"MODE:4") || !strcmp(line,"MODE:123")) {
        mode4=!strcmp(line,"MODE:4");kind=0;wizard=0;alert_end=0;
        reset_segment();reset_dc();ui_phase=ready?UI_LISTEN:UI_SET;status();
    } else if(!strcmp(line,"NAME:STOP")) {
        wizard=0;kind=0;reset_segment();ui_phase=ready?UI_LISTEN:UI_SET;status();
    } else if(!strcmp(line,"NAME:CLEAR")) {
        np=nn=0;ready=kind=had_hit=0;wizard=0;alert_end=0;
        reset_segment();ui_phase=UI_SET;ui_step=0;status();
    } else if(!strcmp(line,"NAME:POS") || !strcmp(line,"NAME:NEG")) {
        int next=!strcmp(line,"NAME:POS")?1:2;
        if((next==1?np:nn)>=TEMPLATES){wave_uart_printf("Name: bank_full; CLEAR before re-enrolling\r\n");return;}
        mode4=1;wizard=0;alert_end=0;begin_attempt(next);
    } else if(!strcmp(line,"NAME:ARM")) {
        wizard=0;kind=0;reset_segment();ui_phase=calibrate()?UI_LISTEN:UI_FAIL;status();
    } else if(!strcmp(line,"NAME:STATUS"))status();
    else if(!strncmp(line,"NAME:CH:",8)) {
        char *end;long n=strtol(line+8,&end,10);
        if(*end || n<0 || n>3){wave_uart_printf("Name: invalid_channel\r\n");return;}
        channel=(unsigned)n;kind=0;wizard=0;reset_segment();reset_dc();
        ui_phase=ready?UI_LISTEN:UI_SET;status();
    } else if(!strncmp(line,"NAME:TAG:",9)) {
        size_t n=strlen(line+9);
        if(n && n<sizeof(tag)){memcpy(tag,line+9,n+1);status();}
    } else if(!strncmp(line,"NAME:GATE:",10)) {
        char *end;long n=strtol(line+10,&end,10);
        if(*end || n<300 || n>50000){wave_uart_printf("Name: gate_range_300_to_50000_u\r\n");return;}
        gate=n/1000000.0f;wizard=0;kind=0;reset_segment();
        ui_phase=ready?UI_LISTEN:UI_SET;status();
    }
}
void nc_key(int long_press)
{
    if(!pending_key)pending_key=long_press?2:1;
}
void nc_dispatch_key(void)
{
    int event=pending_key;
    if(!event)return;
    pending_key=0;
    if(event==2)start_wizard();
    else nc_command(mode4?"MODE:123":"MODE:4");
}
static void remember_block(void)
{
    memcpy(pre[pre_pos],chunk,sizeof(chunk));pre_pos=(pre_pos+1)%PRE_BLOCKS;
    if(pre_count<PRE_BLOCKS)++pre_count;
}
void nc_feed(const float channels[4])
{
    unsigned i;float energy=0,rms,on,off,x,y;
    if(!mode4)return;
    x=channels[channel];
    if(!isfinite(x)){abort_attempt("invalid_sample");reset_dc();return;}
    if(!dc_initialized){dc_x=x;dc_y=0;dc_initialized=1;}
    y=x-dc_x+DC_POLE*dc_y;dc_x=x;dc_y=y;
    chunk[chunk_used++]=y;
    if(chunk_used<BLOCK)return;
    chunk_used=0;
    for(i=0;i<BLOCK;++i)energy+=chunk[i]*chunk[i];
    rms=sqrtf(energy/BLOCK);
    on=fmaxf(gate,noise*3.0f+.0004f);
    off=fmaxf(gate*.6f,noise*1.7f+.0002f);
    if(++level_blocks>=50) {
        level_blocks=0;
        wave_uart_printf("NameLevel: ac_rms_u=%u noise_u=%u start_u=%u stop_u=%u recording=%d phase=%u\r\n",
            (unsigned)(rms*1000000),(unsigned)(noise*1000000),
            (unsigned)(on*1000000),(unsigned)(off*1000000),recording,ui_phase);
    }
    if(wizard && ui_phase==UI_CAL) {
        cal_energy+=energy/BLOCK;
        if(++cal_blocks>=CAL_BLOCKS) {
            noise=fmaxf(.0001f,sqrtf(cal_energy/CAL_BLOCKS));
            if(noise>.02f){abort_attempt("calibration_too_loud");wizard=0;ui_phase=UI_FAIL;}
            else {wave_uart_printf("Name: quiet calibrated ac_noise_u=%u\r\n",(unsigned)(noise*1000000));arm_next();}
        }
        return;
    }
    if(wizard && (ui_phase==UI_GAP || ui_phase==UI_RETRY)) {
        ++gap_blocks;
        if(rms<off)++gap_quiet;else gap_quiet=0;
        if(gap_blocks>=50 && gap_quiet>=QUIET_BLOCKS)arm_next();
        else if(gap_blocks>=150) {
            wizard=0;kind=0;ui_phase=UI_FAIL;
            wave_uart_printf("Name: stopped=continuous_noise; keep quiet then restart setup\r\n");
        }
        return;
    }
    if(!kind && !ready)return;
    /* Count waiting AND recording time. Never wait indefinitely for silence. */
    if(kind && ++attempt_blocks>=ATTEMPT_BLOCKS){abort_attempt("attempt_timeout_10s");return;}
    if(!recording) {
        if(rms<off)noise=fmaxf(.0001f,noise*.999f+rms*.001f);
        if(rms>=on)++attack;else attack=0;
        if(attack>=3) {
            recording=1;used=0;voiced=attack-1;quiet=0;
            if(kind)ui_phase=kind==1?UI_POS_REC:UI_NEG_REC;
            for(i=0;i<pre_count;++i) {
                unsigned slot=(pre_pos+PRE_BLOCKS-pre_count+i)%PRE_BLOCKS;
                memcpy(pcm+used,pre[slot],sizeof(chunk));used+=BLOCK;
            }
        } else {remember_block();return;}
    }
    if(rms>=off){++voiced;quiet=0;}else ++quiet;
    if(used+BLOCK>MAX_PCM){abort_attempt("too_long_2p4s");return;}
    memcpy(pcm+used,chunk,sizeof(chunk));used+=BLOCK;
    if(quiet>=QUIET_BLOCKS)finish_segment();
}
