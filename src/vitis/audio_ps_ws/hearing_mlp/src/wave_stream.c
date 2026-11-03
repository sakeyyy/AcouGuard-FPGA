#include "wave_stream.h"
#include <math.h>
#include <string.h>
#define TAPS 255
#define FRAMES 256
#define PI 3.14159265358979323846
static float coefficients[TAPS], history[4][TAPS];
static uint8_t payload[FRAMES*4*2];
static unsigned position, phase, used, factor, channels, selected, next_flags;
static uint32_t numerator, denominator, sequence;
static wave_write_fn output;
static void put16(uint8_t *p, uint16_t x) { p[0]=(uint8_t)x;p[1]=(uint8_t)(x>>8); }
static void put32(uint8_t *p, uint32_t x) { unsigned i;for(i=0;i<4;++i)p[i]=(uint8_t)(x>>(8*i)); }
static uint32_t crc32(const uint8_t *p, unsigned n) {
    uint32_t crc=0xffffffffU;unsigned i,j;
    for(i=0;i<n;++i){crc^=p[i];for(j=0;j<8;++j)crc=(crc>>1)^((crc&1)?0xedb88320U:0);}
    return crc^0xffffffffU;
}
int wave_init(uint32_t num,uint32_t den,unsigned decimation,unsigned count,
              unsigned channel,wave_write_fn writer) {
    unsigned i;double sum=0,fs,fc;
    if(!num||!den||!decimation||!writer||(count!=1&&count!=4)||channel>3)return -1;
    fs=(double)num/den;
    if(fs/decimation<2500||fs/decimation>8000)return -2;
    /* Display bandwidth is 1 kHz; filtering happens BEFORE decimation. */
    fc=1000.0/fs;
    for(i=0;i<TAPS;++i){double t=(double)i-(TAPS-1)*0.5;
        double h=fabs(t)<1e-12?2*fc:sin(2*PI*fc*t)/(PI*t);
        coefficients[i]=(float)(h*(0.54-0.46*cos(2*PI*i/(TAPS-1))));sum+=coefficients[i];}
    for(i=0;i<TAPS;++i)coefficients[i]=(float)(coefficients[i]/sum);
    numerator=num;denominator=den*decimation;factor=decimation;
    channels=count;selected=channel;output=writer;sequence=0;used=0;
    wave_begin(2);
    return 0;
}
void wave_begin(unsigned flags) {
    wave_flush();memset(history,0,sizeof(history));position=phase=0;next_flags=flags|1U;
}
void wave_flush(void) {
    uint8_t packet[28+FRAMES*4*2+4]={0};unsigned size;
    uint8_t *header=packet;
    if(!used||!output)return;
    size=used*channels*2;memcpy(header,"ASW1",4);header[4]=1;header[5]=(uint8_t)channels;
    put16(header+6,(uint16_t)next_flags);put32(header+8,numerator);put32(header+12,denominator);
    put16(header+16,(uint16_t)used);put32(header+20,sequence++);put32(header+24,size);
    memcpy(packet+28,payload,size);put32(packet+28+size,crc32(payload,size));
    output(packet,28+size+4);
    used=0;next_flags&=~2U;
}
static void frame(const float *x) {
    unsigned ch,j;
    for(ch=0;ch<channels;++ch)history[ch][position]=x[ch];
    if(++phase==factor){phase=0;
        for(ch=0;ch<channels;++ch){float y=0;unsigned k=position;
            for(j=0;j<TAPS;++j){y+=coefficients[j]*history[ch][k];k=k?k-1:TAPS-1;}
            if(y>32767.0f/32768.0f)y=32767.0f/32768.0f;
            if(y< -1)y=-1;
            put16(payload+(used*channels+ch)*2,(uint16_t)(int16_t)lrintf(y*32768.0f));}
        if(++used==FRAMES)wave_flush();}
    if(++position==TAPS)position=0;
}
void wave_push_pcm24(const int32_t *pcm,unsigned frames) {
    unsigned i,ch;float x[4];
    for(i=0;i<frames;++i){
        for(ch=0;ch<channels;++ch){
            x[ch]=(float)pcm[i*4+(channels==1?selected:ch)]/8388608.0f;
        }
        frame(x);
    }
}
void wave_push_float(const float *pcm,unsigned frames) {
    unsigned i;if(channels!=1)return;
    for(i=0;i<frames;++i)frame(pcm+i);
}
