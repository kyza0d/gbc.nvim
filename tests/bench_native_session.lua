local repo_root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.runtimepath:append(repo_root)

local build = require('gbc.build')
local protocol = require('gbc.protocol')
local uv = vim.uv or vim.loop

local function socket_path(name) return string.format('%s/%s-%d.sock', repo_root, name, vim.fn.getpid()) end

local function wait_for(predicate, timeout_ms, step_ms)
  step_ms = step_ms or 10
  if not vim.wait(timeout_ms, predicate, step_ms) then error('timeout waiting for benchmark step') end
end

local function connect_socket(path)
  local sock = assert(uv.new_pipe())
  local connected = false
  local connect_err
  local socket_dir = vim.fs.dirname(path)
  local socket_name = vim.fs.basename(path)
  local old_cwd = assert(uv.cwd())
  local _, chdir_err = uv.chdir(socket_dir)
  if chdir_err then error(chdir_err) end

  local _, err = sock:connect(socket_name, function(callback_err)
    connect_err = callback_err
    connected = callback_err == nil
  end)

  local _, restore_err = uv.chdir(old_cwd)
  if restore_err then error(restore_err) end

  if err then error(err) end

  wait_for(function() return connected or connect_err ~= nil end, 5000)

  if connect_err then error(connect_err) end

  return sock
end

local function run_native_case(renderer_name, frames)
  local binary = assert(build.ensure_built({ notify_ready = false }))
  local rom_path = repo_root .. '/tests/roms/pokemon.gbc'
  local path = socket_path('gbc-native-bench-' .. renderer_name)
  local result
  local done = false

  local proc = vim.system({
    binary,
    '--socket',
    path,
    '--rom',
    rom_path,
  }, {
    env = {
      GBC_PROFILE_NATIVE = '1',
    },
    text = true,
    stdout = true,
    stderr = true,
  }, function(current)
    result = current
    done = true
  end)

  wait_for(function() return uv.fs_stat(path) ~= nil or done end, 5000)

  if done and uv.fs_stat(path) == nil then error((result and result.stderr) or 'bridge exited before socket became ready') end

  local sock = connect_socket(path)
  local recv_buffer = ''
  local frames_received = 0
  local quit_received = false
  local init_received = false

  sock:read_start(function(read_err, data)
    if read_err then error(read_err) end

    if data == nil then return end

    local messages
    messages, recv_buffer = protocol.decode_available(recv_buffer .. data)
    for _, message in ipairs(messages) do
      if message.type == protocol.host.INIT then
        init_received = true
        if renderer_name == 'kitty' then sock:write(protocol.encode_set_frame_shm_name('/gbc-native-bench-shm')) end
        sock:write(protocol.encode_run_frame())
      elseif message.type == protocol.host.FRAME then
        frames_received = frames_received + 1
        if frames_received >= frames then
          sock:write(protocol.encode_stop())
        else
          sock:write(protocol.encode_run_frame())
        end
      elseif message.type == protocol.host.QUIT then
        quit_received = true
      end
    end
  end)

  sock:write(protocol.encode_init({
    rom_path = rom_path,
    renderer = renderer_name,
    audio_enabled = false,
  }))

  wait_for(function() return init_received and quit_received and done end, 15000)

  pcall(sock.read_stop, sock)
  if sock and not sock:is_closing() then sock:close() end
  pcall(uv.fs_unlink, path)
  proc:wait()

  print(renderer_name)
  print(string.format('  frames: %d', frames_received))
  for line in vim.gsplit((result and result.stderr) or '', '\n', { plain = true, trimempty = true }) do
    if line:find('%[gbc%-native%]%[profile%]', 1, false) then print('  ' .. line) end
  end
end

run_native_case('kitty', 120)
run_native_case('cell', 120)
