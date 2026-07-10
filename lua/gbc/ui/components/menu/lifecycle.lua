local api = vim.api
local constants = require('gbc.ui.components.menu.constants')
local mouse_utils = require('gbc.ui.interactions.mouse')
local Button = require('gbc.ui.components.button')
local state = require('gbc.ui.components.menu.state')
local utils = require('gbc.ui.components.menu.utils')
local keymaps_module = require('gbc.ui.components.menu.keymaps')
local rendering = require('gbc.ui.components.menu.rendering')
local interaction = require('gbc.ui.components.menu.interaction')

local close

local function is_open(self) return self.winid ~= nil and api.nvim_win_is_valid(self.winid) end

local function contains_mouse(self, mouse)
  if not is_open(self) or type(mouse) ~= 'table' then return false end
  if mouse.winid == self.winid then return true end

  local pos = api.nvim_win_get_position(self.winid)
  local top = tonumber(pos[1]) and (pos[1] + 1) or nil
  local left = tonumber(pos[2]) and (pos[2] + 1) or nil
  local screenrow = tonumber(mouse.screenrow)
  local screencol = tonumber(mouse.screencol)
  local height = api.nvim_win_get_height(self.winid)
  local width = api.nvim_win_get_width(self.winid)

  if not top or not left or not screenrow or not screencol then return false end
  return screenrow >= top and screenrow < top + height and screencol >= left and screencol < left + width
end

local function current_focus_is_menu(self)
  if not is_open(self) then return false end

  local current_winid = api.nvim_get_current_win()
  if current_winid == self.winid then return true end

  local current_bufnr = api.nvim_get_current_buf()
  return current_bufnr == self.bufnr
end

local function schedule_owner_leave_close(self, reason)
  vim.schedule(function()
    if not is_open(self) then return end
    if current_focus_is_menu(self) then return end
    close(self, reason)
  end)
end

function close(self, reason)
  reason = reason or 'manual'
  local owner_bufnr = self.owner_bufnr
  local owner_winid = self.owner_winid

  if self.augroup then
    pcall(api.nvim_del_augroup_by_id, self.augroup)
    self.augroup = nil
  end

  rendering.clear_hover(self)
  keymaps_module.restore_keymaps(self)

  if self.owns_mousemoveevent then
    state.mousemoveevent_state.depth = math.max(0, state.mousemoveevent_state.depth - 1)
    if state.mousemoveevent_state.depth == 0 and state.mousemoveevent_state.original ~= nil then
      vim.o.mousemoveevent = state.mousemoveevent_state.original
      state.mousemoveevent_state.original = nil
    end
    self.owns_mousemoveevent = false
  end

  if self.winid and api.nvim_win_is_valid(self.winid) then pcall(api.nvim_win_close, self.winid, true) end

  if self.bufnr and api.nvim_buf_is_valid(self.bufnr) then pcall(api.nvim_buf_delete, self.bufnr, { force = true }) end
  mouse_utils.unregister_hover_window(self.winid)

  self.winid = nil
  self.bufnr = nil
  self.menu_hl_ns = nil
  self.hover_ns = nil
  self.active_index = nil
  self.hover_index = nil
  self.owner_bufnr = nil
  self.owner_winid = nil
  self.owner_keymaps_enabled = nil
  self._sync_view_scheduled = nil
  self._mouse_down_index = nil
  if self.interaction_ns then
    vim.on_key(nil, self.interaction_ns)
    self.interaction_ns = nil
  end
  self._scrollable = nil

  if self.on_close then self.on_close(self, reason, {
    owner_bufnr = owner_bufnr,
    owner_winid = owner_winid,
  }) end
end

local function open(self)
  if is_open(self) then return self.winid end
  if #self.items == 0 then return nil end

  self.owner_bufnr = api.nvim_get_current_buf()
  self.owner_winid = api.nvim_get_current_win()
  self.owner_keymaps_enabled = self.owner_bufnr ~= nil and self.owner_bufnr ~= self.bufnr

  local width = math.max(self.min_width, utils.menu_width(self.items))
  if self.max_width then width = math.min(width, self.max_width) end
  local labels = {}
  for _, item in ipairs(self.items) do
    table.insert(labels, utils.render_item_label(item, width))
  end
  local height = #labels
  local win_height = self.max_height and math.min(height, self.max_height) or height
  self._scrollable = win_height < height
  local anchor = self.anchor(width, win_height) or utils.default_anchor(width, win_height)
  local config = vim.tbl_extend('force', anchor, {
    width = width,
    height = win_height,
    style = 'minimal',
    border = self.border,
    focusable = self.focusable,
    mouse = self.captures_mouse,
    noautocmd = true,
    zindex = self.zindex,
  })

  self.bufnr = api.nvim_create_buf(false, true)
  api.nvim_set_option_value('buftype', 'nofile', { buf = self.bufnr })
  api.nvim_set_option_value('bufhidden', 'wipe', { buf = self.bufnr })
  api.nvim_set_option_value('swapfile', false, { buf = self.bufnr })
  api.nvim_set_option_value('modifiable', true, { buf = self.bufnr })
  api.nvim_buf_set_lines(self.bufnr, 0, -1, false, labels)
  api.nvim_set_option_value('modifiable', false, { buf = self.bufnr })

  self.winid = api.nvim_open_win(self.bufnr, false, config)
  mouse_utils.register_hover_window(self.winid, { zindex = self.zindex })

  self.menu_hl_ns = api.nvim_create_namespace('gbc_ui_menu_window_' .. self.bufnr)
  self.hover_ns = api.nvim_create_namespace('gbc_ui_menu_hover_' .. self.bufnr)
  utils.copy_highlight(self.menu_hl_ns, 'Normal', { name = 'GbcMenu', namespaces = { self.hl_ns } })
  utils.copy_highlight(self.menu_hl_ns, 'NormalNC', { name = 'GbcMenu', namespaces = { self.hl_ns } })
  utils.copy_highlight(self.menu_hl_ns, 'NormalFloat', { name = 'GbcMenu', namespaces = { self.hl_ns } })
  utils.copy_highlight(self.menu_hl_ns, 'GbcMenu', { name = 'GbcMenu', namespaces = { self.hl_ns } })
  utils.copy_highlight(self.menu_hl_ns, 'GbcMenuHover', { name = 'GbcMenuHover', namespaces = { self.hl_ns } })
  api.nvim_win_set_hl_ns(self.winid, self.menu_hl_ns)
  api.nvim_set_option_value('number', false, { win = self.winid })
  api.nvim_set_option_value('relativenumber', false, { win = self.winid })
  api.nvim_set_option_value('cursorline', false, { win = self.winid })
  api.nvim_set_option_value('signcolumn', 'no', { win = self.winid })
  api.nvim_set_option_value('foldcolumn', '0', { win = self.winid })
  api.nvim_set_option_value('wrap', false, { win = self.winid })
  api.nvim_set_option_value('scrolloff', 0, { win = self.winid })
  api.nvim_set_option_value('sidescrolloff', 0, { win = self.winid })
  api.nvim_set_option_value('winfixbuf', true, { win = self.winid })
  api.nvim_set_option_value('winbar', '', { scope = 'local', win = self.winid })
  api.nvim_set_option_value('winhl', 'Normal:Normal,NormalNC:NormalNC,NormalFloat:NormalFloat', { win = self.winid })
  local initial_index = self:initial_selectable_index() or 1
  if self:initial_selectable_index() then
    self:set_active(initial_index)
    if not self.use_virtual_cursor then api.nvim_win_set_cursor(self.winid, { initial_index, 0 }) end
  end

  local function schedule_clamp()
    if not is_open(self) then return end
    if self._sync_view_scheduled then return end
    self._sync_view_scheduled = true
    vim.schedule(function()
      self._sync_view_scheduled = nil
      if not is_open(self) then return end
      self:sync_view()
    end)
  end

  local function confirm_selection() self:confirm_selection() end

  local function move_cursor(step) self:move(step) end

  if not self.owns_mousemoveevent then
    if state.mousemoveevent_state.depth == 0 then state.mousemoveevent_state.original = vim.o.mousemoveevent end
    state.mousemoveevent_state.depth = state.mousemoveevent_state.depth + 1
    self.owns_mousemoveevent = true
  end
  if not vim.o.mousemoveevent then vim.o.mousemoveevent = true end

  interaction.install_interaction_listener(self)
  keymaps_module.set_keymap(self, self.bufnr, '<CR>', confirm_selection)

  keymaps_module.set_keymap(self, self.bufnr, 'q', function() close(self, 'dismiss') end)
  keymaps_module.set_keymap(self, self.bufnr, '<Esc>', function() close(self, 'escape') end)

  for _, lhs in ipairs({ 'j', '<Down>', '<C-e>', '<ScrollWheelDown>', '<S-ScrollWheelDown>', '<C-ScrollWheelDown>' }) do
    keymaps_module.set_keymap(self, self.bufnr, lhs, function() move_cursor(1) end)
    if self.owner_keymaps_enabled then keymaps_module.set_keymap(self, self.owner_bufnr, lhs, function() move_cursor(1) end) end
  end

  for _, lhs in ipairs({ 'k', '<Up>', '<C-y>', '<ScrollWheelUp>', '<S-ScrollWheelUp>', '<C-ScrollWheelUp>' }) do
    keymaps_module.set_keymap(self, self.bufnr, lhs, function() move_cursor(-1) end)
    if self.owner_keymaps_enabled then keymaps_module.set_keymap(self, self.owner_bufnr, lhs, function() move_cursor(-1) end) end
  end

  if self.owner_keymaps_enabled then
    keymaps_module.set_keymap(self, self.owner_bufnr, '<CR>', confirm_selection)
    keymaps_module.set_keymap(self, self.owner_bufnr, 'q', function() close(self, 'dismiss') end)
    keymaps_module.set_keymap(self, self.owner_bufnr, '<Esc>', function() close(self, 'escape') end)
  end

  for _, lhs in ipairs({
    '<C-d>',
    '<C-u>',
    '<C-f>',
    '<C-b>',
    '<PageDown>',
    '<PageUp>',
    'zt',
    'zz',
    'zb',
  }) do
    keymaps_module.set_keymap(self, self.bufnr, lhs, function() end)
    if self.owner_keymaps_enabled then keymaps_module.set_keymap(self, self.owner_bufnr, lhs, function() end) end
  end

  self.augroup = api.nvim_create_augroup('gbc_ui_menu_' .. self.bufnr, { clear = true })
  interaction.install_mouse_keymaps(self)
  Button.refresh_hover(vim.fn.getmousepos())

  if self.focusable then
    api.nvim_create_autocmd({ 'WinLeave', 'BufLeave' }, {
      group = self.augroup,
      buffer = self.bufnr,
      callback = function(args) close(self, args.event == 'BufLeave' and 'menu_leave' or 'menu_winleave') end,
    })
  end

  if self.close_on_owner_leave and self.owner_bufnr and self.owner_bufnr ~= self.bufnr then
    api.nvim_create_autocmd({ 'BufLeave', 'BufHidden' }, {
      group = self.augroup,
      buffer = self.owner_bufnr,
      callback = function(args)
        if args.event == 'BufHidden' then
          close(self, 'owner_hidden')
        else
          schedule_owner_leave_close(self, 'owner_leave')
        end
      end,
    })
  end

  if self.close_on_owner_leave and self.owner_winid and self.owner_winid ~= self.winid then
    api.nvim_create_autocmd({ 'WinLeave', 'WinClosed' }, {
      group = self.augroup,
      callback = function(args)
        if args.event == 'WinClosed' then
          if tonumber(args.match) == self.owner_winid then close(self, 'owner_winclosed') end
        else
          if api.nvim_get_current_win() == self.owner_winid then schedule_owner_leave_close(self, 'owner_winleave') end
        end
      end,
    })
  end

  api.nvim_create_autocmd('FocusLost', {
    group = self.augroup,
    callback = function() close(self, 'focus_lost') end,
  })

  api.nvim_create_autocmd({ 'CursorMoved', 'WinScrolled' }, {
    group = self.augroup,
    callback = function(args)
      if not is_open(self) then return end
      if args.event == 'CursorMoved' and args.buf ~= self.bufnr then return end
      if args.event == 'WinScrolled' and args.match ~= tostring(self.winid) then return end
      schedule_clamp()
    end,
  })

  api.nvim_create_autocmd('WinClosed', {
    group = self.augroup,
    pattern = tostring(self.winid),
    callback = function() close(self) end,
  })

  schedule_clamp()

  return self.winid
end

local function toggle(self)
  if is_open(self) then
    close(self, 'toggle')
    return nil
  end

  return open(self)
end

return {
  is_open = is_open,
  contains_mouse = contains_mouse,
  close = close,
  open = open,
  toggle = toggle,
}
