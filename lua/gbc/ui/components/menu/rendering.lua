local api = vim.api
local utils = require('gbc.ui.components.menu.utils')

local function refresh_highlight(self)
  if self.bufnr and self.hover_ns and api.nvim_buf_is_valid(self.bufnr) then
    api.nvim_buf_clear_namespace(self.bufnr, self.hover_ns, 0, -1)
  end

  local index = self.hover_index or self.active_index
  if not index or not self.bufnr or not self.hover_ns or not api.nvim_buf_is_valid(self.bufnr) then return end

  api.nvim_buf_set_extmark(self.bufnr, self.hover_ns, index - 1, 0, {
    line_hl_group = 'GbcMenuHover',
    hl_eol = true,
    priority = 150,
  })
end

local function clear_hover(self)
  self.hover_index = nil
  refresh_highlight(self)
end

local function refresh(self)
  if not self:is_open() or not self.bufnr or not api.nvim_buf_is_valid(self.bufnr) then return end

  local width = math.max(self.min_width, api.nvim_win_get_width(self.winid))
  local labels = {}
  for _, item in ipairs(self.items) do
    table.insert(labels, utils.render_item_label(item, width))
  end

  api.nvim_set_option_value('modifiable', true, { buf = self.bufnr })
  api.nvim_buf_set_lines(self.bufnr, 0, -1, false, labels)
  api.nvim_set_option_value('modifiable', false, { buf = self.bufnr })
  refresh_highlight(self)
  self:sync_view()
end

local function set_hover(self, index)
  if self.hover_index == index then return end

  self.hover_index = index
  refresh_highlight(self)
end

local function set_active(self, index)
  if self.active_index == index then return end

  self.active_index = index
  refresh_highlight(self)
end

return {
  clear_hover = clear_hover,
  refresh_highlight = refresh_highlight,
  refresh = refresh,
  set_hover = set_hover,
  set_active = set_active,
}
