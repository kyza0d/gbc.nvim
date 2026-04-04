local uv = vim.uv or vim.loop

local M = {}

local unpack = table.unpack or unpack
local enabled = vim.env.GBC_PROFILE == '1'
local stats = {}

local function metric(name)
  local current = stats[name]
  if current then return current end

  current = {
    count = 0,
    total_ns = 0,
    max_ns = 0,
  }
  stats[name] = current
  return current
end

function M.enabled() return enabled end

function M.set_enabled(value) enabled = not not value end

function M.record(name, elapsed_ns)
  if not enabled or not name or not elapsed_ns then return end

  local current = metric(name)
  current.count = current.count + 1
  current.total_ns = current.total_ns + elapsed_ns
  if elapsed_ns > current.max_ns then current.max_ns = elapsed_ns end
end

function M.time(name, fn, ...)
  if not enabled then return fn(...) end

  local started = uv.hrtime()
  local results = table.pack(pcall(fn, ...))
  local ok = results[1]
  local finished = uv.hrtime()
  M.record(name, finished - started)

  if not ok then error(results[2]) end

  return unpack(results, 2, results.n)
end

function M.reset() stats = {} end

function M.snapshot() return vim.deepcopy(stats) end

function M.summary_lines()
  local items = {}
  for name, current in pairs(stats) do
    items[#items + 1] = {
      name = name,
      count = current.count,
      total_ns = current.total_ns,
      max_ns = current.max_ns,
      avg_ns = current.count > 0 and math.floor(current.total_ns / current.count) or 0,
    }
  end

  table.sort(items, function(a, b)
    if a.total_ns == b.total_ns then return a.name < b.name end
    return a.total_ns > b.total_ns
  end)

  local lines = {}
  for _, item in ipairs(items) do
    lines[#lines + 1] = string.format(
      '%s count=%d total=%.3fms avg=%.3fms max=%.3fms',
      item.name,
      item.count,
      item.total_ns / 1000000,
      item.avg_ns / 1000000,
      item.max_ns / 1000000
    )
  end

  return lines
end

return M
