local api = vim.api
local utils = require('gbc.ui.components.menu.utils')

local initial_selectable_index

local function current_index(self)
  if self.active_index and utils.is_selectable(self.items[self.active_index]) then return self.active_index end
  return initial_selectable_index(self)
end

local function visible_row(self)
  if self.focusable and self:is_open() then return api.nvim_win_get_cursor(self.winid)[1] end
  return current_index(self) or 1
end

local function first_selectable_index(self)
  for index, item in ipairs(self.items) do
    if utils.is_selectable(item) then return index end
  end
  return nil
end

function initial_selectable_index(self)
  for index, item in ipairs(self.items) do
    if item.selected and utils.is_selectable(item) then return index end
  end

  return first_selectable_index(self)
end

local function last_selectable_index(self)
  for index = #self.items, 1, -1 do
    if utils.is_selectable(self.items[index]) then return index end
  end
  return nil
end

local function next_selectable_index(self, start_index, step)
  local item_count = #self.items
  if item_count == 0 then return nil end
  if step ~= 1 and step ~= -1 then return nil end

  local index = math.max(1, math.min(start_index or 1, item_count))
  for _ = 1, item_count do
    index = ((index - 1 + step) % item_count) + 1
    if utils.is_selectable(self.items[index]) then return index end
  end

  return nil
end

local function move(self, step)
  if not self:is_open() then return end

  local current_row = current_index(self)
  local target_row

  if utils.is_selectable(self.items[current_row]) then
    target_row = next_selectable_index(self, current_row, step)
  elseif step > 0 then
    target_row = next_selectable_index(self, current_row, step) or first_selectable_index(self)
  else
    target_row = next_selectable_index(self, current_row, step) or last_selectable_index(self)
  end

  if target_row then
    self:set_active(target_row)
    self:sync_view()
  end
end

return {
  current_index = current_index,
  visible_row = visible_row,
  first_selectable_index = first_selectable_index,
  initial_selectable_index = initial_selectable_index,
  last_selectable_index = last_selectable_index,
  next_selectable_index = next_selectable_index,
  move = move,
}
