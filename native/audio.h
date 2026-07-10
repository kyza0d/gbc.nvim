#ifndef GBC_AUDIO_H
#define GBC_AUDIO_H

#include <stdbool.h>
#include <stdint.h>

void gbc_audio_start(void);
void gbc_audio_push_sample(int16_t left, int16_t right);
void gbc_audio_stop(void);
bool gbc_audio_is_running(void);

#endif
