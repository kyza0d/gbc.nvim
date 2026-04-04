local defaults = {
  renderer = 'auto',
  audio = false,
  target_fps = 60,
  kitty_present_delay_ms = 750,
  tmux_passthrough = os.getenv('TMUX') ~= nil,
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
