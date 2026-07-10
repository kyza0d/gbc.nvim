#define MINIAUDIO_IMPLEMENTATION
#include "audio.h"

#include <stdlib.h>
#include <string.h>

#include "vendor/miniaudio/miniaudio.h"

#define AUDIO_SAMPLE_RATE 44100
#define AUDIO_RING_SIZE 4096

struct stereo_sample {
  int16_t left;
  int16_t right;
};

static struct {
  struct stereo_sample ring[AUDIO_RING_SIZE];
  uint32_t write_pos;
  uint32_t read_pos;
  ma_device device;
  bool running;
} audio_state;

static void audio_callback(ma_device *device, void *output, const void *input, ma_uint32 frame_count) {
  (void)device;
  (void)input;

  int16_t *out = (int16_t *)output;

  for (ma_uint32 i = 0; i < frame_count; i++) {
    uint32_t w = __atomic_load_n(&audio_state.write_pos, __ATOMIC_ACQUIRE);

    if (audio_state.read_pos != w) {
      struct stereo_sample *s = &audio_state.ring[audio_state.read_pos];
      out[i * 2] = s->left;
      out[i * 2 + 1] = s->right;
      audio_state.read_pos = (audio_state.read_pos + 1) & (AUDIO_RING_SIZE - 1);
    }
    else {
      out[i * 2] = 0;
      out[i * 2 + 1] = 0;
    }
  }

  __atomic_thread_fence(__ATOMIC_RELEASE);
}

void gbc_audio_start(void) {
  if (audio_state.running) {
    return;
  }

  memset(&audio_state, 0, sizeof(audio_state));

  ma_device_config config = ma_device_config_init(ma_device_type_playback);
  config.playback.format = ma_format_s16;
  config.playback.channels = 2;
  config.sampleRate = AUDIO_SAMPLE_RATE;
  config.dataCallback = audio_callback;

  if (ma_device_init(NULL, &config, &audio_state.device) != MA_SUCCESS) {
    fprintf(stderr, "[gbc-native][audio] failed to init audio device\n");
    return;
  }

  if (ma_device_start(&audio_state.device) != MA_SUCCESS) {
    fprintf(stderr, "[gbc-native][audio] failed to start audio device\n");
    ma_device_uninit(&audio_state.device);
    return;
  }

  audio_state.running = true;
  fprintf(stderr, "[gbc-native][audio] started (%u Hz, stereo)\n", AUDIO_SAMPLE_RATE);
}

void gbc_audio_push_sample(int16_t left, int16_t right) {
  if (!audio_state.running) {
    return;
  }

  uint32_t w = audio_state.write_pos;
  uint32_t next = (w + 1) & (AUDIO_RING_SIZE - 1);
  uint32_t r = __atomic_load_n(&audio_state.read_pos, __ATOMIC_ACQUIRE);

  if (next == r) {
    return;
  }

  audio_state.ring[w].left = left;
  audio_state.ring[w].right = right;
  __atomic_store_n(&audio_state.write_pos, next, __ATOMIC_RELEASE);
}

void gbc_audio_stop(void) {
  if (!audio_state.running) {
    return;
  }

  ma_device_stop(&audio_state.device);
  ma_device_uninit(&audio_state.device);
  audio_state.running = false;
  fprintf(stderr, "[gbc-native][audio] stopped\n");
}

bool gbc_audio_is_running(void) {
  return audio_state.running;
}
