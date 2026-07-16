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
local function preset_opts(preset)
  return {
    agent = preset.harness,
    model = preset.model,
    level = preset.reasoning,
    preset_name = preset.name,
  }
end

local function run_hidden_prompt(context, prompt, what, preset)
  local agent = require("agent.manager").start(context, prompt, preset_opts(preset))
  if agent and agent.status ~= "error" then
    local label = require("agent.config").label(agent.agent_name)
    notify(what .. " prompt sent to " .. label .. " (chat #" .. agent.id .. ")")
  end
  return agent
end

function M.toggle()
  local manager = require("agent.manager")
  if manager.has_chats() then
    require("agent.ui").toggle(current_context())
    return
  end
  M.choose_preset("New chat preset", function(preset)
    require("agent.ui").new_chat(current_context(), preset_opts(preset))
  end)
end

function M.new_chat()
  M.choose_preset("New chat preset", function(preset)
    require("agent.ui").new_chat(current_context(), preset_opts(preset))
  end)
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

local function harness_names(config)
  local harnesses = {}
  for _, name in ipairs({ "claude", "codex", "pi" }) do
    if config.options.agents[name] then
      harnesses[#harnesses + 1] = name
    end
  end
  return harnesses
end

local function preset_details(config, preset)
  return config.label(preset.harness)
    .. " · " .. (preset.model or "default model")
    .. " · " .. (preset.reasoning or "default reasoning")
end

local function preset_row(config, preset)
  local name = (preset.default and "● " or "  ") .. (preset.name or "")
  local details = preset_details(config, preset)
  local available = vim.api.nvim_win_get_width(0)
  local picker_width = math.min(math.max(58, math.floor(available * 0.58)), math.max(24, available - 8))
  local content_width = picker_width - 2
  local gap = math.max(2, content_width - vim.fn.strdisplaywidth(name) - vim.fn.strdisplaywidth(details))
  return name .. string.rep(" ", gap) .. details
end

local function sort_presets(config, items, get_preset)
  table.sort(items, function(left, right)
    local left_preset = get_preset(left)
    local right_preset = get_preset(right)
    local left_harness = config.label(left_preset.harness):lower()
    local right_harness = config.label(right_preset.harness):lower()
    if left_harness ~= right_harness then
      return left_harness < right_harness
    end
    local left_name = (left_preset.name or ""):lower()
    local right_name = (right_preset.name or ""):lower()
    if left_name == right_name then
      return (left_preset.name or "") < (right_preset.name or "")
    end
    return left_name < right_name
  end)
  return items
end

local function edit_preset(index, done)
  local config = require("agent.config")
  local existing = index and config.options.presets[index] or nil
  vim.ui.input({ prompt = "Preset name: ", default = existing and existing.name or "" }, function(name)
    name = name and vim.trim(name) or ""
    if name == "" then return end
    vim.ui.select(harness_names(config), {
      prompt = "Harness",
      format_item = function(harness)
        return ((existing and harness == existing.harness) and "● " or "  ") .. config.label(harness)
      end,
    }, function(harness)
      if not harness then return end
      notify("Loading " .. config.label(harness) .. " models…")
      config.discover_models(harness, function(models, err)
        if err then
          notify(err .. "; use Custom model if needed", vim.log.levels.WARN)
        end
        local current_model = existing and existing.harness == harness and existing.model or nil
        select_model(models, current_model, function(model)
          local current_reasoning = existing and existing.harness == harness and existing.reasoning or nil
          select_with_default(config.options.levels[harness], "Reasoning", current_reasoning, function(reasoning)
            local preset, save_err = config.save_preset({
              name = name,
              harness = harness,
              model = model,
              reasoning = reasoning,
            }, index)
            if not preset then
              notify(save_err, vim.log.levels.ERROR)
              return
            end
            notify((existing and "Updated " or "Saved ") .. preset.name .. ": " .. preset_details(config, preset))
            if done then done(preset) end
          end)
        end)
      end)
    end)
  end)
end

function M.choose_preset(prompt, callback)
  local config = require("agent.config")
  local presets = sort_presets(config, vim.deepcopy(config.options.presets or {}), function(preset)
    return preset
  end)
  if #presets == 0 then
    notify("Create your first agent preset")
    edit_preset(nil, callback)
    return
  end
  vim.ui.select(presets, {
    prompt = prompt or "Agent preset",
    format_item = function(preset)
      return preset_row(config, preset)
    end,
  }, function(preset)
    if preset then callback(vim.deepcopy(preset)) end
  end)
end

function M.manage_presets()
  local config = require("agent.config")
  local presets = config.options.presets or {}
  local choices = {}
  for index, preset in ipairs(presets) do
    choices[#choices + 1] = { index = index, preset = preset }
  end
  sort_presets(config, choices, function(item) return item.preset end)
  choices[#choices + 1] = { add = true }
  local function add_preset()
    edit_preset(nil)
  end
  vim.ui.select(choices, {
    prompt = "Agent presets",
    placeholder = #presets == 0 and "No saved presets" or "Search saved presets...",
    footer = "a add   Enter actions   ● default   / search   Esc close",
    extra_keymaps = function(buf, picker)
      vim.keymap.set("n", "a", function()
        picker.close()
        add_preset()
      end, { buffer = buf, nowait = true, silent = true, desc = "Add agent preset" })
    end,
    format_item = function(item)
      if item.add then return "+ Add preset" end
      return preset_row(config, item.preset)
    end,
  }, function(item)
    if not item then return end
    if item.add then
      add_preset()
      return
    end
    vim.ui.select({ "Set as default", "Edit", "Delete" }, { prompt = item.preset.name }, function(action)
      if action == "Set as default" then
        local preset, err = config.set_default_preset(item.index)
        if not preset then
          notify(err, vim.log.levels.ERROR)
          return
        end
        notify("Default preset set to " .. preset.name)
      elseif action == "Edit" then
        edit_preset(item.index)
      elseif action == "Delete" then
        vim.ui.select({ "Cancel", "Delete" }, { prompt = "Delete preset " .. item.preset.name .. "?" }, function(confirm)
          if confirm ~= "Delete" then return end
          local removed, err = config.delete_preset(item.index)
          if not removed then
            notify(err, vim.log.levels.ERROR)
            return
          end
          notify("Deleted preset " .. removed.name)
        end)
      end
    end)
  end)
end

-- Kept for :AgentPreset and existing configs.
M.select_preset = M.manage_presets

function M.hide_all()
  require("agent.ui").hide_all()
end

function M.implement_todo()
  local context = current_context()
  local prompt = ("Implement todo at %s. If todo is not at this path and line location implement all todos from this file."):format(file_ref(context))
  local preset = require("agent.config").default_preset()
  if not preset then
    notify("Set a default preset with <leader>as", vim.log.levels.WARN)
    return
  end
  run_hidden_prompt(context, prompt, "Todo", preset)
end

function M.implement_prompt()
  local preset = require("agent.config").default_preset()
  if not preset then
    notify("Set a default preset with <leader>as", vim.log.levels.WARN)
    return
  end

  local context = current_context()
  vim.ui.input({ prompt = "Implementation prompt: " }, function(input)
    input = input and vim.trim(input) or ""
    if input == "" then return end
    local prompt = ("Dont run code check, just provide code implementation at given location. %s Location: %s."):format(
      input,
      file_ref(context)
    )
    run_hidden_prompt(context, prompt, "Implementation", preset)
  end)
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

  local preset = require("agent.config").default_preset()
  if not preset then
    notify("Set a default preset with <leader>as", vim.log.levels.WARN)
    return
  end
  run_hidden_prompt(context, prompt, "Error-fix", preset)
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

  vim.api.nvim_create_user_command("AgentImplement", function()
    M.implement_prompt()
  end, { desc = "Send hidden implementation prompt at cursor" })

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
    M.manage_presets()
  end, { desc = "Manage saved Agent presets" })

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
  command_alias("agentimplement", "AgentImplement")
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
