local controls = require('gbc.controls')
local input = require('gbc.input')

local M = {}

local function assert_equal(actual, expected, message)
  if actual == expected then return end

  error(string.format('%s: expected %s, got %s', message, vim.inspect(expected), vim.inspect(actual)))
end

M[#M + 1] = {
  name = 'controls normalize mapping resolves known button names',
  run = function()
    local normalized = controls._test.normalize_mapping({
      ['<Left>'] = 'LEFT',
      x = 'A',
      ['<F1>'] = 'UNKNOWN_BUTTON',
    })

    assert_equal(normalized[controls._test.normalize_key('<Left>')], input.button.LEFT, 'left arrow should map to LEFT')
    assert_equal(normalized[controls._test.normalize_key('x')], input.button.A, 'x should map to A')
    assert_equal(normalized[controls._test.normalize_key('<F1>')], nil, 'unknown button names should be ignored')
  end,
}

M[#M + 1] = {
  name = 'controls press_button sets mask bit and starts release timer',
  run = function()
    local calls = {}
    local old_set_button = input.set_button
    input.set_button = function(button, pressed)
      calls[#calls + 1] = { button = button, pressed = pressed }
      return 0
    end

    local timer_start
    local entry = {
      deadlines = {},
      key_hold_ms = 75,
      timer_running = false,
      closed = false,
      timer = {
        start = function(_, delay) timer_start = delay end,
      },
    }

    local ok, err = xpcall(function()
      controls._test.press_button(entry, input.button.A, 1000)

      assert_equal(entry.deadlines[input.button.A], 1075, 'deadline should be set from key hold duration')
      assert_equal(entry.timer_running, true, 'press should arm the release timer')
      assert_equal(timer_start, 75, 'release timer should schedule at key hold duration')
      assert_equal(#calls, 1, 'press should update one button state')
      assert_equal(calls[1].button, input.button.A, 'press should target the mapped button')
      assert_equal(calls[1].pressed, true, 'press should set the button as pressed')
    end, debug.traceback)

    input.set_button = old_set_button
    if not ok then error(err) end
  end,
}

M[#M + 1] = {
  name = 'controls process_deadlines releases expired buttons and re-arms timer',
  run = function()
    local releases = {}
    local old_set_button = input.set_button
    input.set_button = function(button, pressed)
      releases[#releases + 1] = { button = button, pressed = pressed }
      return 0
    end

    local next_delay
    local entry = {
      deadlines = {
        [input.button.LEFT] = 1000,
        [input.button.RIGHT] = 1250,
      },
      timer_running = true,
      closed = false,
      timer = {
        start = function(_, delay) next_delay = delay end,
      },
    }

    local ok, err = xpcall(function()
      controls._test.process_deadlines(entry, 1100)

      assert_equal(entry.deadlines[input.button.LEFT], nil, 'expired button should be cleared')
      assert_equal(entry.deadlines[input.button.RIGHT], 1250, 'future button should remain pressed')
      assert_equal(next_delay, 150, 'timer should be re-armed for earliest remaining deadline')
      assert_equal(#releases, 1, 'one button should be released')
      assert_equal(releases[1].button, input.button.LEFT, 'released button should match expired deadline')
      assert_equal(releases[1].pressed, false, 'expired deadline should release the button')
    end, debug.traceback)

    input.set_button = old_set_button
    if not ok then error(err) end
  end,
}

return M
