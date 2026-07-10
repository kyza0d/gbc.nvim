local api = vim.api
local utils = require('gbc.ui.components.menu.utils')

local function window_topline(winid)
  local ok, topline = pcall(api.nvim_win_call, winid, function()
    local view = vim.fn.winsaveview()
    return view and view.topline or nil
  end)
  topline = ok and tonumber(topline) or nil
  return topline or 1
end

local function select(self, index)
  local item = self.items[index]
  if not utils.is_selectable(item) then return end
  local action = item and item.action
  if item.keep_open then
    if type(action) == 'function' then
      vim.schedule(function()
        action()
        if self:is_open() and self.refresh then self:refresh() end
      end)
    end
    return
  end
  self:close('select')
  if type(action) == 'function' then vim.schedule(action) end
end

local function confirm_selection(self)
  if not self:is_open() then return end
  self:select(self:current_index())
end

local function mouse_item_index(self, mouse)
  if not self:is_open() or type(mouse) ~= 'table' then return nil end
  local index = tonumber(mouse.line)

  if mouse.winid ~= self.winid then
    if not self:contains_mouse(mouse) then return nil end
    local screenrow = tonumber(mouse.screenrow)
    local pos = api.nvim_win_get_position(self.winid)
    local win_row = screenrow and pos and tonumber(pos[1]) and (screenrow - pos[1]) or nil
    if not win_row then return nil end
    index = window_topline(self.winid) + win_row - 1
  end

  if not index or index < 1 or index > #self.items then return nil end
  if not utils.is_selectable(self.items[index]) then return nil end
  return index
end

return {
  select = select,
  confirm_selection = confirm_selection,
  mouse_item_index = mouse_item_index,
}
