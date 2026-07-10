local constants = require('gbc.ui.components.menu.constants')
local lifecycle = require('gbc.ui.components.menu.lifecycle')
local rendering = require('gbc.ui.components.menu.rendering')
local navigation = require('gbc.ui.components.menu.navigation')
local selection = require('gbc.ui.components.menu.selection')
local interaction = require('gbc.ui.components.menu.interaction')
local keymaps_module = require('gbc.ui.components.menu.keymaps')
local view_module = require('gbc.ui.components.menu.view')

local Menu = {}
Menu.__index = Menu

function Menu.new(opts)
  opts = opts or {}
  return setmetatable({
    items = opts.items or {},
    anchor = opts.anchor or require('gbc.ui.components.menu.utils').default_anchor,
    on_close = opts.on_close,
    hl_ns = opts.hl_ns,
    menu_hl_ns = nil,
    hover_ns = nil,
    active_index = nil,
    hover_index = nil,
    border = opts.border or 'none',
    zindex = opts.zindex or 80,
    min_width = opts.min_width or 12,
    max_width = opts.max_width,
    max_height = opts.max_height,
    close_on_owner_leave = opts.close_on_owner_leave == true,
    focusable = opts.focusable == true,
    use_virtual_cursor = opts.use_virtual_cursor ~= false and opts.focusable ~= true,
    captures_mouse = opts.captures_mouse == true or opts.focusable == true,
    preserve_owner_state = opts.preserve_owner_state == true,
    bufnr = nil,
    winid = nil,
    augroup = nil,
    owner_bufnr = nil,
    owner_winid = nil,
    interaction_ns = nil,
    owner_keymaps_enabled = nil,
    owns_mousemoveevent = false,
    keymaps = {},
  }, Menu)
end

Menu.is_open = lifecycle.is_open
Menu.contains_mouse = lifecycle.contains_mouse
Menu.close = lifecycle.close
Menu.open = lifecycle.open
Menu.toggle = lifecycle.toggle

Menu.select = selection.select
Menu.confirm_selection = selection.confirm_selection
Menu.mouse_item_index = selection.mouse_item_index

Menu.clear_hover = rendering.clear_hover
Menu.refresh_highlight = rendering.refresh_highlight
Menu.refresh = rendering.refresh
Menu.set_hover = rendering.set_hover
Menu.set_active = rendering.set_active

Menu.current_index = navigation.current_index
Menu.visible_row = navigation.visible_row
Menu.first_selectable_index = navigation.first_selectable_index
Menu.initial_selectable_index = navigation.initial_selectable_index
Menu.last_selectable_index = navigation.last_selectable_index
Menu.next_selectable_index = navigation.next_selectable_index
Menu.move = navigation.move

Menu.update_hover = interaction.update_hover
Menu.handle_left_mouse_down = interaction.handle_left_mouse_down
Menu.handle_left_mouse_up = interaction.handle_left_mouse_up
Menu.install_interaction_listener = interaction.install_interaction_listener
Menu.install_mouse_keymaps = interaction.install_mouse_keymaps

Menu.save_keymap = keymaps_module.save_keymap
Menu.set_keymap = keymaps_module.set_keymap
Menu.restore_keymaps = keymaps_module.restore_keymaps

Menu.sync_view = view_module.sync_view

return Menu
