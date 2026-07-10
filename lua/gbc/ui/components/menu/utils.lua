local constants = require('gbc.ui.components.menu.constants')

local function is_selectable(item) return item ~= nil and item.selectable ~= false end

local function truncate_to_width(str, max_width, ellipsis)
  ellipsis = ellipsis or ' …'
  if vim.fn.strdisplaywidth(str) <= max_width then return str end

  local ellipsis_width = vim.fn.strdisplaywidth(ellipsis)
  if max_width <= ellipsis_width then return vim.fn.strcharpart('…', 0, math.max(max_width, 0)) end

  local target_width = max_width - ellipsis_width
  local result = ''
  local current_width = 0

  local char_count = vim.fn.strchars(str)
  for i = 0, char_count - 1 do
    local c = vim.fn.strcharpart(str, i, 1)
    local char_width = vim.fn.strdisplaywidth(c)
    if current_width + char_width > target_width then break end
    result = result .. c
    current_width = current_width + char_width
  end

  result = result:gsub('[ \t]+$', '')
  return result .. ellipsis
end

local function default_anchor(width, height)
  local mouse = vim.fn.getmousepos()
  local columns = vim.o.columns
  local lines = vim.o.lines - vim.o.cmdheight
  local row = mouse.screenrow > 0 and mouse.screenrow or 1
  local col = mouse.screencol > 0 and (mouse.screencol - 1) or 1

  row = math.max(0, math.min(row, math.max(0, lines - height - 1)))
  col = math.max(0, math.min(col, math.max(0, columns - width)))

  return {
    relative = 'editor',
    row = row,
    col = col,
  }
end

local function toggle_icon(item)
  if not item or not item.toggle then return nil end
  if item.selected then return item.toggle_icon_on or '✓' end
  return item.toggle_icon_off or ' '
end

local function menu_width(items)
  local width = 0
  for _, item in ipairs(items) do
    local label_width = vim.fn.strdisplaywidth(item.label or '')
    if is_selectable(item) then
      local suffix
      if item.toggle then
        suffix = toggle_icon(item)
      elseif item.selected then
        suffix = constants.SELECTED_ICON
      end
      local suffix_width = suffix and vim.fn.strdisplaywidth(suffix) or 0
      local suffix_gap_width = suffix and 1 or 0
      width = math.max(width, label_width + suffix_width + suffix_gap_width + 2)
    else
      width = math.max(width, label_width)
    end
  end
  return math.max(12, width)
end

local function render_item_label(item, width)
  local label = item.label or ''
  if not is_selectable(item) then
    if width and vim.fn.strdisplaywidth(label) > width then return truncate_to_width(label, width) end
    return label
  end

  local suffix
  if item.toggle then
    suffix = toggle_icon(item)
  elseif item.selected then
    suffix = constants.SELECTED_ICON
  end
  suffix = suffix or ''
  local suffix_width = vim.fn.strdisplaywidth(suffix)
  local suffix_gap_width = suffix ~= '' and 1 or 0
  local available_for_label = width - 1 - suffix_gap_width - suffix_width

  if vim.fn.strdisplaywidth(label) > available_for_label then label = truncate_to_width(label, available_for_label) end

  local line = ' ' .. label
  local line_width = vim.fn.strdisplaywidth(line)
  local padding_width = math.max(0, width - line_width - suffix_gap_width - suffix_width)

  return line .. string.rep(' ', padding_width + suffix_gap_width) .. suffix
end

local function copy_highlight(ns, target, source)
  local source_namespaces = {}

  if type(source) == 'table' then
    source_namespaces = source.namespaces or {}
    source = source.name
  end

  for _, source_ns in ipairs(source_namespaces) do
    local ok, group = pcall(vim.api.nvim_get_hl, source_ns, { name = source, link = false })
    if ok and not vim.tbl_isempty(group) then
      vim.api.nvim_set_hl(ns, target, group)
      return
    end
  end

  local ok, group = pcall(vim.api.nvim_get_hl, 0, { name = source, link = false })
  if not ok or vim.tbl_isempty(group) then return end
  vim.api.nvim_set_hl(ns, target, group)
end

local function get_buffer_mapping(bufnr, lhs, mode)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return nil end

  return vim.api.nvim_buf_call(bufnr, function()
    local mapping = vim.fn.maparg(lhs, mode or 'n', false, true)
    if type(mapping) == 'table' and not vim.tbl_isempty(mapping) then return mapping end
    return nil
  end)
end

local function restore_buffer_mapping(bufnr, mapping)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or type(mapping) ~= 'table' or vim.tbl_isempty(mapping) then return end

  vim.api.nvim_buf_call(bufnr, function() vim.fn.mapset(mapping.mode or 'n', false, mapping) end)
end

local function use_gui_passthrough_interaction(menu)
  return menu and menu.preserve_owner_state == true and menu.owner_keymaps_enabled == false
end

return {
  is_selectable = is_selectable,
  truncate_to_width = truncate_to_width,
  default_anchor = default_anchor,
  menu_width = menu_width,
  render_item_label = render_item_label,
  copy_highlight = copy_highlight,
  get_buffer_mapping = get_buffer_mapping,
  restore_buffer_mapping = restore_buffer_mapping,
  use_gui_passthrough_interaction = use_gui_passthrough_interaction,
}
