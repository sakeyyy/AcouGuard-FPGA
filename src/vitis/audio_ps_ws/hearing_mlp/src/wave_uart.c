#include "wave_uart.h"
#include "xuartps.h"
#include "xuartps_hw.h"
#include "xparameters.h"
#include <stdarg.h>
#include <stdio.h>
#define TX_CAPACITY 16384U
static uint8_t tx[TX_CAPACITY];
static unsigned head,tail,used,dropped,high_water;
static XUartPs uart;
int wave_uart_init(void) {
    XUartPs_Config *cfg;
#ifdef SDT
    cfg=XUartPs_LookupConfig(WAVE_UART_BASE);
#else
    cfg=XUartPs_LookupConfig(XPAR_XUARTPS_1_DEVICE_ID);
#endif
    if(!cfg)return -1;
    if(XUartPs_CfgInitialize(&uart,cfg,WAVE_UART_BASE)!=XST_SUCCESS)return -2;
    if(XUartPs_SetBaudRate(&uart,WAVE_UART_BAUD)!=XST_SUCCESS)return -3;
    XUartPs_SetOperMode(&uart,XUARTPS_OPER_MODE_NORMAL);
    head=tail=used=dropped=high_water=0;
    return 0;
}
void wave_uart_write(const uint8_t *data,unsigned size) {
    unsigned i;
    wave_uart_poll();
    /* A complete waveform packet is queued or dropped atomically. Never
       block the DMA/classifier on a slow display transport. */
    if(size>TX_CAPACITY-used){++dropped;return;}
    for(i=0;i<size;++i){tx[head]=data[i];head=(head+1U)%TX_CAPACITY;}
    used+=size;if(used>high_water)high_water=used;
}
void wave_uart_poll(void) {
    unsigned sent=0;
    while(used && sent<64U &&
          !(XUartPs_ReadReg(WAVE_UART_BASE,XUARTPS_SR_OFFSET)&XUARTPS_SR_TXFULL)) {
        XUartPs_WriteReg(WAVE_UART_BASE,XUARTPS_FIFO_OFFSET,tx[tail]);
        tail=(tail+1U)%TX_CAPACITY;--used;++sent;
    }
}
void wave_uart_drain(void) {while(used)wave_uart_poll();}
void wave_uart_write_blocking(const uint8_t *data,unsigned size) {
    unsigned i;wave_uart_drain();
    for(i=0;i<size;++i)XUartPs_SendByte(WAVE_UART_BASE,data[i]);
}
void wave_uart_printf(const char *format,...) {
    char text[512];va_list args;int n;
    va_start(args,format);n=vsnprintf(text,sizeof(text),format,args);va_end(args);
    if(n>0)wave_uart_write((const uint8_t *)text,(unsigned)n<sizeof(text)?(unsigned)n:sizeof(text)-1U);
}
unsigned wave_uart_dropped(void){return dropped;}
unsigned wave_uart_high_water(void){return high_water;}

int wave_uart_try_read(uint8_t *byte) {
    if(!byte || !XUartPs_IsReceiveData(WAVE_UART_BASE))return 0;
    *byte=(uint8_t)XUartPs_ReadReg(WAVE_UART_BASE,XUARTPS_FIFO_OFFSET);
    return 1;
}
