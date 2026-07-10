local winbar = require('gbc.ui.winbar')

local M = {}

local function assert_match(haystack, needle, message)
  if haystack:find(needle, 1, true) then return end

  error(string.format('%s: %q not found in %q', message, needle, haystack))
end

local function with_scratch_window(run)
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, false, {
    relative = 'editor',
    row = 1,
    col = 1,
    width = 60,
    height = 10,
  })

  local ok, err = xpcall(function() run(win, buf) end, debug.traceback)

  winbar.detach()
  if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end

  if not ok then error(err) end
end

M[#M + 1] = {
  name = 'winbar attach renders title and clickable menu buttons',
  run = function()
    with_scratch_window(function(win, buf)
      winbar.attach(win, buf)

      local value = vim.api.nvim_get_option_value('winbar', { win = win })
      assert_match(value, 'gbc.nvim', 'idle title should render')
      for _, label in ipairs({ 'ROMs', 'Speed', 'States', 'Pause' }) do
        assert_match(value, label, 'button label should render')
      end
      assert_match(value, '@v:lua.__gbc_winbar_callbacks.roms@', 'buttons should carry click callbacks')
    end)
  end,
}

M[#M + 1] = {
  name = 'winbar detach clears the winbar option',
  run = function()
    with_scratch_window(function(win, buf)
      winbar.attach(win, buf)
      winbar.detach()

      local value = vim.api.nvim_get_option_value('winbar', { win = win })
      if value ~= '' then error('winbar should be cleared after detach, got ' .. vim.inspect(value)) end
    end)
  end,
}

M[#M + 1] = {
  name = 'winbar speed menu opens with speed options',
  run = function()
    with_scratch_window(function(win, buf)
      winbar.attach(win, buf)
      winbar.handle_click('speed')

      local menu_win
      vim.wait(1000, function()
        for _, candidate in ipairs(vim.api.nvim_list_wins()) do
          local config = vim.api.nvim_win_get_config(candidate)
          if config.relative ~= '' and candidate ~= win then
            menu_win = candidate
            return true
          end
        end
        return false
      end, 10)

      if not menu_win then error('speed menu float did not open') end

      local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(menu_win), 0, -1, false)
      local text = table.concat(lines, '\n')
      for _, speed in ipairs({ '0.25x', '0.5x', '1x', '2x', '3x', '4x' }) do
        assert_match(text, speed, 'speed option should be listed')
      end
    end)
  end,
}

return M
