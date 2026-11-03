#ifndef AUDIO_APP_CONFIG_H
#define AUDIO_APP_CONFIG_H
#include "model_data.h"

/* PCB order: CH0=FRONT U1, CH1=LEFT U2, CH2=RIGHT U3, CH3=BACK U4. */
#define AUDIO_CHANNELS 4
/* Legacy batch helper only; the streaming pipeline classifies all 4 channels. */
#define AUDIO_CLASSIFY_CHANNEL 0

/* test.v: 50 MHz / 16 BCLK divider / 64 clocks per I2S frame. */
#define AUDIO_INPUT_RATE_NUM 390625ULL
#define AUDIO_INPUT_RATE_DEN 8ULL
#define AUDIO_RESAMPLE_STEP_NUM 3125U
#define AUDIO_RESAMPLE_PHASES 1024U
#define AUDIO_RESAMPLE_TAPS 63U
#define AUDIO_RESAMPLE_CUTOFF_HZ 8000.0
#define AUDIO_REFERENCE_CLIP_INPUT_FRAMES \
    ((AUDIO_CLIP_SAMPLES * AUDIO_INPUT_RATE_NUM + \
      AUDIO_SAMPLE_RATE * AUDIO_INPUT_RATE_DEN - 1ULL) / \
     (AUDIO_SAMPLE_RATE * AUDIO_INPUT_RATE_DEN))

#if AUDIO_CHANNELS != 4
#error "This package is wired and verified for exactly four microphones."
#endif
#if AUDIO_INPUT_RATE_NUM * AUDIO_RESAMPLE_PHASES != \
    AUDIO_SAMPLE_RATE * AUDIO_INPUT_RATE_DEN * AUDIO_RESAMPLE_STEP_NUM
#error "The input/model rate ratio must match the resampler phase table."
#endif
/* Right-aligned, sign-extended signed 24-bit PCM in each 32-bit DMA word. */
#define AUDIO_PCM_RIGHT_SHIFT 0
#define AUDIO_PCM_FULL_SCALE 8388608.0f
#define AUDIO_MINIMUM_RMS 0.0015f
#define AUDIO_DEFAULT_GAIN 1.0f
#define AUDIO_THRESHOLD_SCALE 0.90f
/* Match detect_fsd50k_sensitive_v2.py defaults, not DS-CNN rules. */
#define AUDIO_EMA_ALPHA 0.60
#define AUDIO_CONFIRM_FRAMES 3
#define AUDIO_CONFIRM_HITS 2
#define AUDIO_RELEASE_FRAMES 4
#define AUDIO_PRINT_ALL_SCORES 1
#define AUDIO_DMA_TIMEOUT_SECONDS 6
/* DMA packets carry raw samples continuously; the classifier updates by the
   MODEL sample clock, not by these rounded raw packet boundaries. */
#define AUDIO_DMA_PACKET_FRAMES 12208U
#define AUDIO_PC_HOP_SAMPLES 4000U
#define AUDIO_PC_WARMUP_SAMPLES 16000U
#define AUDIO_CAPTURE_FRAMES AUDIO_REFERENCE_CLIP_INPUT_FRAMES

#if AUDIO_CLASSIFY_CHANNEL < 0 || AUDIO_CLASSIFY_CHANNEL >= AUDIO_CHANNELS
#error "Check AUDIO_CHANNELS and AUDIO_CLASSIFY_CHANNEL"
#endif

/* Override these if the generated xparameters.h uses different IP names. */
#ifdef SDT
#define AUDIO_DMA_LOOKUP XPAR_XAXIDMA_0_BASEADDR
#define AUDIO_GPIO_LOOKUP XPAR_XGPIO_0_BASEADDR
#else
#define AUDIO_DMA_LOOKUP XPAR_AXIDMA_0_DEVICE_ID
#define AUDIO_GPIO_LOOKUP XPAR_GPIO_0_DEVICE_ID
#endif

#endif
