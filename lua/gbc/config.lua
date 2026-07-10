local defaults = {
  renderer = 'auto',
  rom_dirs = {},
  state_slots = 3,
  audio = false,
  target_fps = 60,
  kitty_present_delay_ms = 750,
  tmux_passthrough = os.getenv('TMUX') ~= nil,
  controls = {
    enabled = true,
    key_hold_ms = 75,
    mapping = {
      h = 'LEFT',
      l = 'RIGHT',
      k = 'UP',
      j = 'DOWN',
      z = 'B',
      x = 'A',
      ['<Space>'] = 'SELECT',
      ['<CR>'] = 'START',
    },
  },
}

local values = vim.deepcopy(defaults)

local M = {}

function M.setup(opts)
  if opts then values = vim.tbl_deep_extend('force', values, opts) end

  return values
end

function M.get() return vim.deepcopy(values) end

function M.defaults() return vim.deepcopy(defaults) end

return M
