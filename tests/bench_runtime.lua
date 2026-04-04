local repo_root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.runtimepath:append(repo_root)

local ui = require('gbc.ui')
local protocol = require('gbc.protocol')
local uv = vim.uv or vim.loop

local function measure(iterations, fn)
  collectgarbage('collect')
  local started = uv.hrtime()
  for index = 1, iterations do
    fn(index)
  end
  return (uv.hrtime() - started) / 1000000
end

local function base_state()
  return {
    rom_path = '/tmp/pokemon.gbc',
    renderer_requested = 'kitty',
    renderer = 'kitty',
    renderer_selection_reason = 'bench',
    renderer_fallback_reason = nil,
    transport_status = 'connected',
    transport_close_reason = nil,
    session_status = 'running',
    quit_reason = nil,
    kitty_status = 'active',
    terminal_info = 'kitty',
    bridge_exit = {
      code = nil,
      signal = nil,
    },
    screen_geometry = {
      width = 160,
      height = 144,
      pixel_format = 'rgb24_shm',
    },
    events = {},
    frames_received = 3600,
    frame_lines = {
      'Frame 3600  160x144  rgb24_shm',
      '(kitty graphics active)',
    },
    logs = {},
  }
end

local function seed_legacy_state(log_count, event_count)
  local state = base_state()
  for index = 1, event_count do
    state.events[#state.events + 1] = 'event ' .. index
  end
  for index = 1, log_count do
    state.logs[#state.logs + 1] = 'Protocol -> CMSG_RUN_FRAME ' .. index
  end
  return state
end

local function seed_capped_state(log_count, event_count)
  local state = base_state()
  for index = 1, event_count do
    ui._test.append_capped(state.events, { 'event ' .. index }, ui._test.max_event_lines)
  end
  for index = 1, log_count do
    ui._test.append_capped(state.logs, { 'Protocol -> CMSG_RUN_FRAME ' .. index }, ui._test.max_log_lines)
  end
  return state
end

local function bench_log_refresh()
  local legacy = seed_legacy_state(3600, 600)
  local capped = seed_capped_state(3600, 600)
  local iterations = 250
  local legacy_ms = measure(iterations, function() ui._test.build_log_lines(legacy) end)
  local capped_ms = measure(iterations, function() ui._test.build_log_lines(capped) end)

  print('log_refresh')
  print(string.format('  legacy lines: %d', #ui._test.build_log_lines(legacy)))
  print(string.format('  capped lines: %d', #ui._test.build_log_lines(capped)))
  print(string.format('  legacy total: %.3fms avg: %.3fms', legacy_ms, legacy_ms / iterations))
  print(string.format('  capped total: %.3fms avg: %.3fms', capped_ms, capped_ms / iterations))
end

local function bench_renderers()
  local saved_ui_send = vim.api.nvim_ui_send
  local saved_chan_send = vim.api.nvim_chan_send
  local tty_writes = {}
  local term_writes = {}

  vim.api.nvim_ui_send = function(data) tty_writes[#tty_writes + 1] = data end
  vim.api.nvim_chan_send = function(_, data) term_writes[#term_writes + 1] = data end

  package.loaded['gbc.renderer.kitty'] = nil
  package.loaded['gbc.renderer.cell'] = nil

  local screen = {
    term_width = 61,
    term_height = 17,
    tty_ui_available = true,
    refresh_ui_capabilities = function() end,
    has_tty_ui = function() return true end,
    set_geometry = function() end,
    update_term_size = function() return false end,
    send_term = function(_, data) term_writes[#term_writes + 1] = data end,
    passthrough_escape = function(_, seq) return seq end,
    render_text = function() end,
  }

  local kitty = require('gbc.renderer.kitty').new({
    screen = screen,
    shm_name = '/gbc-bench-runtime',
  })
  local kitty_frame = {
    width = 160,
    height = 144,
    pixel_format = protocol.pixel_format.RGB24_SHM,
    frame_id = 1,
    pixels = '',
  }
  kitty:render(kitty_frame)
  local kitty_iterations = 1000
  local kitty_ms = measure(kitty_iterations, function(index)
    kitty_frame.frame_id = index + 1
    kitty:render(kitty_frame)
  end)

  local gray_pixels = string.rep(string.char(127), 160 * 144)
  local cell = require('gbc.renderer.cell').new({
    screen = screen,
  })
  local cell_frame = {
    width = 160,
    height = 144,
    pixel_format = protocol.pixel_format.GRAY8,
    frame_id = 1,
    pixels = gray_pixels,
  }
  local cell_iterations = 40
  local cell_ms = measure(cell_iterations, function(index)
    cell_frame.frame_id = index
    cell:render(cell_frame)
  end)

  vim.api.nvim_ui_send = saved_ui_send
  vim.api.nvim_chan_send = saved_chan_send
  package.loaded['gbc.renderer.kitty'] = nil
  package.loaded['gbc.renderer.cell'] = nil

  print('renderers')
  print(string.format('  kitty steady-state avg: %.3fms', kitty_ms / kitty_iterations))
  print(string.format('  cell avg: %.3fms', cell_ms / cell_iterations))
end

bench_log_refresh()
bench_renderers()
