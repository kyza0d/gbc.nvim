local api = vim.api

local M = {}

function M.display_width(text) return vim.fn.strdisplaywidth(text or '') end

local function window_screen_info(winid)
  if not winid or not api.nvim_win_is_valid(winid) then return nil end

  local info = vim.fn.getwininfo(winid)[1]
  if type(info) ~= 'table' or vim.tbl_isempty(info) then return nil end
  return info
end

function M.mouse_win_col(mouse, winid)
  local info = window_screen_info(winid)
  local screencol = tonumber(mouse and mouse.screencol)
  local wincol = info and tonumber(info.wincol) or nil

  if screencol and wincol then return math.max(0, screencol - wincol) end

  wincol = tonumber(mouse and mouse.wincol) or 1
  return math.max(0, wincol - 1)
end

function M.is_mouse_on_statusline(winid, mouse)
  if not winid or not api.nvim_win_is_valid(winid) or type(mouse) ~= 'table' then return false end
  if mouse.winid == winid and tonumber(mouse.line) == 0 then return true end

  local info = window_screen_info(winid)
  if not info then return false end

  local screenrow = tonumber(mouse.screenrow)
  local screencol = tonumber(mouse.screencol)
  local winrow = tonumber(info.winrow)
  local wincol = tonumber(info.wincol)
  local width = tonumber(info.width)
  local height = tonumber(info.height)
  local winbar = tonumber(info.winbar) or 0
  local status_height = tonumber(info.status_height)

  if not screenrow or not screencol or not winrow or not wincol or not width or not height or not status_height then
    return false
  end
  if status_height <= 0 then return false end

  local statusline_row = winrow + winbar + height
  local max_col = wincol + width - 1
  return screenrow >= statusline_row
    and screenrow < statusline_row + status_height
    and screencol >= wincol
    and screencol <= max_col
end

function M.is_mouse_on_winbar(winid, mouse)
  if not winid or not api.nvim_win_is_valid(winid) or type(mouse) ~= 'table' then return false end
  if mouse.winid ~= winid then return false end
  return tonumber(mouse.winrow) == 1 and tonumber(mouse.line) == 0
end

function M.segment_contains_col(segment, col)
  if not segment then return false end
  return col >= segment.start_col and col < segment.end_col
end

return M
