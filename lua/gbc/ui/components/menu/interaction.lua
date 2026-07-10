local api = vim.api
local constants = require('gbc.ui.components.menu.constants')
local keymaps_module = require('gbc.ui.components.menu.keymaps')
local mouse_utils = require('gbc.ui.interactions.mouse')
local utils = require('gbc.ui.components.menu.utils')

local function update_hover(self, mouse)
  if not self:is_open() then return end
  mouse = mouse or vim.fn.getmousepos()

  if not mouse_utils.should_window_handle_hover(self.winid, mouse) then
    self:set_hover(nil)
    return
  end

  local index = self:mouse_item_index(mouse)
  self:set_hover(index)
end

local function handle_left_mouse_down(self)
  if not self:is_open() then return end

  self._mouse_down_index = nil

  local mouse = vim.fn.getmousepos()
  if not mouse_utils.should_window_handle_hover(self.winid, mouse) then return end

  local index = self:mouse_item_index(mouse)
  self._mouse_down_index = index

  if not self._mouse_down_index and not self:contains_mouse(mouse) then
    self._mouse_down_index = nil
    self:close('outside_click')
    require('gbc.ui.components.button').refresh_hover(mouse)
  end
end

local function handle_left_mouse_up(self)
  if not self:is_open() then return end

  local armed_index = self._mouse_down_index
  self._mouse_down_index = nil
  if not armed_index then return end

  local mouse = vim.fn.getmousepos()
  if not mouse_utils.should_window_handle_hover(self.winid, mouse) then return end

  local index = self:mouse_item_index(mouse)
  if index and index == armed_index then self:select(index) end
end

local function install_interaction_listener(self)
  if self.interaction_ns then return end

  local mousemove = vim.keycode('<MouseMove>')
  local enter = vim.keycode('<CR>')
  self.interaction_ns = api.nvim_create_namespace('gbc_ui_menu_interaction_' .. tostring(self.bufnr))

  vim.on_key(function(key)
    if not self:is_open() then return end
    if key == mousemove then
      update_hover(self, vim.fn.getmousepos())
      return
    end
    if not utils.use_gui_passthrough_interaction(self) then return end

    local mode = api.nvim_get_mode().mode
    if type(mode) ~= 'string' or mode:sub(1, 1) ~= 'n' then return end

    if key == enter then
      self:confirm_selection()
    elseif constants.GUI_FORWARD_KEYS[key] then
      self:move(1)
    elseif constants.GUI_BACKWARD_KEYS[key] then
      self:move(-1)
    elseif key == constants.GUI_ESCAPE_KEY then
      self:close('escape')
    elseif constants.GUI_DISMISS_KEYS[key] then
      self:close('dismiss')
    end
  end, self.interaction_ns)
end

local function install_mouse_keymaps(self)
  local function install_visible_buffer_keymaps()
    if not self:is_open() then return end

    local seen = {}
    for _, winid in ipairs(api.nvim_list_wins()) do
      if api.nvim_win_is_valid(winid) then
        local bufnr = api.nvim_win_get_buf(winid)
        if bufnr and api.nvim_buf_is_valid(bufnr) and not seen[bufnr] then
          seen[bufnr] = true
          keymaps_module.set_keymap(self, bufnr, '<LeftMouse>', function() handle_left_mouse_down(self) end, {
            mode = { 'n', 'i' },
          })
          keymaps_module.set_keymap(self, bufnr, '<LeftRelease>', function() handle_left_mouse_up(self) end, {
            mode = { 'n', 'i' },
          })
        end
      end
    end
  end

  install_visible_buffer_keymaps()

  if not self.augroup then return end
  api.nvim_create_autocmd({ 'BufWinEnter', 'WinEnter', 'WinNew' }, {
    group = self.augroup,
    callback = install_visible_buffer_keymaps,
  })
end

return {
  update_hover = update_hover,
  handle_left_mouse_down = handle_left_mouse_down,
  handle_left_mouse_up = handle_left_mouse_up,
  install_interaction_listener = install_interaction_listener,
  install_mouse_keymaps = install_mouse_keymaps,
}
