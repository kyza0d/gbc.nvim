local HEADER_SIZE = 3
local PIXEL_FORMAT_GRAY8 = 1
local PIXEL_FORMAT_RGB24_SHM = 2

local M = {
  header_size = HEADER_SIZE,
  pixel_format = {
    GRAY8 = PIXEL_FORMAT_GRAY8,
    RGB24_SHM = PIXEL_FORMAT_RGB24_SHM,
  },
  renderer = {
    CELL = 1,
    KITTY = 2,
  },
  client = {
    INIT = 1,
    SET_INPUT = 2,
    RUN_FRAME = 3,
    SET_FRAME_SHM_NAME = 4,
    STOP = 5,
  },
  host = {
    INIT = 1,
    FRAME = 2,
    LOG = 3,
    QUIT = 4,
  },
}

M.client_names = {
  [M.client.INIT] = 'CMSG_INIT',
  [M.client.SET_INPUT] = 'CMSG_SET_INPUT',
  [M.client.RUN_FRAME] = 'CMSG_RUN_FRAME',
  [M.client.SET_FRAME_SHM_NAME] = 'CMSG_SET_FRAME_SHM_NAME',
  [M.client.STOP] = 'CMSG_STOP',
}

M.host_names = {
  [M.host.INIT] = 'AMSG_INIT',
  [M.host.FRAME] = 'AMSG_FRAME',
  [M.host.LOG] = 'AMSG_LOG',
  [M.host.QUIT] = 'AMSG_QUIT',
}

local function message_name(names, message_type) return names[message_type] or ('UNKNOWN(' .. message_type .. ')') end

local function pack_u16(value)
  assert(value >= 0 and value <= 0xffff, 'protocol u16 out of range')
  return string.char(value % 0x100, math.floor(value / 0x100))
end

local function pack_u32(value)
  assert(value >= 0 and value <= 0xffffffff, 'protocol u32 out of range')
  return string.char(
    value % 0x100,
    math.floor(value / 0x100) % 0x100,
    math.floor(value / 0x10000) % 0x100,
    math.floor(value / 0x1000000) % 0x100
  )
end

local function unpack_u16(payload, offset)
  local lo, hi = payload:byte(offset, offset + 1)
  assert(lo and hi, 'protocol payload truncated while reading u16')
  return lo + (hi * 0x100), offset + 2
end

local function unpack_u32(payload, offset)
  local b1, b2, b3, b4 = payload:byte(offset, offset + 3)
  assert(b1 and b2 and b3 and b4, 'protocol payload truncated while reading u32')
  return b1 + (b2 * 0x100) + (b3 * 0x10000) + (b4 * 0x1000000), offset + 4
end

function M.host_name(message_type) return message_name(M.host_names, message_type) end

function M.client_name(message_type) return message_name(M.client_names, message_type) end

function M.pixel_format_name(value)
  if value == M.pixel_format.GRAY8 then return 'gray8' end

  if value == M.pixel_format.RGB24_SHM then return 'rgb24_shm' end

  return 'unknown(' .. tostring(value) .. ')'
end

function M.renderer_id(name)
  if name == 'kitty' then return M.renderer.KITTY end

  return M.renderer.CELL
end

function M.encode(message_type, payload)
  payload = payload or ''
  assert(type(payload) == 'string', 'protocol payload must be a string')
  assert(message_type >= 0 and message_type <= 0xff, 'protocol message type must fit in u8')
  assert(#payload <= 0xffff, 'protocol payload must fit in u16')

  return string.char(message_type, #payload % 0x100, math.floor(#payload / 0x100)) .. payload
end

function M.encode_init(opts)
  local rom_path = assert(opts.rom_path, 'protocol init requires rom_path')
  assert(#rom_path <= 0xffff, 'protocol init rom_path must fit in u16')

  return M.encode(
    M.client.INIT,
    pack_u16(#rom_path) .. rom_path .. string.char(M.renderer_id(opts.renderer)) .. string.char(opts.audio_enabled and 1 or 0)
  )
end

function M.encode_set_input(mask) return M.encode(M.client.SET_INPUT, pack_u16(mask or 0)) end

function M.encode_run_frame() return M.encode(M.client.RUN_FRAME, '') end

function M.encode_set_frame_shm_name(name)
  name = name or ''
  assert(type(name) == 'string', 'protocol shm name must be a string')
  assert(#name <= 0xffff, 'protocol shm name must fit in u16')

  return M.encode(M.client.SET_FRAME_SHM_NAME, pack_u16(#name) .. name)
end

function M.encode_stop() return M.encode(M.client.STOP, '') end

local function decode_host_init(payload)
  local width, offset = unpack_u16(payload, 1)
  local height
  height, offset = unpack_u16(payload, offset)

  local pixel_format = payload:byte(offset)
  assert(pixel_format, 'protocol payload truncated while reading init pixel format')

  return {
    width = width,
    height = height,
    pixel_format = pixel_format,
  }
end

local function decode_host_frame(payload)
  local width, offset = unpack_u16(payload, 1)
  local height
  height, offset = unpack_u16(payload, offset)

  local pixel_format = payload:byte(offset)
  assert(pixel_format, 'protocol payload truncated while reading frame pixel format')
  offset = offset + 1

  local frame_id
  frame_id, offset = unpack_u32(payload, offset)

  local pixels = ''
  if offset <= #payload then pixels = payload:sub(offset) end

  return {
    width = width,
    height = height,
    pixel_format = pixel_format,
    frame_id = frame_id,
    pixels = pixels,
  }
end

local function decode_host_message(message_type, payload)
  if message_type == M.host.INIT then return decode_host_init(payload) end

  if message_type == M.host.FRAME then return decode_host_frame(payload) end

  return {
    text = payload,
  }
end

function M.decode_available(buffer)
  local messages = {}
  local offset = 1

  while true do
    local available = #buffer - offset + 1
    if available < HEADER_SIZE then break end

    local message_type = buffer:byte(offset)
    local payload_length = buffer:byte(offset + 1) + (buffer:byte(offset + 2) * 0x100)
    local frame_length = HEADER_SIZE + payload_length
    if available < frame_length then break end

    local payload = ''
    if payload_length > 0 then payload = buffer:sub(offset + HEADER_SIZE, offset + frame_length - 1) end

    messages[#messages + 1] = {
      type = message_type,
      name = M.host_name(message_type),
      payload = payload,
      data = decode_host_message(message_type, payload),
    }

    offset = offset + frame_length
  end

  if offset == 1 then return messages, buffer end

  return messages, buffer:sub(offset)
end

function M.encode_frame_payload(frame)
  return pack_u16(frame.width)
    .. pack_u16(frame.height)
    .. string.char(frame.pixel_format)
    .. pack_u32(frame.frame_id or 0)
    .. (frame.pixels or '')
end

return M
