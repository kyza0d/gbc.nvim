local api = vim.api
local utils = require('gbc.ui.components.menu.utils')

local function save_keymap(self, bufnr, lhs, mode)
  mode = mode or 'n'
  self.keymaps[bufnr] = self.keymaps[bufnr] or {}
  self.keymaps[bufnr][mode] = self.keymaps[bufnr][mode] or {}
  if self.keymaps[bufnr][mode][lhs] ~= nil then return end

  local mapping = utils.get_buffer_mapping(bufnr, lhs, mode)
  if mapping then
    self.keymaps[bufnr][mode][lhs] = mapping
    return
  end

  self.keymaps[bufnr][mode][lhs] = false
end

local function set_keymap(self, bufnr, lhs, callback, opts)
  if not bufnr or not api.nvim_buf_is_valid(bufnr) then return end
  opts = opts or {}
  local modes = opts.mode or 'n'
  if type(modes) ~= 'table' then modes = { modes } end

  for _, mode in ipairs(modes) do
    save_keymap(self, bufnr, lhs, mode)
    vim.keymap.set(mode, lhs, callback, {
      buffer = bufnr,
      expr = opts.expr,
      remap = opts.remap == true,
      replace_keycodes = opts.replace_keycodes,
      silent = true,
      nowait = true,
    })
  end
end

local function restore_keymaps(self)
  for bufnr, modes in pairs(self.keymaps) do
    if api.nvim_buf_is_valid(bufnr) then
      for mode, mappings in pairs(modes) do
        for lhs, mapping in pairs(mappings) do
          pcall(vim.keymap.del, mode, lhs, { buffer = bufnr })
          if mapping and mapping.buffer == 1 then utils.restore_buffer_mapping(bufnr, mapping) end
        end
      end
    end
  end

  self.keymaps = {}
end

return {
  save_keymap = save_keymap,
  set_keymap = set_keymap,
  restore_keymaps = restore_keymaps,
}
