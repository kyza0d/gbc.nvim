#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#include "../native/protocol.h"

static uint64_t now_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ((uint64_t)ts.tv_sec * 1000000000ull) + (uint64_t)ts.tv_nsec;
}

static int run_case(const char *label, int iterations, int use_msync, const uint8_t *frame) {
  uint64_t started = now_ns();

  for (int index = 0; index < iterations; index++) {
    char shm_name[128];
    snprintf(shm_name, sizeof(shm_name), "/gbc-bench-%ld-%s-%d", (long)getpid(), label, index % 8);

    shm_unlink(shm_name);
    int fd = shm_open(shm_name, O_CREAT | O_RDWR, 0600);
    if (fd < 0) {
      fprintf(stderr, "shm_open failed: %s\n", strerror(errno));
      return 1;
    }

    if (ftruncate(fd, GBC_RGB24_FRAME_BYTES) < 0) {
      fprintf(stderr, "ftruncate failed: %s\n", strerror(errno));
      close(fd);
      return 1;
    }

    uint8_t *ptr = mmap(NULL, GBC_RGB24_FRAME_BYTES, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (ptr == MAP_FAILED) {
      fprintf(stderr, "mmap failed: %s\n", strerror(errno));
      return 1;
    }

    memcpy(ptr, frame, GBC_RGB24_FRAME_BYTES);
    if (use_msync && msync(ptr, GBC_RGB24_FRAME_BYTES, MS_SYNC) < 0) {
      fprintf(stderr, "msync failed: %s\n", strerror(errno));
      munmap(ptr, GBC_RGB24_FRAME_BYTES);
      return 1;
    }

    if (munmap(ptr, GBC_RGB24_FRAME_BYTES) < 0) {
      fprintf(stderr, "munmap failed: %s\n", strerror(errno));
      return 1;
    }

    shm_unlink(shm_name);
  }

  uint64_t elapsed = now_ns() - started;
  printf(
    "%s iterations=%d total=%.3fms avg=%.3fms\n",
    label,
    iterations,
    (double)elapsed / 1000000.0,
    ((double)elapsed / (double)iterations) / 1000000.0
  );
  return 0;
}

int main(int argc, char **argv) {
  int iterations = 500;
  if (argc > 1) {
    iterations = atoi(argv[1]);
    if (iterations <= 0) {
      fprintf(stderr, "invalid iteration count\n");
      return 2;
    }
  }

  uint8_t *frame = malloc(GBC_RGB24_FRAME_BYTES);
  if (frame == NULL) {
    fprintf(stderr, "failed to allocate frame buffer\n");
    return 1;
  }

  for (size_t index = 0; index < GBC_RGB24_FRAME_BYTES; index++) {
    frame[index] = (uint8_t)(index & 0xff);
  }

  int result = run_case("legacy_msync", iterations, 1, frame);
  if (result == 0) {
    result = run_case("no_msync", iterations, 0, frame);
  }

  free(frame);
  return result;
}
