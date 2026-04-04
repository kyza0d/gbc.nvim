#ifndef GBC_PROTOCOL_H
#define GBC_PROTOCOL_H

#include <stdint.h>

/*
 * Binary framing:
 *   u8  message_type
 *   u16 payload_length (little-endian)
 *   u8[payload_length] payload bytes
 *
 * Lua -> native:
 *   CMSG_INIT
 *     u16 rom_path_len
 *     u8[rom_path_len] rom_path bytes
 *     u8 renderer_id
 *     u8 audio_enabled
 *   CMSG_SET_INPUT
 *     u16 joypad bitmask
 *   CMSG_RUN_FRAME
 *     no payload
 *   CMSG_SET_FRAME_SHM_NAME
 *     u16 shm_name_len
 *     u8[shm_name_len] shm name bytes (empty string disables shm transport)
 *   CMSG_STOP
 *     no payload
 *
 * Native -> Lua:
 *   AMSG_INIT
 *     u16 width
 *     u16 height
 *     u8 pixel_format
 *   AMSG_FRAME
 *     u16 width
 *     u16 height
 *     u8 pixel_format
 *     u32 frame_id
 *     u8[] raw pixel bytes (empty when pixel_format uses shm-backed transport)
 *   AMSG_LOG
 *     UTF-8 text payload
 *   AMSG_QUIT
 *     UTF-8 text payload
 */

#define GBC_PROTOCOL_HEADER_SIZE 3
#define GBC_SCREEN_WIDTH 160
#define GBC_SCREEN_HEIGHT 144
#define GBC_RGB24_FRAME_BYTES (GBC_SCREEN_WIDTH * GBC_SCREEN_HEIGHT * 3)

enum gbc_pixel_format {
  GBC_PIXEL_FORMAT_GRAY8 = 1,
  GBC_PIXEL_FORMAT_RGB24_SHM = 2,
};

enum gbc_renderer_id {
  GBC_RENDERER_CELL = 1,
  GBC_RENDERER_KITTY = 2,
};

enum gbc_client_message_id {
  GBC_CMSG_INIT = 1,
  GBC_CMSG_SET_INPUT,
  GBC_CMSG_RUN_FRAME,
  GBC_CMSG_SET_FRAME_SHM_NAME,
  GBC_CMSG_STOP,
};

enum gbc_host_message_id {
  GBC_AMSG_INIT = 1,
  GBC_AMSG_FRAME,
  GBC_AMSG_LOG,
  GBC_AMSG_QUIT,
};

#endif /* GBC_PROTOCOL_H */
