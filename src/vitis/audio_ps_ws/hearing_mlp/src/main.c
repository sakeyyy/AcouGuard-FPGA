/* OPT1: four independent PC-style classifiers, CH0 waveform, screen control.
   Requires the matching 12208-frame STREAM packetizer, not burst RTL. */
#include <stdint.h>
#include "xparameters.h"
#include "xaxidma.h"
#include "xaxidma_hw.h"
#include "xgpio.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include "sleep.h"
#ifdef SDT
#include "xiltimer.h"
#else
#include "xtime_l.h"
#endif
#include "app_config.h"
#include "audio_resample.h"
#include "audio_pipeline.h"
#include "audio_mlp.h"
#include "wave_stream.h"
#include "wave_uart.h"
#include "screen_control.h"
#include "capture_audio.h"
#include "name_call.h"
#include "name_key.h"
/* Text and PCM must share one ordered queue, never interleave bytes. */
#define xil_printf wave_uart_printf

#define DMA_WORDS (AUDIO_DMA_PACKET_FRAMES*AUDIO_CHANNELS)
#define DMA_BYTES (DMA_WORDS*sizeof(int32_t))
#define STATUS_OVERFLOW (1U<<2)
#define STATUS_STREAM (1U<<3)
#define STATUS_BUILD_MASK 0x0000fe00U
#define STATUS_BUILD_EXPECT 0x00006c00U
static int32_t buffers[2][DMA_WORDS] __attribute__((aligned(64)));
static XAxiDma dma;
static XGpio gpio;
static AudioResampleStream resamplers[AUDIO_CHANNELS];
static uint32_t ps_control;
static int wave_enabled=1;
static int telemetry_due;
static unsigned max_infer_us,max_packet_us;
#define SCREEN_ICON_BIT (1U<<13)
static void service_io(void)
{
    XTime now;
    wave_uart_poll();
    XTime_GetTime(&now);
    nc_tick((uint32_t)(now*1000ULL/COUNTS_PER_SECOND));
    name_key_poll((uint32_t)(now*1000ULL/COUNTS_PER_SECOND));
}
static void service_controls(void)
{
    static int previous_mode;
    uint32_t value;
    service_io();
    nc_dispatch_key();
    if(previous_mode!=nc_mode()) {
        audio_pipeline_init(); /* Discard stale rolling audio and decisions. */
        previous_mode=nc_mode();
        ps_control &= ~(0x1f00U|2U);
        xil_printf("Mode: %s\r\n",previous_mode?"name_call":"functions_123");
    }
    value=(ps_control&~NC_CONTROL_MASK)|nc_control_bits();
    if(nc_mode())value&=~SCREEN_ICON_BIT;
    if(value!=ps_control){ps_control=value;XGpio_DiscreteWrite(&gpio,1,ps_control);}
}
static void name_serial_feed(uint8_t byte)
{
    static char line[80];static unsigned used;static int discard;
    if(byte=='\r')return;
    if(byte=='\n') {
        if(!discard){line[used]=0;nc_command(line);}
        used=0;discard=0;return;
    }
    if(byte<32 || byte>126 || used>=sizeof(line)-1){discard=1;return;}
    if(!discard)line[used++]=(char)byte;
}
static void poll_screen_commands(void)
{
    unsigned count;
    uint8_t byte;
    for(count=0;count<32 && wave_uart_try_read(&byte);++count) {
        name_serial_feed(byte);
        int request=screen_command_feed(byte);
        if(request<0)continue;
        if(request<2) {
            ps_control=(ps_control&~SCREEN_ICON_BIT)|(request?SCREEN_ICON_BIT:0U);
            XGpio_DiscreteWrite(&gpio,1,ps_control);
        }
        if(request<=2) {
            xil_printf("Screen: %s\r\n",(ps_control&SCREEN_ICON_BIT)?"icon":"direction");
        } else if(request>=10 && request<=13) {
            unsigned gain=1U<<(request-10);
            audio_pipeline_set_gain((float)gain);
            xil_printf("Control: gain=%u\r\n",gain);
        } else if(request==20 || request==21) {
            wave_enabled=request==21;
            /* Finish the old segment before toggling display only. */
            wave_begin(2);
            xil_printf("Control: wave=%d\r\n",wave_enabled);
        } else if(request==30) {
            if(nc_mode()){xil_printf("Control: exit_mode4_before_debug_capture\r\n");continue;}
            capture_audio_start();
            xil_printf("Control: recording=4s channels=4; capture stops for UART dump\r\n");
        }
    }
    service_controls();
}

static int initialize(void)
{
    XAxiDma_Config *dc;
    XGpio_Config *gc;
    uint32_t status;
    int ret;
    Xil_ICacheEnable();
    Xil_DCacheEnable();
    /* Start XilTimer's default global counter before GetTime/timeouts. */
    usleep(1000);
    dc=XAxiDma_LookupConfig(AUDIO_DMA_LOOKUP);
    gc=XGpio_LookupConfig(AUDIO_GPIO_LOOKUP);
    if(!dc || !gc) return -1;
    ret=XAxiDma_CfgInitialize(&dma,dc);
    if(ret!=XST_SUCCESS || XAxiDma_HasSg(&dma)) return -2;
    if(XGpio_CfgInitialize(&gpio,gc,gc->BaseAddress)!=XST_SUCCESS) return -3;
    XGpio_SetDataDirection(&gpio,1,0);XGpio_SetDataDirection(&gpio,2,0xffffffffU);
    ps_control=0;XGpio_DiscreteWrite(&gpio,1,0);
    status=XGpio_DiscreteRead(&gpio,2);
    if(!(status&STATUS_STREAM) || (status>>16)!=AUDIO_DMA_PACKET_FRAMES ||
       (status&STATUS_BUILD_MASK)!=STATUS_BUILD_EXPECT) {
        xil_printf("WRONG HARDWARE status=0x%08x expected build=0x36 stream=1 packet_frames=%d\r\n",
                   (unsigned int)status,(int)AUDIO_DMA_PACKET_FRAMES);
        return -4;
    }
    XAxiDma_IntrDisable(&dma,XAXIDMA_IRQ_ALL_MASK,XAXIDMA_DEVICE_TO_DMA);
    for(unsigned ch=0;ch<AUDIO_CHANNELS;++ch)
        if(audio_resample_stream_init(&resamplers[ch])!=0)return -5;
    return audio_pipeline_init();
}
static int start_dma(unsigned index)
{
    Xil_DCacheFlushRange((UINTPTR)buffers[index],DMA_BYTES);
    return XAxiDma_SimpleTransfer(&dma,(UINTPTR)buffers[index],DMA_BYTES,XAXIDMA_DEVICE_TO_DMA);
}
static int wait_dma(uint32_t *status)
{
    XTime start,now;
    XTime_GetTime(&start);
    while(XAxiDma_Busy(&dma,XAXIDMA_DEVICE_TO_DMA)) {
        wave_uart_poll();
        poll_screen_commands();
        uint32_t sr=XAxiDma_ReadReg(dma.RegBase,XAXIDMA_RX_OFFSET+XAXIDMA_SR_OFFSET);
        *status=XGpio_DiscreteRead(&gpio,2);
        if(*status&STATUS_OVERFLOW) return -1;
        if(sr&XAXIDMA_ERR_ALL_MASK) {
            xil_printf("DMA ERROR SR=0x%08x\r\n",(unsigned int)sr);return -2;
        }
        XTime_GetTime(&now);
        if(now-start>(XTime)COUNTS_PER_SECOND*AUDIO_DMA_TIMEOUT_SECONDS) {
            /* Read before the caller disables capture. Do not extend timeout
               to conceal an old one-shot packetizer or broken stream. */
            xil_printf("TIMEOUT control=0x%08x pl_status=0x%08x dma_sr=0x%08x\r\n",
                (unsigned int)XGpio_DiscreteRead(&gpio,1),
                (unsigned int)*status,(unsigned int)sr);
            return -3;
        }
    }
    *status=XGpio_DiscreteRead(&gpio,2);
    return (*status&STATUS_OVERFLOW)?-1:0;
}
/* Report the confirmed event, not an unstable raw candidate.
   Class changes are reported immediately. A one-second heartbeat lets a
   reconnecting viewer recover the current confirmed category. */
static void print_result(const AudioPipelineResult *r)
{
    static int last_label=-1;
    static uint64_t last_report_samples=0;
    int label=r->decision.active_label;
    if(label<0 || label>=MLP_CLASSES) {
        xil_printf("Invalid sound label: %d\r\n",label);
        return;
    }
    /* Reannounce once per second so reconnecting the web page recovers state. */
    if(label==last_label && r->samples_seen-last_report_samples<AUDIO_SAMPLE_RATE) return;
    last_label=label;
    last_report_samples=r->samples_seen;
    xil_printf("Sound: %s\r\n",model_class_names[label]);
}
static unsigned elapsed_us(XTime start)
{
    XTime now;XTime_GetTime(&now);
    return (unsigned)((now-start)*1000000ULL/COUNTS_PER_SECOND);
}
static void report_diagnostics(const AudioPipelineResult *r)
{
    int ch,i;
    /* Integers only: one ppm is 0.000001 full scale; scores are permille. */
    for(ch=0;ch<AUDIO_CHANNELS;++ch) {
        const AudioChannelResult *c=&r->channels[ch];int top=0;
        for(i=1;i<MLP_CLASSES;++i)if(c->current_scores[i]>c->current_scores[top])top=i;
        xil_printf("Diag: ch=%d rms_u=%u peak_u=%u gain=%u gate=%d top=%s p=%u dog=%u horn=%u vehicle=%u impact=%u candidate=%d active=%d\r\n",
            ch,(unsigned)(c->input_rms*1000000),(unsigned)(c->peak*1000000),
            (unsigned)c->gain,c->decision.gated,model_class_names[top],
            (unsigned)(c->current_scores[top]*1000),
            (unsigned)(c->smoothed_scores[4]*1000),(unsigned)(c->smoothed_scores[2]*1000),
            (unsigned)(c->smoothed_scores[7]*1000),(unsigned)(c->smoothed_scores[6]*1000),
            c->decision.candidate_label,c->decision.active_label);
    }
    xil_printf("Perf: infer_us=%u packet_us=%u budget_us=250019 selected_ch=%d tx_drop=%u tx_high=%u\r\n",
        max_infer_us,max_packet_us,r->selected_channel,wave_uart_dropped(),wave_uart_high_water());
    max_infer_us=max_packet_us=0;
}
int main(void)
{
    unsigned current=0,packets=0;
    int ret;
    static AudioPipelineResult result;
    if(wave_uart_init()!=0)return 10;
    xil_printf("\r\nAX7021 FOUR FUNCTIONS: MLP + experimental MFCC/DTW NAME, HW36\r\n");
    ret=initialize();
    if(ret!=0) {xil_printf("Init failed %d\r\n",ret);wave_uart_drain();return 1;}
    audio_features_set_service(service_io);
    if(nc_init(service_io)!=0){xil_printf("Name init failed\r\n");wave_uart_drain();return 12;}
    name_key_init(); /* Serial commands remain available if MIO11 is not GPIO. */
    /* Display branch only: 16k mono -> lowpass -> 4k PCM16.
       All four classifiers receive full-band 16k samples independently. */
    if(wave_init(16000U,1U,4U,1U,0U,wave_uart_write)!=0) {
        xil_printf("WAVE filter init failed\r\n");wave_uart_drain();return 11;
    }
    xil_printf("Screen: direction\r\n");
    xil_printf("Ready. Warming up...\r\n");
    if(start_dma(current)!=XST_SUCCESS) {
        xil_printf("DMA rearm failed at startup\r\n");wave_uart_drain();return 2;
    }
    ps_control=1;XGpio_DiscreteWrite(&gpio,1,ps_control);
    for(;;) {
        unsigned next=current^1U,frame;
        uint32_t status;
        XTime packet_start;
        ret=wait_dma(&status);
        if(ret!=0) {
            XGpio_DiscreteWrite(&gpio,1,0);
            xil_printf("CAPTURE FAILED %d packet=%d status=0x%08x. No silent sample dropping; reset and repair.\r\n",ret,(int)packets,(unsigned int)status);
            wave_uart_drain();
            return 3;
        }
        Xil_DCacheInvalidateRange((UINTPTR)buffers[current],DMA_BYTES);
        /* Rearm the OTHER buffer before feature/model work. PL enable stays 1. */
        if(start_dma(next)!=XST_SUCCESS) {
            XGpio_DiscreteWrite(&gpio,1,0);xil_printf("DMA rearm failed\r\n");wave_uart_drain();return 4;
        }
        XTime_GetTime(&packet_start);
        for(frame=0;frame<AUDIO_DMA_PACKET_FRAMES;++frame) {
            float samples[AUDIO_CHANNELS];int produced=-1;
            unsigned ch;
            for(ch=0;ch<AUDIO_CHANNELS;++ch) {
                ret=audio_resample_stream_push(&resamplers[ch],buffers[current][frame*4+ch],&samples[ch]);
                if(ret<0 || (produced>=0 && ret!=produced)) {
                    XGpio_DiscreteWrite(&gpio,1,0);xil_printf("Resampler sync failure\r\n");wave_uart_drain();return 5;
                }
                produced=ret;
            }
            if(ret==1) {
                int due;
                if(capture_audio_push(samples)) {
                    XGpio_DiscreteWrite(&gpio,1,0);
                    wave_flush();wave_uart_drain();capture_audio_dump();
                    xil_printf("Control: recording_done restart_ELF_to_resume\r\n");wave_uart_drain();return 0;
                }
                nc_feed(samples);
                due=nc_mode()?0:audio_pipeline_feed_frame(samples);
                if(due<0) {
                    XGpio_DiscreteWrite(&gpio,1,0);xil_printf("Inference failed feed=%d\r\n",due);
                    wave_uart_drain();return 6;
                }
                if(due==1) {
                    XTime infer_start;unsigned duration;
                    XTime_GetTime(&infer_start);
                    ret=audio_pipeline_infer(&result);
                    duration=elapsed_us(infer_start);if(duration>max_infer_us)max_infer_us=duration;
                    if(ret!=0) {XGpio_DiscreteWrite(&gpio,1,0);xil_printf("Inference failed %d\r\n",ret);wave_uart_drain();return 7;}
                    ps_control=(ps_control&(SCREEN_ICON_BIT|NC_CONTROL_MASK))|1U|(1U<<12)|((uint32_t)result.decision.active_label<<8)|(result.decision.alarm?2U:0U);
                    XGpio_DiscreteWrite(&gpio,1,ps_control);
                    print_result(&result);
                    if(result.samples_seen%AUDIO_SAMPLE_RATE==0)telemetry_due=1;
                }
                /* Never reset the display FIR at DMA packet boundaries.
                   Called after model feed/inference; does not change samples. */
                if(wave_enabled)wave_push_float(&samples[0],1U);
            }
            if((frame&127U)==0){wave_uart_poll();poll_screen_commands();}
        }
        {
            unsigned duration=elapsed_us(packet_start);
            if(duration>max_packet_us)max_packet_us=duration;
            if(duration>250019U)xil_printf("WARNING: processing_over_budget_us=%u\r\n",duration);
        }
        if(telemetry_due){report_diagnostics(&result);telemetry_due=0;}
        wave_uart_poll();
        ++packets;
        current=next;
    }
}
