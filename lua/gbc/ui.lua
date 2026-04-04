local api = vim.api
local profile = require('gbc.profile')

local M = {}

local MAX_EVENT_LINES = 64
local MAX_LOG_LINES = 256
local state = {
  buf = nil,
  win = nil,
  log_buf = nil,
  log_win = nil,
  screen_buf = nil,
  screen_win = nil,
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
  bridge_exit = {
    code = nil,
    signal = nil,
  },
  screen_geometry = {
    width = nil,
    height = nil,
    pixel_format = nil,
  },
  events = {},
  frames_received = 0,
  frame_lines = { '(no frame yet)' },
  logs = {},
}

local screen = nil

local function is_valid_buf(buf) return buf and api.nvim_buf_is_valid(buf) end

local function is_valid_win(win) return win and api.nvim_win_is_valid(win) end

local function mutate(callback)
  local function run() callback() end

  if vim.in_fast_event() then
    vim.schedule(run)
    return
  end

  local ok, err = pcall(run)
  if ok then return end

  if type(err) == 'string' and (err:find('E565:', 1, true) or err:find('E523:', 1, true) or err:find('textlock', 1, true)) then
    vim.schedule(run)
    return
  end

  error(err)
end

local function apply_screen_window_options(win)
  api.nvim_set_option_value('wrap', false, { win = win })
  api.nvim_set_option_value('number', false, { win = win })
  api.nvim_set_option_value('relativenumber', false, { win = win })
  api.nvim_set_option_value('cursorline', false, { win = win })
  api.nvim_set_option_value('cursorcolumn', false, { win = win })
  api.nvim_set_option_value('spell', false, { win = win })
  api.nvim_set_option_value('list', false, { win = win })
  api.nvim_set_option_value('signcolumn', 'no', { win = win })
  api.nvim_set_option_value('foldcolumn', '0', { win = win })
  api.nvim_set_option_value('statuscolumn', '', { win = win })
  api.nvim_set_option_value('winfixbuf', true, { win = win })
end

local function ensure_log_buffer()
  if is_valid_buf(state.log_buf) then return state.log_buf end

  state.log_buf = api.nvim_create_buf(false, true)
  vim.bo[state.log_buf].buftype = 'nofile'
  vim.bo[state.log_buf].bufhidden = 'hide'
  vim.bo[state.log_buf].swapfile = false
  vim.bo[state.log_buf].filetype = 'gbc-log'
  api.nvim_buf_set_name(state.log_buf, 'gbc://log')

  return state.log_buf
end

local log_refresh_pending = false
local LOG_REFRESH_INTERVAL_MS = 100

local function trim_list(list, max_items)
  local overflow = #list - max_items
  if overflow <= 0 then return end

  table.move(list, overflow + 1, #list, 1, list)
  for index = #list, (#list - overflow) + 1, -1 do
    list[index] = nil
  end
end

local function append_capped(list, values, max_items)
  if not values or #values == 0 then return end

  vim.list_extend(list, values)
  trim_list(list, max_items)
end

local function build_log_lines(current)
  local geometry = current.screen_geometry.width
      and current.screen_geometry.height
      and string.format(
        '%dx%d %s',
        current.screen_geometry.width,
        current.screen_geometry.height,
        current.screen_geometry.pixel_format or 'unknown'
      )
    or '(unknown)'

  local lines = {
    'gbc.nvim',
    '',
    'ROM: ' .. (current.rom_path or '(none)'),
    'Renderer Requested: ' .. current.renderer_requested,
    'Renderer: ' .. current.renderer,
    'Renderer Reason: ' .. (current.renderer_selection_reason or '(none)'),
    'Renderer Fallback: ' .. (current.renderer_fallback_reason or '(none)'),
    'Kitty: ' .. current.kitty_status,
    'Terminal: ' .. (current.terminal_info or '(unknown)'),
    'Transport: ' .. current.transport_status,
    'Transport Close: ' .. (current.transport_close_reason or '(open)'),
    'Session: ' .. current.session_status,
    'Quit: ' .. (current.quit_reason or '(none)'),
    'Bridge Exit: '
      .. (current.bridge_exit.code == nil and '(running)' or tostring(current.bridge_exit.code))
      .. (current.bridge_exit.signal and current.bridge_exit.signal ~= 0 and (' signal=' .. current.bridge_exit.signal) or ''),
    'Screen: ' .. geometry,
    'Frames Received: ' .. current.frames_received,
    '',
    'Events:',
  }

  vim.list_extend(lines, vim.tbl_isempty(current.events) and { '(no events yet)' } or current.events)
  vim.list_extend(lines, {
    '',
    'Frame:',
  })
  vim.list_extend(lines, current.frame_lines)
  lines[#lines + 1] = ''
  lines[#lines + 1] = 'Logs:'
  vim.list_extend(lines, vim.tbl_isempty(current.logs) and { '(no logs yet)' } or current.logs)

  return lines
end

local function refresh_log_now()
  log_refresh_pending = false
  local buf = ensure_log_buffer()
  if not is_valid_buf(buf) then return end

  local lines = profile.time('ui.refresh_log.build_lines', build_log_lines, state)
  profile.time('ui.refresh_log.set_lines', api.nvim_buf_set_lines, buf, 0, -1, false, lines)
end

local function refresh_log()
  if log_refresh_pending then return end

  log_refresh_pending = true
  vim.defer_fn(refresh_log_now, LOG_REFRESH_INTERVAL_MS)
end

local Screen = {}

local tty_write = api.nvim_ui_send or function(data)
  io.stderr:write(data)
  io.stderr:flush()
end

function Screen.new(opts)
  local current = setmetatable({
    buf = nil,
    win = nil,
    term_chan = nil,
    term_width = nil,
    term_height = nil,
    res_x = nil,
    res_y = nil,
    closed = false,
    tty_ui_available = false,
    tmux_passthrough = opts.tmux_passthrough or false,
    augroup = nil,
    resize_handler = nil,
    term_response_handler = nil,
    close_handler = nil,
  }, { __index = Screen })

  return current
end

function Screen:refresh_ui_capabilities()
  if vim.in_fast_event() then return self.tty_ui_available end

  self.tty_ui_available = false
  for _, ui in ipairs(api.nvim_list_uis()) do
    if ui.stdout_tty then
      self.tty_ui_available = true
      break
    end
  end
end

function Screen:has_tty_ui()
  if not vim.in_fast_event() then self:refresh_ui_capabilities() end

  return self.tty_ui_available
end

function Screen:_notify_resize(reason)
  if not self.resize_handler then return end

  self.resize_handler(reason, self.term_width, self.term_height)
end

function Screen:_notify_term_response(sequence, source)
  if not self.term_response_handler or not sequence or sequence == '' then return end

  self.term_response_handler(sequence, source or 'unknown')
end

function Screen:_notify_close(reason)
  if not self.close_handler then return end

  self.close_handler(reason)
end

function Screen:_ensure_autocmds()
  if self.augroup then return end

  self.augroup = api.nvim_create_augroup(string.format('gbc-screen-%d', self.buf), { clear = true })

  api.nvim_create_autocmd('TermResponse', {
    group = self.augroup,
    callback = function(args)
      if self.closed then return end

      self:_notify_term_response(args.data.sequence, 'TermResponse')
    end,
    desc = '[gbc.nvim] Forward terminal responses to the active renderer',
  })

  api.nvim_create_autocmd({ 'VimResized', 'WinResized', 'BufWinEnter' }, {
    group = self.augroup,
    callback = function(args)
      if self.closed then return end

      if args.event == 'WinResized' and is_valid_win(self.win) and vim.v.event then
        if not vim.list_contains(vim.v.event.windows or {}, self.win) then return end
      end

      local changed = self:update_term_size({ use_fallback = true })
      if changed then self:_notify_resize(args.event) end
    end,
    desc = '[gbc.nvim] Refresh terminal dimensions for the active screen',
  })

  api.nvim_create_autocmd('WinClosed', {
    group = self.augroup,
    callback = function(args)
      if self.closed or not self.win or tonumber(args.match) ~= self.win then return end

      self.win = nil
      state.screen_win = nil
    end,
    desc = '[gbc.nvim] Track the active screen window',
  })

  api.nvim_create_autocmd({ 'BufUnload', 'BufWipeout', 'VimLeavePre' }, {
    group = self.augroup,
    callback = function(args)
      if self.closed then return end

      if args.event ~= 'VimLeavePre' and args.buf ~= self.buf then return end

      self:_notify_close(args.event)
    end,
    desc = '[gbc.nvim] Stop the active session when the screen disappears',
  })
end

function Screen:ensure_buffer()
  if is_valid_buf(self.buf) then return self.buf end

  self.buf = api.nvim_create_buf(true, true)
  vim.bo[self.buf].bufhidden = 'hide'
  vim.bo[self.buf].swapfile = false
  vim.bo[self.buf].filetype = 'gbc-screen'
  api.nvim_buf_set_name(self.buf, 'gbc://screen')

  self.term_chan = api.nvim_open_term(self.buf, {
    on_input = function(_, _, _, data)
      local lines, columns = data:match('^\27%[(%d+);(%d+)R$')
      if lines then
        local width = tonumber(columns)
        local height = tonumber(lines)
        local changed = width ~= self.term_width or height ~= self.term_height
        self.term_width = width
        self.term_height = height
        if changed then self:_notify_resize('dsr') end
      end

      self:_notify_term_response(data, 'term_input')
    end,
    force_crlf = false,
  })
  api.nvim_chan_send(self.term_chan, '\27[?25l\27[?7l')
  api.nvim_set_option_value('scrollback', 1, { buf = self.buf })

  state.screen_buf = self.buf
  self:_ensure_autocmds()
  return self.buf
end

function Screen:ensure_window()
  if is_valid_win(self.win) then
    apply_screen_window_options(self.win)
    return self.win
  end

  vim.cmd('botright vsplit')
  self.win = api.nvim_get_current_win()
  api.nvim_win_set_buf(self.win, self:ensure_buffer())
  apply_screen_window_options(self.win)

  state.screen_win = self.win
  return self.win
end

function Screen:open()
  self:ensure_buffer()
  self:ensure_window()
  self:refresh_ui_capabilities()
  api.nvim_win_set_buf(self.win, self.buf)
end

function Screen:run(callback)
  mutate(function()
    if self.closed then return end

    self:open()
    callback(self)
  end)
end

function Screen:passthrough_escape(seq)
  if self.tmux_passthrough then return ('\27Ptmux;%s\27\\'):format(seq:gsub('\27', '\27\27')) end

  return seq
end

function Screen:update_term_size(opts)
  opts = opts or {}
  local old_term_width = self.term_width
  local old_term_height = self.term_height

  if self.term_chan then
    -- Match actually-doom.nvim: ask the terminal for the current cursor
    -- position after moving to the bottom-right, which yields the real
    -- drawable cell area for this terminal surface.
    api.nvim_chan_send(self.term_chan, '\27[99999;99999H\27[6n')
  end

  -- Only fall back when the DSR path has not populated dimensions yet.
  -- Overwriting a real CPR result with window dimensions makes the kitty
  -- placeholder grid drift away from the terminal's actual drawable area.
  if not self.term_width or not self.term_height then
    if is_valid_win(self.win) then
      self.term_width = api.nvim_win_get_width(self.win)
      self.term_height = api.nvim_win_get_height(self.win)
    else
      self.term_width = api.nvim_get_option_value('columns', {})
      self.term_height = api.nvim_get_option_value('lines', {}) - api.nvim_get_option_value('cmdheight', {})
    end
  end

  self.term_width = math.max(1, self.term_width or 1)
  self.term_height = math.max(1, self.term_height or 1)
  return self.term_width ~= old_term_width or self.term_height ~= old_term_height
end

function Screen:set_geometry(width, height)
  self.res_x = width
  self.res_y = height
end

function Screen:send_term(data)
  if not self.term_chan then return end

  api.nvim_chan_send(self.term_chan, data)
end

function Screen:clear()
  self:run(function(current) current:send_term('\27[m\27[2J\27[3J\27[H') end)
end

function Screen:render_text(lines)
  self:run(function(current)
    current:update_term_size()
    profile.time('screen.render_text', current.send_term, current, '\27[m\27[2J\27[3J\27[H' .. table.concat(lines, '\r\n'))
  end)
end

function Screen:send_tty(data)
  self:run(function(current)
    if not current:has_tty_ui() then return end

    tty_write(data)
  end)
end

function Screen:set_resize_handler(handler) self.resize_handler = handler end

function Screen:set_term_response_handler(handler) self.term_response_handler = handler end

function Screen:set_close_handler(handler) self.close_handler = handler end

function Screen:close()
  self.closed = true
  if self.augroup then
    pcall(api.nvim_del_augroup_by_id, self.augroup)
    self.augroup = nil
  end
end

function M.open(rom_path, opts)
  opts = opts or {}

  mutate(function()
    local log_buf = ensure_log_buffer()
    if not is_valid_win(state.log_win) then state.log_win = api.nvim_get_current_win() end
    api.nvim_win_set_buf(state.log_win, log_buf)
    api.nvim_set_option_value('wrap', false, { win = state.log_win })

    if not screen or screen.closed then
      screen = Screen.new({
        tmux_passthrough = opts.tmux_passthrough or false,
      })
    else
      screen.tmux_passthrough = opts.tmux_passthrough or false
      screen.closed = false
    end

    screen:open()

    state.log_buf = log_buf
    state.buf = log_buf
    state.win = state.log_win
    state.screen_buf = screen.buf
    state.screen_win = screen.win
    state.rom_path = rom_path
    state.renderer_requested = opts.renderer_requested or opts.renderer or 'pending'
    state.renderer = opts.renderer or 'pending'
    state.renderer_selection_reason = opts.renderer_reason or nil
    state.renderer_fallback_reason = nil
    state.transport_status = 'starting'
    state.transport_close_reason = nil
    state.session_status = 'waiting for bridge'
    state.quit_reason = nil
    state.kitty_status = 'idle'
    state.terminal_info = opts.terminal_info or nil
    state.bridge_exit = {
      code = nil,
      signal = nil,
    }
    state.screen_geometry = {
      width = nil,
      height = nil,
      pixel_format = nil,
    }
    state.events = {}
    state.frames_received = 0
    state.frame_lines = { '(no frame yet)' }
    state.logs = {}

    refresh_log()
    screen:clear()
    api.nvim_set_current_win(screen.win)
  end)

  return {
    buf = state.log_buf,
    win = state.log_win,
    screen_buf = state.screen_buf,
    screen_win = state.screen_win,
  }
end

function M.screen() return screen end

M._test = {
  append_capped = append_capped,
  build_log_lines = build_log_lines,
  max_event_lines = MAX_EVENT_LINES,
  max_log_lines = MAX_LOG_LINES,
  new_screen = function(opts) return Screen.new(opts or {}) end,
}

function M.set_renderer(name)
  mutate(function()
    state.renderer = name or 'pending'
    refresh_log()
  end)
end

function M.set_renderer_requested(name)
  mutate(function()
    state.renderer_requested = name or 'pending'
    refresh_log()
  end)
end

function M.set_renderer_reason(reason)
  mutate(function()
    state.renderer_selection_reason = reason
    refresh_log()
  end)
end

function M.set_renderer_fallback_reason(reason)
  mutate(function()
    state.renderer_fallback_reason = reason
    refresh_log()
  end)
end

function M.set_kitty_status(status)
  mutate(function()
    state.kitty_status = status or 'idle'
    refresh_log()
  end)
end

function M.set_terminal_info(info)
  mutate(function()
    state.terminal_info = info
    refresh_log()
  end)
end

function M.set_transport_status(status)
  mutate(function()
    state.transport_status = status or 'idle'
    refresh_log()
  end)
end

function M.set_transport_closed(reason)
  mutate(function()
    state.transport_close_reason = reason
    refresh_log()
  end)
end

function M.set_session_status(status)
  mutate(function()
    state.session_status = status or 'idle'
    refresh_log()
  end)
end

function M.set_screen_geometry(width, height, pixel_format)
  mutate(function()
    state.screen_geometry = {
      width = width,
      height = height,
      pixel_format = pixel_format,
    }
    if screen then screen:set_geometry(width, height) end
    refresh_log()
  end)
end

function M.render_frame(lines, opts)
  opts = opts or {}
  state.frame_lines = (lines and #lines > 0) and lines or { '(empty frame)' }
  if opts.refresh == false then return end

  refresh_log()
end

function M.set_frames_received(count) state.frames_received = count or 0 end

function M.set_quit_reason(reason)
  mutate(function()
    state.quit_reason = reason
    refresh_log()
  end)
end

function M.set_bridge_exit(code, signal)
  mutate(function()
    state.bridge_exit = {
      code = code,
      signal = signal,
    }
    refresh_log()
  end)
end

function M.record_event(event)
  mutate(function()
    if not event or event == '' then return end

    append_capped(state.events, { event }, MAX_EVENT_LINES)
    refresh_log()
  end)
end

function M.append_log(message)
  mutate(function()
    local lines = vim.split(message, '\n', { trimempty = true })
    if vim.tbl_isempty(lines) then return end

    append_capped(state.logs, lines, MAX_LOG_LINES)
    refresh_log()
  end)
end

function M.state() return vim.deepcopy(state) end

return M
