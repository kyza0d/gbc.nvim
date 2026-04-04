local transport = require('gbc.transport')

local M = {}

local function assert_equal(actual, expected, message)
  if actual == expected then return end

  error(string.format('%s: expected %s, got %s', message, vim.inspect(expected), vim.inspect(actual)))
end

M[#M + 1] = {
  name = 'transport dispatch_message schedules protocol delivery onto the main loop',
  run = function()
    local queue = {}
    local saved_schedule = vim.schedule
    vim.schedule = function(callback) queue[#queue + 1] = callback end

    local received = {}
    local state = {
      closed = false,
      on_message = function(message) received[#received + 1] = message.name end,
    }

    local ok, err = xpcall(function()
      transport._test.dispatch_message(state, { name = 'AMSG_FRAME' })
      assert_equal(#received, 0, 'message delivery should be deferred')
      assert_equal(#queue, 1, 'message delivery should queue one callback')

      queue[1]()
      assert_equal(#received, 1, 'scheduled delivery should invoke on_message')
      assert_equal(received[1], 'AMSG_FRAME', 'scheduled delivery should preserve the decoded message')
    end, debug.traceback)

    vim.schedule = saved_schedule

    if not ok then error(err) end
  end,
}

M[#M + 1] = {
  name = 'transport dispatch_message skips queued delivery after close',
  run = function()
    local queue = {}
    local saved_schedule = vim.schedule
    vim.schedule = function(callback) queue[#queue + 1] = callback end

    local delivered = false
    local state = {
      closed = false,
      on_message = function() delivered = true end,
    }

    local ok, err = xpcall(function()
      transport._test.dispatch_message(state, { name = 'AMSG_FRAME' })
      state.closed = true
      queue[1]()
      assert_equal(delivered, false, 'closed transports should drop queued messages')
    end, debug.traceback)

    vim.schedule = saved_schedule

    if not ok then error(err) end
  end,
}

M[#M + 1] = {
  name = 'transport only logs protocol sends when explicitly requested',
  run = function()
    assert_equal(transport._test.should_log_send('CMSG_RUN_FRAME'), false, 'hot-path sends should not log by default')
    assert_equal(
      transport._test.should_log_send('CMSG_INIT', { log = true }),
      true,
      'important control messages should still be traceable'
    )
  end,
}

return M
