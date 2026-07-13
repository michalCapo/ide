local terminal = require("agent.terminal")
local config = require("agent.config")

local M = { agents = {}, seq = 0, last_created_agent = nil }

-- Keep the chat stack small: once there are more than MAX_CHATS chats, only
-- the most recent KEEP_CHATS survive (plus the one just created).
local MAX_CHATS = 4
local KEEP_CHATS = 3

local function notify(msg, level)
  vim.schedule(function()
    vim.notify(msg, level or vim.log.levels.INFO, { title = "Agent" })
  end)
end

local function refresh_ui()
  require("agent.ui").refresh_status()
end

local function short_title(prompt)
  local line = (prompt or ""):gsub("%s+", " "):sub(1, 60)
  if line == "" then
    line = "Agent"
  end
  return line
end

local function create_opts(opts, status)
  local out = {}
  for k, v in pairs(opts or {}) do
    out[k] = v
  end
  out.status = status
  return out
end

local function create(context, prompt, title, user_prompt, opts)
  context = context or {}
  opts = opts or {}
  M.seq = M.seq + 1
  local preset = config.options.preset or {}
  local agent = {
    id = tostring(M.seq),
    title = short_title(title or user_prompt or prompt),
    file = context.file,
    line = context.line,
    cwd = vim.fn.getcwd(),
    prompt = prompt,
    user_prompt = user_prompt or title or prompt,
    status = opts.status or "new",
    created_at = os.time(),
    updated_at = os.time(),
    kind = "terminal",
    agent_name = opts.agent or opts.agent_name or config.options.default_agent or "pi",
    model = opts.model ~= nil and opts.model or preset.model,
    level = opts.level ~= nil and opts.level or preset.level,
  }
  M.agents[#M.agents + 1] = agent
  M.last_created_agent = agent
  M.trim_old(agent)
  refresh_ui()
  return agent
end

function M.trim_old(keep_agent)
  local live = {}
  for _, agent in ipairs(M.agents) do
    if agent.status ~= "deleted" then
      live[#live + 1] = agent
    end
  end
  if #live <= MAX_CHATS then
    return
  end
  for i = 1, #live - KEEP_CHATS do
    if live[i] ~= keep_agent then
      M.delete(live[i])
    end
  end
end

function M.last_created()
  local agent = M.last_created_agent
  if agent and agent.status ~= "deleted" then
    return agent
  end

  for i = #M.agents, 1, -1 do
    if M.agents[i].status ~= "deleted" then
      M.last_created_agent = M.agents[i]
      return M.last_created_agent
    end
  end

  M.last_created_agent = nil
  return nil
end

function M.start(context, prompt, opts)
  opts = opts or {}
  local agent_name = opts.agent or opts.agent_name or config.options.default_agent or "pi"
  local agent = create(context, prompt or "", prompt or config.label(agent_name) .. " Agent", prompt or "", create_opts(opts, "starting"))
  terminal.start(agent, prompt)
  refresh_ui()
  return agent
end

function M.paste_prompt(agent, prompt)
  if not terminal.paste_prompt(agent, prompt) then
    notify("No running Agent terminal for prompt", vim.log.levels.WARN)
    return false
  end
  return true
end

function M.start_empty(context, opts)
  opts = opts or {}
  local agent = create(context, "", config.label(opts.agent or opts.agent_name) .. " Agent", "", create_opts(opts, "starting"))
  terminal.start(agent)
  refresh_ui()
  return agent
end

function M.mark_submitted(agent)
  terminal.mark_submitted(agent)
end

function M.delete(agent)
  agent.status = "deleted"
  agent.updated_at = os.time()
  if agent.output_win and vim.api.nvim_win_is_valid(agent.output_win) then
    pcall(vim.api.nvim_win_close, agent.output_win, true)
  end
  terminal.kill(agent)
  if M.last_created_agent == agent then
    M.last_created_agent = nil
  end
  for i, item in ipairs(M.agents) do
    if item == agent then
      table.remove(M.agents, i)
      break
    end
  end
  if agent.term_buf and vim.api.nvim_buf_is_valid(agent.term_buf) then
    vim.defer_fn(function()
      if agent.term_buf and vim.api.nvim_buf_is_valid(agent.term_buf) then
        pcall(vim.api.nvim_buf_delete, agent.term_buf, { force = true })
      end
    end, 100)
  end
  refresh_ui()
end

function M.clear_done()
  local cleared = 0
  for i = #M.agents, 1, -1 do
    local agent = M.agents[i]
    if agent.status == "done" then
      M.delete(agent)
      cleared = cleared + 1
    end
  end
  notify("Cleared " .. tostring(cleared) .. " done Agent task" .. (cleared == 1 and "" or "s"), vim.log.levels.INFO)
  refresh_ui()
  return cleared
end

return M
