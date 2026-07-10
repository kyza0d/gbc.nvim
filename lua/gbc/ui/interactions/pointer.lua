local api = vim.api

local M = {}

local sequences = {
  kitty = {
    on = '\027]22;>pointer\027\\',
    off = '\027]22;<\027\\',
  },
  ghostty = {
    on = '\027]22;pointer\027\\',
    off = '\027]22;default\027\\',
  },
}

local state = {
  active_count = 0,
  sources = {},
  augroup = nil,
}

local function is_kitty() return vim.env.KITTY_WINDOW_ID ~= nil or (vim.env.TERM or '') == 'xterm-kitty' end

local function is_ghostty()
  local term = (vim.env.TERM or ''):lower()
  local term_program = (vim.env.TERM_PROGRAM or ''):lower()
  return vim.env.GHOSTTY_RESOURCES_DIR ~= nil
    or vim.env.GHOSTTY_BIN_DIR ~= nil
    or term:find('ghostty', 1, true) ~= nil
    or term_program == 'ghostty'
end

local function terminal_kind()
  if vim.g.gbc_pointer_shape == false then return nil end

  local override = vim.g.gbc_pointer_shape_terminal
  if sequences[override] then return override end
  if is_kitty() then return 'kitty' end
  if vim.g.gbc_pointer_shape == true then return 'ghostty' end
  return is_ghostty() and 'ghostty' or nil
end

local function emit(sequence)
  if not sequence then return end

  if type(api.nvim_ui_send) == 'function' then
    local ok = pcall(api.nvim_ui_send, sequence)
    if ok then return end
  end

  pcall(vim.fn.chansend, vim.v.stderr, sequence)
end

local function emit_shape(active)
  local kind = terminal_kind()
  local sequence = sequences[kind]
  if sequence then emit(sequence[active and 'on' or 'off']) end
end

function M.clear()
  local was_active = state.active_count > 0
  state.sources = {}
  state.active_count = 0
  if not was_active then return end
  emit_shape(false)
end

local function ensure_autocmds()
  if state.augroup then return end

  state.augroup = api.nvim_create_augroup('gbc_ui_pointer_shape', { clear = true })
  api.nvim_create_autocmd({ 'FocusLost', 'VimLeavePre' }, {
    group = state.augroup,
    callback = M.clear,
  })
end

function M.set_source(source, active)
  if source == nil then return end
  active = active == true

  local was_active = state.active_count > 0
  local source_was_active = state.sources[source] == true
  if source_was_active == active then return end

  state.sources[source] = active or nil
  state.active_count = state.active_count + (active and 1 or -1)

  local is_active = state.active_count > 0
  if is_active == was_active then return end
  if is_active then ensure_autocmds() end
  emit_shape(is_active)
end

function M.is_active() return state.active_count > 0 end

function M._reset_for_tests()
  state.sources = {}
  state.active_count = 0
  if state.augroup then
    pcall(api.nvim_del_augroup_by_id, state.augroup)
    state.augroup = nil
  end
end

return M
