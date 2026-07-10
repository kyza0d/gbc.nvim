local api = vim.api

local function sync_view(self)
  if not self:is_open() then return end

  local active_index = self:current_index()
  pcall(api.nvim_win_call, self.winid, function()
    local view = vim.fn.winsaveview()
    local height = math.max(1, api.nvim_win_get_height(self.winid))
    local item_count = math.max(1, #self.items)

    if active_index and self._scrollable then
      local max_topline = math.max(1, item_count - height + 1)
      local topline = math.max(1, math.min(view.topline, max_topline))
      if active_index < topline then
        topline = active_index
      elseif active_index >= topline + height then
        topline = active_index - height + 1
      end
      view.topline = math.max(1, math.min(topline, max_topline))
    else
      view.topline = 1
    end

    view.leftcol = 0
    view.skipcol = 0
    vim.fn.winrestview(view)

    if active_index and not self.use_virtual_cursor then api.nvim_win_set_cursor(self.winid, { active_index, 0 }) end
  end)
end

return {
  sync_view = sync_view,
}
