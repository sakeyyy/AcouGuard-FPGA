/* Full-band model inputs, before gain/display filtering. Recording mode stops
   PL before the slow UART dump; it is deliberately not a live safety mode. */
#include "capture_audio.h"
#include "wave_uart.h"
#include <string.h>
#define FRAMES (4U*AUDIO_SAMPLE_RATE)
static float recorded[FRAMES*AUDIO_CHANNELS];
static unsigned used,active;
static void put32(uint8_t *p,uint32_t value) {
    unsigned j;for(j=0;j<4;++j)p[j]=(uint8_t)(value>>(8*j));
}
void capture_audio_start(void){used=0;active=1;}
int capture_audio_push(const float frame[AUDIO_CHANNELS]) {
    if(!active)return 0;
    memcpy(recorded+used*AUDIO_CHANNELS,frame,AUDIO_CHANNELS*sizeof(float));
    if(++used==FRAMES){active=0;return 1;}
    return 0;
}
void capture_audio_dump(void) {
    uint8_t header[20];uint32_t crc=0xffffffffU;
    const uint8_t *data=(const uint8_t *)recorded;
    unsigned i,j,size=used*AUDIO_CHANNELS*sizeof(float);
    for(i=0;i<size;++i){crc^=data[i];for(j=0;j<8;++j)crc=(crc>>1)^((crc&1U)?0xedb88320U:0U);}
    memcpy(header,"APC2",4);put32(header+4,AUDIO_SAMPLE_RATE);
    put32(header+8,used);put32(header+12,AUDIO_CHANNELS);put32(header+16,crc^0xffffffffU);
    wave_uart_write_blocking(header,sizeof(header));
    wave_uart_write_blocking(data,size);
}
