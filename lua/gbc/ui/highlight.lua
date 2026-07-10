local M = {}

local groups = {
  GbcWinbarTitle = { link = 'WinBar' },
  GbcWinbarAccent = { link = 'WinBar' },
  GbcButtonHover = { link = 'PmenuSel' },
  GbcButtonGhostHover = { link = 'PmenuSel' },
  GbcMenu = { link = 'Pmenu' },
  GbcMenuHover = { link = 'PmenuSel' },
}

local applied = false

function M.setup()
  if applied then return end
  applied = true

  for name, attrs in pairs(groups) do
    vim.api.nvim_set_hl(0, name, vim.tbl_extend('force', attrs, { default = true }))
  end

  vim.api.nvim_create_autocmd('ColorScheme', {
    group = vim.api.nvim_create_augroup('gbc_ui_highlight', { clear = true }),
    callback = function()
      for name, attrs in pairs(groups) do
        vim.api.nvim_set_hl(0, name, vim.tbl_extend('force', attrs, { default = true }))
      end
    end,
  })
end

return M
