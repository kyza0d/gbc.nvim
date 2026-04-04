local ui = require('gbc.ui')

local M = {}

local function assert_equal(actual, expected, message)
  if actual == expected then return end

  error(string.format('%s: expected %s, got %s', message, vim.inspect(expected), vim.inspect(actual)))
end

M[#M + 1] = {
  name = 'ui append_capped keeps only the newest entries',
  run = function()
    local items = { 'a', 'b' }
    ui._test.append_capped(items, { 'c', 'd', 'e' }, 3)
    assert_equal(items[1], 'c', 'oldest overflow entries should be trimmed')
    assert_equal(items[2], 'd', 'middle entry should be preserved')
    assert_equal(items[3], 'e', 'newest entry should be preserved')
    assert_equal(#items, 3, 'list size should stay capped')
  end,
}

M[#M + 1] = {
  name = 'ui build_log_lines shows placeholders for empty logs',
  run = function()
    local lines = ui._test.build_log_lines({
      rom_path = nil,
      renderer_requested = 'pending',
      renderer = 'pending',
      renderer_selection_reason = nil,
      renderer_fallback_reason = nil,
      transport_status = 'idle',
      transport_close_reason = nil,
      session_status = 'idle',
      quit_reason = nil,
      kitty_status = 'idle',
      terminal_info = nil,
      bridge_exit = { code = nil, signal = nil },
      screen_geometry = { width = nil, height = nil, pixel_format = nil },
      events = {},
      frames_received = 0,
      frame_lines = { '(no frame yet)' },
      logs = {},
    })

    assert_equal(lines[#lines], '(no logs yet)', 'empty logs should produce a readable placeholder')
  end,
}

return M
