local manager = require("agent.manager")
local config = require("agent.config")

local M = {}

-- ---------------------------------------------------------------------------
-- Highlights and shared helpers
-- ---------------------------------------------------------------------------

local status_hl = {
  waiting = "AgentWaiting",
  running = "AgentRunning",
  starting = "AgentRunning",
  done = "AgentDone",
  error = "AgentError",
  aborted = "AgentAborted",
  exited = "Comment",
  new = "Comment",
}

local status_icon = {
  waiting = "◷",
  running = "●",
  starting = "◌",
  done = "✓",
  error = "✗",
  aborted = "!",
  exited = "○",
  new = "○",
}

local status_label = {
  waiting = "Waiting",
  running = "Running ....",
  starting = "Starting",
  done = "Done",
  error = "Error",
  aborted = "Aborted",
  exited = "Done",
  new = "New",
}

local function define_highlights()
  pcall(vim.api.nvim_set_hl, 0, "AgentWaiting", { link = "DiagnosticInfo" })
  pcall(vim.api.nvim_set_hl, 0, "AgentRunning", { link = "DiagnosticWarn" })
  pcall(vim.api.nvim_set_hl, 0, "AgentDone", { link = "DiagnosticOk" })
  pcall(vim.api.nvim_set_hl, 0, "AgentError", { link = "DiagnosticError" })
  pcall(vim.api.nvim_set_hl, 0, "AgentAborted", { link = "DiagnosticInfo" })
  pcall(vim.api.nvim_set_hl, 0, "AgentFocusedBorder", { link = "DiagnosticInfo" })
  pcall(vim.api.nvim_set_hl, 0, "AgentInactiveBorder", { link = "Comment" })
  pcall(vim.api.nvim_set_hl, 0, "AgentFocusedTitle", { link = "Title" })
  pcall(vim.api.nvim_set_hl, 0, "AgentInactiveTitle", { link = "Comment" })
  pcall(vim.api.nvim_set_hl, 0, "AgentFooter", { link = "Comment" })
end

local function location(agent, modifier)
  local file = vim.fn.fnamemodify(agent.file or "", modifier or ":~:.")
  if file == "" then
    file = "[no file]"
  end
  return file .. ":" .. tostring(agent.line or 1)
end

local function trim_display(text, max_width)
  text = tostring(text or "")
  if max_width <= 0 then
    return ""
  end
  if vim.fn.strdisplaywidth(text) <= max_width then
    return text
  end

  local out = ""
  for _, char in ipairs(vim.fn.split(text, "\\zs")) do
    if vim.fn.strdisplaywidth(out .. char .. "…") > max_width then
      return out .. "…"
    end
    out = out .. char
  end
  return out
end

local function agent_display_title(agent)
  local title = tostring(agent.title or "")
  if title == "" or title == "Agent" or title == config.label(agent.agent_name) .. " Agent" then
    return ""
  end
  return title
end

local function scroll_window_to_bottom(win, buf)
  if not vim.api.nvim_win_is_valid(win) or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local line_count = math.max(vim.api.nvim_buf_line_count(buf), 1)
  pcall(vim.api.nvim_win_set_cursor, win, { line_count, 0 })
end

local function live_chats()
  local chats = {}
  for _, agent in ipairs(manager.agents) do
    if agent.status ~= "deleted" then
      chats[#chats + 1] = agent
    end
  end
  return chats
end

local function chat_index(chats, id)
  for i, chat in ipairs(chats) do
    if chat.id == id then
      return i
    end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Corner status float (background chats only, hidden while the stack is open)
-- ---------------------------------------------------------------------------

local status_buf
local status_wins = {}
local status_ns = vim.api.nvim_create_namespace("agent_status")
local status_refresh_pending = false
local status_lines_key

-- Keep completed chats visible here too, so the corner popup is also a compact
-- overview of the whole retained chat stack.
local active_status = {
  new = true,
  starting = true,
  waiting = true,
  running = true,
  done = true,
}

local function status_win_for_tab(tab)
  local win = status_wins[tab]
  if not win or not vim.api.nvim_win_is_valid(win) then
    status_wins[tab] = nil
    return nil
  end

  local ok, win_tab = pcall(vim.api.nvim_win_get_tabpage, win)
  if not ok or win_tab ~= tab then
    status_wins[tab] = nil
    return nil
  end

  return win
end

local function close_status_win(win)
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
end

local function close_status_windows()
  for _, win in pairs(status_wins) do
    close_status_win(win)
  end
  status_wins = {}
  status_lines_key = nil

  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    local ok, wins = pcall(vim.api.nvim_tabpage_list_wins, tab)
    if ok then
      for _, win in ipairs(wins) do
        local ok_buf, buf = pcall(vim.api.nvim_win_get_buf, win)
        local is_current_status_buf = ok_buf and status_buf and vim.api.nvim_buf_is_valid(status_buf) and buf == status_buf
        local is_agent_status_buf = false
        if ok_buf then
          local ok_ft, filetype = pcall(function()
            return vim.bo[buf].filetype
          end)
          is_agent_status_buf = ok_ft and filetype == "agent-status"
        end
        if is_current_status_buf or is_agent_status_buf then
          close_status_win(win)
        end
      end
    end
  end
end

local function active_agents()
  local agents = {}
  for _, agent in ipairs(manager.agents) do
    if active_status[agent.status or ""] then
      agents[#agents + 1] = agent
    end
  end
  return agents
end

local function status_summary_line(agent, width)
  width = math.max(width or 0, 0)
  local icon = status_icon[agent.status] or "○"
  local prefix = string.format("%s #%s %-8s [%s] ", icon, agent.id, agent.status or "unknown", agent.agent_name or "pi")
  local prefix_width = vim.fn.strdisplaywidth(prefix)
  if prefix_width >= width then
    return trim_display(prefix, width)
  end
  return prefix .. trim_display(location(agent, ":t"), width - prefix_width)
end

-- ---------------------------------------------------------------------------
-- Chat stack UI
--
-- One centered column: done/previous chats collapse into small dashed boxes
-- above the current chat, next/running chats collapse below it. Ctrl-p /
-- Ctrl-n move the active chat up/down; Ctrl-n past the last chat creates a
-- new one. The active chat id is remembered so the stack always reopens at
-- the same position.
-- ---------------------------------------------------------------------------

local stack = {
  open = false,
  context = nil,
  current_id = nil,
  main_win = nil,
  mini_wins = {},
  mini_bufs = {},
}

local mini_border = { "╭", "╌", "╮", "┆", "╯", "╌", "╰", "┆" }

local nav, delete_current, focus_main, render

local function close_mini_wins()
  for _, win in ipairs(stack.mini_wins) do
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  stack.mini_wins = {}
  for _, buf in ipairs(stack.mini_bufs) do
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  stack.mini_bufs = {}
end

local function close_main_win()
  if stack.main_win and vim.api.nvim_win_is_valid(stack.main_win) then
    pcall(vim.api.nvim_win_close, stack.main_win, true)
  end
  stack.main_win = nil
end

function M.hide_all()
  if not stack.open then
    return
  end
  stack.open = false
  vim.cmd("stopinsert")
  close_mini_wins()
  close_main_win()
  M.refresh_status()
end

function M.stack_is_open()
  return stack.open
end

local function current_chat()
  local chats = live_chats()
  local idx = chat_index(chats, stack.current_id) or #chats
  return chats[idx], idx, chats
end

local function map_chat_buffer(buf, chat)
  if vim.b[buf].agent_stack_mapped then
    return
  end
  vim.b[buf].agent_stack_mapped = true

  vim.keymap.set("t", "<Esc>", function()
    if chat.job_id then
      vim.fn.chansend(chat.job_id, "\027")
    end
  end, { buffer = buf, nowait = true, silent = true, desc = "Send Esc to agent" })
  vim.keymap.set("t", "<C-p>", function()
    nav(-1)
  end, { buffer = buf, nowait = true, silent = true, desc = "Previous chat" })
  vim.keymap.set("t", "<C-n>", function()
    nav(1)
  end, { buffer = buf, nowait = true, silent = true, desc = "Next chat / new chat" })
  vim.keymap.set("t", "<C-g>", function()
    vim.cmd("stopinsert")
    M.hide_all()
  end, { buffer = buf, nowait = true, silent = true, desc = "Hide agent chats" })

  local spec = config.get(chat.agent_name)
  if spec and spec.status_parser == "generic" then
    vim.keymap.set("t", "<CR>", function()
      manager.mark_submitted(chat)
      return "\r"
    end, { buffer = buf, expr = true, replace_keycodes = false, nowait = true, desc = "Submit agent input" })
  end

  vim.keymap.set("n", "<Esc>", M.hide_all, { buffer = buf, nowait = true, silent = true, desc = "Hide agent chats" })
  vim.keymap.set("n", "<C-g>", M.hide_all, { buffer = buf, nowait = true, silent = true, desc = "Hide agent chats" })
  vim.keymap.set("n", "<C-p>", function()
    nav(-1)
  end, { buffer = buf, nowait = true, silent = true, desc = "Previous chat" })
  vim.keymap.set("n", "<C-n>", function()
    nav(1)
  end, { buffer = buf, nowait = true, silent = true, desc = "Next chat / new chat" })
  vim.keymap.set("n", "<C-d>", delete_current, { buffer = buf, nowait = true, silent = true, desc = "Delete chat" })
  local insert_input = function()
    if stack.main_win and vim.api.nvim_win_is_valid(stack.main_win) then
      scroll_window_to_bottom(stack.main_win, buf)
      vim.cmd("startinsert")
    end
  end
  vim.keymap.set("n", "i", insert_input, { buffer = buf, nowait = true, silent = true, desc = "Type in chat input" })
  vim.keymap.set("n", "p", insert_input, { buffer = buf, nowait = true, silent = true, desc = "Type in chat input" })
end

local function mini_line(chat, width)
  local label = status_label[chat.status] or tostring(chat.status or "")
  local text = " " .. (status_icon[chat.status] or "○") .. " " .. label
  local title = agent_display_title(chat)
  local detail = config.label(chat.agent_name) .. " #" .. chat.id .. " · " .. location(chat, ":t")
  if title ~= "" then
    detail = detail .. " · " .. title
  end
  local text_width = vim.fn.strdisplaywidth(text)
  local remaining = width - text_width - 4
  if remaining > 8 then
    text = text .. "   " .. trim_display(detail, remaining)
  end
  return text
end

local function open_mini_win(chat, row, width, col)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { mini_line(chat, width) })
  vim.api.nvim_buf_add_highlight(buf, status_ns, status_hl[chat.status] or "Comment", 0, 0, -1)
  vim.bo[buf].modifiable = false

  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    width = width,
    height = 1,
    row = row,
    col = col,
    style = "minimal",
    border = mini_border,
    focusable = false,
    zindex = 44,
  })
  vim.wo[win].winhl = "FloatBorder:AgentInactiveBorder,NormalFloat:Normal"
  vim.wo[win].wrap = false
  stack.mini_wins[#stack.mini_wins + 1] = win
  stack.mini_bufs[#stack.mini_bufs + 1] = buf
end

render = function()
  if not stack.open then
    return
  end
  define_highlights()

  local chats = live_chats()
  if #chats == 0 then
    M.hide_all()
    return
  end

  local function buf_ok(c)
    return c.term_buf ~= nil and vim.api.nvim_buf_is_valid(c.term_buf)
  end

  -- When the current chat was removed (deleted, or its process exited),
  -- select the previous chat; when there is none, hide all chat dialogs.
  local idx = chat_index(chats, stack.current_id)
  if not idx and stack.current_id then
    local current_seq = tonumber(stack.current_id) or math.huge
    for i = #chats, 1, -1 do
      if (tonumber(chats[i].id) or 0) < current_seq then
        idx = i
        break
      end
    end
    if not idx then
      M.hide_all()
      return
    end
    stack.current_id = chats[idx].id
  end
  idx = idx or #chats

  -- Safety net: chats whose terminal buffer is gone cannot be shown anymore
  -- and are removed the same way.
  if not buf_ok(chats[idx]) then
    local fallback
    for i = idx - 1, 1, -1 do
      if buf_ok(chats[i]) then
        fallback = chats[i]
        break
      end
    end
    if not fallback then
      for _, c in ipairs(chats) do
        if not buf_ok(c) then
          manager.delete(c)
        end
      end
      M.hide_all()
      return
    end
    stack.current_id = fallback.id
  end
  for _, c in ipairs(chats) do
    if not buf_ok(c) then
      manager.delete(c)
    end
  end
  chats = live_chats()
  if #chats == 0 then
    M.hide_all()
    return
  end
  idx = chat_index(chats, stack.current_id) or #chats
  stack.current_id = chats[idx].id
  local chat = chats[idx]

  -- Anchor the stack to the right edge, like the corner status float.
  local width = math.min(math.max(math.floor(vim.o.columns * 0.62), 56), math.max(vim.o.columns - 8, 40))
  local col = math.max(vim.o.columns - width - 2, 0)

  local prev_count = idx - 1
  local next_count = #chats - idx
  local mini_total = (prev_count + next_count) * 3
  local avail = math.max(vim.o.lines - 4, 12)
  local main_h = math.max(avail - mini_total - 2, 8)
  local total = mini_total + main_h + 2
  local row = math.max(math.floor((vim.o.lines - total) / 2 - 1), 0)

  close_mini_wins()

  -- Previous (older) chats stacked above the current one.
  local r = row
  for i = 1, prev_count do
    open_mini_win(chats[i], r, width, col)
    r = r + 3
  end

  -- Current chat box.
  local buf = chat.term_buf
  map_chat_buffer(buf, chat)

  local title = string.format(" Chat — %s #%s [%s] %s ", config.label(chat.agent_name), chat.id, chat.status or "?", location(chat, ":t"))
  local win_config = {
    relative = "editor",
    width = width,
    height = main_h,
    row = r,
    col = col,
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "center",
    footer = " Ctrl-p prev  Ctrl-n next/new  Ctrl-g hide  Ctrl-d delete ",
    footer_pos = "center",
    zindex = 45,
  }

  if stack.main_win and vim.api.nvim_win_is_valid(stack.main_win) then
    pcall(vim.api.nvim_win_set_config, stack.main_win, win_config)
    if vim.api.nvim_win_get_buf(stack.main_win) ~= buf then
      vim.api.nvim_win_set_buf(stack.main_win, buf)
      scroll_window_to_bottom(stack.main_win, buf)
    end
  else
    stack.main_win = vim.api.nvim_open_win(buf, false, win_config)
    scroll_window_to_bottom(stack.main_win, buf)
  end
  vim.wo[stack.main_win].winhl = "FloatBorder:AgentFocusedBorder,FloatTitle:AgentFocusedTitle,FloatFooter:AgentFooter"
  vim.wo[stack.main_win].number = false
  vim.wo[stack.main_win].relativenumber = false
  vim.wo[stack.main_win].signcolumn = "no"
  r = r + main_h + 2

  -- Next (newer) chats stacked below the current one.
  for i = idx + 1, #chats do
    open_mini_win(chats[i], r, width, col)
    r = r + 3
  end
end

focus_main = function()
  if not stack.open or not stack.main_win or not vim.api.nvim_win_is_valid(stack.main_win) then
    return
  end
  vim.api.nvim_set_current_win(stack.main_win)
  local chat = current_chat()
  if chat and chat.term_buf and vim.api.nvim_buf_is_valid(chat.term_buf)
      and vim.api.nvim_win_get_buf(stack.main_win) == chat.term_buf then
    scroll_window_to_bottom(stack.main_win, chat.term_buf)
    vim.cmd("startinsert")
  else
    vim.cmd("stopinsert")
  end
end

nav = function(delta)
  local _, idx, chats = current_chat()
  if not idx then
    return
  end
  local target = idx + delta
  if target < 1 then
    return
  end
  if target > #chats then
    -- Past the last chat: Ctrl-n creates a new one.
    local previous = chats[idx]
    M.new_chat(stack.context, {
      agent = previous.agent_name,
      model = previous.model,
      level = previous.level,
    })
    return
  end
  vim.cmd("stopinsert")
  stack.current_id = chats[target].id
  render()
  focus_main()
end

-- Delete the current chat and select the previous one; when no previous chat
-- exists, hide all chat dialogs.
delete_current = function()
  local chat, idx, chats = current_chat()
  if not chat then
    return
  end
  local fallback = chats[idx - 1]
  stack.current_id = fallback and fallback.id or nil
  vim.cmd("stopinsert")
  manager.delete(chat)
  if not fallback then
    M.hide_all()
    return
  end
  render()
  focus_main()
end

local function usable_chat(chat)
  if not chat or chat.status == "aborted" or chat.status == "exited" then
    return false
  end
  return chat.term_buf ~= nil and vim.api.nvim_buf_is_valid(chat.term_buf)
end

function M.open_stack(context)
  if context then
    stack.context = context
  end

  -- Open at the remembered chat if it is still usable, otherwise fall back to
  -- the last usable (not closed/aborted) chat, otherwise create a new one.
  local chats = live_chats()
  local idx = chat_index(chats, stack.current_id)
  local target = idx and usable_chat(chats[idx]) and chats[idx] or nil
  if not target then
    for i = #chats, 1, -1 do
      if usable_chat(chats[i]) then
        target = chats[i]
        break
      end
    end
  end
  if not target then
    target = manager.start_empty(stack.context or {}, { agent = config.options.default_agent })
  end
  stack.current_id = target.id
  stack.open = true
  render()
  focus_main()
  M.refresh_status()
end

function M.new_chat(context, opts)
  if context then
    stack.context = context
  end
  local chat = manager.start_empty(stack.context or {}, opts or { agent = config.options.default_agent })
  stack.current_id = chat.id
  stack.open = true
  render()
  focus_main()
  M.refresh_status()
end

function M.paste_to_active(context, text)
  if context then
    stack.context = context
  end
  M.open_stack(stack.context)
  local chat = current_chat()
  if not chat or not manager.paste_prompt(chat, text) then
    return false
  end
  focus_main()
  return true
end

function M.toggle(context)
  if stack.open then
    M.hide_all()
    return
  end
  M.open_stack(context)
end

-- ---------------------------------------------------------------------------
-- Status refresh entry point (called by manager/terminal on any change)
-- ---------------------------------------------------------------------------

function M.refresh_status()
  if status_refresh_pending then
    return
  end
  status_refresh_pending = true
  vim.schedule(function()
    status_refresh_pending = false
    define_highlights()

    if stack.open then
      close_status_windows()
      render()
      return
    end

    local agents = active_agents()
    if #agents == 0 then
      close_status_windows()
      return
    end

    local width = math.min(math.max(math.floor(vim.o.columns * 0.44), 46), 76)
    local max_height = math.max(vim.o.lines - 6, 1)
    local shown_count = math.min(#agents, max_height)
    local shown = {}
    for i = 1, shown_count do
      shown[#shown + 1] = agents[i]
    end

    local lines = {}
    for _, agent in ipairs(shown) do
      lines[#lines + 1] = status_summary_line(agent, width)
    end
    if #agents > shown_count then
      lines[#lines + 1] = string.format("… %d more", #agents - shown_count)
    end

    if not status_buf or not vim.api.nvim_buf_is_valid(status_buf) then
      status_buf = vim.api.nvim_create_buf(false, true)
      status_lines_key = nil
      vim.bo[status_buf].buftype = "nofile"
      vim.bo[status_buf].bufhidden = "hide"
      vim.bo[status_buf].swapfile = false
      vim.bo[status_buf].filetype = "agent-status"
    end

    local lines_key = table.concat(lines, "\0")
    if status_lines_key ~= lines_key then
      vim.bo[status_buf].modifiable = true
      vim.api.nvim_buf_set_lines(status_buf, 0, -1, false, lines)
      vim.api.nvim_buf_clear_namespace(status_buf, status_ns, 0, -1)
      for i, agent in ipairs(shown) do
        vim.api.nvim_buf_add_highlight(status_buf, status_ns, status_hl[agent.status] or "Comment", i - 1, 0, -1)
      end
      vim.bo[status_buf].modifiable = false
      status_lines_key = lines_key
    end

    local win_config = {
      relative = "editor",
      width = width,
      height = #lines,
      row = 1,
      col = math.max(vim.o.columns - width - 2, 0),
      style = "minimal",
      border = "rounded",
      title = "Agents",
      title_pos = "center",
      focusable = false,
      zindex = 45,
    }

    local current_tab = vim.api.nvim_get_current_tabpage()
    local status_win = status_win_for_tab(current_tab)
    if status_win then
      vim.api.nvim_win_set_config(status_win, win_config)
    else
      status_win = vim.api.nvim_open_win(status_buf, false, win_config)
      status_wins[current_tab] = status_win
      vim.wo[status_win].winblend = 8
      vim.wo[status_win].wrap = false
    end
  end)
end

return M
