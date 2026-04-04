local kitty_support = require('gbc.kitty_support')

local M = {}

local function assert_equal(actual, expected, message)
  if actual == expected then return end

  error(string.format('%s: expected %s, got %s', message, vim.inspect(expected), vim.inspect(actual)))
end

local function assert_contains(haystack, needle, message)
  if haystack and haystack:find(needle, 1, true) then return end

  error(string.format('%s: missing %q in %s', message, needle, vim.inspect(haystack)))
end

local function with_stubs(stubs, run)
  local saved_api = {}
  local saved_fn = {}
  local saved_getenv = os.getenv

  if stubs.api then
    for name, value in pairs(stubs.api) do
      saved_api[name] = vim.api[name]
      vim.api[name] = value
    end
  end

  if stubs.fn then
    for name, value in pairs(stubs.fn) do
      saved_fn[name] = vim.fn[name]
      vim.fn[name] = value
    end
  end

  if stubs.getenv then os.getenv = stubs.getenv end

  local ok, result = xpcall(run, debug.traceback)

  os.getenv = saved_getenv
  for name, value in pairs(saved_api) do
    vim.api[name] = value
  end
  for name, value in pairs(saved_fn) do
    vim.fn[name] = value
  end

  if not ok then error(result) end

  return result
end

M[#M + 1] = {
  name = 'auto-select kitty inside tmux from tmux client termname',
  run = function()
    with_stubs({
      getenv = function(name)
        if name == 'TMUX' then return '/tmp/tmux-1000/default,1234,0' end
        if name == 'TERM' then return 'tmux-256color' end
        return nil
      end,
      api = {
        nvim_list_uis = function()
          return {
            { stdout_tty = true },
          }
        end,
      },
      fn = {
        has = function() return 0 end,
        executable = function(cmd)
          if cmd == 'tmux' then return 1 end
          return 0
        end,
        systemlist = function(cmd)
          if cmd[2] == 'display-message' then return { 'xterm-kitty' } end
          if cmd[2] == 'show-options' then return { 'on' } end
          return {}
        end,
      },
    }, function()
      local facts = kitty_support.inspect({
        tmux_passthrough = true,
      })

      assert_equal(facts.terminal_advertises_kitty, true, 'tmux client term should advertise kitty')
      assert_equal(kitty_support.should_auto_select(facts), true, 'auto renderer should select kitty')
      assert_contains(
        kitty_support.positive_summary(facts),
        'tmux client terminal advertises "kitty"',
        'positive summary should mention tmux client terminal support'
      )
    end)
  end,
}

M[#M + 1] = {
  name = 'reject kitty passthrough when tmux allow-passthrough is off',
  run = function()
    with_stubs({
      getenv = function(name)
        if name == 'TMUX' then return '/tmp/tmux-1000/default,1234,0' end
        if name == 'TERM' then return 'tmux-256color' end
        return nil
      end,
      api = {
        nvim_list_uis = function()
          return {
            { stdout_tty = true },
          }
        end,
      },
      fn = {
        has = function() return 0 end,
        executable = function(cmd)
          if cmd == 'tmux' then return 1 end
          return 0
        end,
        systemlist = function(cmd)
          if cmd[2] == 'display-message' then return { 'xterm-ghostty' } end
          if cmd[2] == 'show-options' then return { 'off' } end
          return {}
        end,
      },
    }, function()
      local facts = kitty_support.inspect({
        tmux_passthrough = true,
      })

      assert_equal(kitty_support.has_hard_reject(facts), true, 'hard reject expected when tmux passthrough is off')
      assert_contains(
        kitty_support.hard_reject_summary(facts),
        'tmux allow-passthrough is off',
        'hard reject summary should explain tmux passthrough setting'
      )
    end)
  end,
}

M[#M + 1] = {
  name = 'skip runtime probe inside tmux when passthrough is enabled and tmux advertises kitty',
  run = function()
    with_stubs({
      getenv = function(name)
        if name == 'TMUX' then return '/tmp/tmux-1000/default,1234,0' end
        if name == 'TERM' then return 'tmux-256color' end
        return nil
      end,
      api = {
        nvim_list_uis = function()
          return {
            { stdout_tty = true },
          }
        end,
      },
      fn = {
        has = function() return 0 end,
        executable = function(cmd)
          if cmd == 'tmux' then return 1 end
          return 0
        end,
        systemlist = function(cmd)
          if cmd[2] == 'display-message' then return { 'xterm-kitty' } end
          if cmd[2] == 'show-options' then return { 'on' } end
          return {}
        end,
      },
    }, function()
      local facts = kitty_support.inspect({
        tmux_passthrough = true,
      })
      local should_probe, reason = kitty_support.should_runtime_probe(facts, 'auto')

      assert_equal(should_probe, false, 'runtime probe should be skipped in the known-good tmux kitty path')
      assert_contains(reason, 'runtime probe skipped', 'skip reason should explain why the probe was disabled')
    end)
  end,
}

M[#M + 1] = {
  name = 'keep runtime probe in auto mode when terminal facts are inconclusive',
  run = function()
    with_stubs({
      getenv = function(name)
        if name == 'TERM' then return 'xterm-256color' end
        return nil
      end,
      api = {
        nvim_list_uis = function()
          return {
            { stdout_tty = true },
          }
        end,
      },
      fn = {
        has = function() return 0 end,
        executable = function() return 0 end,
      },
    }, function()
      local facts = kitty_support.inspect({
        tmux_passthrough = false,
      })
      local should_probe, reason = kitty_support.should_runtime_probe(facts, 'auto')

      assert_equal(should_probe, true, 'runtime probe should remain enabled when the terminal is not clearly kitty-capable')
      assert_contains(reason, 'inconclusive', 'probe reason should explain the inconclusive terminal advertisement')
    end)
  end,
}

return M
