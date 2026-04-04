#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include "protocol.h"
#include "vendor/SameBoy/Core/gb.h"

struct gbc_init_request {
  char *rom_path;
  uint8_t renderer_id;
  bool audio_enabled;
};

struct gbc_session {
  bool initialized;
  bool stop_requested;
  int client_fd;
  char *rom_path;
  char *frame_shm_name;
  uint16_t input_mask;
  uint32_t frame_id;
  uint16_t width;
  uint16_t height;
  uint8_t renderer_id;
  GB_gameboy_t *gb;
  uint32_t *framebuffer;
  uint8_t *framebuffer_gray;
  uint8_t *framebuffer_rgb24;
  size_t framebuffer_pixels;
};

struct gbc_message {
  uint8_t type;
  uint16_t payload_length;
  uint8_t *payload;
};

struct gbc_profile_stat {
  uint64_t count;
  uint64_t total_ns;
  uint64_t max_ns;
};

struct gbc_profile_state {
  bool enabled;
  struct gbc_profile_stat gb_run_frame;
  struct gbc_profile_stat write_frame_shm;
  struct gbc_profile_stat convert_framebuffer;
  struct gbc_profile_stat send_frame_inline_gray;
};

static struct gbc_profile_state profile_state;

static void print_usage(const char *program) {
  fprintf(stderr, "usage: %s --socket PATH --rom PATH\n", program);
  fprintf(stderr, "Host-driven SameBoy bridge: wait for CMSG_INIT, run frames on demand, return AMSG_FRAME.\n");
}

static void log_line(const char *message) {
  fprintf(stderr, "[gbc-native] %s\n", message);
}

static uint64_t now_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ((uint64_t)ts.tv_sec * 1000000000ull) + (uint64_t)ts.tv_nsec;
}

static void profile_record(struct gbc_profile_stat *stat, uint64_t elapsed_ns) {
  if (!profile_state.enabled || stat == NULL) {
    return;
  }

  stat->count += 1;
  stat->total_ns += elapsed_ns;
  if (elapsed_ns > stat->max_ns) {
    stat->max_ns = elapsed_ns;
  }
}

static void profile_dump_one(const char *label, const struct gbc_profile_stat *stat) {
  if (stat == NULL || stat->count == 0) {
    return;
  }

  fprintf(stderr,
          "[gbc-native][profile] %s count=%" PRIu64 " total=%.3fms avg=%.3fms max=%.3fms\n",
          label,
          stat->count,
          (double)stat->total_ns / 1000000.0,
          ((double)stat->total_ns / (double)stat->count) / 1000000.0,
          (double)stat->max_ns / 1000000.0);
}

static void profile_dump(void) {
  if (!profile_state.enabled) {
    return;
  }

  profile_dump_one("GB_run_frame", &profile_state.gb_run_frame);
  profile_dump_one("write_frame_shm", &profile_state.write_frame_shm);
  profile_dump_one("convert_framebuffer", &profile_state.convert_framebuffer);
  profile_dump_one("send_frame_inline_gray", &profile_state.send_frame_inline_gray);
}

static int write_all(int fd, const uint8_t *data, size_t length) {
  while (length > 0) {
    ssize_t written = write(fd, data, length);
    if (written < 0) {
      if (errno == EINTR) {
        continue;
      }

      fprintf(stderr, "[gbc-native] write failed: %s\n", strerror(errno));
      return -1;
    }

    data += (size_t)written;
    length -= (size_t)written;
  }

  return 0;
}

static int read_all(int fd, uint8_t *data, size_t length) {
  while (length > 0) {
    ssize_t count = read(fd, data, length);
    if (count < 0) {
      if (errno == EINTR) {
        continue;
      }

      fprintf(stderr, "[gbc-native] read failed: %s\n", strerror(errno));
      return -1;
    }

    if (count == 0) {
      return 1;
    }

    data += (size_t)count;
    length -= (size_t)count;
  }

  return 0;
}

static uint16_t read_u16(const uint8_t *data) {
  return (uint16_t)data[0] | ((uint16_t)data[1] << 8);
}

static void write_u16(uint8_t *data, uint16_t value) {
  data[0] = (uint8_t)(value & 0xff);
  data[1] = (uint8_t)((value >> 8) & 0xff);
}

static void write_u32(uint8_t *data, uint32_t value) {
  data[0] = (uint8_t)(value & 0xff);
  data[1] = (uint8_t)((value >> 8) & 0xff);
  data[2] = (uint8_t)((value >> 16) & 0xff);
  data[3] = (uint8_t)((value >> 24) & 0xff);
}

static int send_message(int fd, uint8_t message_type, const uint8_t *payload, size_t payload_length) {
  uint8_t header[GBC_PROTOCOL_HEADER_SIZE];
  if (payload_length > UINT16_MAX) {
    fprintf(stderr, "[gbc-native] payload too large for framed message (%zu bytes)\n", payload_length);
    return -1;
  }

  header[0] = message_type;
  header[1] = (uint8_t)(payload_length & 0xff);
  header[2] = (uint8_t)((payload_length >> 8) & 0xff);

  if (write_all(fd, header, sizeof(header)) < 0) {
    return -1;
  }

  if (payload_length > 0 && write_all(fd, payload, payload_length) < 0) {
    return -1;
  }

  return 0;
}

static int send_text(int fd, uint8_t message_type, const char *payload) {
  size_t payload_length = payload == NULL ? 0 : strlen(payload);
  return send_message(fd, message_type, (const uint8_t *)payload, payload_length);
}

static int send_init(int fd, const struct gbc_session *session) {
  uint8_t payload[5];
  write_u16(payload, session->width);
  write_u16(payload + 2, session->height);
  payload[4] = session->renderer_id == GBC_RENDERER_KITTY
                 ? GBC_PIXEL_FORMAT_RGB24_SHM
                 : GBC_PIXEL_FORMAT_GRAY8;
  return send_message(fd, GBC_AMSG_INIT, payload, sizeof(payload));
}

static int send_frame_inline_gray(int fd, const struct gbc_session *session) {
  size_t gray_size = session->framebuffer_pixels;
  size_t payload_length = 2 + 2 + 1 + 4 + gray_size;
  uint8_t *payload = malloc(payload_length);
  if (payload == NULL) {
    fprintf(stderr, "[gbc-native] failed to allocate frame payload\n");
    return -1;
  }

  write_u16(payload, session->width);
  write_u16(payload + 2, session->height);
  payload[4] = GBC_PIXEL_FORMAT_GRAY8;
  write_u32(payload + 5, session->frame_id);
  memcpy(payload + 9, session->framebuffer_gray, gray_size);

  int result = send_message(fd, GBC_AMSG_FRAME, payload, payload_length);
  free(payload);
  return result;
}

static int send_frame_shm_ready(int fd, const struct gbc_session *session) {
  uint8_t payload[9];
  write_u16(payload, session->width);
  write_u16(payload + 2, session->height);
  payload[4] = GBC_PIXEL_FORMAT_RGB24_SHM;
  write_u32(payload + 5, session->frame_id);
  return send_message(fd, GBC_AMSG_FRAME, payload, sizeof(payload));
}

static int create_server_socket(const char *socket_path) {
  int server_fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (server_fd < 0) {
    fprintf(stderr, "[gbc-native] socket() failed: %s\n", strerror(errno));
    return -1;
  }

  struct sockaddr_un address;
  memset(&address, 0, sizeof(address));
  address.sun_family = AF_UNIX;

  size_t path_length = strlen(socket_path);
  if (path_length >= sizeof(address.sun_path)) {
    fprintf(stderr, "[gbc-native] socket path too long: %s\n", socket_path);
    close(server_fd);
    return -1;
  }

  strncpy(address.sun_path, socket_path, sizeof(address.sun_path) - 1);
  unlink(socket_path);

  if (bind(server_fd, (const struct sockaddr *)&address, sizeof(address)) < 0) {
    fprintf(stderr, "[gbc-native] bind() failed for %s: %s\n", socket_path, strerror(errno));
    close(server_fd);
    unlink(socket_path);
    return -1;
  }

  if (listen(server_fd, 1) < 0) {
    fprintf(stderr, "[gbc-native] listen() failed: %s\n", strerror(errno));
    close(server_fd);
    unlink(socket_path);
    return -1;
  }

  return server_fd;
}

static int accept_client(int server_fd) {
  for (;;) {
    int client_fd = accept(server_fd, NULL, NULL);
    if (client_fd >= 0) {
      return client_fd;
    }

    if (errno != EINTR) {
      fprintf(stderr, "[gbc-native] accept() failed: %s\n", strerror(errno));
      return -1;
    }
  }
}

static int read_message(int fd, struct gbc_message *message) {
  uint8_t header[GBC_PROTOCOL_HEADER_SIZE];
  memset(message, 0, sizeof(*message));

  int status = read_all(fd, header, sizeof(header));
  if (status != 0) {
    return status;
  }

  message->type = header[0];
  message->payload_length = read_u16(header + 1);
  if (message->payload_length == 0) {
    return 0;
  }

  message->payload = malloc(message->payload_length);
  if (message->payload == NULL) {
    fprintf(stderr, "[gbc-native] failed to allocate %u-byte payload\n", message->payload_length);
    return -1;
  }

  status = read_all(fd, message->payload, message->payload_length);
  if (status != 0) {
    free(message->payload);
    message->payload = NULL;
    return status;
  }

  return 0;
}

static void free_message(struct gbc_message *message) {
  free(message->payload);
  memset(message, 0, sizeof(*message));
}

static int parse_init_request(const uint8_t *payload, uint16_t payload_length, struct gbc_init_request *request) {
  memset(request, 0, sizeof(*request));
  if (payload_length < 4) {
    fprintf(stderr, "[gbc-native] CMSG_INIT payload too short (%u bytes)\n", payload_length);
    return -1;
  }

  uint16_t rom_path_length = read_u16(payload);
  size_t expected = (size_t)rom_path_length + 4;
  if (payload_length != expected) {
    fprintf(stderr,
            "[gbc-native] CMSG_INIT payload length mismatch (expected %zu bytes, got %u)\n",
            expected,
            payload_length);
    return -1;
  }

  request->rom_path = calloc((size_t)rom_path_length + 1, 1);
  if (request->rom_path == NULL) {
    fprintf(stderr, "[gbc-native] failed to allocate rom path buffer\n");
    return -1;
  }

  memcpy(request->rom_path, payload + 2, rom_path_length);
  request->renderer_id = payload[2 + rom_path_length];
  request->audio_enabled = payload[3 + rom_path_length] != 0;
  return 0;
}

static void free_init_request(struct gbc_init_request *request) {
  free(request->rom_path);
  memset(request, 0, sizeof(*request));
}

static bool file_exists(const char *path) {
  struct stat st;
  return stat(path, &st) == 0 && S_ISREG(st.st_mode);
}

static void close_frame_shm(struct gbc_session *session) {
  if (session->frame_shm_name != NULL) {
    if (shm_unlink(session->frame_shm_name) < 0 && errno != ENOENT) {
      fprintf(stderr, "[gbc-native] shm_unlink(%s) failed: %s\n", session->frame_shm_name, strerror(errno));
    }

    free(session->frame_shm_name);
    session->frame_shm_name = NULL;
  }
}

static uint32_t sameboy_rgb_encode(GB_gameboy_t *gb, uint8_t r, uint8_t g, uint8_t b) {
  (void)gb;
  return ((uint32_t)r << 16) | ((uint32_t)g << 8) | (uint32_t)b;
}

static void sameboy_log_callback(GB_gameboy_t *gb, const char *string, GB_log_attributes_t attributes) {
  (void)attributes;
  struct gbc_session *session = GB_get_user_data(gb);
  if (session == NULL || session->client_fd < 0 || string == NULL) {
    return;
  }

  send_text(session->client_fd, GBC_AMSG_LOG, string);
}

static int allocate_framebuffers(struct gbc_session *session) {
  session->width = (uint16_t)GB_get_screen_width(session->gb);
  session->height = (uint16_t)GB_get_screen_height(session->gb);
  session->framebuffer_pixels = (size_t)session->width * session->height;

  free(session->framebuffer);
  free(session->framebuffer_gray);
  free(session->framebuffer_rgb24);

  session->framebuffer = calloc(session->framebuffer_pixels, sizeof(uint32_t));
  session->framebuffer_gray = calloc(session->framebuffer_pixels, 1);
  session->framebuffer_rgb24 = calloc(session->framebuffer_pixels * 3, 1);
  if (session->framebuffer == NULL || session->framebuffer_gray == NULL || session->framebuffer_rgb24 == NULL) {
    fprintf(stderr,
            "[gbc-native] failed to allocate framebuffers for %ux%u frame\n",
            session->width,
            session->height);
    return -1;
  }

  GB_set_pixels_output(session->gb, session->framebuffer);
  return 0;
}

static void disable_debugger(GB_gameboy_t *gb) {
#ifndef GB_DISABLE_DEBUGGER
  GB_debugger_set_disabled(gb, true);
  GB_set_input_callback(gb, NULL);
  GB_set_async_input_callback(gb, NULL);
#else
  (void)gb;
#endif
}

static bool boot_rom_has_data(GB_gameboy_t *gb) {
  size_t size = 0;
  uint8_t *boot_rom = GB_get_direct_access(gb, GB_DIRECT_ACCESS_BOOTROM, &size, NULL);
  if (boot_rom == NULL || size == 0) {
    return false;
  }

  for (size_t i = 0; i < size; i++) {
    if (boot_rom[i] != 0) {
      return true;
    }
  }

  return false;
}

static bool rom_prefers_cgb(GB_gameboy_t *gb) {
  size_t size = 0;
  uint8_t *rom = GB_get_direct_access(gb, GB_DIRECT_ACCESS_ROM, &size, NULL);
  return rom != NULL && size > 0x143 && (rom[0x143] & 0x80) != 0;
}

/* SameBoy expects either a boot ROM or a frontend-provided post-boot state. */
static void apply_fast_boot_fallback(GB_gameboy_t *gb) {
  GB_registers_t *registers = GB_get_registers(gb);
  bool cgb_mode = GB_is_cgb(gb) && rom_prefers_cgb(gb);
  if (!cgb_mode && GB_is_cgb(gb)) {
    GB_write_memory(gb, 0xFF4C, 0x0C); /* KEY0: leave CGB hardware in DMG mode */
  }

  if (cgb_mode) {
    registers->af = 0x1180;
    registers->bc = 0x0000;
    registers->de = 0xff56;
    registers->hl = 0x000d;
  }
  else {
    registers->af = 0x01b0;
    registers->bc = 0x0013;
    registers->de = 0x00d8;
    registers->hl = 0x014d;
  }

  registers->sp = 0xfffe;
  registers->pc = 0x0100;
  GB_write_memory(gb, 0xFF50, 0x01); /* Unmap boot ROM */

  GB_write_memory(gb, 0xFF05, 0x00); /* TIMA */
  GB_write_memory(gb, 0xFF06, 0x00); /* TMA */
  GB_write_memory(gb, 0xFF07, 0x00); /* TAC */
  GB_write_memory(gb, 0xFF10, 0x80); /* NR10 */
  GB_write_memory(gb, 0xFF11, 0xBF); /* NR11 */
  GB_write_memory(gb, 0xFF12, 0xF3); /* NR12 */
  GB_write_memory(gb, 0xFF14, 0xBF); /* NR14 */
  GB_write_memory(gb, 0xFF16, 0x3F); /* NR21 */
  GB_write_memory(gb, 0xFF17, 0x00); /* NR22 */
  GB_write_memory(gb, 0xFF19, 0xBF); /* NR24 */
  GB_write_memory(gb, 0xFF1A, 0x7F); /* NR30 */
  GB_write_memory(gb, 0xFF1B, 0xFF); /* NR31 */
  GB_write_memory(gb, 0xFF1C, 0x9F); /* NR32 */
  GB_write_memory(gb, 0xFF1E, 0xBF); /* NR34 */
  GB_write_memory(gb, 0xFF20, 0xFF); /* NR41 */
  GB_write_memory(gb, 0xFF21, 0x00); /* NR42 */
  GB_write_memory(gb, 0xFF22, 0x00); /* NR43 */
  GB_write_memory(gb, 0xFF23, 0xBF); /* NR44 */
  GB_write_memory(gb, 0xFF24, 0x77); /* NR50 */
  GB_write_memory(gb, 0xFF25, 0xF3); /* NR51 */
  GB_write_memory(gb, 0xFF26, 0xF1); /* NR52 */
  GB_write_memory(gb, 0xFF40, 0x91); /* LCDC */
  GB_write_memory(gb, 0xFF42, 0x00); /* SCY */
  GB_write_memory(gb, 0xFF43, 0x00); /* SCX */
  GB_write_memory(gb, 0xFF45, 0x00); /* LYC */
  GB_write_memory(gb, 0xFF47, 0xFC); /* BGP */
  GB_write_memory(gb, 0xFF48, 0xFF); /* OBP0 */
  GB_write_memory(gb, 0xFF49, 0xFF); /* OBP1 */
  GB_write_memory(gb, 0xFF4A, 0x00); /* WY */
  GB_write_memory(gb, 0xFF4B, 0x00); /* WX */
  GB_write_memory(gb, 0xFFFF, 0x00); /* IE */
}

static void update_input(struct gbc_session *session) {
  GB_set_key_mask(session->gb, (GB_key_mask_t)(session->input_mask & 0xff));
}

static void convert_framebuffer(struct gbc_session *session) {
  for (size_t i = 0; i < session->framebuffer_pixels; i++) {
    uint32_t pixel = session->framebuffer[i];
    uint8_t r = (uint8_t)((pixel >> 16) & 0xff);
    uint8_t g = (uint8_t)((pixel >> 8) & 0xff);
    uint8_t b = (uint8_t)(pixel & 0xff);
    session->framebuffer_gray[i] = (uint8_t)(((uint16_t)r * 30u + (uint16_t)g * 59u + (uint16_t)b * 11u) / 100u);
  }
}

static void convert_framebuffer_rgb24(struct gbc_session *session, uint8_t *target) {
  for (size_t i = 0; i < session->framebuffer_pixels; i++) {
    uint32_t pixel = session->framebuffer[i];
    target[i * 3] = (uint8_t)((pixel >> 16) & 0xff);
    target[i * 3 + 1] = (uint8_t)((pixel >> 8) & 0xff);
    target[i * 3 + 2] = (uint8_t)(pixel & 0xff);
  }
}

static void session_reset(struct gbc_session *session) {
  if (session->gb != NULL) {
    if (GB_is_inited(session->gb)) {
      GB_free(session->gb);
    }
    GB_dealloc(session->gb);
  }

  free(session->rom_path);
  free(session->framebuffer);
  free(session->framebuffer_gray);
  free(session->framebuffer_rgb24);
  close_frame_shm(session);
  session->gb = NULL;
  session->rom_path = NULL;
  session->framebuffer = NULL;
  session->framebuffer_gray = NULL;
  session->framebuffer_rgb24 = NULL;
  session->framebuffer_pixels = 0;
  session->width = 0;
  session->height = 0;
  session->frame_id = 0;
  session->input_mask = 0;
  session->renderer_id = GBC_RENDERER_CELL;
  session->stop_requested = false;
  session->initialized = false;
}

static int session_init(struct gbc_session *session, const struct gbc_init_request *request, int fd) {
  if (!file_exists(request->rom_path)) {
    fprintf(stderr, "[gbc-native] ROM file does not exist: %s\n", request->rom_path);
    send_text(fd, GBC_AMSG_LOG, "init failed: rom file missing");
    return -1;
  }

  session_reset(session);
  session->client_fd = fd;
  session->gb = GB_alloc();
  if (session->gb == NULL) {
    send_text(fd, GBC_AMSG_LOG, "init failed: GB_alloc returned NULL");
    return -1;
  }

  GB_init(session->gb, GB_MODEL_CGB_E);
  disable_debugger(session->gb);
  GB_set_user_data(session->gb, session);
  GB_set_log_callback(session->gb, sameboy_log_callback);
  GB_set_rgb_encode_callback(session->gb, sameboy_rgb_encode);

  if (allocate_framebuffers(session) < 0) {
    send_text(fd, GBC_AMSG_LOG, "init failed: framebuffer allocation failed");
    return -1;
  }

  if (GB_load_rom(session->gb, request->rom_path) != 0) {
    send_text(fd, GBC_AMSG_LOG, "init failed: GB_load_rom returned an error");
    return -1;
  }

  GB_reset(session->gb);
  if (!boot_rom_has_data(session->gb)) {
    apply_fast_boot_fallback(session->gb);
    send_text(fd, GBC_AMSG_LOG, "No boot ROM loaded; using fast-boot fallback");
  }

  session->rom_path = strdup(request->rom_path);
  if (session->rom_path == NULL) {
    send_text(fd, GBC_AMSG_LOG, "init failed: rom path allocation failed");
    return -1;
  }

  session->initialized = true;
  session->input_mask = 0;
  session->frame_id = 0;
  session->renderer_id = request->renderer_id;

  if (send_text(fd, GBC_AMSG_LOG, "SameBoy session initialized") < 0 ||
      send_init(fd, session) < 0) {
    return -1;
  }

  return 0;
}

static int session_set_input(struct gbc_session *session, const uint8_t *payload, uint16_t payload_length) {
  if (payload_length != 2) {
    fprintf(stderr, "[gbc-native] CMSG_SET_INPUT expected 2 bytes, got %u\n", payload_length);
    return -1;
  }

  session->input_mask = read_u16(payload);
  if (session->initialized) {
    update_input(session);
  }
  return 0;
}

static int session_set_frame_shm(struct gbc_session *session, const uint8_t *payload, uint16_t payload_length, int fd) {
  if (payload_length < 2) {
    fprintf(stderr, "[gbc-native] CMSG_SET_FRAME_SHM_NAME payload too short (%u bytes)\n", payload_length);
    return -1;
  }

  uint16_t shm_name_length = read_u16(payload);
  if (payload_length != (uint16_t)(shm_name_length + 2)) {
    fprintf(stderr,
            "[gbc-native] CMSG_SET_FRAME_SHM_NAME payload length mismatch (expected %u bytes, got %u)\n",
            (unsigned)(shm_name_length + 2),
            payload_length);
    return -1;
  }

  close_frame_shm(session);
  if (shm_name_length == 0) {
    return 0;
  }

  char *shm_name = calloc((size_t)shm_name_length + 1, 1);
  if (shm_name == NULL) {
    send_text(fd, GBC_AMSG_LOG, "set_frame_shm_name failed: allocation failed");
    return -1;
  }
  memcpy(shm_name, payload + 2, shm_name_length);

  session->frame_shm_name = shm_name;
  return 0;
}

static int write_frame_shm(struct gbc_session *session, int fd) {
  if (session->frame_shm_name == NULL || session->frame_shm_name[0] == '\0') {
    send_text(fd, GBC_AMSG_LOG, "frame shm transport requested without a shm name");
    return -1;
  }

  /*
   * Kitty-compatible terminals can hold on to the first shm-backed image if we
   * keep reusing the same mapped object. Recreate the shm segment for every
   * frame so each presentation points at fresh image storage.
   */
  if (shm_unlink(session->frame_shm_name) < 0 && errno != ENOENT) {
    fprintf(stderr, "[gbc-native] shm_unlink(%s) failed before create: %s\n",
            session->frame_shm_name, strerror(errno));
  }

  int shm_fd = shm_open(session->frame_shm_name, O_CREAT | O_RDWR, 0600);
  if (shm_fd < 0) {
    fprintf(stderr, "[gbc-native] shm_open(%s) failed: %s\n", session->frame_shm_name, strerror(errno));
    send_text(fd, GBC_AMSG_LOG, "frame shm write failed: shm_open");
    return -1;
  }

  if (ftruncate(shm_fd, GBC_RGB24_FRAME_BYTES) < 0) {
    fprintf(stderr, "[gbc-native] ftruncate(%s) failed: %s\n", session->frame_shm_name, strerror(errno));
    close(shm_fd);
    send_text(fd, GBC_AMSG_LOG, "frame shm write failed: ftruncate");
    return -1;
  }

  uint8_t *ptr = mmap(NULL, GBC_RGB24_FRAME_BYTES, PROT_READ | PROT_WRITE, MAP_SHARED, shm_fd, 0);
  close(shm_fd);
  if (ptr == MAP_FAILED) {
    fprintf(stderr, "[gbc-native] mmap(%s) failed: %s\n", session->frame_shm_name, strerror(errno));
    send_text(fd, GBC_AMSG_LOG, "frame shm write failed: mmap");
    return -1;
  }

  convert_framebuffer_rgb24(session, ptr);

  if (munmap(ptr, GBC_RGB24_FRAME_BYTES) < 0) {
    fprintf(stderr, "[gbc-native] munmap(%s) failed: %s\n", session->frame_shm_name, strerror(errno));
    send_text(fd, GBC_AMSG_LOG, "frame shm write failed: munmap");
    return -1;
  }

  return send_frame_shm_ready(fd, session);
}

static int session_run_frame(struct gbc_session *session, int fd) {
  if (!session->initialized) {
    send_text(fd, GBC_AMSG_LOG, "run_frame ignored: session not initialized");
    return -1;
  }

  update_input(session);
  session->frame_id += 1;
  uint64_t started = now_ns();
  GB_run_frame(session->gb);
  profile_record(&profile_state.gb_run_frame, now_ns() - started);
  if (session->renderer_id == GBC_RENDERER_KITTY && session->frame_shm_name != NULL) {
    started = now_ns();
    int result = write_frame_shm(session, fd);
    profile_record(&profile_state.write_frame_shm, now_ns() - started);
    return result;
  }

  started = now_ns();
  convert_framebuffer(session);
  profile_record(&profile_state.convert_framebuffer, now_ns() - started);
  started = now_ns();
  int result = send_frame_inline_gray(fd, session);
  profile_record(&profile_state.send_frame_inline_gray, now_ns() - started);
  return result;
}

static void session_free(struct gbc_session *session) {
  session_reset(session);
  session->client_fd = -1;
}

int main(int argc, char **argv) {
  const char *socket_path = NULL;
  const char *bootstrap_rom = NULL;
  const char *profile_env = getenv("GBC_PROFILE_NATIVE");

  memset(&profile_state, 0, sizeof(profile_state));
  profile_state.enabled = profile_env != NULL && strcmp(profile_env, "0") != 0;

  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--socket") == 0) {
      if (i + 1 >= argc) {
        print_usage(argv[0]);
        return 2;
      }

      socket_path = argv[++i];
      continue;
    }

    if (strcmp(argv[i], "--rom") == 0) {
      if (i + 1 >= argc) {
        print_usage(argv[0]);
        return 2;
      }

      bootstrap_rom = argv[++i];
      continue;
    }

    if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
      print_usage(argv[0]);
      return 0;
    }

    fprintf(stderr, "[gbc-native] unknown argument: %s\n", argv[i]);
    print_usage(argv[0]);
    return 2;
  }

  if (socket_path == NULL || bootstrap_rom == NULL) {
    print_usage(argv[0]);
    return 2;
  }

  log_line("Starting SameBoy bridge.");
  fprintf(stderr, "[gbc-native] socket path: %s\n", socket_path);
  fprintf(stderr, "[gbc-native] bootstrap rom path: %s\n", bootstrap_rom);

  int server_fd = create_server_socket(socket_path);
  if (server_fd < 0) {
    return 1;
  }

  log_line("Waiting for Lua host to connect...");
  int client_fd = accept_client(server_fd);
  if (client_fd < 0) {
    close(server_fd);
    unlink(socket_path);
    return 1;
  }

  struct gbc_session session = {
    .client_fd = client_fd,
  };
  bool running = true;

  while (running) {
    struct gbc_message message;
    int read_status = read_message(client_fd, &message);
    if (read_status == 1) {
      log_line("Lua host closed the socket.");
      break;
    }

    if (read_status != 0) {
      send_text(client_fd, GBC_AMSG_QUIT, "socket read failed");
      break;
    }

    switch (message.type) {
      case GBC_CMSG_INIT: {
        struct gbc_init_request request;
        if (parse_init_request(message.payload, message.payload_length, &request) == 0) {
          fprintf(stderr,
                  "[gbc-native] CMSG_INIT rom=%s renderer=%u audio=%u\n",
                  request.rom_path,
                  request.renderer_id,
                  request.audio_enabled ? 1u : 0u);
          if (strcmp(request.rom_path, bootstrap_rom) != 0) {
            send_text(client_fd, GBC_AMSG_LOG, "init rom path differs from bootstrap argv; using protocol rom path");
          }

          if (session_init(&session, &request, client_fd) < 0) {
            send_text(client_fd, GBC_AMSG_QUIT, "init failed");
            running = false;
          }
        }
        else {
          send_text(client_fd, GBC_AMSG_QUIT, "invalid init payload");
          running = false;
        }
        free_init_request(&request);
        break;
      }

      case GBC_CMSG_SET_INPUT:
        if (session_set_input(&session, message.payload, message.payload_length) < 0) {
          send_text(client_fd, GBC_AMSG_LOG, "invalid input payload");
        }
        break;

      case GBC_CMSG_RUN_FRAME:
        if (session_run_frame(&session, client_fd) < 0) {
          send_text(client_fd, GBC_AMSG_QUIT, "frame request failed");
          running = false;
        }
        break;

      case GBC_CMSG_SET_FRAME_SHM_NAME:
        if (session_set_frame_shm(&session, message.payload, message.payload_length, client_fd) < 0) {
          send_text(client_fd, GBC_AMSG_QUIT, "set_frame_shm_name failed");
          running = false;
        }
        break;

      case GBC_CMSG_STOP:
        session.stop_requested = true;
        send_text(client_fd, GBC_AMSG_QUIT, "host requested stop");
        running = false;
        break;

      default:
        send_text(client_fd, GBC_AMSG_LOG, "unknown client message");
        break;
    }

    free_message(&message);
  }

  session_free(&session);
  close(client_fd);
  close(server_fd);
  unlink(socket_path);
  profile_dump();
  log_line("Exiting cleanly.");

  return 0;
}
