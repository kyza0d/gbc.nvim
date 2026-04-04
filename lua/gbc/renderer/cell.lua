local protocol = require('gbc.protocol')
local profile = require('gbc.profile')

local M = {
  type = 'cell',
}

local Cell = {}

local RAMP = ' .:-=+*#%@'
local MAX_WIDTH = 80
local MAX_HEIGHT = 48

local function ramp_char(value)
  local slot = math.floor((value / 255) * (#RAMP - 1)) + 1
  return RAMP:sub(slot, slot)
end

function M.new(opts)
  return setmetatable({
    screen = assert(opts.screen, 'cell renderer requires a screen'),
  }, { __index = Cell })
end

function Cell:close() end

function Cell:should_auto_stop() return true end

function Cell:render(frame)
  return profile.time('cell.render', function()
    if not frame then return { '(missing frame payload)' } end

    if frame.pixel_format ~= protocol.pixel_format.GRAY8 then
      return {
        string.format('(unsupported pixel format %s)', protocol.pixel_format_name(frame.pixel_format)),
      }
    end

    local width = frame.width or 0
    local height = frame.height or 0
    local pixels = frame.pixels or ''
    local expected = width * height
    if width <= 0 or height <= 0 then return { '(invalid frame geometry)' } end

    if #pixels < expected then
      return {
        string.format('(truncated frame payload: expected %d bytes, got %d)', expected, #pixels),
      }
    end

    local block_width = math.max(1, math.ceil(width / MAX_WIDTH))
    local block_height = math.max(1, math.ceil(height / MAX_HEIGHT))
    local lines = {
      string.format('Frame %d  %dx%d  %s', frame.frame_id or 0, width, height, protocol.pixel_format_name(frame.pixel_format)),
    }

    for y = 0, height - 1, block_height do
      local chars = {}
      for x = 0, width - 1, block_width do
        local total = 0
        local count = 0

        for yy = y, math.min(height - 1, y + block_height - 1) do
          for xx = x, math.min(width - 1, x + block_width - 1) do
            local pixel_index = ((yy * width) + xx) + 1
            local shade = pixels:byte(pixel_index)
            total = total + shade
            count = count + 1
          end
        end

        chars[#chars + 1] = ramp_char(total / count)
      end

      lines[#lines + 1] = table.concat(chars)
    end

    self.screen:render_text(lines)
    return lines
  end)
end

return M
