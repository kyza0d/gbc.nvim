local protocol = require('gbc.protocol')
local ui = require('gbc.ui')

local M = {}

local function assert_equal(actual, expected, message)
  if actual == expected then return end

  error(string.format('%s: expected %s, got %s', message, vim.inspect(expected), vim.inspect(actual)))
end

local function assert_contains(haystack, needle, message)
  if haystack and haystack:find(needle, 1, true) then return end

  error(string.format('%s: missing %q in %s', message, needle, vim.inspect(haystack)))
end

local function with_api_stubs(stubs, fn)
  local saved = {}
  for name, value in pairs(stubs) do
    saved[name] = vim.api[name]
    vim.api[name] = value
  end

  local ok, result = xpcall(fn, debug.traceback)

  for name, value in pairs(saved) do
    vim.api[name] = value
  end

  if not ok then error(result) end

  return result
end

M[#M + 1] = {
  name = 'update_term_size falls back before the first DSR result',
  run = function()
    local screen = ui._test.new_screen()
    screen.win = 17
    screen.term_chan = 23

    with_api_stubs({
      nvim_chan_send = function() end,
      nvim_win_is_valid = function(win) return win == screen.win end,
      nvim_win_get_width = function(win)
        assert_equal(win, screen.win, 'fallback width queried from the active window')
        return 60
      end,
      nvim_win_get_height = function(win)
        assert_equal(win, screen.win, 'fallback height queried from the active window')
        return 18
      end,
    }, function()
      local changed = screen:update_term_size({ use_fallback = true })
      assert_equal(changed, true, 'first size update should report a change')
      assert_equal(screen.term_width, 60, 'fallback width should seed the screen size')
      assert_equal(screen.term_height, 18, 'fallback height should seed the screen size')
    end)
  end,
}

M[#M + 1] = {
  name = 'kitty presentation keeps the DSR size instead of overwriting it with window fallback',
  run = function()
    local screen = ui._test.new_screen()
    screen.win = 7
    screen.term_chan = 99
    screen.tty_ui_available = true
    ---@diagnostic disable-next-line:duplicate-set-field
    screen.refresh_ui_capabilities = function() end
    ---@diagnostic disable-next-line:duplicate-set-field
    screen.run = function(self, callback) callback(self) end

    local term_writes = {}
    local tty_writes = {}

    with_api_stubs({
      nvim_chan_send = function(_, data)
        if data == '\27[99999;99999H\27[6n' then
          screen.term_width = 61
          screen.term_height = 17
          return
        end

        term_writes[#term_writes + 1] = data
      end,
      nvim_win_is_valid = function(win) return win == screen.win end,
      nvim_win_get_width = function() return 60 end,
      nvim_win_get_height = function() return 18 end,
      nvim_ui_send = function(data) tty_writes[#tty_writes + 1] = data end,
    }, function()
      package.loaded['gbc.renderer.kitty'] = nil
      local kitty = require('gbc.renderer.kitty').new({
        screen = screen,
        shm_name = '/gbc-kitty-regression',
      })

      local lines = kitty:render({
        width = 160,
        height = 144,
        pixel_format = protocol.pixel_format.RGB24_SHM,
        frame_id = 1,
        pixels = '',
      })

      assert_equal(lines[2], '(kitty graphics active)', 'kitty render should report an active image')
      assert_contains(term_writes[1], '\27[38;5;', 'placeholder grid should be written to the term buffer')
      assert_contains(tty_writes[1], 'c=61,r=17', 'kitty placement should use the DSR-reported size')
      if tty_writes[1]:find('c=60,r=18', 1, true) then
        error('kitty placement incorrectly used the window fallback dimensions')
      end
    end)

    package.loaded['gbc.renderer.kitty'] = nil
  end,
}

return M
