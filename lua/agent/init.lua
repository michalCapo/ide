local M = {}

local function current_context()
  local file = vim.api.nvim_buf_get_name(0)
  if file == "" then
    file = vim.fn.getcwd()
  end
  local ok, cursor = pcall(vim.api.nvim_win_get_cursor, 0)
  local line = ok and cursor[1] or 1
  return { file = file, line = line }
end

local function file_ref(context)
  local file = context.file ~= "" and context.file or vim.fn.getcwd()
  return vim.fn.fnamemodify(file, ":~:.") .. ":" .. tostring(context.line or 1)
end

local function command_alias(alias, command)
  vim.cmd(
    ("cnoreabbrev <expr> %s getcmdtype() ==# ':' && getcmdline() ==# %s ? %s : %s"):format(
      alias,
      vim.fn.string(alias),
      vim.fn.string(command),
      vim.fn.string(alias)
    )
  )
end

local function default_agent_command(name)
  return function()
    M.set_default(name)
  end
end

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "Agent" })
end

-- Run a prompt in a background chat: the chat joins the stack but no chat box
-- is shown, the user only gets a notification that the prompt was sent.
local function run_hidden_prompt(context, prompt, what)
  local agent = require("agent.manager").start(context, prompt)
  if agent and agent.status ~= "error" then
    local label = require("agent.config").label(agent.agent_name)
    notify(what .. " prompt sent to " .. label .. " (chat #" .. agent.id .. ")")
  end
  return agent
end

function M.toggle()
  require("agent.ui").toggle(current_context())
end

function M.new_chat()
  require("agent.ui").new_chat(current_context())
end

function M.paste_location()
  if vim.api.nvim_buf_get_name(0) == "" then
    notify("Current buffer has no file path", vim.log.levels.WARN)
    return
  end
  local context = current_context()
  require("agent.ui").paste_to_active(context, file_ref(context))
end

local function select_with_default(items, prompt, current, callback)
  local choices = { { value = nil, label = "Default" } }
  for _, value in ipairs(items or {}) do
    choices[#choices + 1] = { value = value, label = value }
  end
  vim.ui.select(choices, {
    prompt = prompt,
    format_item = function(item)
      return (item.value == current and "● " or "  ") .. item.label
    end,
  }, function(choice)
    if choice then
      callback(choice.value)
    end
  end)
end

local function select_model(items, current, callback)
  local choices = { { value = nil, label = "Default" } }
  local found_current = current == nil
  for _, value in ipairs(items or {}) do
    choices[#choices + 1] = { value = value, label = value }
    found_current = found_current or value == current
  end
  if current and not found_current then
    choices[#choices + 1] = { value = current, label = current }
  end
  choices[#choices + 1] = { custom = true, label = "Custom model…" }

  vim.ui.select(choices, {
    prompt = "Agent model",
    format_item = function(item)
      return (item.value == current and not item.custom and "● " or "  ") .. item.label
    end,
  }, function(choice)
    if not choice then return end
    if not choice.custom then
      callback(choice.value)
      return
    end
    vim.ui.input({ prompt = "Model ID: ", default = current or "" }, function(value)
      value = value and vim.trim(value) or nil
      if value and value ~= "" then
        callback(value)
      end
    end)
  end)
end

function M.select_preset()
  local config = require("agent.config")
  local harnesses = {}
  for _, name in ipairs({ "claude", "codex", "pi" }) do
    if config.options.agents[name] then
      harnesses[#harnesses + 1] = name
    end
  end

  vim.ui.select(harnesses, {
    prompt = "Agent harness",
    format_item = function(name)
      return (name == config.options.default_agent and "● " or "  ") .. config.label(name)
    end,
  }, function(harness)
    if not harness then return end
    local preset = config.options.preset or {}
    notify("Loading " .. config.label(harness) .. " models…")
    config.discover_models(harness, function(models, err)
      if err then
        notify(err .. "; use Custom model if needed", vim.log.levels.WARN)
      end
      select_model(models, preset.model, function(model)
        select_with_default(config.options.levels[harness], "Agent level", preset.level, function(level)
          config.set_preset(harness, model, level)
          local details = config.label(harness)
            .. " · " .. (model or "default model")
            .. " · " .. (level or "default level")
          notify("New chat preset: " .. details)
        end)
      end)
    end)
  end)
end

function M.hide_all()
  require("agent.ui").hide_all()
end

function M.implement_todo()
  local context = current_context()
  local prompt = ("Implement todo at %s. If todo is not at this path and line location implement all todos from this file."):format(file_ref(context))
  run_hidden_prompt(context, prompt, "Todo")
end

function M.fix_error()
  local context = current_context()
  local ref = file_ref(context)

  local messages = {}
  local ok, diagnostics = pcall(vim.diagnostic.get, 0, { lnum = (context.line or 1) - 1 })
  if ok then
    for _, diagnostic in ipairs(diagnostics) do
      local message = tostring(diagnostic.message or ""):gsub("%s+", " ")
      if message ~= "" then
        messages[#messages + 1] = message
      end
    end
  end

  local prompt
  if #messages > 0 then
    prompt = ("Use this error as description and implement the feature or fix this error at %s: %s. If the error is not found at the given position, fix all errors found in this file."):format(
      ref,
      table.concat(messages, "; ")
    )
  else
    prompt = ("Implement the feature or fix the error at %s. If no error is found at the given position, fix all errors found in this file."):format(ref)
  end

  run_hidden_prompt(context, prompt, "Error-fix")
end

function M.clear_done()
  require("agent.manager").clear_done()
end

function M.set_default(agent_name)
  local config = require("agent.config")
  local spec, name_or_err = config.set_default(agent_name)
  if not spec then
    notify(name_or_err, vim.log.levels.ERROR)
    return
  end
  notify("Default agent set to " .. config.label(name_or_err))
end

function M.setup(opts)
  local config = require("agent.config")
  config.setup(opts)

  local default_spec, default_name = config.get(config.options.default_agent)
  if default_spec and not config.executable_available(default_spec) then
    vim.schedule(function()
      notify("Agent default backend '" .. tostring(default_name) .. "' executable is not in PATH", vim.log.levels.WARN)
    end)
  end

  vim.api.nvim_create_user_command("Agent", function()
    M.new_chat()
  end, { desc = "Create a new agent chat" })

  vim.api.nvim_create_user_command("AgentToggle", function()
    M.toggle()
  end, { desc = "Toggle the agent chat stack" })

  vim.api.nvim_create_user_command("AgentTodo", function()
    M.implement_todo()
  end, { desc = "Send hidden prompt: implement todo at cursor" })

  vim.api.nvim_create_user_command("AgentError", function()
    M.fix_error()
  end, { desc = "Send hidden prompt: fix error at cursor" })

  vim.api.nvim_create_user_command("AgentDefault", function(cmd)
    if cmd.args == "" then
      notify("Default agent is " .. config.label(config.options.default_agent))
      return
    end
    M.set_default(cmd.args)
  end, {
    nargs = "?",
    complete = function()
      return config.names()
    end,
    desc = "Set the default backend for new Agent chats",
  })

  vim.api.nvim_create_user_command("AgentPreset", function()
    M.select_preset()
  end, { desc = "Choose harness, model, and level for new Agent chats" })

  vim.api.nvim_create_user_command("PyAgent", default_agent_command("pi"), {
    desc = "Preselect Pi backend for new Agent chats",
  })

  vim.api.nvim_create_user_command("ClaudeAgent", default_agent_command("claude"), {
    desc = "Preselect Claude backend for new Agent chats",
  })

  vim.api.nvim_create_user_command("CodexAgent", default_agent_command("codex"), {
    desc = "Preselect Codex backend for new Agent chats",
  })

  vim.api.nvim_create_user_command("AgentClear", function()
    M.clear_done()
  end, { desc = "Delete all done Agent chats" })

  command_alias("agent", "Agent")
  command_alias("agenttoggle", "AgentToggle")
  command_alias("agenttodo", "AgentTodo")
  command_alias("agenterror", "AgentError")
  command_alias("agentdefault", "AgentDefault")
  command_alias("agentpreset", "AgentPreset")
  command_alias("pyagent", "PyAgent")
  command_alias("claudeagent", "ClaudeAgent")
  command_alias("codexagent", "CodexAgent")
  command_alias("agentclear", "AgentClear")

  local group = vim.api.nvim_create_augroup("AgentStatus", { clear = true })
  vim.api.nvim_create_autocmd({ "VimResized", "TabEnter" }, {
    group = group,
    callback = function()
      require("agent.ui").refresh_status()
    end,
  })
end

return M
