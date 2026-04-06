local api = vim.api
local bit = require('bit')
local fn = vim.fn
local uv = vim.uv or vim.loop

local input = require('gbc.input')

local M = {}

local ns = api.nvim_create_namespace('gbc-controls')
local on_key_registered = false

local passthrough_keys = {
  [vim.keycode('<C-Bslash>')] = true,
  [vim.keycode('<C-N>')] = true,
  [vim.keycode('<C-O>')] = true,
}

local state = {
  by_buf = {},
  by_session = setmetatable({}, { __mode = 'k' }),
}

local function push_unique(list, seen, value)
  if type(value) ~= 'string' or value == '' or seen[value] then return end

  seen[value] = true
  list[#list + 1] = value
end

local function key_candidates(key)
  local candidates = {}
  local seen = {}
  if type(key) ~= 'string' or key == '' then return candidates end

  local translated = fn.keytrans(key)
  push_unique(candidates, seen, key)
  push_unique(candidates, seen, vim.keycode(key))
  push_unique(candidates, seen, translated)
  push_unique(candidates, seen, vim.keycode(translated))

  local base = translated:match('.*[-<](.+)>')
  if base then
    push_unique(candidates, seen, base)
    push_unique(candidates, seen, base:lower())
    push_unique(candidates, seen, '<' .. base .. '>')
    push_unique(candidates, seen, vim.keycode('<' .. base .. '>'))
  end

  if translated == '^M' or key == '\r' then
    push_unique(candidates, seen, '<CR>')
    push_unique(candidates, seen, vim.keycode('<CR>'))
  end

  if translated == '<Space>' or key == ' ' then
    push_unique(candidates, seen, '<Space>')
    push_unique(candidates, seen, vim.keycode('<Space>'))
  end

  return candidates
end

local function normalize_key(key)
  local candidates = key_candidates(key)
  if #candidates == 0 then return nil end

  return candidates[1]
end

local function resolve_button(button_value)
  if type(button_value) == 'number' then return button_value end

  if type(button_value) ~= 'string' then return nil end

  local name = vim.trim(button_value):upper()
  if name == '' then return nil end

  return input.button[name]
end

local function normalize_mapping(mapping)
  local normalized = {}

  if type(mapping) ~= 'table' then return normalized end

  for lhs, rhs in pairs(mapping) do
    local button = resolve_button(rhs)
    if button then
      for _, candidate in ipairs(key_candidates(lhs)) do
        normalized[candidate] = button
      end
    end
  end

  return normalized
end

local function close_timer(timer)
  if not timer then return end

  pcall(timer.stop, timer)
  if timer.is_closing and timer:is_closing() then return end

  pcall(timer.close, timer)
end

local function pressed_button_count(entry)
  local count = 0
  for _ in pairs(entry.deadlines) do
    count = count + 1
  end

  return count
end

local function process_deadlines(entry, now_ms)
  now_ms = now_ms or uv.now()

  local next_due_ms = nil
  for button, deadline in pairs(entry.deadlines) do
    if now_ms >= deadline then
      entry.deadlines[button] = nil
      input.set_button(button, false)
    else
      if not next_due_ms or deadline < next_due_ms then next_due_ms = deadline end
    end
  end

  if not next_due_ms then
    entry.timer_running = false
    return
  end

  entry.timer_running = true
  local delay = math.max(0, next_due_ms - now_ms)
  entry.timer:start(delay, 0, vim.schedule_wrap(function()
    if entry.closed then return end

    process_deadlines(entry, uv.now())
  end))
end

local function press_button(entry, button, now_ms)
  now_ms = now_ms or uv.now()

  local was_pressed = entry.deadlines[button] ~= nil
  entry.deadlines[button] = now_ms + entry.key_hold_ms
  input.set_button(button, true)

  if not entry.timer_running then process_deadlines(entry, now_ms) end

  return not was_pressed
end

local function on_key(key)
  if api.nvim_get_mode().mode ~= 't' then return end

  local buf = api.nvim_get_current_buf()
  local entry = state.by_buf[buf]
  if not entry or entry.closed then return end

  local button
  for _, candidate in ipairs(key_candidates(key)) do
    if passthrough_keys[candidate] then return end

    button = entry.mapping[candidate]
    if button then break end
  end
  if not button then return end

  press_button(entry, button)
  return ''
end

local function ensure_on_key()
  if on_key_registered then return end

  on_key_registered = true
  vim.on_key(function(key)
    local ok, result = pcall(on_key, key)
    return ok and result or nil
  end, ns)
end

function M.attach(session, opts)
  opts = opts or {}
  if opts.enabled == false or not session then return false end

  local buf = opts.buf
  if type(buf) ~= 'number' or not api.nvim_buf_is_valid(buf) then return false, 'invalid screen buffer' end

  M.detach(session)

  local timer = assert(uv.new_timer())
  local entry = {
    session = session,
    buf = buf,
    mapping = normalize_mapping(opts.mapping),
    key_hold_ms = math.max(1, tonumber(opts.key_hold_ms) or 75),
    deadlines = {},
    timer = timer,
    timer_running = false,
    closed = false,
    bound_keys = {},
  }

  state.by_buf[buf] = entry
  state.by_session[session] = entry

  if type(opts.mapping) == 'table' then
    for lhs, rhs in pairs(opts.mapping) do
      local button = resolve_button(rhs)
      if button then
        vim.keymap.set('t', lhs, function()
          if entry.closed then return '' end

          press_button(entry, button)
          return ''
        end, {
          buffer = buf,
          expr = true,
          nowait = true,
          noremap = true,
          replace_keycodes = false,
          silent = true,
          desc = '[gbc.nvim] terminal control input',
        })
        entry.bound_keys[#entry.bound_keys + 1] = lhs
      end
    end
  end

  ensure_on_key()
  return true
end

function M.detach(session)
  local entry = state.by_session[session]
  if not entry then return end

  entry.closed = true
  close_timer(entry.timer)
  for _, lhs in ipairs(entry.bound_keys or {}) do
    pcall(vim.keymap.del, 't', lhs, { buffer = entry.buf })
  end

  state.by_session[session] = nil
  if state.by_buf[entry.buf] == entry then state.by_buf[entry.buf] = nil end

  if vim.tbl_isempty(state.by_buf) then
    input.set_state(0)
    return
  end

  local mask = 0
  for _, active in pairs(state.by_buf) do
    if not active.closed then
      for button in pairs(active.deadlines) do
        mask = bit.bor(mask, button)
      end
    end
  end
  input.set_state(mask)
end

M._test = {
  normalize_key = normalize_key,
  normalize_mapping = normalize_mapping,
  process_deadlines = process_deadlines,
  press_button = press_button,
  pressed_button_count = pressed_button_count,
}

return M
