/* Generated from the trained .npz model. Do not edit. */
#ifndef AUDIO_MODEL_DATA_H
#define AUDIO_MODEL_DATA_H
#define AUDIO_SAMPLE_RATE 16000
#define AUDIO_CLIP_SAMPLES 32000
#define AUDIO_FRAME_LENGTH 400
#define AUDIO_HOP_LENGTH 160
#define AUDIO_FFT_SIZE 512
#define AUDIO_MEL_BINS 40
#define MLP_FEATURES 160
#define MLP_HIDDEN1 128
#define MLP_HIDDEN2 64
#define MLP_CLASSES 9
extern const float model_scaler_mean[160];
extern const float model_scaler_scale[160];
extern const float model_thresholds[9];
extern const float model_hann[400];
extern const float model_mel_filters[10280];
extern const float model_weights_0[20480];
extern const float model_biases_0[128];
extern const float model_weights_1[8192];
extern const float model_biases_1[64];
extern const float model_weights_2[576];
extern const float model_biases_2[9];
extern const char *const model_class_names[MLP_CLASSES];
#endif
