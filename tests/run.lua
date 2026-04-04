local failures = 0
local total = 0

local repo_root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.runtimepath:append(repo_root)

local function run_case(name, fn)
  total = total + 1
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    print('ok - ' .. name)
    return
  end

  failures = failures + 1
  print('not ok - ' .. name)
  print(err)
end

local tests = require('tests.test_kitty_regressions')
for _, case in ipairs(tests) do
  run_case(case.name, case.run)
end

tests = require('tests.test_kitty_support')
for _, case in ipairs(tests) do
  run_case(case.name, case.run)
end

tests = require('tests.test_frameloop')
for _, case in ipairs(tests) do
  run_case(case.name, case.run)
end

tests = require('tests.test_ui')
for _, case in ipairs(tests) do
  run_case(case.name, case.run)
end

tests = require('tests.test_transport')
for _, case in ipairs(tests) do
  run_case(case.name, case.run)
end

print(string.format('%d test(s), %d failure(s)', total, failures))
if failures > 0 then vim.cmd('cquit ' .. failures) end
