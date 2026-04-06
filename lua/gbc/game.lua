local build = require('gbc.build')
local config = require('gbc.config')
local controls = require('gbc.controls')
local input = require('gbc.input')
local kitty_support = require('gbc.kitty_support')
local profile = require('gbc.profile')
local protocol = require('gbc.protocol')
local transport = require('gbc.transport')
local ui = require('gbc.ui')
local uv = vim.uv or vim.loop

local M = {}

local session = {}
local DEFAULT_TARGET_FPS = 60
local FRAME_DIAGNOSTIC_INTERVAL_NS = 250 * 1000000

local function frame_shm_name() return string.format('/gbc-%d-%d', vim.fn.getpid(), math.floor(uv.hrtime() / 1000)) end

local function close_timer(timer)
  if not timer then return end

  pcall(timer.stop, timer)
  if timer.is_closing and timer:is_closing() then return end

  pcall(timer.close, timer)
end

local function normalize_renderer_value(value)
  if type(value) ~= 'string' then return nil end

  local normalized = vim.trim(value):lower()
  if normalized == '' then return nil end

  return normalized
end

local function normalize_target_fps(value)
  local numeric = tonumber(value)
  if not numeric or numeric <= 0 then return DEFAULT_TARGET_FPS end

  return numeric
end

local function frame_interval_ns(target_fps) return math.floor(1000000000 / normalize_target_fps(target_fps)) end

local function advance_frame_deadline(loop, now_ns)
  now_ns = now_ns or uv.hrtime()

  if not loop.next_due_ns then
    loop.next_due_ns = now_ns
    return loop.next_due_ns
  end

  loop.next_due_ns = loop.next_due_ns + loop.frame_interval_ns
  if loop.next_due_ns < now_ns then loop.next_due_ns = now_ns end

  return loop.next_due_ns
end

local function frame_delay_ms(next_due_ns, now_ns)
  now_ns = now_ns or uv.hrtime()
  if not next_due_ns or next_due_ns <= now_ns then return 0 end

  return math.max(0, math.floor(((next_due_ns - now_ns) / 1000000) + 0.5))
end

local function log(message, level)
  local formatted = '[gbc] ' .. message
  vim.schedule(function()
    if (level or vim.log.levels.INFO) >= vim.log.levels.WARN then
      vim.notify(formatted, level or vim.log.levels.INFO, { title = 'gbc.nvim' })
    end
    ui.append_log(formatted)
  end)
end

local function record_event(event) ui.record_event(event) end

local function append_profile_summary(current)
  if not current or current.profile_summary_appended or not profile.enabled() then return end

  local lines = profile.summary_lines()
  if vim.tbl_isempty(lines) then return end

  current.profile_summary_appended = true
  ui.append_log('[gbc][profile]\n' .. table.concat(lines, '\n'))
end

local function socket_dir()
  local candidates = {
    (uv.os_tmpdir and uv.os_tmpdir() or nil),
    vim.fn.stdpath('run'),
    '/tmp',
    vim.fn.stdpath('cache'),
  }

  for _, base in ipairs(candidates) do
    if base and base ~= '' then
      local dir = base .. '/gbc'
      vim.fn.mkdir(dir, 'p')
      if vim.fn.isdirectory(dir) == 1 and vim.fn.filewritable(dir) == 2 then return dir end
    end
  end

  error('gbc.nvim could not find a writable socket directory')
end

local function socket_path()
  local name = string.format('gbc-%d-%d.sock', vim.fn.getpid(), math.floor(uv.hrtime() / 1000))
  return socket_dir() .. '/' .. name
end

local function cleanup_socket(path)
  if not path or path == '' then return end

  pcall(uv.fs_unlink, path)
end

local function is_active(current) return session.current == current end

local function close_renderer(current)
  if current.renderer and current.renderer.close then pcall(current.renderer.close, current.renderer) end
end

local function cancel_frame_timer(current)
  if not current or not current.frame_timer then return end

  close_timer(current.frame_timer)
  current.frame_timer = nil
end

local function close_transport(current, reason)
  cancel_frame_timer(current)
  current.frame_in_flight = false
  if current.transport then
    current.transport:close(reason)
    current.transport = nil
  end
end

local function stop_active_session(reason)
  local active = session.current
  if not active then return end

  session.current = nil
  controls.detach(active)
  cancel_frame_timer(active)
  if active.transport and active.transport.connected then
    active.stop_sent = true
    active.transport:send(protocol.encode_stop(), protocol.client_name(protocol.client.STOP))
  end
  close_renderer(active)
  close_transport(active, reason or 'replaced')

  if active.handle and not active.handle:is_closing() then pcall(active.handle.kill, active.handle, 15) end
end

local function send_message(current, payload, message_type, opts)
  if not current.transport then return false, 'missing transport' end

  local ok, err = current.transport:send(payload, protocol.client_name(message_type), opts)
  if not ok then
    log('Failed to send ' .. protocol.client_name(message_type) .. ': ' .. err, vim.log.levels.ERROR)
    return false, err
  end

  return true
end

local function ensure_frame_timer(current)
  if current.frame_timer then return current.frame_timer end

  current.frame_timer = assert(uv.new_timer())
  return current.frame_timer
end

local function ensure_frame_shm(current)
  if not current.frame_shm_name or current.frame_shm_sent then return true end

  if
    send_message(
      current,
      protocol.encode_set_frame_shm_name(current.frame_shm_name),
      protocol.client.SET_FRAME_SHM_NAME,
      { log = true }
    )
  then
    current.frame_shm_sent = true
    record_event(protocol.client_name(protocol.client.SET_FRAME_SHM_NAME))
    return true
  end

  return false
end

local function sync_input(current)
  local current_input = input.current_state()
  if current.last_input_mask == current_input then return true end

  if send_message(current, protocol.encode_set_input(current_input), protocol.client.SET_INPUT) then
    current.last_input_mask = current_input
    record_event(protocol.client_name(protocol.client.SET_INPUT))
    return true
  end

  return false
end

local function request_frame(current, reason)
  if current.stop_sent or current.frame_in_flight or not current.initialized or not is_active(current) then return end

  cancel_frame_timer(current)

  if not ensure_frame_shm(current) then return end

  if not sync_input(current) then return end

  current.frame_in_flight = true
  current.last_frame_request_ns = uv.hrtime()

  if send_message(current, protocol.encode_run_frame(), protocol.client.RUN_FRAME) then return end

  current.frame_in_flight = false
end

local function should_refresh_frame_diagnostics(current)
  local now_ns = uv.hrtime()
  if not current.last_frame_ui_update_ns then
    current.last_frame_ui_update_ns = now_ns
    return true
  end

  if (now_ns - current.last_frame_ui_update_ns) < FRAME_DIAGNOSTIC_INTERVAL_NS then return false end

  current.last_frame_ui_update_ns = now_ns
  return true
end

local function schedule_next_frame(current, reason)
  if current.stop_sent or current.frame_in_flight or not current.initialized or not is_active(current) then return end

  local loop = current.loop
  if not loop or not loop.running then return end

  local now_ns = uv.hrtime()
  if reason == 'init' or not loop.next_due_ns then
    loop.next_due_ns = now_ns
  else
    advance_frame_deadline(loop, now_ns)
  end

  local delay_ms = frame_delay_ms(loop.next_due_ns, now_ns)
  local timer = ensure_frame_timer(current)
  timer:start(
    delay_ms,
    0,
    vim.schedule_wrap(function()
      if not is_active(current) then return end

      request_frame(current, reason == 'init' and 'first-frame' or 'loop')
    end)
  )
end

local function resolve_renderer_plan(configured_renderer, current_config, launch_opts)
  local requested = normalize_renderer_value(launch_opts.requested_renderer or configured_renderer)
  local facts = kitty_support.inspect({
    tmux_passthrough = current_config.tmux_passthrough,
  })
  local detect_support, detect_reason = kitty_support.should_runtime_probe(facts, requested or 'auto')

  if launch_opts.renderer_override then
    return {
      requested = requested or normalize_renderer_value(configured_renderer) or 'auto',
      selected = launch_opts.renderer_override,
      reason = launch_opts.renderer_reason or ('forced ' .. launch_opts.renderer_override),
      fallback_reason = launch_opts.fallback_reason,
      terminal_facts = facts,
      detect_support = detect_support,
      detect_reason = detect_reason,
      invalid_config = false,
    }
  end

  if requested == 'cell' then
    return {
      requested = 'cell',
      selected = 'cell',
      reason = 'explicit cell renderer requested',
      terminal_facts = facts,
      detect_support = false,
      detect_reason = 'runtime probe skipped for cell renderer',
      invalid_config = false,
    }
  end

  if requested == 'kitty' then
    if kitty_support.has_hard_reject(facts) then
      return {
        requested = 'kitty',
        selected = 'cell',
        reason = 'explicit kitty request rejected before launch',
        fallback_reason = kitty_support.hard_reject_summary(facts),
        terminal_facts = facts,
        detect_support = false,
        detect_reason = 'runtime probe skipped because kitty was rejected before launch',
        invalid_config = false,
      }
    end

    local reason = 'explicit kitty renderer requested'
    local soft_reject = kitty_support.soft_reject_summary(facts)
    if soft_reject then
      reason = reason .. '; runtime probe required because ' .. soft_reject
    elseif kitty_support.positive_summary(facts) then
      reason = reason .. '; ' .. kitty_support.positive_summary(facts)
    end

    return {
      requested = 'kitty',
      selected = 'kitty',
      reason = reason,
      terminal_facts = facts,
      detect_support = false,
      detect_reason = 'runtime probe skipped for explicit kitty renderer selection',
      invalid_config = false,
    }
  end

  if requested ~= nil and requested ~= 'auto' then
    return {
      requested = requested,
      selected = 'cell',
      reason = string.format('unknown renderer %q; falling back to cell', tostring(configured_renderer)),
      terminal_facts = facts,
      detect_support = false,
      detect_reason = 'runtime probe skipped because kitty was not selected',
      invalid_config = true,
    }
  end

  if not kitty_support.has_hard_reject(facts) then
    local reason
    local positive = kitty_support.positive_summary(facts)
    local soft_reject = kitty_support.soft_reject_summary(facts)
    if positive then
      reason = 'auto selected kitty; ' .. positive
    elseif soft_reject then
      reason = 'auto selected kitty; runtime probe required because ' .. soft_reject
    else
      reason = 'auto selected kitty; runtime probe required'
    end

    return {
      requested = 'auto',
      selected = 'kitty',
      reason = reason,
      terminal_facts = facts,
      detect_support = detect_support,
      detect_reason = detect_reason,
      invalid_config = false,
    }
  end

  return {
    requested = 'auto',
    selected = 'cell',
    reason = 'auto selected cell; '
      .. (
        kitty_support.hard_reject_summary(facts)
        or kitty_support.soft_reject_summary(facts)
        or 'kitty graphics were not advertised'
      ),
    terminal_facts = facts,
    detect_support = false,
    detect_reason = 'runtime probe skipped because auto selection chose cell',
    invalid_config = false,
  }
end

local function build_renderer(current)
  if current.renderer_name == 'kitty' then
    return require('gbc.renderer.kitty').new({
      screen = ui.screen(),
      shm_name = current.frame_shm_name,
      terminal_facts = current.terminal_facts,
      detect_support = current.detect_support,
      on_status = function(message, level)
        if not is_active(current) then return end

        ui.set_kitty_status(message)
        log(message, level)
      end,
      on_failure = function(message)
        if not is_active(current) then return end

        ui.set_renderer_fallback_reason(message)
        ui.set_session_status('kitty unavailable; restarting with cell fallback')
        log('Kitty renderer failed: ' .. message, vim.log.levels.WARN)

        if current.fallback_scheduled then return end

        current.fallback_scheduled = true
        vim.schedule(function()
          if not is_active(current) then return end

          local rom_path = current.rom_path
          stop_active_session('kitty_fallback')
          M.start(rom_path, {
            renderer_override = 'cell',
            requested_renderer = current.requested_renderer,
            renderer_reason = 'fallback to cell after kitty failure',
            fallback_reason = message,
          })
        end)
      end,
    })
  end

  return require('gbc.renderer.cell').new({
    screen = ui.screen(),
  })
end

local function attach_screen_handlers(current)
  local screen = ui.screen()
  if not screen then return end

  screen:set_resize_handler(function(reason)
    if not is_active(current) or not current.renderer or not current.renderer.handle_resize then return end

    current.renderer:handle_resize(reason)
  end)

  screen:set_term_response_handler(function(sequence, source)
    if not is_active(current) or not current.renderer or not current.renderer.handle_term_response then return end

    current.renderer:handle_term_response(sequence, source)
  end)

  screen:set_close_handler(function(reason)
    if not is_active(current) then return end

    log('Screen closed (' .. tostring(reason) .. '); stopping active session.')
    stop_active_session('ui_closed')
  end)
end

local function handle_protocol_message(current, message)
  if not is_active(current) then return end

  if message.type == protocol.host.INIT then
    current.initialized = true
    current.init = message.data
    record_event(message.name)
    ui.set_screen_geometry(message.data.width, message.data.height, protocol.pixel_format_name(message.data.pixel_format))
    ui.set_session_status(
      string.format(
        'initialized %dx%d %s',
        message.data.width,
        message.data.height,
        protocol.pixel_format_name(message.data.pixel_format)
      )
    )
    log(
      string.format(
        'Protocol <- %s: %dx%d %s',
        message.name,
        message.data.width,
        message.data.height,
        protocol.pixel_format_name(message.data.pixel_format)
      )
    )
    log(string.format('Starting frameloop at %.2ffps.', current.loop.target_fps))
    schedule_next_frame(current, 'init')
    return
  end

  if message.type == protocol.host.FRAME then
    profile.time('game.handle_frame', function()
      current.frame_in_flight = false
      current.frames_received = current.frames_received + 1
      ui.set_frames_received(current.frames_received)

      local rendered = profile.time('renderer.render', current.renderer.render, current.renderer, message.data)
      ui.render_frame(rendered, {
        refresh = should_refresh_frame_diagnostics(current),
      })
      schedule_next_frame(current, 'frame')
    end)
    return
  end

  if message.type == protocol.host.LOG then
    log(string.format('Protocol <- %s: %s', message.name, message.data.text))
    return
  end

  if message.type == protocol.host.QUIT then
    record_event(message.name)
    ui.set_quit_reason(message.data.text)
    log(string.format('Protocol <- %s: %s', message.name, message.data.text))
    ui.set_session_status('bridge exited')
    append_profile_summary(current)
    close_transport(current, 'protocol_quit')
    return
  end

  log(string.format('Protocol <- %s: %q', message.name, message.payload), vim.log.levels.WARN)
end

function M.start(rom_path, launch_opts)
  launch_opts = launch_opts or {}

  local binary, err = build.ensure_built({ notify_ready = false })
  if not binary then return nil, err end

  profile.reset()
  stop_active_session('restarting')

  local current_config = config.get()
  local controls_config = current_config.controls or {}
  local target_fps = normalize_target_fps(current_config.target_fps)
  local selection = resolve_renderer_plan(current_config.renderer, current_config, launch_opts)
  local current = {
    rom_path = rom_path,
    socket_path = socket_path(),
    renderer_name = selection.selected,
    requested_renderer = selection.requested,
    renderer_reason = selection.reason,
    terminal_facts = selection.terminal_facts,
    detect_support = selection.detect_support,
    detect_reason = selection.detect_reason,
    frames_received = 0,
    frame_shm_name = selection.selected == 'kitty' and frame_shm_name() or nil,
    loop = {
      running = true,
      target_fps = target_fps,
      frame_interval_ns = frame_interval_ns(target_fps),
      next_due_ns = nil,
    },
  }
  session.current = current

  ui.open(rom_path, {
    renderer = current.renderer_name,
    renderer_requested = current.requested_renderer,
    renderer_reason = current.renderer_reason,
    tmux_passthrough = current_config.tmux_passthrough,
    terminal_info = kitty_support.describe_terminal(selection.terminal_facts),
  })
  local screen = ui.screen()
  local controls_ok, controls_err = controls.attach(current, {
    enabled = controls_config.enabled,
    key_hold_ms = controls_config.key_hold_ms,
    mapping = controls_config.mapping,
    buf = screen and screen.buf or nil,
  })
  if controls_ok then
    ui.record_event('controls attached')
  elseif controls_config.enabled ~= false then
    log('Failed to attach controls: ' .. tostring(controls_err), vim.log.levels.WARN)
    ui.record_event('controls unavailable')
  else
    ui.record_event('controls disabled')
  end
  if selection.fallback_reason then ui.set_renderer_fallback_reason(selection.fallback_reason) end
  ui.set_terminal_info(kitty_support.describe_terminal(selection.terminal_facts))
  ui.set_renderer_requested(current.requested_renderer)
  ui.set_renderer(current.renderer_name)
  ui.set_renderer_reason(current.renderer_reason)
  ui.set_kitty_status(current.renderer_name == 'kitty' and 'awaiting first kitty frame' or 'inactive (cell renderer selected)')
  ui.set_transport_status('starting')
  ui.set_session_status('launching bridge')

  current.renderer = build_renderer(current)
  attach_screen_handlers(current)
  record_event('launch bridge')

  local args = {
    binary,
    '--socket',
    current.socket_path,
    '--rom',
    rom_path,
  }

  log('Build ready: ' .. binary)
  log('Launching bridge for ROM: ' .. rom_path)
  log('Socket path: ' .. current.socket_path)
  log(
    string.format(
      'Resolved config: renderer=%s audio=%s tmux_passthrough=%s target_fps=%.2f',
      tostring(current_config.renderer),
      current_config.audio and 'true' or 'false',
      current_config.tmux_passthrough and 'true' or 'false',
      target_fps
    )
  )
  log('Terminal facts: ' .. kitty_support.describe_terminal(selection.terminal_facts))
  log('Renderer decision: requested=' .. current.requested_renderer .. ' selected=' .. current.renderer_name)
  log('Renderer reason: ' .. current.renderer_reason)
  log('Kitty runtime probe: ' .. (current.detect_support and 'enabled' or 'skipped') .. ' - ' .. tostring(current.detect_reason))
  if selection.fallback_reason then log('Renderer fallback reason: ' .. selection.fallback_reason, vim.log.levels.WARN) end
  log(
    string.format(
      'Selected renderer path: %s (protocol id %d)',
      current.renderer_name,
      protocol.renderer_id(current.renderer_name)
    )
  )

  current.transport = transport.start({
    socket_path = current.socket_path,
    on_close = function(reason)
      cleanup_socket(current.socket_path)
      if is_active(current) then
        ui.set_transport_closed(reason)
        ui.set_transport_status('closed')
        record_event('transport close (' .. (reason or 'unknown') .. ')')
        log('Transport closed: ' .. (reason or 'unknown'))
      end
    end,
    on_connect = function()
      if not is_active(current) then return end

      record_event('socket connect')
      ui.set_transport_status('connected')
      ui.set_session_status('sending init')
      log(
        string.format(
          'Sending %s with renderer=%s (id=%d), audio=%s',
          protocol.client_name(protocol.client.INIT),
          current.renderer_name,
          protocol.renderer_id(current.renderer_name),
          current_config.audio and 'true' or 'false'
        )
      )

      if
        send_message(
          current,
          protocol.encode_init({
            rom_path = rom_path,
            renderer = current.renderer_name,
            audio_enabled = current_config.audio,
          }),
          protocol.client.INIT,
          { log = true }
        )
      then
        record_event(protocol.client_name(protocol.client.INIT))
      end
    end,
    on_log = function(message, level)
      if not is_active(current) then return end

      if message:match('^Socket connected') then
        ui.set_transport_status('connected')
      elseif message:match('^Connecting to socket') then
        ui.set_transport_status('connecting')
      end
      log(message, level)
    end,
    on_message = function(message) handle_protocol_message(current, message) end,
  })

  current.handle = vim.system(args, {
    text = true,
    stdout = true,
    stderr = true,
  }, function(result)
    if not is_active(current) then return end

    vim.schedule(function()
      if not is_active(current) then return end

      if result.stdout and result.stdout ~= '' then ui.append_log('[gbc][stdout]\n' .. result.stdout) end

      if result.stderr and result.stderr ~= '' then ui.append_log('[gbc][stderr]\n' .. result.stderr) end

      ui.set_bridge_exit(result.code, result.signal)
      record_event(
        result.signal and result.signal ~= 0 and string.format('bridge exit code=%d signal=%d', result.code, result.signal)
          or string.format('bridge exit code=%d', result.code)
      )

      if result.code == 0 then
        log('Bridge exited cleanly.')
        ui.set_session_status('bridge exited cleanly')
      else
        log('Bridge exited with code ' .. result.code, vim.log.levels.ERROR)
        ui.set_session_status('bridge exited with code ' .. result.code)
      end

      append_profile_summary(current)
      close_transport(current, 'bridge_exit')
    end)
  end)

  return current.handle
end

M._test = {
  normalize_target_fps = normalize_target_fps,
  frame_interval_ns = frame_interval_ns,
  advance_frame_deadline = advance_frame_deadline,
  frame_delay_ms = frame_delay_ms,
}

return M
