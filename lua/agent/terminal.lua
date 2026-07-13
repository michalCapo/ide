local config = require("agent.config")

local M = {}

local function refresh_status(agent)
  if agent then
    agent.updated_at = os.time()
  end
  vim.schedule(function()
    local ok, ui = pcall(require, "agent.ui")
    if ok then
      ui.refresh_status()
    end
  end)
end

local function notify(msg, level)
  vim.schedule(function()
    vim.notify(msg, level or vim.log.levels.INFO, { title = "Agent" })
  end)
end

local function ensure_term_buf(agent)
  if agent.term_buf and vim.api.nvim_buf_is_valid(agent.term_buf) then
    return agent.term_buf
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  agent.term_buf = buf
  agent.output_buf = buf
  return buf
end

local function is_alive(agent)
  return agent.job_id and vim.fn.jobwait({ agent.job_id }, 0)[1] == -1
end

local function parser_kind(agent)
  local spec = config.get(agent.agent_name)
  return spec and spec.status_parser or nil
end

local function is_generic(agent)
  return parser_kind(agent) == "generic"
end

local function now_ms()
  return vim.uv.now()
end

local function set_status(agent, status)
  if agent.status == "deleted" or agent.status == status then
    return
  end
  agent.status = status
  refresh_status(agent)
end

local function strip_ansi(text)
  text = tostring(text or "")
  text = text:gsub("\27%[[0-?]*[ -/]*[@-~]", "")
  text = text:gsub("\r", "")
  return text
end

local function terminal_tail_lines(agent)
  if not agent.term_buf or not vim.api.nvim_buf_is_valid(agent.term_buf) then
    return {}
  end
  local count = vim.api.nvim_buf_line_count(agent.term_buf)
  local start = math.max(count - 40, 0)
  return vim.tbl_map(strip_ansi, vim.api.nvim_buf_get_lines(agent.term_buf, start, count, false))
end

local function tail_signature(lines)
  return table.concat(lines or {}, "\n")
end

local function note_generic_output(agent, lines)
  if not is_generic(agent) or not agent.generic_submitted_at then
    return
  end

  local signature = tail_signature(lines or terminal_tail_lines(agent))
  if signature ~= agent.generic_tail_signature then
    agent.generic_tail_signature = signature
    agent.generic_last_output_at = now_ms()
  end
end

local function generic_idle_status(agent)
  if not is_generic(agent) or agent.status ~= "running" or not agent.generic_submitted_at then
    return nil
  end

  local idle_ms = tonumber(agent.generic_idle_done_ms or config.options.generic_idle_done_ms or 8000)
  local last_output_at = agent.generic_last_output_at or agent.generic_submitted_at
  if now_ms() - last_output_at >= idle_ms then
    return "done"
  end

  return nil
end

local function generic_status_from_line(line)
  line = strip_ansi(line):lower()

  local running = line:match("esc%s+to%s+interrupt")
    or line:match("interrupt%s+to%s+cancel")
    or line:match("ctrl%+c%s+to%s+interrupt")
    or line:match("thinking")
    or line:match("working")
    or line:match("streaming")
    or line:match("generating")
    or line:match("processing")
    or line:match("running")
    or line:match("calling%s+tool")
    or line:match("executing")
    or line:match("%d+%.?%d*%s+tok/s")
    or line:match("tokens?[/ ]s")
  if running then
    return "running"
  end

  return nil
end

local function generic_status_from_lines(lines, agent)
  local signature = tail_signature(lines)
  if agent.status == "done" and agent.generic_tail_signature == signature then
    return nil
  end

  -- Generic TUIs like Codex/Claude/OpenCode print and redraw startup/status
  -- text that can look like activity. Do not leave `waiting` until we know a
  -- prompt was submitted through our terminal mapping or an initial prompt was
  -- provided by start().
  if not agent.generic_submitted_at then
    return nil
  end

  note_generic_output(agent, lines)

  local idle_status = generic_idle_status(agent)
  if idle_status then
    return idle_status
  end

  for i = #lines, 1, -1 do
    local status = generic_status_from_line(lines[i])
    if status then
      return status
    end
  end

  return nil
end

local function status_from_line(line)
  line = strip_ansi(line):lower()
  -- The Pi TUI keeps historical text in the terminal buffer. Only trust lines
  -- that look like the live footer/status area, not old assistant prose.
  local done_footer = line:match("^%s*done%s*[—%-]")
    or line:match("^%s*✓%s*done%s*[—%-]")
    or line:match("^%s*✓️%s*done%s*[—%-]")
    or line:match("^%s*✔%s*done%s*[—%-]")
    or line:match("^%s*✔️%s*done%s*[—%-]")
    or line:match("^%s*✅%s*done%s*[—%-]")
  if done_footer then
    return "done"
  end

  -- Follow-up prompts can leave the previous turn's `done — ...` footer in
  -- scrollback while the current live footer only says `Working...`, shows a
  -- percent/context line, or displays live throughput. Treat those as running
  -- so stale done lines from the previous turn do not win the bottom-up scan.
  local working_footer = line:match("^%s*working%.%.%.") or line:match("^%s*%S+%s+working%.%.%.")
  local waiting_footer = line:match("^%s*0%.0%%/%d+%a*") or line:match("^%s*0%%/%d+%a*")
  if waiting_footer then
    return "waiting"
  end

  local progress_footer = line:match("^%s*%d+%.%d+%%/%d+%a*") or line:match("^%s*%d+%%/%d+%a*")
  local throughput_footer = line:match("^%s*%d+%.%d+%s+tok/s") or line:match("^%s*%d+%s+tok/s")
  local streaming_footer = line:match("^%s*streaming") or line:match("^%s*%S+%s+streaming")
  local running_footer = streaming_footer or throughput_footer or working_footer or progress_footer

  if running_footer then
    return "running"
  end
  return nil
end

local function infer_status(agent)
  local spec = config.get(agent.agent_name)
  local lines = terminal_tail_lines(agent)
  if spec and type(spec.status_parser) == "function" then
    return spec.status_parser(lines, agent)
  end
  if spec and spec.status_parser == "generic" then
    return generic_status_from_lines(lines, agent)
  end
  if spec and spec.status_parser and spec.status_parser ~= "pi" then
    return nil
  end

  -- Scan bottom-up and use the most recent footer/status line. This fixes the
  -- previous false `running` state caused by older `streaming` lines remaining
  -- above a newer `done — ...` footer in the terminal scrollback.
  for i = #lines, 1, -1 do
    local status = status_from_line(lines[i])
    if status then
      return status
    end
  end
  return nil
end

local function poll_status(agent)
  if agent.status == "deleted" or not is_alive(agent) then
    return
  end
  local inferred = infer_status(agent)
  if inferred then
    set_status(agent, inferred)
  end
end

local function schedule_poll(agent, delay)
  if not agent or agent.poll_scheduled or agent.status == "deleted" then
    return
  end
  agent.poll_scheduled = true
  vim.defer_fn(function()
    agent.poll_scheduled = false
    poll_status(agent)
  end, delay or 120)
end

local function start_monitor(agent)
  if agent.monitor then
    agent.monitor:stop()
    agent.monitor:close()
  end

  if agent.term_buf and vim.api.nvim_buf_is_valid(agent.term_buf) and not agent.status_attached then
    agent.status_attached = true
    vim.api.nvim_buf_attach(agent.term_buf, false, {
      on_lines = vim.schedule_wrap(function()
        if is_generic(agent) and agent.generic_submitted_at then
          agent.generic_last_output_at = now_ms()
        end
        schedule_poll(agent)
      end),
      on_detach = function()
        agent.status_attached = false
      end,
    })
  end

  -- Fallback timer for terminal redraws that don't produce normal on_lines at
  -- the moment the footer changes.
  agent.monitor = vim.uv.new_timer()
  agent.monitor:start(300, 1000, vim.schedule_wrap(function()
    if agent.status == "deleted" then
      if agent.monitor then
        agent.monitor:stop()
        agent.monitor:close()
        agent.monitor = nil
      end
      return
    end

    if not is_alive(agent) then
      if agent.monitor then
        agent.monitor:stop()
        agent.monitor:close()
        agent.monitor = nil
      end
      return
    end

    poll_status(agent)
  end))
end

function M.start(agent, initial_prompt)
  local buf = ensure_term_buf(agent)
  local cmd, err, spec, name = config.build_command(agent, initial_prompt)
  if not cmd then
    agent.status = "error"
    notify(err, vim.log.levels.ERROR)
    refresh_status(agent)
    return false
  end
  if not config.executable_available(spec) then
    agent.status = "error"
    notify("Agent backend '" .. tostring(name) .. "' executable is not available", vim.log.levels.ERROR)
    refresh_status(agent)
    return false
  end

  agent.status = initial_prompt and initial_prompt ~= "" and "running" or "waiting"
  agent.kind = "terminal"
  if is_generic(agent) and initial_prompt and initial_prompt ~= "" then
    agent.generic_submitted_at = now_ms()
    agent.generic_last_output_at = agent.generic_submitted_at
  end
  refresh_status(agent)

  vim.api.nvim_buf_call(buf, function()
    agent.job_id = vim.fn.termopen(cmd, {
      cwd = agent.cwd or vim.fn.getcwd(),
      on_exit = function(_, code, _)
        agent.exit_code = code
        if agent.status ~= "deleted" then
          agent.status = code == 0 and "done" or "error"
        end
        refresh_status(agent)
        -- A chat whose process ended cannot be used anymore: close and remove
        -- it immediately.
        vim.schedule(function()
          if agent.status ~= "deleted" then
            require("agent.manager").delete(agent)
          end
        end)
      end,
    })
  end)

  if not agent.job_id or agent.job_id <= 0 then
    agent.status = "error"
    notify("Failed to start " .. config.label(agent.agent_name) .. " agent", vim.log.levels.ERROR)
    refresh_status(agent)
    return false
  end

  start_monitor(agent)
  return true
end

function M.paste_prompt(agent, prompt)
  if not agent or not agent.job_id or not prompt or prompt == "" then
    return false
  end
  if not is_alive(agent) then
    return false
  end

  if agent.agent_name == "codex" then
    -- A freshly spawned Codex process clears input received before its composer
    -- is mounted. Pi preserves that early input, which made this race specific
    -- to <leader>ya on Codex chats. Wait until the composer prompt is visible,
    -- then deliver the reference as a terminal paste event.
    local attempts = 0
    local function paste_when_ready()
      if not is_alive(agent) then
        return
      end

      local lines = terminal_tail_lines(agent)
      local ready = false
      for i = #lines, 1, -1 do
        if lines[i]:match("^%s*›") then
          ready = true
          break
        end
      end

      attempts = attempts + 1
      if ready or attempts >= 100 then
        vim.fn.chansend(agent.job_id, "\027[200~" .. prompt .. "\027[201~")
      else
        vim.defer_fn(paste_when_ready, 50)
      end
    end

    paste_when_ready()
    return true
  end

  vim.fn.chansend(agent.job_id, prompt)
  return true
end

function M.mark_submitted(agent)
  if not agent or not is_generic(agent) or not is_alive(agent) then
    return
  end

  agent.generic_submitted_at = now_ms()
  agent.generic_last_output_at = agent.generic_submitted_at
  agent.generic_tail_signature = tail_signature(terminal_tail_lines(agent))
  set_status(agent, "running")
end

function M.kill(agent)
  if is_alive(agent) then
    pcall(vim.fn.jobstop, agent.job_id)
  end
  if agent.monitor then
    agent.monitor:stop()
    agent.monitor:close()
    agent.monitor = nil
  end
  if agent.status ~= "deleted" then
    set_status(agent, "done")
  else
    refresh_status(agent)
  end
end

return M
