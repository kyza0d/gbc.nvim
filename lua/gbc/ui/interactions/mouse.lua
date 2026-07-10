local api = vim.api

local M = {}

local hover_state = {
  windows = {},
  sequence = 0,
}

local function window_contains_screen_position(winid, screenrow, screencol)
  if not winid or not api.nvim_win_is_valid(winid) then return false end
  if not screenrow or not screencol or screenrow <= 0 or screencol <= 0 then return false end

  local pos = api.nvim_win_get_position(winid)
  local top = tonumber(pos[1]) and (pos[1] + 1) or nil
  local left = tonumber(pos[2]) and (pos[2] + 1) or nil
  local height = api.nvim_win_get_height(winid)
  local width = api.nvim_win_get_width(winid)
  if not top or not left or not height or not width then return false end

  return screenrow >= top and screenrow < (top + height) and screencol >= left and screencol < (left + width)
end

local function window_sort_key(winid)
  local config = api.nvim_win_get_config(winid)
  local is_float = type(config.relative) == 'string' and config.relative ~= ''
  local zindex = tonumber(config.zindex)

  if is_float and zindex == nil then zindex = 50 end
  if zindex == nil then zindex = -1 end

  return is_float, zindex
end

function M.register_hover_window(winid, opts)
  if not winid or not api.nvim_win_is_valid(winid) then return end

  local config = api.nvim_win_get_config(winid)
  local is_float = type(config.relative) == 'string' and config.relative ~= ''
  local zindex = opts and tonumber(opts.zindex) or tonumber(config.zindex)
  if is_float and zindex == nil then zindex = 50 end
  if zindex == nil then zindex = -1 end

  local existing = hover_state.windows[winid]
  hover_state.sequence = hover_state.sequence + 1
  hover_state.windows[winid] = {
    order = existing and existing.order or hover_state.sequence,
    zindex = zindex,
  }
end

function M.unregister_hover_window(winid)
  if not winid then return end
  hover_state.windows[winid] = nil
end

function M.clear_hover_windows() hover_state.windows = {} end

function M.topmost_window_under_mouse(mouse)
  if type(mouse) ~= 'table' then return nil end

  local screenrow = tonumber(mouse.screenrow)
  local screencol = tonumber(mouse.screencol)
  if not screenrow or not screencol or screenrow <= 0 or screencol <= 0 then return nil end

  local topmost_winid
  local topmost_is_float = false
  local topmost_zindex = -1
  local topmost_order = -1

  local function should_replace_candidate(winid, is_float, zindex)
    local candidate = hover_state.windows[winid]
    local order = candidate and candidate.order or -1

    if topmost_winid == nil then return true, order end
    if zindex > topmost_zindex then return true, order end
    if zindex < topmost_zindex then return false, order end
    if is_float and not topmost_is_float then return true, order end
    if is_float ~= topmost_is_float then return false, order end
    if order > topmost_order then return true, order end
    return false, order
  end

  for winid, _ in pairs(hover_state.windows) do
    if window_contains_screen_position(winid, screenrow, screencol) then
      local is_float, zindex = window_sort_key(winid)
      local replace, order = should_replace_candidate(winid, is_float, zindex)
      if replace then
        topmost_winid = winid
        topmost_is_float = is_float
        topmost_zindex = zindex
        topmost_order = order
      end
    end
  end

  return topmost_winid
end

function M.should_window_handle_hover(winid, mouse)
  if not winid or not api.nvim_win_is_valid(winid) then return false end
  local topmost_winid = M.topmost_window_under_mouse(mouse)
  if not topmost_winid then return true end
  return topmost_winid == winid
end

return M
