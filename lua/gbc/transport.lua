local protocol = require('gbc.protocol')
local profile = require('gbc.profile')
local uv = vim.uv or vim.loop

local M = {}

local function should_log_send(label, opts)
  if not label then return false end

  if opts and opts.log ~= nil then return opts.log end

  return false
end

local function dispatch_message(transport, message)
  if not transport.on_message then return end

  -- libuv socket callbacks run in a fast event. Queue protocol handling onto
  -- the main loop so renderers can finish presenting shm-backed frames before
  -- the next frame request is scheduled.
  vim.schedule(function()
    if transport.closed then return end

    profile.time('transport.dispatch_message', transport.on_message, message)
  end)
end

local function close_handle(handle)
  if not handle then return end

  if handle.is_closing and handle:is_closing() then return end

  handle:close()
end

function M.start(opts)
  local transport = {
    closed = false,
    connected = false,
    on_connect = opts.on_connect,
    on_close = opts.on_close,
    on_log = opts.on_log,
    on_message = opts.on_message,
    recv_buffer = '',
    socket_dir = vim.fs.dirname(opts.socket_path),
    socket_name = vim.fs.basename(opts.socket_path),
    socket_path = opts.socket_path,
    max_tries = opts.tries or 20,
    tries_left = opts.tries or 20,
    retry_delay_ms = opts.retry_delay_ms or 150,
    sock = nil,
    timer = assert(uv.new_timer()),
  }

  local schedule_connect

  local function reset_socket_handle()
    if transport.sock then
      ---@diagnostic disable-next-line:undefined-field
      pcall(transport.sock.read_stop, transport.sock)
      close_handle(transport.sock)
    end

    transport.sock = assert(uv.new_pipe())
  end

  function transport:log(message, level)
    if self.on_log then self.on_log(message, level) end
  end

  function transport:send(payload, label, send_opts)
    if self.closed then return false, 'transport closed' end

    if not self.connected or not self.sock then return false, 'transport not connected' end

    ---@diagnostic disable-next-line:undefined-field
    local ok, err = pcall(self.sock.write, self.sock, payload, function(write_err)
      if write_err and not transport.closed then
        transport:log('Socket write failed: ' .. write_err, vim.log.levels.ERROR)
        transport:close('write_error')
        return
      end

      if should_log_send(label, send_opts) then transport:log('Protocol -> ' .. label, vim.log.levels.INFO) end
    end)
    if not ok then return false, err end

    return true
  end

  function transport:close(reason)
    if self.closed then return end

    self.closed = true
    if self.timer then
      self.timer:stop()
      close_handle(self.timer)
      self.timer = nil
    end

    if self.sock then
      ---@diagnostic disable-next-line:undefined-field
      pcall(self.sock.read_stop, self.sock)
      close_handle(self.sock)
      self.sock = nil
    end

    if self.on_close then self.on_close(reason) end
  end

  local function handle_frames(data)
    local messages
    messages, transport.recv_buffer =
      profile.time('protocol.decode_available', protocol.decode_available, transport.recv_buffer .. data)
    for _, message in ipairs(messages) do
      dispatch_message(transport, message)
    end
  end

  local function connect_cb(connect_err)
    if transport.closed then return end

    if connect_err then
      transport.tries_left = transport.tries_left - 1
      local attempt = transport.max_tries - transport.tries_left
      local message = string.format('Socket connect failed: %s (%d attempt(s) left)', connect_err, transport.tries_left)
      local level = vim.log.levels.WARN

      if connect_err == 'ENOENT' and attempt == 1 then
        message = string.format('Socket not ready yet: %s (%d attempt(s) left)', connect_err, transport.tries_left)
        level = vim.log.levels.INFO
      end

      transport:log(message, level)

      if transport.tries_left <= 0 then
        transport:log('No socket connection attempts remain; giving up.', vim.log.levels.ERROR)
        transport:close('connect_failed')
        return
      end

      schedule_connect(transport.retry_delay_ms)
      return
    end

    transport.connected = true
    transport:log('Socket connected.', vim.log.levels.INFO)
    ---@diagnostic disable-next-line:undefined-field
    assert(transport.sock:read_start(function(read_err, data)
      if transport.closed then return end

      if read_err then
        transport:log('Socket read failed: ' .. read_err, vim.log.levels.ERROR)
        transport:close('read_error')
        return
      end

      if data == nil then
        transport:log('Socket closed by bridge.', vim.log.levels.INFO)
        transport:close('eof')
        return
      end

      handle_frames(data)
    end))

    if transport.on_connect then transport.on_connect(transport) end
  end

  schedule_connect = function(delay_ms)
    if transport.closed then return end

    assert(transport.timer:start(delay_ms, 0, function()
      if transport.closed then return end

      local old_cwd = assert(uv.cwd())
      local _, chdir_err = uv.chdir(transport.socket_dir)
      if chdir_err then
        transport:log(
          string.format('Failed to enter socket directory "%s": %s', transport.socket_dir, chdir_err),
          vim.log.levels.ERROR
        )
        transport:close('cwd_failed')
        return
      end

      reset_socket_handle()
      local sock = transport.sock
      assert(sock, 'transport.sock must be set before connect')
      ---@diagnostic disable-next-line:undefined-field
      local _, connect_err = sock:connect(transport.socket_name, function(connect_err_inner)
        if transport.closed or transport.sock ~= sock then return end

        connect_cb(connect_err_inner)
      end)
      local _, restore_err = uv.chdir(old_cwd)
      if restore_err then
        vim.schedule(function() vim.fn.chdir('~') end)

        transport:log(
          string.format('Failed to restore working directory to "%s": %s', old_cwd, restore_err),
          vim.log.levels.ERROR
        )
        transport:close('cwd_restore_failed')
        return
      end

      if connect_err then connect_cb(connect_err) end
    end))
  end

  transport:log('Connecting to socket ' .. transport.socket_path .. '...', vim.log.levels.INFO)
  schedule_connect(0)

  return transport
end

M._test = {
  dispatch_message = dispatch_message,
  should_log_send = should_log_send,
}

return M
