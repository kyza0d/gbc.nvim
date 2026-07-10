local config = require('gbc.config')

local M = {}
local commands_registered = false

local function ensure_helptags()
  if not vim or not vim.fn or not vim.fn.fnamemodify then return end

  local info = debug.getinfo(ensure_helptags, 'S')
  if not info or type(info.source) ~= 'string' then return end

  local source = info.source
  if source:sub(1, 1) ~= '@' then return end

  -- This file lives at: <plugin_root>/lua/gbc/init.lua
  local plugin_root = vim.fn.fnamemodify(source:sub(2), ':p:h:h:h')
  local doc_dir = plugin_root .. '/doc'
  if vim.fn.isdirectory(doc_dir) ~= 1 or vim.fn.filereadable(doc_dir .. '/gbc.txt') ~= 1 then return end

  local tags_path = doc_dir .. '/tags'
  if vim.fn.filereadable(tags_path) ~= 1 then pcall(vim.cmd.helptags, doc_dir) end
end

local function notify(message, level) vim.notify(message, level or vim.log.levels.INFO, { title = 'gbc.nvim' }) end

local function register_commands()
  if commands_registered then return end

  commands_registered = true

  vim.api.nvim_create_user_command('GB', function(opts)
    if not opts.args or vim.trim(opts.args) == '' then
      notify('Usage: :GB /absolute/path/to/rom.gb', vim.log.levels.ERROR)
      return
    end

    M.start(opts.args)
  end, {
    nargs = '*',
    complete = 'file',
    desc = 'Launch gbc.nvim with a ROM path',
  })

  vim.api.nvim_create_user_command('GBCheck', function()
    local binary, err = require('gbc.build').ensure_built()
    if binary then return end

    if err then notify('Bridge build failed. See :messages for details.', vim.log.levels.ERROR) end
  end, {
    nargs = 0,
    desc = 'Build or verify the gbc.nvim native bridge',
  })

  vim.api.nvim_create_user_command('GBSpeed', function(opts) require('gbc.game').set_speed(opts.args) end, {
    nargs = 1,
    desc = 'Set emulator speed multiplier (e.g. :GBSpeed 2 for 2x, :GBSpeed 0.5 for half speed)',
    complete = "customlist,v:lua.require'gbc'._speed_complete",
  })

  vim.api.nvim_create_user_command(
    'GBSave',
    function(opts) require('gbc.game').save_state(opts.args ~= '' and opts.args or 1) end,
    {
      nargs = '?',
      desc = 'Save emulator state to a slot (default 1)',
    }
  )

  vim.api.nvim_create_user_command(
    'GBLoad',
    function(opts) require('gbc.game').load_state(opts.args ~= '' and opts.args or 1) end,
    {
      nargs = '?',
      desc = 'Load emulator state from a slot (default 1)',
    }
  )

  vim.api.nvim_create_user_command('GBPause', function() require('gbc.game').toggle_pause() end, {
    nargs = 0,
    desc = 'Toggle emulator pause',
  })
end

function M._register_commands() register_commands() end

function M._speed_complete() return { '0.25', '0.5', '1', '2', '3', '4', '5' } end

function M.set_speed(multiplier) require('gbc.game').set_speed(multiplier) end

function M.setup(opts)
  config.setup(opts)
  ensure_helptags()
  register_commands()
  return config.get()
end

function M.config() return config.get() end

function M.start(rom_path)
  if not rom_path or vim.trim(rom_path) == '' then
    notify('Usage: :GB /absolute/path/to/rom.gb', vim.log.levels.ERROR)
    return nil, 'missing rom path'
  end

  local resolved = vim.fn.fnamemodify(rom_path, ':p')
  if vim.fn.filereadable(resolved) ~= 1 then
    notify('ROM file does not exist: ' .. resolved, vim.log.levels.ERROR)
    return nil, 'missing rom file'
  end

  return require('gbc.game').start(resolved)
end

return M
