local api = vim.api
local pointer = require('gbc.ui.interactions.pointer')

local Button = {}
Button.__index = Button

---@class gbc.ui.button
---@field get_target function|nil
---@field on_change function|nil
---@field pointer boolean
---@field hover_id string|nil
---@field id string
---@field attached boolean

local hover_state = {
  controllers = {},
  augroup = nil,
  on_key_ns = nil,
  mousemoveevent_enabled = false,
  mousemoveevent_original = nil,
  update_scheduled = false,
  last_mouse = nil,
}

local function controller_count()
  local count = 0
  for _ in pairs(hover_state.controllers) do
    count = count + 1
  end
  return count
end

local function clear_all_hover()
  for _, controller in pairs(hover_state.controllers) do
    controller:clear_hover()
  end
end

local function update_all_hover(mouse)
  mouse = mouse or vim.fn.getmousepos()
  for _, controller in pairs(hover_state.controllers) do
    controller:update_hover(mouse)
  end
end

local function schedule_hover_update()
  if hover_state.update_scheduled then return end
  hover_state.update_scheduled = true

  vim.schedule(function()
    hover_state.update_scheduled = false
    if controller_count() == 0 then return end
    update_all_hover(hover_state.last_mouse)
  end)
end

function Button.refresh_hover(mouse)
  if controller_count() == 0 then return end
  update_all_hover(mouse)
end

function Button.schedule_refresh() schedule_hover_update() end

function Button.clear_all_hover() clear_all_hover() end

local function teardown_global_listener()
  if controller_count() > 0 then return end

  if hover_state.augroup then
    pcall(api.nvim_del_augroup_by_id, hover_state.augroup)
    hover_state.augroup = nil
  end

  if hover_state.on_key_ns then
    vim.on_key(nil, hover_state.on_key_ns)
    hover_state.on_key_ns = nil
  end

  if hover_state.mousemoveevent_enabled then
    if hover_state.mousemoveevent_original ~= nil then vim.o.mousemoveevent = hover_state.mousemoveevent_original end
    hover_state.mousemoveevent_enabled = false
    hover_state.mousemoveevent_original = nil
  end
end

local function ensure_global_listener()
  if hover_state.mousemoveevent_original == nil then hover_state.mousemoveevent_original = vim.o.mousemoveevent end
  if not vim.o.mousemoveevent then vim.o.mousemoveevent = true end
  hover_state.mousemoveevent_enabled = true

  if not hover_state.on_key_ns then
    hover_state.on_key_ns = api.nvim_create_namespace('gbc_ui_button_hover')
    vim.on_key(function(key)
      if key == vim.keycode('<MouseMove>') then
        hover_state.last_mouse = vim.fn.getmousepos()
        schedule_hover_update()
      end
    end, hover_state.on_key_ns)
  end

  if not hover_state.augroup then
    hover_state.augroup = api.nvim_create_augroup('gbc_ui_button_hover', { clear = true })
    api.nvim_create_autocmd('FocusLost', {
      group = hover_state.augroup,
      callback = clear_all_hover,
    })
    api.nvim_create_autocmd('FocusGained', {
      group = hover_state.augroup,
      callback = schedule_hover_update,
    })
  end
end

---@param opts? table
---@return gbc.ui.button
function Button.new(opts)
  opts = opts or {}
  return setmetatable({
    get_target = opts.get_target,
    on_change = opts.on_change,
    pointer = opts.pointer == true,
    hover_id = nil,
    id = tostring(vim.uv.hrtime()),
    attached = false,
  }, Button)
end

function Button.render(label, opts)
  opts = opts or {}

  local parts = {}
  local hl_group = opts.hl
  if opts.hovered then
    if opts.variant == 'ghost' then
      hl_group = opts.ghost_hover_hl or opts.hover_hl or opts.hl
    else
      hl_group = opts.hover_hl or opts.hl
    end
  end
  if opts.callback and opts.callback ~= '' then table.insert(parts, opts.callback) end
  if hl_group and hl_group ~= '' then table.insert(parts, ('%%#%s#'):format(hl_group)) end
  table.insert(parts, label or '')
  if opts.callback and opts.callback ~= '' then table.insert(parts, '%T') end
  if opts.reset_hl and opts.reset_hl ~= '' then table.insert(parts, ('%%#%s#'):format(opts.reset_hl)) end

  return table.concat(parts)
end

function Button:is_hovered(target) return self.hover_id ~= nil and self.hover_id == target end

function Button:set_hover(target)
  if self.hover_id == target then return end
  self.hover_id = target
  if self.pointer then pointer.set_source(self.id, target ~= nil) end
  if self.on_change then self.on_change(target) end
end

function Button:clear_hover() self:set_hover(nil) end

function Button:update_hover(mouse)
  local target = self.get_target and self.get_target(mouse or vim.fn.getmousepos()) or nil
  self:set_hover(target)
end

function Button:attach()
  if self.attached then return end

  hover_state.controllers[self.id] = self
  self.attached = true
  ensure_global_listener()
  schedule_hover_update()
end

function Button:detach()
  if not self.attached then return end

  hover_state.controllers[self.id] = nil
  self.attached = false
  self:clear_hover()
  teardown_global_listener()
end

return Button
