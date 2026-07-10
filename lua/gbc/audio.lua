local config = require('gbc.config')

local M = {}

function M.is_enabled()
  return config.get().audio == true
end

return M
