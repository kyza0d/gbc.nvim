local api = vim.api
local Button = require('gbc.ui.components.button')
local Menu = require('gbc.ui.components.menu')
local geometry = require('gbc.ui.geometry')
local highlight = require('gbc.ui.highlight')

local M = {}

local BUTTONS = {
  { id = 'roms', minwid = 1, label = '  ROMs  ' },
  { id = 'speed', minwid = 2, label = '  Speed  ' },
  { id = 'states', minwid = 3, label = '  States  ' },
  { id = 'pause', minwid = 4 },
}

local SPEEDS = { 0.25, 0.5, 1, 2, 3, 4 }

local state = {
  winid = nil,
  bufnr = nil,
  layout = nil,
  hover = nil,
  menu = nil,
  menu_id = nil,
  resumed_insert = nil,
}

_G.__gbc_winbar_callbacks = _G.__gbc_winbar_callbacks or {}

local function game() return require('gbc.game') end

local function is_attached() return state.winid ~= nil and api.nvim_win_is_valid(state.winid) end

local function pause_label()
  local info = game().session_info()
  return (info and info.paused) and '  Resume  ' or '  Pause  '
end

local function button_label(button)
  if button.id == 'pause' then return pause_label() end
  return button.label
end

local function title_text()
  local info = game().session_info()
  if not info then return ' gbc.nvim ' end

  local title = ' ' .. vim.fn.fnamemodify(info.rom_path or '', ':t:r') .. ' '
  if info.paused then return title .. '· paused ' end
  if info.speed_multiplier and info.speed_multiplier ~= 1 then return title .. string.format('· %gx ', info.speed_multiplier) end
  return title
end

local function build_layout()
  local width = is_attached() and api.nvim_win_get_width(state.winid) or 80
  local right_width = 0
  for _, button in ipairs(BUTTONS) do
    right_width = right_width + geometry.display_width(button_label(button))
  end

  local buttons = {}
  local col = math.max(0, width - right_width)
  for _, button in ipairs(BUTTONS) do
    local label = button_label(button)
    local label_width = geometry.display_width(label)
    buttons[button.id] = {
      start_col = col,
      end_col = col + label_width,
      label = label,
      minwid = button.minwid,
    }
    col = col + label_width
  end

  state.layout = {
    width = width,
    title = title_text(),
    buttons = buttons,
  }
  return state.layout
end

local function callback_expr(button_id, minwid)
  _G.__gbc_winbar_callbacks[button_id] = function() M.handle_click(button_id) end
  return ('%%%d@v:lua.__gbc_winbar_callbacks.%s@'):format(minwid, button_id)
end

local function build_winbar()
  local layout = build_layout()
  local parts = {
    '%#GbcWinbarTitle#',
    layout.title:gsub('%%', '%%%%'),
    '%*',
    '%=',
    '%#GbcWinbarAccent#',
  }

  for _, button in ipairs(BUTTONS) do
    local segment = layout.buttons[button.id]
    local active = state.menu_id == button.id and state.menu ~= nil and state.menu:is_open()
    parts[#parts + 1] = Button.render(segment.label, {
      callback = callback_expr(button.id, segment.minwid),
      hl = 'GbcWinbarAccent',
      hover_hl = 'GbcButtonHover',
      hovered = state.hover == button.id or active,
      reset_hl = 'GbcWinbarAccent',
    })
  end

  parts[#parts + 1] = '%*'
  return table.concat(parts)
end

function M.refresh()
  if not is_attached() then return end
  api.nvim_set_option_value('winbar', build_winbar(), { win = state.winid })
end

local function hover_target(mouse)
  if not is_attached() or not geometry.is_mouse_on_winbar(state.winid, mouse) then return nil end

  local layout = state.layout or build_layout()
  local col = geometry.mouse_win_col(mouse, state.winid)
  for _, button in ipairs(BUTTONS) do
    if geometry.segment_contains_col(layout.buttons[button.id], col) then return button.id end
  end
  return nil
end

local function menu_anchor(button_id)
  return function()
    if not is_attached() then return nil end
    local layout = state.layout or build_layout()
    local segment = layout.buttons[button_id]
    local width = api.nvim_win_get_width(state.winid)
    return {
      relative = 'win',
      win = state.winid,
      anchor = 'NE',
      row = 0,
      col = math.max(0, math.min(segment and segment.end_col or width, width)),
    }
  end
end

local function suspend_terminal_mode()
  state.resumed_insert = api.nvim_get_mode().mode:sub(1, 1) == 't' and api.nvim_get_current_buf() == state.bufnr
  if state.resumed_insert then vim.cmd('stopinsert') end
end

local function restore_terminal_mode()
  if not state.resumed_insert then return end
  state.resumed_insert = nil

  vim.schedule(function()
    if not is_attached() then return end
    if api.nvim_get_current_win() ~= state.winid then return end
    if api.nvim_get_current_buf() ~= state.bufnr then return end
    vim.cmd('startinsert')
  end)
end

local function close_menu()
  if state.menu then state.menu:close('replaced') end
end

local function open_menu(button_id, items)
  if #items == 0 then return end

  suspend_terminal_mode()
  state.menu_id = button_id
  state.menu = Menu.new({
    items = items,
    close_on_owner_leave = true,
    anchor = menu_anchor(button_id),
    on_close = function()
      state.menu = nil
      state.menu_id = nil
      restore_terminal_mode()
      M.refresh()
    end,
  })
  state.menu:open()
  M.refresh()
end

local function scan_rom_dirs()
  local roms = {}
  local seen = {}
  local rom_dirs = require('gbc.config').get().rom_dirs or {}

  for _, dir in ipairs(rom_dirs) do
    local expanded = vim.fn.fnamemodify(dir, ':p')
    for _, pattern in ipairs({ '*.gb', '*.gbc' }) do
      for _, path in ipairs(vim.fn.glob(expanded .. pattern, true, true)) do
        if not seen[path] then
          seen[path] = true
          roms[#roms + 1] = path
        end
      end
    end
  end

  table.sort(roms)
  return roms
end

local function browse_start_dir()
  local rom_dirs = require('gbc.config').get().rom_dirs or {}
  local info = game().session_info()
  if info and info.rom_path then return vim.fn.fnamemodify(info.rom_path, ':h') .. '/' end
  if rom_dirs[1] then return vim.fn.fnamemodify(rom_dirs[1], ':p') end
  return vim.fn.getcwd() .. '/'
end

local function file_dialog_command(start_dir)
  if vim.fn.executable('zenity') == 1 then
    return {
      'zenity',
      '--file-selection',
      '--title=Select ROM',
      '--filename=' .. start_dir,
      '--file-filter=Game Boy ROMs | *.gb *.gbc',
      '--file-filter=All files | *',
    }
  end

  if vim.fn.executable('kdialog') == 1 then return { 'kdialog', '--getopenfilename', start_dir, '*.gb *.gbc|Game Boy ROMs' } end

  return nil
end

local function browse_for_rom()
  local command = file_dialog_command(browse_start_dir())
  if not command then
    vim.ui.input({ prompt = 'ROM path: ', completion = 'file' }, function(path)
      if path and vim.trim(path) ~= '' then require('gbc').start(path) end
    end)
    return
  end

  vim.system(command, { text = true }, function(result)
    -- Non-zero exit means the dialog was cancelled; stay quiet.
    if result.code ~= 0 then return end

    local path = vim.trim(result.stdout or '')
    if path == '' then return end

    vim.schedule(function() require('gbc').start(path) end)
  end)
end

local function rom_menu_items()
  local info = game().session_info()
  local current_rom = info and info.rom_path or nil
  local items = {}

  for _, path in ipairs(scan_rom_dirs()) do
    items[#items + 1] = {
      label = vim.fn.fnamemodify(path, ':t'),
      selected = path == current_rom,
      action = function() require('gbc').start(path) end,
    }
  end

  items[#items + 1] = {
    label = 'Browse…',
    action = browse_for_rom,
  }

  return items
end

local function speed_menu_items()
  local info = game().session_info()
  local current = info and info.speed_multiplier or 1
  local items = {}

  for _, speed in ipairs(SPEEDS) do
    items[#items + 1] = {
      label = string.format('%gx', speed),
      selected = speed == current,
      action = function() game().set_speed(speed) end,
    }
  end

  return items
end

local function state_menu_items()
  local slots = tonumber(require('gbc.config').get().state_slots) or 3
  local items = {}

  for slot = 1, slots do
    items[#items + 1] = {
      label = string.format('Save Slot %d', slot),
      action = function() game().save_state(slot) end,
    }
  end

  items[#items + 1] = { label = '──────', selectable = false }

  for slot = 1, slots do
    local exists = game().state_slot_exists(slot)
    items[#items + 1] = {
      label = string.format('Load Slot %d%s', slot, exists and '' or ' (empty)'),
      selectable = exists,
      action = function() game().load_state(slot) end,
    }
  end

  return items
end

function M.handle_click(button_id)
  if state.menu and state.menu_id == button_id and state.menu:is_open() then
    close_menu()
    return
  end
  close_menu()

  if button_id == 'pause' then
    game().toggle_pause()
    M.refresh()
    return
  end

  -- Deferred so the winbar click fully unwinds before a float opens; opening
  -- a window from inside the click expression can hit textlock.
  vim.schedule(function()
    if not is_attached() then return end
    if button_id == 'roms' then
      open_menu('roms', rom_menu_items())
    elseif button_id == 'speed' then
      open_menu('speed', speed_menu_items())
    elseif button_id == 'states' then
      open_menu('states', state_menu_items())
    end
  end)
end

function M.attach(winid, bufnr)
  if not winid or not api.nvim_win_is_valid(winid) then return end

  highlight.setup()
  state.winid = winid
  state.bufnr = bufnr

  if not state.hover_button then
    state.hover_button = Button.new({
      pointer = true,
      get_target = hover_target,
      on_change = function(target)
        state.hover = target
        M.refresh()
      end,
    })
  end
  state.hover_button:attach()

  M.refresh()
end

function M.detach()
  close_menu()
  if state.hover_button then
    state.hover_button:detach()
    state.hover_button = nil
  end
  if is_attached() then pcall(api.nvim_set_option_value, 'winbar', '', { win = state.winid }) end
  state.winid = nil
  state.bufnr = nil
  state.layout = nil
  state.hover = nil
end

return M
