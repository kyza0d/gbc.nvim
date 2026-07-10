local SELECTED_ICON = ' '
local SELECTED_ICON_WIDTH = vim.fn.strdisplaywidth(SELECTED_ICON)

local GUI_FORWARD_KEYS = {
  ['j'] = true,
  [vim.keycode('<Down>')] = true,
  [vim.keycode('<C-e>')] = true,
  [vim.keycode('<ScrollWheelDown>')] = true,
  [vim.keycode('<S-ScrollWheelDown>')] = true,
  [vim.keycode('<C-ScrollWheelDown>')] = true,
}

local GUI_BACKWARD_KEYS = {
  ['k'] = true,
  [vim.keycode('<Up>')] = true,
  [vim.keycode('<C-y>')] = true,
  [vim.keycode('<ScrollWheelUp>')] = true,
  [vim.keycode('<S-ScrollWheelUp>')] = true,
  [vim.keycode('<C-ScrollWheelUp>')] = true,
}

local GUI_DISMISS_KEYS = {
  ['q'] = true,
}

local GUI_ESCAPE_KEY = vim.keycode('<Esc>')

return {
  SELECTED_ICON = SELECTED_ICON,
  SELECTED_ICON_WIDTH = SELECTED_ICON_WIDTH,
  GUI_FORWARD_KEYS = GUI_FORWARD_KEYS,
  GUI_BACKWARD_KEYS = GUI_BACKWARD_KEYS,
  GUI_DISMISS_KEYS = GUI_DISMISS_KEYS,
  GUI_ESCAPE_KEY = GUI_ESCAPE_KEY,
}
