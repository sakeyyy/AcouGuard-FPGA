#include "audio_mlp.h"

#include <math.h>
#include <stddef.h>
#include <string.h>

#include "kiss_fft.h"

static union {
    double align;
    unsigned char bytes[16384];
} fft_memory;
static kiss_fft_cfg fft_config;
static kiss_fft_cpx fft_input[AUDIO_FFT_SIZE];
static kiss_fft_cpx fft_output[AUDIO_FFT_SIZE];
static float centered[AUDIO_CLIP_SAMPLES];
static unsigned mel_first[AUDIO_MEL_BINS], mel_end[AUDIO_MEL_BINS];
static void (*background_service)(void);
void audio_features_set_service(void (*service)(void)){background_service=service;}

int audio_features_init(void)
{
    size_t required = 0;
    size_t available = sizeof(fft_memory.bytes);
    kiss_fft_alloc(AUDIO_FFT_SIZE, 0, NULL, &required);
    if (required > available) {
        return -1;
    }
    fft_config = kiss_fft_alloc(AUDIO_FFT_SIZE, 0, fft_memory.bytes, &available);
    /* Triangular mel bands are sparse. Keep the original accumulation order. */
    for (unsigned band = 0; band < AUDIO_MEL_BINS; ++band) {
        unsigned bins = AUDIO_FFT_SIZE / 2 + 1;
        unsigned first = 0, end = bins;
        while (first < bins && model_mel_filters[band * bins + first] == 0) ++first;
        while (end > first && model_mel_filters[band * bins + end - 1] == 0) --end;
        mel_first[band] = first;
        mel_end[band] = end;
    }
    return fft_config ? 0 : -1;
}

int audio_extract_features(const float *samples, float features[MLP_FEATURES])
{
    const int bins = AUDIO_FFT_SIZE / 2 + 1;
    double means[AUDIO_MEL_BINS] = {0};
    double m2[AUDIO_MEL_BINS] = {0};
    double deltas[AUDIO_MEL_BINS] = {0};
    float maxima[AUDIO_MEL_BINS];
    float previous[AUDIO_MEL_BINS] = {0};
    float power[AUDIO_FFT_SIZE / 2 + 1];
    double sample_sum = 0;
    float peak = 0;
    float mean;
    int frame_count = 0;
    int i, frame_start, k, band;

    if (!fft_config || !samples || !features) {
        return -1;
    }
    for (i = 0; i < AUDIO_CLIP_SAMPLES; ++i) {
        if (!isfinite(samples[i])) {
            return -2;
        }
        sample_sum += samples[i];
    }
    mean = (float)(sample_sum / AUDIO_CLIP_SAMPLES);
    for (i = 0; i < AUDIO_CLIP_SAMPLES; ++i) {
        centered[i] = samples[i] - mean;
        if (fabsf(centered[i]) > peak) {
            peak = fabsf(centered[i]);
        }
    }
    if (peak > 1.0f) {
        for (i = 0; i < AUDIO_CLIP_SAMPLES; ++i) {
            centered[i] /= peak;
        }
    }

    for (band = 0; band < AUDIO_MEL_BINS; ++band) {
        maxima[band] = -INFINITY;
    }
    for (frame_start = 0; frame_start + AUDIO_FRAME_LENGTH <= AUDIO_CLIP_SAMPLES;
         frame_start += AUDIO_HOP_LENGTH) {
        if(background_service)background_service();
        memset(fft_input, 0, sizeof(fft_input));
        for (i = 0; i < AUDIO_FRAME_LENGTH; ++i) {
            fft_input[i].r = centered[frame_start + i] * model_hann[i];
        }
        kiss_fft(fft_config, fft_input, fft_output);
        for (k = 0; k < bins; ++k) {
            power[k] = fft_output[k].r * fft_output[k].r
                     + fft_output[k].i * fft_output[k].i;
        }
        ++frame_count;
        for (band = 0; band < AUDIO_MEL_BINS; ++band) {
            double energy = 0;
            float value;
            double difference;
            for (k = (int)mel_first[band]; k < (int)mel_end[band]; ++k) {
                energy += (double)power[k] * model_mel_filters[band * bins + k];
            }
            value = logf(fmaxf((float)energy, 1e-10f));
            difference = value - means[band];
            means[band] += difference / frame_count;
            m2[band] += difference * (value - means[band]);
            if (value > maxima[band]) {
                maxima[band] = value;
            }
            if (frame_count > 1) {
                deltas[band] += fabsf(value - previous[band]);
            }
            previous[band] = value;
        }
    }
    for (band = 0; band < AUDIO_MEL_BINS; ++band) {
        features[band] = (float)means[band];
        features[AUDIO_MEL_BINS + band] = (float)sqrt(fmax(m2[band] / frame_count, 0.0));
        features[2 * AUDIO_MEL_BINS + band] = maxima[band];
        features[3 * AUDIO_MEL_BINS + band] = frame_count > 1
            ? (float)(deltas[band] / (frame_count - 1)) : 0.0f;
    }
    return 0;
}

static void dense(const float *input, const float *weights, const float *bias,
                  int input_count, int output_count, float *output, int relu)
{
    int i, j;
    for (j = 0; j < output_count; ++j) {
        double sum = bias[j];
        for (i = 0; i < input_count; ++i) {
            sum += (double)input[i] * weights[i * output_count + j];
        }
        output[j] = relu && sum < 0 ? 0.0f : (float)sum;
    }
}

void audio_mlp_probabilities(const float features[MLP_FEATURES], float scores[MLP_CLASSES])
{
    float normalized[MLP_FEATURES];
    float hidden1[MLP_HIDDEN1], hidden2[MLP_HIDDEN2];
    float maximum, total = 0;
    int i;
    for (i = 0; i < MLP_FEATURES; ++i) {
        normalized[i] = (features[i] - model_scaler_mean[i]) / model_scaler_scale[i];
    }
    dense(normalized, model_weights_0, model_biases_0,
          MLP_FEATURES, MLP_HIDDEN1, hidden1, 1);
    dense(hidden1, model_weights_1, model_biases_1,
          MLP_HIDDEN1, MLP_HIDDEN2, hidden2, 1);
    dense(hidden2, model_weights_2, model_biases_2,
          MLP_HIDDEN2, MLP_CLASSES, scores, 0);
    maximum = scores[0];
    for (i = 1; i < MLP_CLASSES; ++i) {
        maximum = fmaxf(maximum, scores[i]);
    }
    for (i = 0; i < MLP_CLASSES; ++i) {
        scores[i] = expf(scores[i] - maximum);
        total += scores[i];
    }
    for (i = 0; i < MLP_CLASSES; ++i) {
        scores[i] /= total;
    }
}

int audio_select_event(const float scores[MLP_CLASSES], float threshold_scale,
                       float vehicle_minimum)
{
    int i, selected = -1, background = 0;
    float best = -1.0f;
    for (i = 0; i < MLP_CLASSES; ++i) {
        float threshold;
        if (strcmp(model_class_names[i], "background") == 0) {
            background = i;
            continue;
        }
        threshold = model_thresholds[i] * threshold_scale;
        if (strcmp(model_class_names[i], "road_vehicle") == 0) {
            threshold = fmaxf(threshold, vehicle_minimum);
        }
        if (scores[i] >= threshold && scores[i] > best) {
            selected = i;
            best = scores[i];
        }
    }
    return selected >= 0 ? selected : background;
}
