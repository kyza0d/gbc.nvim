local api = vim.api
local fn = vim.fn

local M = {}

local function has_stdout_tty()
  for _, ui in ipairs(api.nvim_list_uis()) do
    if ui.stdout_tty then return true end
  end

  return false
end

local function env_flag(name)
  local value = os.getenv(name)
  return value ~= nil and value ~= '', value
end

local function contains(haystack, needle) return haystack:find(needle, 1, true) ~= nil end

local function join(parts) return table.concat(parts, '; ') end

local function tmux_display_message(format)
  if fn.executable('tmux') ~= 1 then return nil end

  local output = fn.systemlist({ 'tmux', 'display-message', '-p', format })
  if vim.v.shell_error ~= 0 or not output or output[1] == '' then return nil end

  return output[1]
end

local function tmux_show_option(name)
  if fn.executable('tmux') ~= 1 then return nil end

  local output = fn.systemlist({ 'tmux', 'show-options', '-gv', name })
  if vim.v.shell_error ~= 0 or not output or output[1] == '' then return nil end

  return output[1]
end

function M.inspect(opts)
  opts = opts or {}

  local term = (os.getenv('TERM') or ''):lower()
  local term_program = (os.getenv('TERM_PROGRAM') or ''):lower()
  local has_kitty_window_id = env_flag('KITTY_WINDOW_ID')
  local has_kitty_listen_on = env_flag('KITTY_LISTEN_ON')
  local has_ghostty_resources_dir = env_flag('GHOSTTY_RESOURCES_DIR')
  local has_tmux = env_flag('TMUX')
  local has_stdout = has_stdout_tty()
  local in_termux = fn.has('termux') == 1 or term_program == 'termux'
  local tmux_client_termname = has_tmux and tmux_display_message('#{client_termname}') or nil
  local tmux_allow_passthrough = has_tmux and tmux_show_option('allow-passthrough') or nil
  local tmux_client_termname_lower = (tmux_client_termname or ''):lower()
  local kitty_env = has_kitty_window_id or has_kitty_listen_on
  local ghostty_env = has_ghostty_resources_dir
  local term_looks_kitty = contains(term, 'kitty') or term_program == 'kitty'
  local term_looks_ghostty = contains(term, 'ghostty') or term_program == 'ghostty'
  local tmux_term_looks_kitty = contains(tmux_client_termname_lower, 'kitty')
  local tmux_term_looks_ghostty = contains(tmux_client_termname_lower, 'ghostty')
  local terminal_advertises_kitty = kitty_env
    or ghostty_env
    or term_looks_kitty
    or term_looks_ghostty
    or tmux_term_looks_kitty
    or tmux_term_looks_ghostty

  local hard_reject_reasons = {}
  local soft_reject_reasons = {}
  local positive_reasons = {}

  if has_stdout then
    positive_reasons[#positive_reasons + 1] = 'stdout_tty=true'
  else
    hard_reject_reasons[#hard_reject_reasons + 1] = 'no stdout TTY UI is attached'
  end

  if in_termux then hard_reject_reasons[#hard_reject_reasons + 1] = 'Termux is not treated as kitty-graphics capable' end

  if kitty_env then
    positive_reasons[#positive_reasons + 1] = 'kitty environment variables are present'
  elseif ghostty_env then
    positive_reasons[#positive_reasons + 1] = 'Ghostty environment variables are present'
  elseif term_looks_kitty then
    positive_reasons[#positive_reasons + 1] = 'TERM/TERM_PROGRAM advertises "kitty"'
  elseif term_looks_ghostty then
    positive_reasons[#positive_reasons + 1] = 'TERM/TERM_PROGRAM advertises "ghostty"'
  elseif tmux_term_looks_kitty then
    positive_reasons[#positive_reasons + 1] = 'tmux client terminal advertises "kitty"'
  elseif tmux_term_looks_ghostty then
    positive_reasons[#positive_reasons + 1] = 'tmux client terminal advertises "ghostty"'
  else
    soft_reject_reasons[#soft_reject_reasons + 1] = 'terminal environment does not advertise kitty or Ghostty'
  end

  if has_tmux then
    if opts.tmux_passthrough then
      positive_reasons[#positive_reasons + 1] = 'tmux detected and passthrough is enabled'
      if tmux_allow_passthrough == 'on' then
        positive_reasons[#positive_reasons + 1] = 'tmux allow-passthrough=on'
      elseif tmux_allow_passthrough == 'off' then
        hard_reject_reasons[#hard_reject_reasons + 1] = 'tmux allow-passthrough is off'
      end
    else
      hard_reject_reasons[#hard_reject_reasons + 1] = 'tmux detected but tmux_passthrough=false'
    end
  end

  return {
    has_stdout_tty = has_stdout,
    term = term,
    term_program = term_program,
    in_termux = in_termux,
    in_tmux = has_tmux,
    tmux_passthrough = opts.tmux_passthrough and true or false,
    tmux_client_termname = tmux_client_termname,
    tmux_allow_passthrough = tmux_allow_passthrough,
    kitty_env = kitty_env,
    ghostty_env = ghostty_env,
    terminal_advertises_kitty = terminal_advertises_kitty,
    positive_reasons = positive_reasons,
    hard_reject_reasons = hard_reject_reasons,
    soft_reject_reasons = soft_reject_reasons,
  }
end

function M.should_auto_select(facts) return #facts.hard_reject_reasons == 0 and facts.terminal_advertises_kitty end

function M.has_hard_reject(facts) return #facts.hard_reject_reasons > 0 end

function M.should_runtime_probe(facts, requested_renderer)
  if requested_renderer ~= 'auto' then
    return false, 'runtime probe skipped for explicit renderer selection'
  end

  if
    facts.in_tmux
    and facts.tmux_passthrough
    and facts.tmux_allow_passthrough == 'on'
    and facts.terminal_advertises_kitty
  then
    return false, 'runtime probe skipped; tmux passthrough is enabled and the tmux client terminal advertises kitty graphics'
  end

  if facts.terminal_advertises_kitty then
    return true, 'runtime probe enabled to confirm advertised kitty graphics support'
  end

  return true, 'runtime probe required because the terminal advertisement is inconclusive'
end

function M.hard_reject_summary(facts)
  if #facts.hard_reject_reasons == 0 then return nil end

  return join(facts.hard_reject_reasons)
end

function M.soft_reject_summary(facts)
  if #facts.soft_reject_reasons == 0 then return nil end

  return join(facts.soft_reject_reasons)
end

function M.positive_summary(facts)
  if #facts.positive_reasons == 0 then return nil end

  return join(facts.positive_reasons)
end

function M.describe_terminal(facts)
  return table.concat({
    'stdout_tty=' .. (facts.has_stdout_tty and 'true' or 'false'),
    'TERM=' .. (facts.term ~= '' and facts.term or '(empty)'),
    'TERM_PROGRAM=' .. (facts.term_program ~= '' and facts.term_program or '(empty)'),
    'tmux=' .. (facts.in_tmux and 'true' or 'false'),
    'tmux_client_termname=' .. (facts.tmux_client_termname and facts.tmux_client_termname ~= '' and facts.tmux_client_termname or '(unknown)'),
    'tmux_allow_passthrough='
      .. (facts.tmux_allow_passthrough and facts.tmux_allow_passthrough ~= '' and facts.tmux_allow_passthrough or '(unknown)'),
    'tmux_passthrough=' .. (facts.tmux_passthrough and 'true' or 'false'),
    'kitty_env=' .. (facts.kitty_env and 'true' or 'false'),
    'ghostty_env=' .. (facts.ghostty_env and 'true' or 'false'),
    'terminal_advertises_kitty=' .. (facts.terminal_advertises_kitty and 'true' or 'false'),
  }, ' ')
end

return M
