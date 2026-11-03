#ifndef CAPTURE_AUDIO_H
#define CAPTURE_AUDIO_H
#include "app_config.h"
void capture_audio_start(void);
int capture_audio_push(const float frame[AUDIO_CHANNELS]);
void capture_audio_dump(void);
#endif
