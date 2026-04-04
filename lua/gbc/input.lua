local bit = require('bit')

local M = {
  button = {
    RIGHT = 0x01,
    LEFT = 0x02,
    UP = 0x04,
    DOWN = 0x08,
    A = 0x10,
    B = 0x20,
    SELECT = 0x40,
    START = 0x80,
  },
}

local state = {
  mask = 0,
}

function M.current_state() return state.mask end

function M.set_state(mask)
  state.mask = bit.band(mask or 0, 0xff)
  return state.mask
end

function M.set_button(button, pressed)
  if pressed then
    state.mask = bit.bor(state.mask, button)
  else
    state.mask = bit.band(state.mask, bit.bnot(button))
  end

  state.mask = bit.band(state.mask, 0xff)
  return state.mask
end

return M
