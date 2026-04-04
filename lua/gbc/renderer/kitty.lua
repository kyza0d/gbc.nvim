local api = vim.api
local base64 = vim.base64
local bit = require('bit')
local fn = vim.fn
local profile = require('gbc.profile')
local uv = vim.uv or vim.loop

local protocol = require('gbc.protocol')

local M = {
  type = 'kitty',
}

local Kitty = {}
local DETECT_TIMEOUT_MS = 350

local tty_write = api.nvim_ui_send or function(data)
  io.stderr:write(data)
  io.stderr:flush()
end

local diacritics = {
  '\204\133',
  '\204\141',
  '\204\142',
  '\204\144',
  '\204\146',
  '\204\189',
  '\204\190',
  '\204\191',
  '\205\134',
  '\205\138',
  '\205\139',
  '\205\140',
  '\205\144',
  '\205\145',
  '\205\146',
  '\205\151',
  '\205\155',
  '\205\163',
  '\205\164',
  '\205\165',
  '\205\166',
  '\205\167',
  '\205\168',
  '\205\169',
  '\205\170',
  '\205\171',
  '\205\172',
  '\205\173',
  '\205\174',
  '\205\175',
  '\210\131',
  '\210\132',
  '\210\133',
  '\210\134',
  '\210\135',
  '\214\146',
  '\214\147',
  '\214\148',
  '\214\149',
  '\214\151',
  '\214\152',
  '\214\153',
  '\214\156',
  '\214\157',
  '\214\158',
  '\214\159',
  '\214\160',
  '\214\161',
  '\214\168',
  '\214\169',
  '\214\171',
  '\214\172',
  '\214\175',
  '\215\132',
  '\216\144',
  '\216\145',
  '\216\146',
  '\216\147',
  '\216\148',
  '\216\149',
  '\216\150',
  '\216\151',
  '\217\151',
  '\217\152',
  '\217\153',
  '\217\154',
  '\217\155',
  '\217\157',
  '\217\158',
  '\219\150',
  '\219\151',
  '\219\152',
  '\219\153',
  '\219\154',
  '\219\155',
  '\219\156',
  '\219\159',
  '\219\160',
  '\219\161',
  '\219\162',
  '\219\164',
  '\219\167',
  '\219\168',
  '\219\171',
  '\219\172',
  '\220\176',
  '\220\178',
  '\220\179',
  '\220\181',
  '\220\182',
  '\220\186',
  '\220\189',
  '\220\191',
  '\221\128',
  '\221\129',
  '\221\131',
  '\221\133',
  '\221\135',
  '\221\137',
  '\221\138',
  '\223\171',
  '\223\172',
  '\223\173',
  '\223\174',
  '\223\175',
  '\223\176',
  '\223\177',
  '\223\179',
  '\224\160\150',
  '\224\160\151',
  '\224\160\152',
  '\224\160\153',
  '\224\160\155',
  '\224\160\156',
  '\224\160\157',
  '\224\160\158',
  '\224\160\159',
  '\224\160\160',
  '\224\160\161',
  '\224\160\162',
  '\224\160\163',
  '\224\160\165',
  '\224\160\166',
  '\224\160\167',
  '\224\160\169',
  '\224\160\170',
  '\224\160\171',
  '\224\160\172',
  '\224\160\173',
  '\224\165\145',
  '\224\165\147',
  '\224\165\148',
  '\224\190\130',
  '\224\190\131',
  '\224\190\134',
  '\224\190\135',
  '\225\141\157',
  '\225\141\158',
  '\225\141\159',
  '\225\159\157',
  '\225\164\186',
  '\225\168\151',
  '\225\169\181',
  '\225\169\182',
  '\225\169\183',
  '\225\169\184',
  '\225\169\185',
  '\225\169\186',
  '\225\169\187',
  '\225\169\188',
  '\225\173\171',
  '\225\173\173',
  '\225\173\174',
  '\225\173\175',
  '\225\173\176',
  '\225\173\177',
  '\225\173\178',
  '\225\173\179',
  '\225\179\144',
  '\225\179\145',
  '\225\179\146',
  '\225\179\154',
  '\225\179\155',
  '\225\179\160',
  '\225\183\128',
  '\225\183\129',
  '\225\183\131',
  '\225\183\132',
  '\225\183\133',
  '\225\183\134',
  '\225\183\135',
  '\225\183\136',
  '\225\183\137',
  '\225\183\139',
  '\225\183\140',
  '\225\183\145',
  '\225\183\146',
  '\225\183\147',
  '\225\183\148',
  '\225\183\149',
  '\225\183\150',
  '\225\183\151',
  '\225\183\152',
  '\225\183\153',
  '\225\183\154',
  '\225\183\155',
  '\225\183\156',
  '\225\183\157',
  '\225\183\158',
  '\225\183\159',
  '\225\183\160',
  '\225\183\161',
  '\225\183\162',
  '\225\183\163',
  '\225\183\164',
  '\225\183\165',
  '\225\183\166',
  '\225\183\190',
  '\226\131\144',
  '\226\131\145',
  '\226\131\148',
  '\226\131\149',
  '\226\131\150',
  '\226\131\151',
  '\226\131\155',
  '\226\131\156',
  '\226\131\161',
  '\226\131\167',
  '\226\131\169',
  '\226\131\176',
  '\226\179\175',
  '\226\179\176',
  '\226\179\177',
  '\226\183\160',
  '\226\183\161',
  '\226\183\162',
  '\226\183\163',
  '\226\183\164',
  '\226\183\165',
  '\226\183\166',
  '\226\183\167',
  '\226\183\168',
  '\226\183\169',
  '\226\183\170',
  '\226\183\171',
  '\226\183\172',
  '\226\183\173',
  '\226\183\174',
  '\226\183\175',
  '\226\183\176',
  '\226\183\177',
  '\226\183\178',
  '\226\183\179',
  '\226\183\180',
  '\226\183\181',
  '\226\183\182',
  '\226\183\183',
  '\226\183\184',
  '\226\183\185',
  '\226\183\186',
  '\226\183\187',
  '\226\183\188',
  '\226\183\189',
  '\226\183\190',
  '\226\183\191',
  '\234\153\175',
  '\234\153\188',
  '\234\153\189',
  '\234\155\176',
  '\234\155\177',
  '\234\163\160',
  '\234\163\161',
  '\234\163\162',
  '\234\163\163',
  '\234\163\164',
  '\234\163\165',
  '\234\163\166',
  '\234\163\167',
  '\234\163\168',
  '\234\163\169',
  '\234\163\170',
  '\234\163\171',
  '\234\163\172',
  '\234\163\173',
  '\234\163\174',
  '\234\163\175',
  '\234\163\176',
  '\234\163\177',
  '\234\170\176',
  '\234\170\178',
  '\234\170\179',
  '\234\170\183',
  '\234\170\184',
  '\234\170\190',
  '\234\170\191',
  '\234\171\129',
  '\239\184\160',
  '\239\184\161',
  '\239\184\162',
  '\239\184\163',
  '\239\184\164',
  '\239\184\165',
  '\239\184\166',
  '\240\144\168\143',
  '\240\144\168\184',
  '\240\157\134\133',
  '\240\157\134\134',
  '\240\157\134\135',
  '\240\157\134\136',
  '\240\157\134\137',
  '\240\157\134\170',
  '\240\157\134\171',
  '\240\157\134\172',
  '\240\157\134\173',
  '\240\157\137\130',
  '\240\157\137\131',
  '\240\157\137\132',
}

local function describe_frame(frame)
  return string.format(
    'Frame %d  %dx%d  %s',
    frame.frame_id or 0,
    frame.width,
    frame.height,
    protocol.pixel_format_name(frame.pixel_format)
  )
end

local function setup_term_buf(kitty)
  profile.time('kitty.setup_term_buf', function()
    local chunks = {
      '\27[m\27[2J\27[3J\27[H',
      '\27[38;5;',
      tostring(kitty.image_id_lsb),
      'm',
    }

    local id_msb_diacritic = assert(diacritics[kitty.image_id_msb + 1])
    for y = 1, kitty.screen.term_height do
      local row_diacritic = diacritics[y]
      if not row_diacritic then break end

      for x = 1, kitty.screen.term_width do
        local col_diacritic = diacritics[x]
        if not col_diacritic then break end

        chunks[#chunks + 1] = '\244\142\187\174'
        chunks[#chunks + 1] = row_diacritic
        chunks[#chunks + 1] = col_diacritic
        chunks[#chunks + 1] = id_msb_diacritic
      end

      if y < kitty.screen.term_height then chunks[#chunks + 1] = '\r\n' end
    end

    kitty.screen:send_term(table.concat(chunks))
  end)
end

function M.new(opts)
  local kitty = setmetatable({
    screen = assert(opts.screen, 'kitty renderer requires a screen'),
    shm_name = assert(opts.shm_name, 'kitty renderer requires a shm_name'),
    shm_name_base64 = base64.encode(opts.shm_name),
    terminal_facts = opts.terminal_facts or {},
    on_status = opts.on_status,
    on_failure = opts.on_failure,
    image_id = 0,
    image_id_lsb = 0,
    image_id_msb = 0,
    has_image = false,
    presented_once = false,
    presentation_failed = false,
    support_state = opts.detect_support and 'probing' or 'supported',
    detect_support = opts.detect_support and true or false,
    detect_timeout_ms = math.max(50, tonumber(opts.detect_timeout_ms) or DETECT_TIMEOUT_MS),
    detect_started = false,
    detect_complete = not (opts.detect_support and true or false),
    detect_timer = nil,
    last_frame = nil,
    last_failure = nil,
    last_term_width = nil,
    last_term_height = nil,
    failure_reported = false,
    last_status_message = nil,
  }, { __index = Kitty })

  while true do
    kitty.image_id = fn.rand()
    if bit.band(kitty.image_id, 0xff) >= 16 then break end
  end

  kitty.image_id = bit.band(kitty.image_id, bit.bnot(0xffff00))
  kitty.image_id_lsb = bit.band(kitty.image_id, 0xff)
  kitty.image_id_msb = bit.rshift(kitty.image_id, 24)
  kitty.image_id = kitty.image_id % 0x100000000
  return kitty
end

function Kitty:_emit_status(message, level)
  if not message or message == self.last_status_message then return end

  self.last_status_message = message
  if self.on_status then self.on_status(message, level or vim.log.levels.INFO, self.support_state) end
end

function Kitty:_fail(message, opts)
  opts = opts or {}
  if self.detect_timer then
    self.detect_timer:stop()
    self.detect_timer:close()
    self.detect_timer = nil
  end
  self.presentation_failed = true
  self.support_state = 'failed'
  self.last_failure = message
  self:_emit_status(message, opts.level or vim.log.levels.WARN)

  if opts.fallback == false or self.failure_reported or not self.on_failure then return end

  self.failure_reported = true
  self.on_failure(message, opts)
end

function Kitty:close()
  if self.detect_timer then
    self.detect_timer:stop()
    self.detect_timer:close()
    self.detect_timer = nil
  end

  if not self.has_image then return end

  vim.schedule(
    function() tty_write(self.screen:passthrough_escape(('\27_Gq=2,a=d,d=I,i=%u,p=%u\27\\'):format(self.image_id, self.image_id))) end
  )
  self.has_image = false
end

function Kitty:should_auto_stop() return false end

function Kitty:_validate_term_grid(screen)
  local max = #diacritics
  if screen.term_width > max or screen.term_height > max then
    return nil,
      string.format('kitty placeholder grid %dx%d exceeds supported limit %d', screen.term_width, screen.term_height, max)
  end

  return true
end

function Kitty:_start_detection(frame)
  if self.detect_started or self.detect_complete then return false end

  self.detect_started = true
  self.support_state = 'probing'
  self:_emit_status('detecting kitty graphics support...', vim.log.levels.INFO)
  self:_emit_status(
    string.format(
      'kitty probe query sent: image_id=%u size=%dx%d shm=%s',
      self.image_id,
      frame.width,
      frame.height,
      self.shm_name
    ),
    vim.log.levels.INFO
  )

  local query = self.screen:passthrough_escape(
    ('\27_Ga=q,t=s,f=24,i=%u,s=%u,v=%u;%s\27\\\27[c'):format(self.image_id, frame.width, frame.height, self.shm_name_base64)
  )
  tty_write(query)

  local timer = assert(uv.new_timer())
  self.detect_timer = timer
  timer:start(
    self.detect_timeout_ms,
    0,
    vim.schedule_wrap(function()
      if self.detect_timer ~= timer then return end

      timer:stop()
      timer:close()
      self.detect_timer = nil
      if self.presentation_failed or self.detect_complete then return end

      self:_fail('kitty detection timed out; terminal may not support kitty graphics or tmux passthrough is disabled')
    end)
  )
  return true
end

function Kitty:handle_term_response(sequence, source)
  if not self.detect_support or self.detect_complete or not self.detect_started or not sequence or sequence == '' then return false end

  local status = sequence:match(('^\27_Gi=%d;(.+)$'):format(self.image_id))
  if not status and sequence:find('^\27%[%?64;', 1, false) then status = 'Unsupported by terminal' end
  if not status then return false end

  self:_emit_status(
    'kitty probe response received'
      .. (source and source ~= '' and (' via ' .. source) or '')
      .. ': '
      .. status,
    vim.log.levels.INFO
  )

  if self.detect_timer then
    self.detect_timer:stop()
    self.detect_timer:close()
    self.detect_timer = nil
  end

  if status ~= 'OK' then
    self:_fail('kitty detection failed: ' .. status)
    return true
  end

  self.detect_complete = true
  self.support_state = 'supported'
  self:_emit_status('kitty graphics detected', vim.log.levels.INFO)
  return true
end

function Kitty:handle_resize(reason)
  if self.presentation_failed or not self.last_frame then return end

  local ok, err = pcall(self.refresh, self, 'resize:' .. tostring(reason))
  if not ok then self:_fail('kitty resize refresh failed: ' .. err, {
    level = vim.log.levels.ERROR,
  }) end
end

function Kitty:refresh(reason, opts)
  return profile.time('kitty.refresh', function()
    opts = opts or {}
    if self.presentation_failed or not self.last_frame then return false end

    local frame = self.last_frame
    local screen = self.screen
    local is_steady_state = self.presented_once

    if self.detect_support and not self.detect_complete then
      self:_start_detection(frame)
      return false
    end

    -- On the first frame we need full validation; on steady-state frames
    -- we skip the expensive UI capability check and terminal size probe.
    if not is_steady_state then
      screen:refresh_ui_capabilities()
      if not screen:has_tty_ui() then error('no TTY UI is attached') end
    end

    screen:set_geometry(frame.width, frame.height)

    -- Only probe terminal size on first frame or explicit resize.
    local resized = false
    if not is_steady_state or reason:find('resize', 1, true) then resized = screen:update_term_size({ use_fallback = true }) end

    if not is_steady_state then
      local ok, err = self:_validate_term_grid(screen)
      if not ok then error(err) end
    end

    if
      not self.has_image
      or resized
      or screen.term_width ~= self.last_term_width
      or screen.term_height ~= self.last_term_height
    then
      setup_term_buf(self)
    end

    self.last_term_width = screen.term_width
    self.last_term_height = screen.term_height

    -- Build and cache the kitty command when dimensions haven't changed.
    if
      not self._cached_kitty_cmd
      or screen.term_width ~= self._cached_term_width
      or screen.term_height ~= self._cached_term_height
    then
      self._cached_kitty_cmd = screen:passthrough_escape(
        ('\27_Gq=2,a=T,U=1,z=-1,p=%u,c=%u,r=%u,' .. 't=s,f=24,i=%u,s=%u,v=%u;%s\27\\'):format(
          self.image_id,
          screen.term_width,
          screen.term_height,
          self.image_id,
          frame.width,
          frame.height,
          self.shm_name_base64
        )
      )
      self._cached_term_width = screen.term_width
      self._cached_term_height = screen.term_height
    end

    tty_write(self._cached_kitty_cmd)
    self.has_image = true

    if not is_steady_state then self:_emit_status('kitty image presented (' .. tostring(reason) .. ')', vim.log.levels.INFO) end

    return true
  end)
end

function Kitty:render(frame)
  if frame.pixel_format ~= protocol.pixel_format.RGB24_SHM then
    return {
      string.format(
        '(kitty expected %s, got %s)',
        protocol.pixel_format_name(protocol.pixel_format.RGB24_SHM),
        protocol.pixel_format_name(frame.pixel_format)
      ),
    }
  end

  self.last_frame = frame

  if self.presentation_failed then
    return {
      describe_frame(frame),
      '(' .. (self.last_failure or 'kitty renderer failed') .. ')',
    }
  end

  -- First-frame: full validation through has_tty_ui (needs mutate-safe context).
  -- Steady-state: skip the check — if TTY was available on first frame it still is.
  if not self.presented_once and not self.screen:has_tty_ui() then
    self:_fail('kitty renderer cannot present because no live TTY UI is attached', {
      presentation = true,
    })
    return {
      describe_frame(frame),
      '(kitty unavailable: no live TTY UI attached)',
    }
  end

  local reason = self.presented_once and 'frame' or 'first-frame'
  local ok, err = pcall(self.refresh, self, reason)
  if not ok then
    self:_fail('kitty presentation failed: ' .. err, {
      level = vim.log.levels.ERROR,
    })
    return {
      describe_frame(frame),
      '(kitty presentation failed; falling back to cell)',
    }
  end

  if self.detect_support and not self.detect_complete then
    return {
      describe_frame(frame),
      '(detecting kitty graphics support...)',
    }
  end

  self.presented_once = true
  self.support_state = 'supported'
  return {
    describe_frame(frame),
    '(kitty graphics active)',
  }
end

return M
