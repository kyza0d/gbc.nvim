local config = require('gbc.config')
local game = require('gbc.game')

local M = {}

local function assert_equal(actual, expected, message)
  if actual == expected then return end

  error(string.format('%s: expected %s, got %s', message, vim.inspect(expected), vim.inspect(actual)))
end

M[#M + 1] = {
  name = 'config defaults expose a 60fps frameloop target',
  run = function() assert_equal(config.defaults().target_fps, 60, 'default target fps should be 60') end,
}

M[#M + 1] = {
  name = 'frameloop timing falls back to 60fps for invalid targets',
  run = function()
    local helpers = game._test
    assert_equal(helpers.normalize_target_fps(nil), 60, 'nil target fps should fall back')
    assert_equal(helpers.normalize_target_fps(0), 60, 'zero target fps should fall back')
    assert_equal(helpers.normalize_target_fps('120'), 120, 'numeric strings should be accepted')
  end,
}

M[#M + 1] = {
  name = 'frameloop deadlines advance by one frame budget and clamp when behind',
  run = function()
    local helpers = game._test
    local loop = {
      frame_interval_ns = helpers.frame_interval_ns(60),
      next_due_ns = nil,
    }

    local first_due = helpers.advance_frame_deadline(loop, 1000000000)
    assert_equal(first_due, 1000000000, 'first deadline should start immediately')
    assert_equal(helpers.frame_delay_ms(first_due, 1000000000), 0, 'first frame should not wait')

    local second_due = helpers.advance_frame_deadline(loop, 1005000000)
    assert_equal(second_due, first_due + loop.frame_interval_ns, 'second deadline should add one frame interval')

    local late_due = helpers.advance_frame_deadline(loop, 2000000000)
    assert_equal(late_due, 2000000000, 'deadline should clamp forward when the loop falls behind')
  end,
}

return M
