local M = {}

local function notify(message, level) vim.notify(message, level or vim.log.levels.INFO, { title = 'gbc.nvim' }) end

local function repo_root()
  local source = debug.getinfo(1, 'S').source:sub(2)
  return vim.fn.fnamemodify(source, ':p:h:h:h')
end

function M.root_dir() return repo_root() end

function M.binary_path() return repo_root() .. '/native/sameboy-host' end

local function is_built(path) return vim.fn.executable(path) == 1 end

local function run_make(args)
  return vim
    .system(args, {
      cwd = repo_root(),
      text = true,
      stdout = true,
      stderr = true,
    })
    :wait()
end

function M.ensure_built(opts)
  opts = opts or {}
  local binary = M.binary_path()

  local status = run_make({ 'make', '-q' })
  if status.code == 0 and is_built(binary) then
    if opts.notify_ready ~= false then notify('Native bridge is ready: ' .. binary) end
    return binary
  end

  notify('Building native bridge with make...')
  local result = run_make({ 'make' })

  if result.code ~= 0 or not is_built(binary) then
    local details = vim.trim(table.concat({
      result.stdout or '',
      result.stderr or '',
    }, '\n'))

    notify(
      'Failed to build native bridge.\n' .. (details ~= '' and details or 'make exited with code ' .. result.code),
      vim.log.levels.ERROR
    )
    return nil, details
  end

  if opts.notify_ready ~= false then notify('Built native bridge: ' .. binary) end
  return binary
end

return M
