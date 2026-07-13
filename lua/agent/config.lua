local M = {}

local function with_prompt(cmd, prompt)
  local out = vim.deepcopy(cmd)
  if prompt and prompt ~= "" then
    table.insert(out, prompt)
  end
  return out
end

M.defaults = {
  default_agent = "pi",
  preset = {
    model = nil,
    level = nil,
  },
  levels = {
    pi = { "off", "minimal", "low", "medium", "high", "xhigh", "max" },
    claude = { "low", "medium", "high", "xhigh", "max" },
    codex = { "minimal", "low", "medium", "high", "xhigh" },
  },
  models = {
    pi = {},
    claude = {},
    codex = {},
  },
  generic_idle_done_ms = 8000,
  agents = {
    pi = {
      executable = "pi",
      display_name = "Pi",
      status_parser = "pi",
      command = function(agent, prompt)
        local cmd = { "pi", "--name", agent.title or "nvim Agent" }
        if agent.model then
          vim.list_extend(cmd, { "--model", agent.model })
        end
        if agent.level then
          vim.list_extend(cmd, { "--thinking", agent.level })
        end
        if prompt and prompt ~= "" then
          table.insert(cmd, prompt)
        end
        return cmd
      end,
    },
    claude = {
      executable = "claude",
      display_name = "Claude",
      status_parser = "generic",
      command = function(agent, prompt)
        local cmd = { "claude" }
        if agent.model then
          vim.list_extend(cmd, { "--model", agent.model })
        end
        if agent.level then
          vim.list_extend(cmd, { "--effort", agent.level })
        end
        return with_prompt(cmd, prompt)
      end,
    },
    codex = {
      executable = "codex",
      display_name = "Codex",
      status_parser = "generic",
      command = function(agent, prompt)
        local cmd = { "codex" }
        if agent.model then
          vim.list_extend(cmd, { "--model", agent.model })
        end
        if agent.level then
          vim.list_extend(cmd, { "--config", 'model_reasoning_effort="' .. agent.level .. '"' })
        end
        return with_prompt(cmd, prompt)
      end,
    },
    opencode = {
      executable = "opencode",
      display_name = "OpenCode",
      status_parser = "generic",
      command = function(_, prompt)
        return with_prompt({ "opencode" }, prompt)
      end,
    },
  },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  opts = opts or {}
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  return M.options
end

function M.get(name)
  name = name or M.options.default_agent or "pi"
  return M.options.agents[name], name
end

function M.set_default(name)
  name = name or ""
  local spec = M.options.agents and M.options.agents[name]
  if not spec then
    return nil, "Unknown agent backend: " .. tostring(name)
  end
  M.options.default_agent = name
  return spec, name
end

function M.set_preset(name, model, level)
  local spec, err = M.set_default(name)
  if not spec then
    return nil, err
  end
  M.options.preset = { model = model, level = level }
  return M.options.preset
end

function M.names()
  local names = {}
  for name, _ in pairs(M.options.agents or {}) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

function M.label(name)
  local spec = M.get(name)
  return (spec and (spec.display_name or spec.name)) or name or "agent"
end

function M.executable_available(spec)
  if not spec or spec.executable == false then
    return true
  end
  local exe = spec.executable
  if not exe and type(spec.command) == "table" then
    exe = spec.command[1]
  elseif not exe and type(spec.command) == "string" then
    exe = spec.command:match("^%S+")
  end
  return exe and vim.fn.executable(exe) == 1
end

local model_cache = {}
local MODEL_CACHE_MS = 5 * 60 * 1000

local function unique_models(items)
  local seen, out = {}, {}
  for _, item in ipairs(items or {}) do
    item = vim.trim(tostring(item or ""))
    if item ~= "" and not seen[item] then
      seen[item] = true
      out[#out + 1] = item
    end
  end
  return out
end

local function finish_discovery(name, callback, models, err)
  models = unique_models(models)
  if #models > 0 then
    model_cache[name] = { at = vim.uv.now(), models = models }
  end
  vim.schedule(function()
    callback(models, err)
  end)
end

local function discover_pi(callback)
  vim.system({ "pi", "--list-models" }, { text = true }, function(result)
    local models = {}
    if result.code == 0 then
      for line in (result.stdout or ""):gmatch("[^\r\n]+") do
        local provider, model = line:match("^%s*(%S+)%s+(%S+)")
        if provider and model and provider ~= "provider" then
          models[#models + 1] = provider .. "/" .. model
        end
      end
    end
    local err = #models == 0 and "Pi model discovery failed" or nil
    finish_discovery("pi", callback, models, err)
  end)
end

local function discover_codex(callback)
  vim.system({ "codex", "debug", "models" }, { text = true }, function(result)
    local models = {}
    local levels = {}
    local ok, catalog = pcall(vim.json.decode, result.stdout or "")
    if ok then
      for _, model in ipairs(catalog.models or {}) do
        if model.slug and model.visibility ~= "hide" then
          models[#models + 1] = model.slug
          for _, level in ipairs(model.supported_reasoning_levels or {}) do
            if level.effort then levels[#levels + 1] = level.effort end
          end
        end
      end
    end
    if #levels > 0 then
      M.options.levels.codex = unique_models(levels)
    end
    local err = #models == 0 and "Codex model discovery failed" or nil
    finish_discovery("codex", callback, models, err)
  end)
end

-- Claude currently exposes its account-specific catalog only in the /model
-- picker. Run that picker in a hidden terminal and read its rendered rows.
local function discover_claude(callback)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local job
  vim.api.nvim_buf_call(buf, function()
    job = vim.fn.termopen({ "claude" }, { width = 120, height = 40 })
  end)
  if not job or job <= 0 then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    finish_discovery("claude", callback, {}, "Claude model discovery failed")
    return
  end

  local finished = false
  local function cleanup(models, err)
    if finished then return end
    finished = true
    pcall(vim.fn.jobstop, job)
    vim.defer_fn(function()
      if vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end, 50)
    finish_discovery("claude", callback, models, err)
  end

  vim.defer_fn(function()
    if finished then return end
    if vim.fn.jobwait({ job }, 0)[1] ~= -1 then
      cleanup({}, "Claude exited before model discovery")
      return
    end
    vim.fn.chansend(job, "/model")
    vim.defer_fn(function()
      if not finished and vim.fn.jobwait({ job }, 0)[1] == -1 then
        vim.fn.chansend(job, "\r")
      end
    end, 300)

    local attempts = 0
    local function poll()
      attempts = attempts + 1
      if not vim.api.nvim_buf_is_valid(buf) then
        cleanup({}, "Claude model discovery buffer closed")
        return
      end
      local models = {}
      for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
        local _, label = line:match("(%d+)%.%s+([%w][%w._%-]*)")
        if label and label:lower() ~= "default" then
          models[#models + 1] = label:lower()
        end
      end
      if #models > 0 then
        cleanup(models)
      elseif attempts < 20 then
        vim.defer_fn(poll, 200)
      else
        cleanup({}, "Claude /model picker did not return a catalog")
      end
    end
    vim.defer_fn(poll, 700)
  end, 1500)
end

function M.discover_models(name, callback)
  local cached = model_cache[name]
  if cached and vim.uv.now() - cached.at < MODEL_CACHE_MS then
    vim.schedule(function() callback(vim.deepcopy(cached.models)) end)
    return
  end
  if name == "pi" then
    discover_pi(callback)
  elseif name == "codex" then
    discover_codex(callback)
  elseif name == "claude" then
    discover_claude(callback)
  else
    vim.schedule(function() callback(vim.deepcopy(M.options.models[name] or {})) end)
  end
end

function M.build_command(agent, prompt)
  local spec, name = M.get(agent.agent_name)
  if not spec then
    return nil, "Unknown agent backend: " .. tostring(agent.agent_name)
  end

  local command = spec.command or spec.cmd
  if type(command) == "function" then
    return command(agent, prompt), nil, spec, name
  elseif type(command) == "table" then
    return spec.append_prompt == false and vim.deepcopy(command) or with_prompt(command, prompt), nil, spec, name
  elseif type(command) == "string" then
    local cmd = { command }
    if spec.append_prompt ~= false and prompt and prompt ~= "" then
      table.insert(cmd, prompt)
    end
    return cmd, nil, spec, name
  end

  return nil, "No command configured for agent backend: " .. tostring(name)
end

return M
