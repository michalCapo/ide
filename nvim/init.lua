local config_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
vim.opt.runtimepath:prepend(config_dir)
vim.opt.packpath:prepend(config_dir)

-- Vendored plugins are not discovered automatically because runtimepath is
-- not recursive. Register plugin roots kept beside or inside lua/.
for _, root in ipairs({ config_dir, config_dir .. "/lua" }) do
  for name in vim.fs.dir(root) do
    if not name:match("^%.") then
      local path = root .. "/" .. name
      local stat = vim.uv.fs_stat(path)
      if stat and stat.type == "directory"
          and (vim.uv.fs_stat(path .. "/plugin") or vim.uv.fs_stat(path .. "/lua")) then
        vim.opt.runtimepath:prepend(path)
      end
    end
  end
end
local references_view = require("views.references")

local function reread_all_buffers_and_restart_lsp()
  local current_buf = vim.api.nvim_get_current_buf()
  local reloaded = 0
  local skipped = 0

  vim.cmd("silent! checktime")

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf)
        and vim.bo[buf].buflisted
        and vim.bo[buf].buftype == ""
        and vim.api.nvim_buf_get_name(buf) ~= "" then
      if vim.bo[buf].modified then
        skipped = skipped + 1
      else
        local ok = pcall(vim.api.nvim_buf_call, buf, function()
          vim.cmd("silent keepalt edit")
        end)
        if ok then
          reloaded = reloaded + 1
        end
      end
    end
  end

  local get_clients = vim.lsp.get_clients or vim.lsp.get_active_clients
  local clients = get_clients()
  if #clients > 0 then
    vim.notify("Restarting LSP clients...", vim.log.levels.INFO)
  else
    vim.notify("No active LSP clients; starting LSP for open buffers...", vim.log.levels.INFO)
  end
  for _, client in ipairs(clients) do
    client.stop(false)
  end

  vim.defer_fn(function()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" and vim.bo[buf].filetype ~= "" then
        pcall(vim.api.nvim_buf_call, buf, function()
          vim.cmd("silent doautocmd <nomodeline> FileType")
        end)
      end
    end
  end, 100)

  if vim.api.nvim_buf_is_valid(current_buf) then
    pcall(vim.api.nvim_set_current_buf, current_buf)
  end

  local message = string.format("Reloaded %d buffers and restarted LSP", reloaded)
  if skipped > 0 then
    message = message .. string.format(" (%d modified skipped)", skipped)
  end
  vim.notify(message, vim.log.levels.INFO)
end

vim.api.nvim_create_user_command("RereadAllBuffersAndRestartLsp", reread_all_buffers_and_restart_lsp, { desc = "Reread all buffers and restart LSP" })

-- Reload clean buffers after another process changes their files. 'autoread'
-- protects buffers with unsaved edits; checktime only reports the conflict for
-- those buffers instead of replacing their contents.
vim.o.autoread = true
do
  if _G.nvim_auto_reload_timer then
    pcall(_G.nvim_auto_reload_timer.stop, _G.nvim_auto_reload_timer)
    pcall(_G.nvim_auto_reload_timer.close, _G.nvim_auto_reload_timer)
  end

  local group = vim.api.nvim_create_augroup("AutoReloadChangedFiles", { clear = true })
  local timer = vim.uv.new_timer()
  _G.nvim_auto_reload_timer = timer
  local check_scheduled = false
  local disk_versions = {}

  local function current_tab_window_for_buffer(buf)
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_buf(win) == buf then
        return win
      end
    end
  end

  local function stop_diffing_buffer(buf)
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_set_option_value("diff", false, { win = win })
      end
    end
  end

  local function show_disk_version(buf)
    local entry = disk_versions[buf]
    if not entry or not vim.api.nvim_buf_is_valid(entry.disk_buf) then
      return
    end

    local original_win = current_tab_window_for_buffer(buf)
    if not original_win then
      return
    end
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_buf(win) == entry.disk_buf then
        return
      end
    end

    local previous_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(original_win)
    vim.cmd("rightbelow vsplit")
    local disk_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(disk_win, entry.disk_buf)
    vim.api.nvim_set_option_value("diff", true, { win = original_win })
    vim.api.nvim_set_option_value("diff", true, { win = disk_win })
    if vim.api.nvim_win_is_valid(previous_win) then
      vim.api.nvim_set_current_win(previous_win)
    end
  end

  local function update_disk_version(buf, path, lines, filetype)
    if not vim.api.nvim_buf_is_valid(buf) or not vim.bo[buf].modified then
      return
    end

    local entry = disk_versions[buf]
    if not entry or not vim.api.nvim_buf_is_valid(entry.disk_buf) then
      local disk_buf = vim.api.nvim_create_buf(false, true)
      entry = { disk_buf = disk_buf }
      disk_versions[buf] = entry
      vim.api.nvim_buf_set_name(disk_buf, "[disk version] " .. path)
      vim.bo[disk_buf].buftype = "nofile"
      vim.bo[disk_buf].bufhidden = "wipe"
      vim.bo[disk_buf].swapfile = false
      vim.bo[disk_buf].filetype = filetype

      vim.api.nvim_create_autocmd("BufWipeout", {
        group = group,
        buffer = disk_buf,
        once = true,
        callback = function()
          if disk_versions[buf] == entry then
            disk_versions[buf] = nil
          end
          vim.schedule(function()
            stop_diffing_buffer(buf)
          end)
        end,
      })
    end

    vim.bo[entry.disk_buf].modifiable = true
    vim.api.nvim_buf_set_lines(entry.disk_buf, 0, -1, false, lines)
    vim.bo[entry.disk_buf].modifiable = false
    vim.bo[entry.disk_buf].modified = false
    show_disk_version(buf)
    vim.cmd("silent! diffupdate")
    vim.notify("File changed on disk; opened a diff without replacing unsaved edits", vim.log.levels.WARN)
  end

  local function check_for_disk_changes()
    if check_scheduled then
      return
    end
    check_scheduled = true
    vim.schedule(function()
      check_scheduled = false
      pcall(vim.cmd, "silent! checktime")
    end)
  end

  -- Focus/buffer events make the common case immediate. The timer also catches
  -- changes made while Neovim remains focused and idle.
  vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter" }, {
    group = group,
    callback = function(args)
      check_for_disk_changes()
      if args.event == "BufEnter" then
        vim.schedule(function()
          show_disk_version(args.buf)
        end)
      end
    end,
  })
  vim.api.nvim_create_autocmd("FileChangedShell", {
    group = group,
    callback = function(args)
      if vim.v.fcs_reason ~= "conflict" or not vim.bo[args.buf].modified then
        vim.v.fcs_choice = "ask"
        return
      end

      vim.v.fcs_choice = ""
      local path = vim.api.nvim_buf_get_name(args.buf)
      local ok, lines = pcall(vim.fn.readfile, path)
      if not ok then
        vim.notify("File changed on disk but could not be read: " .. path, vim.log.levels.ERROR)
        return
      end
      local filetype = vim.bo[args.buf].filetype
      vim.schedule(function()
        update_disk_version(args.buf, path, lines, filetype)
      end)
    end,
  })
  timer:start(1000, 1000, check_for_disk_changes)

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    once = true,
    callback = function()
      timer:stop()
      timer:close()
      if _G.nvim_auto_reload_timer == timer then
        _G.nvim_auto_reload_timer = nil
      end
    end,
  })
end

vim.api.nvim_create_user_command("Reload", function()
  local init_lua = vim.env.NVIM_PORTABLE_INIT or vim.fn.expand("~/.config/nvim/init.lua")
  vim.cmd("luafile " .. vim.fn.fnameescape(init_lua))
  vim.notify("Reloaded " .. init_lua, vim.log.levels.INFO)
end, { desc = "Reload ~/.config/nvim/init.lua" })

vim.api.nvim_create_autocmd("RecordingEnter", {
  group = vim.api.nvim_create_augroup("DisableMacroRecording", { clear = true }),
  callback = function()
    vim.schedule(function()
      vim.api.nvim_feedkeys("q", "n", false)
    end)
  end,
})

vim.g.mapleader = " "
vim.g.maplocalleader = " "

-- Clean up quickfix mappings/autocmds left behind by older versions of this config.
pcall(vim.api.nvim_del_augroup_by_name, "PiQuickfixLocationPreview")
do
  local legacy_quickfix_map_descs = {
    ["Open quickfix location"] = true,
    ["Next quickfix location preview"] = true,
    ["Previous quickfix location preview"] = true,
    ["Close quickfix location list"] = true,
    ["Return to quickfix source location"] = true,
    ["Next LSP error preview"] = true,
    ["Previous LSP error preview"] = true,
    ["Open LSP error"] = true,
  }
  local preview_ns = vim.api.nvim_create_namespace("PiLocationPreviewTarget")
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      pcall(vim.api.nvim_buf_clear_namespace, buf, preview_ns, 0, -1)
      if vim.bo[buf].buftype == "quickfix" then
        for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
          if legacy_quickfix_map_descs[map.desc or ""] then
            pcall(vim.keymap.del, "n", map.lhs, { buffer = buf })
          end
        end
      end
    end
  end
end

-- Turn on the richer built-in Go syntax groups.
vim.g.go_highlight_functions = 1
vim.g.go_highlight_function_calls = 1
vim.g.go_highlight_function_parameters = 1
vim.g.go_highlight_fields = 1
vim.g.go_highlight_types = 1
vim.g.go_highlight_operators = 1
vim.g.go_highlight_extra_types = 1
vim.g.go_highlight_variable_declarations = 1
vim.g.go_highlight_variable_assignments = 1

-- Prefer the VS Code theme bundled beside this configuration. Keep the lazy
-- path as a fallback for older installations of this config.
do
  local config_path = vim.env.NVIM_PORTABLE_INIT or debug.getinfo(1, "S").source:sub(2)
  local bundled_path = vim.fs.dirname(vim.fs.normalize(config_path)) .. "/vscode-theme"
  local lazy_path = vim.fn.stdpath("data") .. "/lazy/vscode-theme"
  if vim.uv.fs_stat(bundled_path) then
    vim.opt.runtimepath:prepend(bundled_path)
  elseif vim.uv.fs_stat(lazy_path) then
    vim.opt.runtimepath:prepend(lazy_path)
  end
end

local current_theme_background
local function apply_colorscheme(background)
  if current_theme_background == background then
    return false
  end

  vim.o.background = background
  local ok, vscode = pcall(require, "vscode")
  if ok then
    vscode.setup({
      style = background,
    })
  end
  pcall(vim.cmd.colorscheme, "vscode")

  current_theme_background = background
  return true
end

vim.o.number = true
vim.o.relativenumber = true
vim.o.cursorline = true
vim.o.cursorlineopt = "both"
vim.o.termguicolors = true
-- Mode-aware cursor shape: block in normal/visual/command, bar in insert,
-- underline while replacing; keep all modes steady (no blink).
vim.o.guicursor = table.concat({
  "n-v-c:block-Cursor/lCursor-blinkwait0-blinkon0-blinkoff0",
  "i-ci-ve:ver25-Cursor/lCursor-blinkwait0-blinkon0-blinkoff0",
  "r-cr:hor20-Cursor/lCursor-blinkwait0-blinkon0-blinkoff0",
  "o:hor50-Cursor/lCursor-blinkwait0-blinkon0-blinkoff0",
  "sm:block-Cursor/lCursor-blinkwait0-blinkon0-blinkoff0",
}, ",")
vim.o.mouse = "a"
vim.opt.clipboard = "unnamedplus"
vim.o.ignorecase = true
vim.o.smartcase = true
vim.o.splitright = true
vim.o.splitbelow = true
vim.o.updatetime = 250
vim.o.timeout = true
vim.o.timeoutlen = 400
vim.o.ttimeout = true
-- Resolve escape sequences immediately so <Esc> leaves insert mode with no lag.
vim.o.ttimeoutlen = 10
-- Cap the time matchparen may spend per keystroke in insert mode (default 60ms).
vim.g.matchparen_insert_timeout = 15
vim.o.tabstop = 4
vim.o.shiftwidth = 4
vim.o.softtabstop = 4
vim.o.expandtab = true

local function tabline_escape(text)
  return tostring(text):gsub("%%", "%%%%"):gsub("\n", " ")
end

function _G.nvim_is_hidden_buffer_tab(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return false
  end

  local name = vim.api.nvim_buf_get_name(buf)
  local buftype = vim.bo[buf].buftype
  local filetype = vim.bo[buf].filetype
  local ok_dap_terminal, is_dap_terminal = pcall(function()
    return vim.b[buf].is_dap_terminal
  end)

  return (ok_dap_terminal and is_dap_terminal)
    or buftype == "quickfix"
    or filetype == "dap-repl"
    or name:find("[dap-terminal]", 1, true) ~= nil
    or name:find("[terminal-dap]", 1, true) ~= nil
end

function _G.nvim_hide_buffer_tab(buf)
  if _G.nvim_is_hidden_buffer_tab(buf) then
    pcall(vim.api.nvim_set_option_value, "buflisted", false, { buf = buf })
    return true
  end
  return false
end

local function listed_buffers()
  local buffers = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buflisted and not _G.nvim_is_hidden_buffer_tab(buf) then
      table.insert(buffers, buf)
    end
  end
  return buffers
end

function _G.nvim_current_listed_buffer_index(buffers)
  local current = vim.api.nvim_get_current_buf()
  for index, buf in ipairs(buffers) do
    if buf == current then
      return index
    end
  end
end

function _G.nvim_switch_listed_buffer(direction)
  local buffers = listed_buffers()
  if #buffers == 0 then
    return
  end

  local current_index = _G.nvim_current_listed_buffer_index(buffers)
  local next_index
  if current_index then
    next_index = ((current_index - 1 + direction) % #buffers) + 1
  elseif direction < 0 then
    next_index = #buffers
  else
    next_index = 1
  end

  vim.api.nvim_set_current_buf(buffers[next_index])
end

function _G.nvim_dap_terminal_window_heights()
  local heights = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local ok_buf, buf = pcall(vim.api.nvim_win_get_buf, win)
    if ok_buf and _G.nvim_is_hidden_buffer_tab(buf) then
      heights[win] = vim.api.nvim_win_get_height(win)
    end
  end
  return heights
end

function _G.nvim_restore_dap_terminal_window_heights(heights)
  for win, height in pairs(heights or {}) do
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_set_height, win, height)
      pcall(vim.api.nvim_set_option_value, "winfixheight", true, { win = win })
    end
  end
end

function _G.nvim_delete_buffer(buf)
  local ok, err = pcall(vim.api.nvim_buf_delete, buf, {})
  if not ok then
    vim.notify(err, vim.log.levels.WARN)
  end
  return ok
end

function _G.nvim_delete_current_buffer()
  local current = vim.api.nvim_get_current_buf()
  if vim.bo[current].modified then
    _G.nvim_delete_buffer(current)
    return
  end

  local heights = _G.nvim_dap_terminal_window_heights()
  local buffers = listed_buffers()
  local current_index = _G.nvim_current_listed_buffer_index(buffers)
  local target = nil

  if current_index then
    target = buffers[current_index + 1] or buffers[current_index - 1]
  else
    target = buffers[1]
  end

  if target and vim.api.nvim_buf_is_valid(target) then
    vim.api.nvim_set_current_buf(target)
  else
    local empty = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(empty)
  end

  if not _G.nvim_delete_buffer(current) and vim.api.nvim_buf_is_valid(current) then
    pcall(vim.api.nvim_set_current_buf, current)
  end

  _G.nvim_restore_dap_terminal_window_heights(heights)
  vim.schedule(function()
    _G.nvim_restore_dap_terminal_window_heights(heights)
  end)
end

function _G.nvim_delete_buffers_left()
  local buffers = listed_buffers()
  local current_index = _G.nvim_current_listed_buffer_index(buffers)
  if not current_index then
    return
  end

  for index = current_index - 1, 1, -1 do
    _G.nvim_delete_buffer(buffers[index])
  end
end

function _G.nvim_delete_buffers_right()
  local buffers = listed_buffers()
  local current_index = _G.nvim_current_listed_buffer_index(buffers)
  if not current_index then
    return
  end

  for index = #buffers, current_index + 1, -1 do
    _G.nvim_delete_buffer(buffers[index])
  end
end

function _G.nvim_delete_other_buffers()
  local current = vim.api.nvim_get_current_buf()
  local buffers = listed_buffers()
  local deleting = {}

  for _, buf in ipairs(buffers) do
    if buf ~= current then
      deleting[buf] = true
    end
  end

  -- If a window still displays a buffer while it is deleted, Neovim may create
  -- a new listed buffer as its replacement. Move those windows first so that
  -- "close others" cannot leave a replacement tab behind.
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local ok, buf = pcall(vim.api.nvim_win_get_buf, win)
    if ok and deleting[buf] then
      pcall(vim.api.nvim_win_set_buf, win, current)
    end
  end

  for _, buf in ipairs(buffers) do
    if deleting[buf] then
      local deleted = _G.nvim_delete_buffer(buf)
      if not deleted and vim.api.nvim_buf_is_valid(buf) then
        -- Keep any state Neovim refused to discard, but still honor the
        -- command's promise that no other buffer tab remains visible.
        pcall(vim.api.nvim_set_option_value, "buflisted", false, { buf = buf })
      end
    end
  end

  vim.cmd("redrawtabline")
end

local function buffer_tab_name(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    return "[No Name]"
  end
  return vim.fn.fnamemodify(name, ":t")
end

local function buffer_error_count(buf)
  if not vim.diagnostic or not vim.diagnostic.get then
    return 0
  end
  return #vim.diagnostic.get(buf, { severity = vim.diagnostic.severity.ERROR })
end

function _G.open_buffer_tab(buf)
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_set_current_buf(buf)
  end
end

function _G.nvim_buffer_tab_label(buf)
  local label = " " .. buffer_tab_name(buf)

  if vim.bo[buf].modified then
    label = label .. " ●"
  end

  local errors = buffer_error_count(buf)
  if errors > 0 then
    label = label .. "  E:" .. errors
  end

  return label .. " "
end

function _G.nvim_buffer_tab_width(buf)
  return vim.fn.strdisplaywidth(_G.nvim_buffer_tab_label(buf))
end

function _G.nvim_render_buffer_tab(buf, active)
  local tab_hl = active and "%#BufferTabActive#" or "%#BufferTabInactive#"
  local label = " " .. buffer_tab_name(buf)

  if vim.bo[buf].modified then
    label = label .. " ●"
  end

  local tab = string.format("%%%d@v:lua.open_buffer_tab@%s%s", buf, tab_hl, tabline_escape(label))
  local errors = buffer_error_count(buf)
  if errors > 0 then
    local error_hl = active and "%#BufferTabErrorActive#" or "%#BufferTabErrorInactive#"
    tab = tab .. error_hl .. tabline_escape("  E:" .. errors)
  end

  return tab .. tab_hl .. " %T"
end

function _G.nvim_buffer_tabline()
  local current = vim.api.nvim_get_current_buf()
  local buffers = listed_buffers()
  local current_index = _G.nvim_current_listed_buffer_index(buffers)
  local parts = {}

  if not current_index then
    for _, buf in ipairs(buffers) do
      table.insert(parts, _G.nvim_render_buffer_tab(buf, false))
    end
    return table.concat(parts) .. "%#BufferTabFill#%="
  end

  -- Neovim truncates an over-wide tabline from the left, which can hide the
  -- selected buffer. Render only a viewport of buffer tabs that always includes
  -- the current buffer, with edge markers when tabs exist off-screen.
  local columns = math.max(vim.o.columns or 0, 1)
  local marker_width = vim.fn.strdisplaywidth(" ‹ ")
  local start_index = current_index
  local end_index = current_index
  local used_width = _G.nvim_buffer_tab_width(buffers[current_index])
  local add_left_next = true

  local function total_width(start_candidate, end_candidate, content_width)
    local total = content_width
    if start_candidate > 1 then
      total = total + marker_width
    end
    if end_candidate < #buffers then
      total = total + marker_width
    end
    return total
  end

  while start_index > 1 or end_index < #buffers do
    local can_add_left = false
    local can_add_right = false

    if start_index > 1 then
      local candidate_width = used_width + _G.nvim_buffer_tab_width(buffers[start_index - 1])
      can_add_left = total_width(start_index - 1, end_index, candidate_width) <= columns
    end

    if end_index < #buffers then
      local candidate_width = used_width + _G.nvim_buffer_tab_width(buffers[end_index + 1])
      can_add_right = total_width(start_index, end_index + 1, candidate_width) <= columns
    end

    if not can_add_left and not can_add_right then
      break
    end

    if (add_left_next and can_add_left) or not can_add_right then
      start_index = start_index - 1
      used_width = used_width + _G.nvim_buffer_tab_width(buffers[start_index])
    else
      end_index = end_index + 1
      used_width = used_width + _G.nvim_buffer_tab_width(buffers[end_index])
    end

    add_left_next = not add_left_next
  end

  if start_index > 1 then
    table.insert(parts, "%#BufferTabInactive#" .. tabline_escape(" ‹ "))
  end

  for index = start_index, end_index do
    local buf = buffers[index]
    table.insert(parts, _G.nvim_render_buffer_tab(buf, buf == current))
  end

  if end_index < #buffers then
    table.insert(parts, "%#BufferTabInactive#" .. tabline_escape(" › "))
  end

  return table.concat(parts) .. "%#BufferTabFill#%="
end

vim.o.showtabline = 2
vim.o.tabline = "%!v:lua.nvim_buffer_tabline()"

vim.api.nvim_create_autocmd({ "BufAdd", "BufEnter", "BufFilePost", "TermOpen" }, {
  group = vim.api.nvim_create_augroup("HiddenBufferTabs", { clear = true }),
  callback = function(args)
    if _G.nvim_hide_buffer_tab(args.buf) then
      vim.cmd("redrawtabline")
    end
  end,
})

vim.api.nvim_create_autocmd({ "BufAdd", "BufDelete", "BufEnter", "BufFilePost", "BufModifiedSet", "DiagnosticChanged" }, {
  group = vim.api.nvim_create_augroup("BufferTabs", { clear = true }),
  callback = function()
    vim.cmd("redrawtabline")
  end,
})

-- Remember the listed file buffers separately for each project. This is kept
-- deliberately smaller than a Vim session: layouts, terminals, quickfix lists,
-- and plugin windows are not restored.
do
  local directory_arg = vim.fn.argc() == 1 and vim.fn.argv(0) or nil
  if directory_arg and vim.fn.isdirectory(directory_arg) ~= 1 then
    directory_arg = nil
  end
  local cwd = vim.fn.fnamemodify(directory_arg or vim.fn.getcwd(), ":p"):gsub("/$", "")
  local project_root = vim.fs.root(cwd, { ".git" }) or cwd
  local state_dir = vim.fn.stdpath("state") .. "/project-buffers"
  local state_file = state_dir .. "/" .. vim.fn.sha256(project_root) .. ".json"
  local pending_positions = {}

  local function initialize_restored_buffer(buf)
    local position = pending_positions[buf]
    if not position then
      return
    end
    pending_positions[buf] = nil

    -- A buffer created with bufadd() can be read without running the usual
    -- filetype detection. Detect it here so syntax, ftplugins, LSP, and other
    -- FileType hooks initialize just as they do for a file opened normally.
    if vim.bo[buf].filetype == "" then
      pcall(vim.api.nvim_buf_call, buf, function()
        vim.cmd("filetype detect")
      end)
    end
    if vim.api.nvim_get_current_buf() == buf then
      pcall(vim.api.nvim_win_set_cursor, 0, position)
    end
  end

  local function file_buffer_state()
    local files = {}
    local current_path = vim.api.nvim_buf_get_name(0)

    for _, buf in ipairs(listed_buffers()) do
      local path = vim.api.nvim_buf_get_name(buf)
      if vim.bo[buf].buftype == "" and path ~= "" then
        local mark = vim.api.nvim_buf_get_mark(buf, '"')
        if buf == vim.api.nvim_get_current_buf() then
          mark = vim.api.nvim_win_get_cursor(0)
        end
        files[#files + 1] = {
          path = vim.fn.fnamemodify(path, ":p"),
          line = math.max(mark[1] or 1, 1),
          col = math.max(mark[2] or 0, 0),
        }
      end
    end

    return {
      root = project_root,
      current = current_path ~= "" and vim.fn.fnamemodify(current_path, ":p") or nil,
      files = files,
    }
  end

  local function save_project_buffers()
    local state = file_buffer_state()
    if #state.files == 0 then
      return
    end
    vim.fn.mkdir(state_dir, "p")
    pcall(vim.fn.writefile, { vim.json.encode(state) }, state_file)
  end

  local function restore_project_buffers()
    if (vim.fn.argc() ~= 0 and not directory_arg) or vim.fn.filereadable(state_file) ~= 1 then
      return
    end

    local ok, state = pcall(vim.json.decode, table.concat(vim.fn.readfile(state_file), "\n"))
    if not ok or type(state) ~= "table" or state.root ~= project_root or type(state.files) ~= "table" then
      return
    end

    local initial = vim.api.nvim_get_current_buf()
    local restored = {}
    local first_restored
    for _, item in ipairs(state.files) do
      if type(item) == "table" and type(item.path) == "string" and vim.fn.filereadable(item.path) == 1 then
        local buf = vim.fn.bufadd(item.path)
        vim.bo[buf].buflisted = true
        pending_positions[buf] = {
          math.max(tonumber(item.line) or 1, 1),
          math.max(tonumber(item.col) or 0, 0),
        }
        restored[item.path] = buf
        first_restored = first_restored or buf
      end
    end

    local target = restored[state.current] or first_restored
    if target and vim.api.nvim_buf_is_valid(target) then
      vim.api.nvim_set_current_buf(target)
      -- bufadd() may reuse the initial empty buffer, in which case changing to
      -- target emits no BufEnter/BufWinEnter event.
      initialize_restored_buffer(target)
      local initial_name = vim.api.nvim_buf_get_name(initial)
      if initial ~= target and vim.api.nvim_buf_is_valid(initial)
          and (initial_name == "" or vim.fn.isdirectory(initial_name) == 1)
          and not vim.bo[initial].modified then
        pcall(vim.api.nvim_buf_delete, initial, { force = true })
      end
    end
  end

  local group = vim.api.nvim_create_augroup("ProjectBufferPersistence", { clear = true })
  vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, {
    group = group,
    callback = function(args)
      initialize_restored_buffer(args.buf)
    end,
  })
  vim.api.nvim_create_autocmd("VimEnter", { group = group, once = true, callback = restore_project_buffers })
  vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = save_project_buffers })
end

-- Automatic code completion: suggest from LSP plus nearby/current-file words.
-- Keep it buffer-local so prompt/floating picker popups do not autocomplete.
vim.o.autocomplete = false
-- 100ms delay: the menu appears on a micro-pause instead of churning under
-- every keystroke of continuous typing; timeout caps source collection.
vim.o.autocompletedelay = 100
vim.o.autocompletetimeout = 100
-- Sources: LSP (o), current buffer, visible windows, loaded buffers. Unloaded
-- buffers (u) and tags (t) are dropped — slow scans for rarely useful items.
vim.o.complete = "o,.^12,w^8,b^8"
vim.o.pumheight = 10
-- Fuzzy matching lets abbreviations/subsequences rank correctly, e.g.
-- typing `empname` narrows `employee_name` without needing the full prefix.
-- Show suggestions without inserting/selecting one automatically; <Tab> accepts
-- explicitly. No "popup" flag: the auto docs window next to the menu triggers
-- extra resolve requests and visual noise while typing.
vim.o.completeopt = "menuone,fuzzy,noinsert,noselect"

local autocomplete_group = vim.api.nvim_create_augroup("NvimBufferAutocomplete", { clear = true })

local function configure_buffer_autocomplete(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local enabled = vim.bo[buf].buftype == "" and vim.bo[buf].modifiable
  pcall(vim.api.nvim_set_option_value, "autocomplete", enabled, { buf = buf })
end

vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter", "BufReadPost", "BufNewFile", "FileType" }, {
  group = autocomplete_group,
  callback = function(event)
    configure_buffer_autocomplete(event.buf)
  end,
})
vim.api.nvim_create_autocmd("OptionSet", {
  group = autocomplete_group,
  pattern = { "buftype", "modifiable" },
  callback = function()
    configure_buffer_autocomplete()
  end,
})
configure_buffer_autocomplete()

local function keycode(keys)
  return vim.keycode(keys)
end

vim.keymap.set("i", "<Tab>", function()
  local predict = require("predict")
  if predict.has_prediction() then
    -- expr mappings run under textlock; apply the edit right after.
    vim.schedule(predict.accept)
    return ""
  end
  if vim.fn.pumvisible() == 1 then
    -- With only whitespace before the cursor, Tab means indent even if a stray
    -- popup is open; accepting a completion there is always a mistype.
    local col = vim.fn.col(".") - 1
    if col > 0 and vim.fn.getline("."):sub(1, col):match("%S") then
      local info = vim.fn.complete_info({ "selected" })
      if info.selected == -1 then
        return keycode("<C-n><C-y>")
      end
      return keycode("<C-y>")
    end
    return keycode("<C-e><Tab>")
  end
  return keycode("<Tab>")
end, { expr = true, desc = "Accept completion or insert tab" })

vim.keymap.set("n", "<Tab>", function()
  if require("predict").accept() then
    return
  end
  vim.api.nvim_feedkeys(keycode("<C-i>"), "n", false)
end, { desc = "Accept prediction or jump forward" })

vim.keymap.set("i", "<esc>", function()
  -- expr mappings run under textlock; drop the prediction right after.
  vim.schedule(require("predict").dismiss)
  return keycode("<Esc>")
end, { expr = true, desc = "Dismiss prediction and leave insert" })

vim.keymap.set("i", "<S-Tab>", function()
  if vim.fn.pumvisible() == 1 then
    return keycode("<C-p>")
  end
  return keycode("<S-Tab>")
end, { expr = true, desc = "Previous completion or shift-tab" })

-- <CR> accepts an explicitly selected completion item; with an open but
-- unselected menu it closes the menu first so the popup does not carry over
-- onto the new line.
vim.keymap.set("i", "<CR>", function()
  if vim.fn.pumvisible() == 1 then
    local info = vim.fn.complete_info({ "selected" })
    if info.selected ~= -1 then
      return keycode("<C-y>")
    end
    return keycode("<C-e><CR>")
  end
  return keycode("<CR>")
end, { expr = true, desc = "Accept selected completion or newline" })

-- Word-wise deletion in insert mode. Alacritty maps Ctrl+Backspace to <C-w>,
-- so <C-h> remains the normal single-character backspace/Ctrl-h path.
vim.keymap.set("i", "<C-BS>", "<C-g>u<C-w>", { desc = "Delete previous word" })
vim.keymap.set("i", "<C-Del>", '<C-g>u<C-o>"_de', { desc = "Delete next word" })
-- Undo breakpoints so a stray <C-w>/<C-u> is recoverable with one `u`.
vim.keymap.set("i", "<C-w>", "<C-g>u<C-w>", { desc = "Delete previous word" })
vim.keymap.set("i", "<C-u>", "<C-g>u<C-u>", { desc = "Delete to line start" })

vim.opt.scrolloff = 999
vim.opt.sidescrolloff = 8
vim.o.wrap = false

-- Make <C-d>/<C-u> scroll a fixed number of lines instead of half a page.
-- Set to half the window height for default-like behavior, or a fixed count
-- to make it more/less aggressive.
local scroll_step = 15
vim.keymap.set("n", "<C-d>", function()
  local count = vim.v.count1 * scroll_step
  vim.api.nvim_win_set_cursor(0, { math.min(vim.fn.line(".") + count, vim.fn.line("$")), 0 })
end, { desc = "Scroll down N lines" })
vim.keymap.set("n", "<C-u>", function()
  local count = vim.v.count1 * scroll_step
  vim.api.nvim_win_set_cursor(0, { math.max(vim.fn.line(".") - count, 1), 0 })
end, { desc = "Scroll up N lines" })

function _G.nvim_keep_current_line_centered()
  if vim.api.nvim_win_get_config(0).relative ~= "" then
    return
  end
  if vim.bo.buftype ~= "" then
    return
  end

  vim.wo.scrolloff = 999
  pcall(vim.cmd.normal, { "zz", bang = true })
end

vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter", "VimResized" }, {
  group = vim.api.nvim_create_augroup("NvimKeepCurrentLineCentered", { clear = true }),
  callback = _G.nvim_keep_current_line_centered,
})
vim.opt.shortmess:append("I")

local landing_namespace = vim.api.nvim_create_namespace("nvim_landing")
local landing_logo = {
  "███╗   ██╗██╗   ██╗██╗███╗   ███╗",
  "████╗  ██║██║   ██║██║████╗ ████║",
  "██╔██╗ ██║██║   ██║██║██╔████╔██║",
  "██║╚██╗██║╚██╗ ██╔╝██║██║╚██╔╝██║",
  "██║ ╚████║ ╚████╔╝ ██║██║ ╚═╝ ██║",
  "╚═╝  ╚═══╝  ╚═══╝  ╚═╝╚═╝     ╚═╝",
}
local landing_logo_segments = {
  { 0, 10, "NvimLandingBlue" },
  { 10, nil, "NvimLandingGreen" },
}

local function nvim_version_label()
  local version = vim.version()
  return string.format("NVIM v%d.%d.%d", version.major, version.minor, version.patch)
end

local function centered_text(line, width)
  local padding = math.max(math.floor((width - vim.fn.strdisplaywidth(line)) / 2), 0)
  return string.rep(" ", padding) .. line, padding
end

local function render_landing_page(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local width = vim.api.nvim_win_get_width(0)
  local height = vim.api.nvim_win_get_height(0)
  local content_height = #landing_logo + 2
  local top_padding = math.max(math.floor((height - content_height) / 2), 0)
  local lines = {}
  local logo_lines = {}

  for _ = 1, top_padding do
    table.insert(lines, "")
  end

  for _, row in ipairs(landing_logo) do
    local line, padding = centered_text(row, width)
    table.insert(lines, line)
    table.insert(logo_lines, { line = #lines, text = row, padding = padding })
  end

  table.insert(lines, "")
  local version_line = centered_text(nvim_version_label(), width)
  table.insert(lines, version_line)
  local version_lnum = #lines

  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_clear_namespace(buf, landing_namespace, 0, -1)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

  for _, logo_line in ipairs(logo_lines) do
    local line = lines[logo_line.line]
    local logo_width = vim.fn.strdisplaywidth(logo_line.text)
    for _, segment in ipairs(landing_logo_segments) do
      local start_display_col = logo_line.padding + segment[1]
      local end_display_col = logo_line.padding + (segment[2] or logo_width)
      local start_col = vim.str_byteindex(line, math.min(start_display_col, vim.fn.strdisplaywidth(line)))
      local end_col = vim.str_byteindex(line, math.min(end_display_col, vim.fn.strdisplaywidth(line)))
      vim.api.nvim_buf_add_highlight(buf, landing_namespace, segment[3], logo_line.line - 1, start_col, end_col)
    end
  end
  vim.api.nvim_buf_add_highlight(buf, landing_namespace, "NvimLandingVersion", version_lnum - 1, 0, -1)
end

local function show_landing_page()
  if vim.fn.argc() ~= 0 or vim.fn.line("$") ~= 1 or vim.fn.getline(1) ~= "" then
    return
  end

  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].buflisted = false
  pcall(vim.api.nvim_buf_set_name, buf, "[Nvim]")

  vim.wo.number = false
  vim.wo.relativenumber = false
  vim.wo.signcolumn = "no"
  vim.wo.foldcolumn = "0"
  vim.wo.cursorline = false
  vim.wo.list = false

  render_landing_page(buf)

  local group = vim.api.nvim_create_augroup("NvimLanding", { clear = true })
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      if vim.api.nvim_get_current_buf() == buf then
        render_landing_page(buf)
      end
    end,
  })
end

vim.api.nvim_create_autocmd("VimEnter", {
  once = true,
  callback = show_landing_page,
})

local function enable_line_numbers_for_normal_windows()
  if vim.bo.buftype ~= "" then
    return
  end
  if vim.api.nvim_win_get_config(0).relative ~= "" then
    return
  end

  vim.wo.number = true
  vim.wo.relativenumber = true
  vim.wo.signcolumn = "auto"
  vim.wo.cursorline = true
end

vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
  group = vim.api.nvim_create_augroup("NvimNormalWindowLineNumbers", { clear = true }),
  callback = enable_line_numbers_for_normal_windows,
})

local function preferred_editor_background()
  local function system_output(command)
    local ok, output = pcall(vim.fn.system, command)
    if not ok or vim.v.shell_error ~= 0 then
      return nil
    end
    output = tostring(output or ""):gsub("^%s+", ""):gsub("%s+$", "")
    return output ~= "" and output or nil
  end

  local function command_exists(command)
    return vim.fn.executable(command) == 1
  end

  -- Manual escape hatch: `NVIM_BACKGROUND=light nvim` or `NVIM_BACKGROUND=dark nvim`.
  local override = vim.env.NVIM_BACKGROUND
  if override == "light" or override == "dark" then
    return override
  end

  if vim.fn.has("macunix") == 1 then
    local style = system_output({ "defaults", "read", "-g", "AppleInterfaceStyle" })
    return style and style:lower():find("dark", 1, true) and "dark" or "light"
  end

  if command_exists("gsettings") then
    local color_scheme = system_output({ "gsettings", "get", "org.gnome.desktop.interface", "color-scheme" })
    if color_scheme then
      color_scheme = color_scheme:lower()
      if color_scheme:find("prefer%-dark") or color_scheme:find("dark") then
        return "dark"
      elseif color_scheme:find("prefer%-light") or color_scheme:find("light") or color_scheme:find("default") then
        return "light"
      end
    end

    local gtk_theme = system_output({ "gsettings", "get", "org.gnome.desktop.interface", "gtk-theme" })
    if gtk_theme then
      return gtk_theme:lower():find("dark", 1, true) and "dark" or "light"
    end
  end

  if command_exists("kreadconfig6") or command_exists("kreadconfig5") then
    local kreadconfig = command_exists("kreadconfig6") and "kreadconfig6" or "kreadconfig5"
    local color_scheme = system_output({ kreadconfig, "--group", "General", "--key", "ColorScheme" })
    if color_scheme then
      return color_scheme:lower():find("dark", 1, true) and "dark" or "light"
    end
  end

  if vim.fn.has("win32") == 1 or vim.fn.has("wsl") == 1 then
    local apps_use_light = system_output({ "powershell.exe", "-NoProfile", "-Command", "(Get-ItemProperty -Path HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize).AppsUseLightTheme" })
    if apps_use_light == "0" then
      return "dark"
    elseif apps_use_light == "1" then
      return "light"
    end
  end

  local colorfgbg = vim.env.COLORFGBG
  local terminal_bg = colorfgbg and tonumber(colorfgbg:match(".*[;:]([0-9]+)$") or colorfgbg:match("^([0-9]+)$"))
  if terminal_bg then
    -- ANSI background colors 0-6 and 8 are dark; 7 and 9-15 are light.
    return (terminal_bg == 7 or terminal_bg >= 9) and "light" or "dark"
  end

  return "dark"
end

local function apply_code_highlights()
  local c
  if vim.o.background == "light" then
    c = {
      bg = "#ffffff",
      fg = "#1f2328",
      muted = "#6e7781",
      gutter = "#8c959f",
      keyword = "#0000ff",
      control = "#af00db",
      func = "#795e26",
      type = "#267f99",
      variable = "#001080",
      string = "#a31515",
      number = "#098658",
      comment = "#008000",
      operator = "#1f2328",
      special = "#811f3f",
      error = "#a1260d",
    }
  else
    c = {
      bg = "#1f1f1f",
      fg = "#d4d4d4",
      muted = "#808080",
      gutter = "#5a5a5a",
      keyword = "#569cd6",
      control = "#c586c0",
      func = "#dcdcaa",
      type = "#4ec9b0",
      variable = "#9cdcfe",
      string = "#ce9178",
      number = "#b5cea8",
      comment = "#6a9955",
      operator = "#d4d4d4",
      special = "#d7ba7d",
      error = "#f44747",
    }
  end

  local function paint(groups, opts)
    for _, group in ipairs(groups) do
      vim.api.nvim_set_hl(0, group, opts)
    end
  end

  local function paint_lang(langs, bases, opts)
    for _, lang in ipairs(langs) do
      local groups = {}
      for _, base in ipairs(bases) do
        table.insert(groups, base .. "." .. lang)
      end
      paint(groups, opts)
    end
  end

  vim.api.nvim_set_hl(0, "Normal", { fg = c.fg, bg = c.bg })
  vim.api.nvim_set_hl(0, "SignColumn", { fg = c.muted, bg = c.bg })
  vim.api.nvim_set_hl(0, "LineNr", { fg = c.gutter })
  vim.api.nvim_set_hl(0, "EndOfBuffer", { fg = c.bg })

  paint({ "Comment", "goComment", "cComment", "@comment", "@lsp.type.comment" }, { fg = c.comment })
  paint({ "Statement", "Keyword", "goDeclaration", "goPackage", "goImport", "goVar", "goConst", "goTypeDecl", "goDeclType", "cStatement", "cStorageClass", "@keyword", "@keyword.function", "@keyword.operator", "@keyword.storage", "@lsp.type.keyword" }, { fg = c.keyword })
  paint({ "Conditional", "Repeat", "Label", "Exception", "goStatement", "goConditional", "goRepeat", "goLabel", "cConditional", "cRepeat", "cLabel", "@conditional", "@repeat", "@keyword.conditional", "@keyword.repeat", "@keyword.return", "@keyword.exception", "@keyword.import", "@lsp.typemod.keyword.controlFlow" }, { fg = c.control })
  paint({ "Function", "goFunction", "goFunctionCall", "goBuiltins", "@function", "@function.call", "@function.builtin", "@function.method", "@function.method.call", "@method", "@method.call", "@lsp.type.function", "@lsp.type.method", "@lsp.type.member" }, { fg = c.func })
  paint({ "Type", "StorageClass", "Structure", "Typedef", "goType", "goSignedInts", "goUnsignedInts", "goFloats", "goComplexes", "goReceiverType", "goTypeConstructor", "goTypeName", "goExtraType", "goParamType", "cType", "cStructure", "@type", "@type.builtin", "@constructor", "@lsp.type.type", "@lsp.type.typeParameter", "@lsp.type.struct", "@lsp.type.interface", "@lsp.type.class" }, { fg = c.type })
  paint({ "Identifier", "goVarDefs", "goVarAssign", "goParamName", "goReceiverVar", "goField", "@variable", "@parameter", "@field", "@property", "@variable.parameter", "@variable.member", "@lsp.type.variable", "@lsp.type.parameter", "@lsp.type.property", "@lsp.typemod.variable.readonly", "@lsp.typemod.variable.definition", "@lsp.typemod.property.readonly", "@lsp.typemod.parameter.definition" }, { fg = c.variable })
  paint({ "String", "Character", "goString", "goRawString", "goImportString", "cString", "cCharacter", "@string", "@string.regexp", "@character", "@lsp.type.string" }, { fg = c.string })
  paint({ "Number", "Float", "Constant", "goDecimalInt", "goHexadecimalInt", "goOctalInt", "goBinaryInt", "goFloat", "cConstant", "cNumbers", "@number", "@float", "@constant", "@constant.builtin", "@lsp.type.number", "@lsp.type.enumMember" }, { fg = c.number })
  paint({ "Boolean", "goBoolean", "goPredefinedIdentifiers", "@boolean" }, { fg = c.keyword })
  paint({ "Operator", "goOperator", "goPointerOperator", "goVarArgs", "cOperator", "@operator", "@punctuation", "@punctuation.delimiter", "@punctuation.bracket" }, { fg = c.operator })
  paint({ "Special", "SpecialChar", "goSpecialString", "goFormatSpecifier", "cSpecial", "cFormat", "cPreProc", "@punctuation.special", "@variable.builtin" }, { fg = c.special })
  paint({ "Error", "ErrorMsg", "goSpaceError", "goEscapeError", "cError" }, { fg = c.error })

  local langs = { "c", "cpp", "go", "javascript", "javascriptreact", "typescript", "typescriptreact" }
  paint_lang(langs, { "@variable", "@variable.member", "@variable.parameter", "@property", "@field", "@lsp.type.variable", "@lsp.type.parameter", "@lsp.type.property", "@lsp.typemod.variable.readonly", "@lsp.typemod.variable.definition", "@lsp.typemod.property.readonly", "@lsp.typemod.parameter.definition" }, { fg = c.variable })
  paint_lang(langs, { "@function", "@function.call", "@function.method", "@function.method.call", "@method", "@method.call", "@lsp.type.function", "@lsp.type.method", "@lsp.type.member" }, { fg = c.func })
  paint_lang(langs, { "@type", "@type.builtin", "@constructor", "@lsp.type.type", "@lsp.type.typeParameter", "@lsp.type.class", "@lsp.type.interface", "@lsp.type.struct" }, { fg = c.type })
end

local function apply_picker_highlights()
  local function paint_foreground_on_background(group, foreground_group, background_group)
    local foreground = vim.api.nvim_get_hl(0, { name = foreground_group, link = false })
    local background = vim.api.nvim_get_hl(0, { name = background_group, link = false })
    foreground.bg = background.reverse and background.fg or background.bg
    vim.api.nvim_set_hl(0, group, foreground)
  end

  vim.api.nvim_set_hl(0, "PiPickerNormal", { link = "NormalFloat" })
  vim.api.nvim_set_hl(0, "PiPickerBorder", { link = "FloatBorder" })
  vim.api.nvim_set_hl(0, "PiPickerSelected", { link = "PmenuSel" })
  vim.api.nvim_set_hl(0, "PiPickerTitle", { link = "FloatTitle" })
  vim.api.nvim_set_hl(0, "PiPickerMuted", { link = "Comment" })
  vim.api.nvim_set_hl(0, "DapBreakpointSign", { link = "DiagnosticError" })
  vim.api.nvim_set_hl(0, "DapBreakpointLine", { link = "DiagnosticVirtualTextError" })
  vim.api.nvim_set_hl(0, "DapBreakpointNumber", { link = "DiagnosticError" })
  vim.api.nvim_set_hl(0, "DapBreakpointConditionSign", { link = "DiagnosticWarn" })
  vim.api.nvim_set_hl(0, "DapBreakpointRejectedSign", { link = "Comment" })
  vim.api.nvim_set_hl(0, "DapStoppedSign", { link = "DiagnosticOk" })
  vim.api.nvim_set_hl(0, "DapStoppedLine", { link = "DiagnosticVirtualTextOk" })
  vim.api.nvim_set_hl(0, "DapStoppedNumber", { link = "DiagnosticOk" })
  vim.api.nvim_set_hl(0, "NvimLandingBlue", { link = "Identifier" })
  vim.api.nvim_set_hl(0, "NvimLandingGreen", { link = "Function" })
  vim.api.nvim_set_hl(0, "NvimLandingVersion", { link = "Comment" })
  vim.api.nvim_set_hl(0, "FunctionContextWinbar", { link = "WinBar" })
  vim.api.nvim_set_hl(0, "FunctionContextWinbarLine", { link = "LineNr" })
  vim.api.nvim_set_hl(0, "BufferTabActive", { link = "TabLineSel" })
  vim.api.nvim_set_hl(0, "BufferTabInactive", { link = "TabLine" })
  paint_foreground_on_background("BufferTabErrorActive", "DiagnosticError", "TabLineSel")
  paint_foreground_on_background("BufferTabErrorInactive", "DiagnosticError", "TabLine")
  vim.api.nvim_set_hl(0, "BufferTabFill", { link = "TabLineFill" })
  vim.api.nvim_set_hl(0, "DiagnosticFloatingError", { link = "DiagnosticError" })
  vim.api.nvim_set_hl(0, "DiagnosticFloatingWarn", { link = "DiagnosticWarn" })
  vim.api.nvim_set_hl(0, "DiagnosticFloatingInfo", { link = "DiagnosticInfo" })
  vim.api.nvim_set_hl(0, "DiagnosticFloatingHint", { link = "DiagnosticHint" })

  apply_code_highlights()
end

local function apply_os_background()
  local background = preferred_editor_background()
  if apply_colorscheme(background) then
    apply_picker_highlights()
  end
end

apply_os_background()

local function reserve_code_signcolumn(win)
  win = win or vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(win) then
    return
  end

  local buf = vim.api.nvim_win_get_buf(win)
  if vim.bo[buf].buftype == "" then
    vim.wo[win].signcolumn = "yes:1"
    vim.wo[win].cursorline = true
  end
end

vim.api.nvim_create_autocmd({ "BufWinEnter", "WinEnter" }, {
  group = vim.api.nvim_create_augroup("CodeSignColumn", { clear = true }),
  callback = function()
    reserve_code_signcolumn(vim.api.nvim_get_current_win())
  end,
})
reserve_code_signcolumn()

vim.defer_fn(function()
  local theme_timer = vim.uv.new_timer()
  if theme_timer then
    theme_timer:start(0, 2000, vim.schedule_wrap(apply_os_background))
  end
end, 0)

local selection_expand_state = {
  buf = nil,
  base = nil,
  ranges = nil,
  index = 0,
}

local function selection_range_key(range)
  return table.concat(range, ":")
end

local function selection_range_is_valid(range)
  return range
      and (range[1] < range[3] or (range[1] == range[3] and range[2] < range[4]))
end

local function append_unique_selection_range(ranges, seen, range)
  if not selection_range_is_valid(range) then
    return
  end

  local key = selection_range_key(range)
  if not seen[key] then
    table.insert(ranges, range)
    seen[key] = true
  end
end

local function treesitter_selection_ranges(buf, pos)
  if not (vim.treesitter and vim.treesitter.get_node) then
    return {}
  end

  local ok, node = pcall(vim.treesitter.get_node, {
    bufnr = buf,
    pos = pos,
    ignore_injections = false,
  })
  if not ok or not node then
    return {}
  end

  local ranges = {}
  local seen = {}
  while node do
    local start_row, start_col, end_row, end_col = node:range()
    append_unique_selection_range(ranges, seen, { start_row, start_col, end_row, end_col })
    node = node:parent()
  end

  return ranges
end

local function byte_span_on_line(line, col, predicate)
  if line == "" then
    return nil
  end

  local byte_count = #line
  local index = math.min(math.max(col + 1, 1), byte_count)
  local function matches(i)
    return i >= 1 and i <= byte_count and predicate(line:sub(i, i))
  end

  if not matches(index) and matches(index - 1) then
    index = index - 1
  end
  if not matches(index) then
    return nil
  end

  local start_index = index
  while matches(start_index - 1) do
    start_index = start_index - 1
  end

  local end_index = index
  while matches(end_index + 1) do
    end_index = end_index + 1
  end

  return start_index - 1, end_index
end

local function fallback_selection_ranges(buf, pos)
  local row, col = pos[1], pos[2]
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  local ranges = {}
  local seen = {}

  local word_start, word_end = byte_span_on_line(line, col, function(char)
    return char:match("[%w_]") ~= nil
  end)
  if word_start then
    append_unique_selection_range(ranges, seen, { row, word_start, row, word_end })
  end

  local WORD_start, WORD_end = byte_span_on_line(line, col, function(char)
    return char:match("%S") ~= nil
  end)
  if WORD_start then
    append_unique_selection_range(ranges, seen, { row, WORD_start, row, WORD_end })
  end

  append_unique_selection_range(ranges, seen, { row, 0, row, #line })

  local line_count = vim.api.nvim_buf_line_count(buf)
  local paragraph_start = row
  local paragraph_end = row
  while paragraph_start > 0 do
    local previous_line = vim.api.nvim_buf_get_lines(buf, paragraph_start - 1, paragraph_start, false)[1] or ""
    if previous_line:match("^%s*$") then
      break
    end
    paragraph_start = paragraph_start - 1
  end
  while paragraph_end < line_count - 1 do
    local next_line = vim.api.nvim_buf_get_lines(buf, paragraph_end + 1, paragraph_end + 2, false)[1] or ""
    if next_line:match("^%s*$") then
      break
    end
    paragraph_end = paragraph_end + 1
  end
  local paragraph_last_line = vim.api.nvim_buf_get_lines(buf, paragraph_end, paragraph_end + 1, false)[1] or ""
  append_unique_selection_range(ranges, seen, { paragraph_start, 0, paragraph_end, #paragraph_last_line })

  local last_line = vim.api.nvim_buf_get_lines(buf, line_count - 1, line_count, false)[1] or ""
  append_unique_selection_range(ranges, seen, { 0, 0, line_count - 1, #last_line })

  return ranges
end

local function selection_ranges_at(buf, pos)
  local ranges = treesitter_selection_ranges(buf, pos)
  if #ranges == 0 then
    ranges = fallback_selection_ranges(buf, pos)
  end
  return ranges
end

local function exclusive_end_to_cursor(buf, row, col)
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  if col > 0 then
    local prefix = line:sub(1, col)
    local char_count = vim.fn.strchars(prefix)
    if char_count > 0 then
      return row, vim.str_byteindex(line, char_count - 1)
    end
  end

  local previous_row = math.max(row - 1, 0)
  local previous_line = vim.api.nvim_buf_get_lines(buf, previous_row, previous_row + 1, false)[1] or ""
  if previous_line == "" then
    return previous_row, 0
  end
  return previous_row, vim.str_byteindex(previous_line, vim.fn.strchars(previous_line) - 1)
end

local function select_buffer_range(buf, range)
  local end_row, end_col = exclusive_end_to_cursor(buf, range[3], range[4])
  pcall(vim.cmd, "normal! \27")
  vim.api.nvim_win_set_cursor(0, { range[1] + 1, range[2] })
  vim.cmd("normal! v")
  vim.api.nvim_win_set_cursor(0, { end_row + 1, end_col })
end

local function reset_selection_expand_state(buf, base)
  selection_expand_state.buf = buf
  selection_expand_state.base = base
  selection_expand_state.ranges = selection_ranges_at(buf, base)
  selection_expand_state.index = 0
end

local function selection_expand_state_is_current(buf)
  return selection_expand_state.buf == buf
      and selection_expand_state.base ~= nil
      and selection_expand_state.ranges ~= nil
      and #selection_expand_state.ranges > 0
end

local function increase_selection_at_cursor(from_visual)
  local buf = vim.api.nvim_get_current_buf()
  if not from_visual or not selection_expand_state_is_current(buf) then
    local cursor = vim.api.nvim_win_get_cursor(0)
    reset_selection_expand_state(buf, { cursor[1] - 1, cursor[2] })
  end

  if not selection_expand_state_is_current(buf) then
    vim.notify("No selectable range found at cursor", vim.log.levels.WARN)
    return
  end

  selection_expand_state.index = math.min(selection_expand_state.index + 1, #selection_expand_state.ranges)
  select_buffer_range(buf, selection_expand_state.ranges[selection_expand_state.index])
end

local function decrease_selection_at_cursor()
  local buf = vim.api.nvim_get_current_buf()
  if not selection_expand_state_is_current(buf) or selection_expand_state.index <= 1 then
    vim.notify("No smaller selection range", vim.log.levels.INFO)
    return
  end

  selection_expand_state.index = selection_expand_state.index - 1
  select_buffer_range(buf, selection_expand_state.ranges[selection_expand_state.index])
end

vim.keymap.set("n", "<M-i>", function() increase_selection_at_cursor(false) end, { desc = "Increase selection at cursor" })
vim.keymap.set("x", "<M-i>", function() increase_selection_at_cursor(true) end, { desc = "Increase selection at cursor" })
vim.keymap.set({ "n", "x" }, "<M-I>", decrease_selection_at_cursor, { desc = "Decrease selection at cursor" })
vim.keymap.set({ "n", "x" }, "<S-M-i>", decrease_selection_at_cursor, { desc = "Decrease selection at cursor" })

_G.nvim_toggle_comment_range = function(range)
  if not range then
    vim.notify("No range found to comment", vim.log.levels.WARN)
    return
  end

  local buf = vim.api.nvim_get_current_buf()
  local commentstring = vim.bo[buf].commentstring
  if not commentstring or commentstring == "" or not commentstring:find("%s", 1, true) then
    commentstring = "// %s"
  end

  local prefix, suffix = commentstring:match("^(.-)%%s(.-)$")
  prefix = prefix or ""
  suffix = suffix or ""
  local prefix_marker = vim.trim(prefix)
  local suffix_marker = vim.trim(suffix)

  local start_row = range.start_row
  local end_row = range.mode == "line" and range.end_row or range.end_row + 1
  if end_row <= start_row then
    end_row = start_row + 1
  end

  local lines = vim.api.nvim_buf_get_lines(buf, start_row, end_row, false)
  local function line_is_commented(line)
    local trimmed = vim.trim(line)
    if trimmed == "" then
      return true
    end
    if prefix_marker ~= "" and not vim.startswith(trimmed, prefix_marker) then
      return false
    end
    if suffix_marker ~= "" and not vim.endswith(trimmed, suffix_marker) then
      return false
    end
    return prefix_marker ~= "" or suffix_marker ~= ""
  end

  local function uncomment_line(line)
    local indent, body = line:match("^(%s*)(.-)$")
    if prefix_marker ~= "" then
      body = body:gsub("^" .. vim.pesc(prefix_marker) .. "%s?", "", 1)
    end
    if suffix_marker ~= "" then
      body = body:gsub("%s?" .. vim.pesc(suffix_marker) .. "$", "", 1)
    end
    return indent .. body
  end

  local all_commented = true
  for _, line in ipairs(lines) do
    if line:match("%S") and not line_is_commented(line) then
      all_commented = false
      break
    end
  end

  for index, line in ipairs(lines) do
    if line:match("%S") then
      if all_commented then
        lines[index] = uncomment_line(line)
      else
        local indent, body = line:match("^(%s*)(.-)$")
        lines[index] = indent .. prefix .. body .. suffix
      end
    end
  end

  vim.api.nvim_buf_set_lines(buf, start_row, end_row, false, lines)
end

_G.nvim_matching_pair_line_range = function()
  local start_cursor = vim.api.nvim_win_get_cursor(0)
  pcall(vim.cmd, "normal! %")
  local match_cursor = vim.api.nvim_win_get_cursor(0)
  vim.api.nvim_win_set_cursor(0, start_cursor)

  if start_cursor[1] == match_cursor[1] and start_cursor[2] == match_cursor[2] then
    vim.notify("No matching pair found", vim.log.levels.WARN)
    return nil
  end

  local start_row = math.min(start_cursor[1], match_cursor[1]) - 1
  local end_row = math.max(start_cursor[1], match_cursor[1])
  return { mode = "line", start_row = start_row, end_row = end_row }
end

_G.nvim_toggle_comment_matching_pair = function()
  _G.nvim_toggle_comment_range(_G.nvim_matching_pair_line_range())
end

vim.keymap.set("n", "t5", _G.nvim_toggle_comment_matching_pair, { desc = "Toggle comment matching pair block" })
vim.keymap.set("n", "tl", function()
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  _G.nvim_toggle_comment_range({ mode = "line", start_row = row, end_row = row + 1 })
end, { desc = "Toggle comment current line" })

local function paste_register_prefix()
  local register = vim.v.register
  if register == '"' then
    return ""
  end
  return '"' .. register
end

vim.keymap.set("x", "p", function()
  return '"_d' .. paste_register_prefix() .. "P"
end, { expr = true, desc = "Paste over selection without clobbering yank register" })
vim.keymap.set("x", "P", function()
  return '"_d' .. paste_register_prefix() .. "P"
end, { expr = true, desc = "Paste over selection without clobbering yank register" })

vim.keymap.set("n", "<leader>q", "<cmd>quit<cr>", { desc = "Quit" })
vim.keymap.set("n", "<leader>w", "<cmd>set wrap!<cr>", { desc = "Toggle line wrap" })
vim.keymap.set("n", "<leader>yy", function()
  local file = vim.api.nvim_buf_get_name(0)
  if file == "" then
    vim.notify("Current buffer has no file path", vim.log.levels.WARN)
    return
  end
  local location = vim.fn.fnamemodify(file, ":~:.") .. ":" .. vim.api.nvim_win_get_cursor(0)[1]
  vim.fn.setreg("+", location)
  vim.notify("Copied " .. location, vim.log.levels.INFO)
end, { desc = "Copy current file and line location" })
vim.keymap.set("n", "<C-s>", "<cmd>SaveAllWithFormat<cr>", { desc = "Format current buffer and save all files" })
vim.keymap.set("n", "00", "^", { desc = "First non-blank character", nowait = true })
vim.keymap.set("n", "44", "$", { desc = "End of line", nowait = true })
vim.keymap.set("n", "gb", "G", { desc = "Bottom of buffer" })
vim.keymap.set("n", "5", "%", { desc = "Matching pair" })
vim.keymap.set("n", "d5", "d%", { desc = "Delete until matching pair", remap = true })
vim.keymap.set("n", "c5", "c%", { desc = "Change until matching pair", remap = true })
vim.keymap.set("n", "y5", "y%", { desc = "Yank until matching pair", remap = true })
vim.keymap.set("o", "0", "^", { desc = "Until first non-blank character" })
vim.keymap.set("o", "4", "$", { desc = "Until end of line" })
vim.keymap.set("o", "5", "%", { desc = "Until matching pair" })
vim.keymap.set("n", "<C-h>", "<C-w>h", { desc = "Focus left window" })
vim.keymap.set("n", "<C-j>", "<C-w>j", { desc = "Focus lower window" })
vim.keymap.set("n", "<C-k>", "<C-w>k", { desc = "Focus upper window" })
vim.keymap.set("n", "<C-l>", "<C-w>l", { desc = "Focus right window" })
-- vim.keymap.set("n", "H", function() _G.nvim_switch_listed_buffer(-1) end, { desc = "Previous buffer" })
-- vim.keymap.set("n", "L", function() _G.nvim_switch_listed_buffer(1) end, { desc = "Next buffer" })
vim.keymap.set("n", "[-b", "<cmd>bprevious<cr>", { desc = "Previous buffer" })
vim.keymap.set("n", "]-b", "<cmd>bnext<cr>", { desc = "Next buffer" })
vim.keymap.set("n", "[q", function()
  local ok, err = pcall(vim.cmd, "cprevious")
  if not ok then
    vim.notify(tostring(err):gsub("^Vim%([^)]*%):", ""), vim.log.levels.WARN)
  end
end, { desc = "Previous quickfix item" })
vim.keymap.set("n", "]q", function()
  local ok, err = pcall(vim.cmd, "cnext")
  if not ok then
    vim.notify(tostring(err):gsub("^Vim%([^)]*%):", ""), vim.log.levels.WARN)
  end
end, { desc = "Next quickfix item" })
vim.keymap.set("n", "<leader>bd", _G.nvim_delete_current_buffer, { desc = "Close buffer" })
vim.keymap.set("n", "<leader>bl", _G.nvim_delete_buffers_left, { desc = "Close buffers to the left" })
vim.keymap.set("n", "<leader>br", _G.nvim_delete_buffers_right, { desc = "Close buffers to the right" })
vim.keymap.set("n", "<leader>bo", _G.nvim_delete_other_buffers, { desc = "Close other buffers" })

local bottom_terminal_buf
local bottom_terminal_win
local bottom_terminal_height = 8

local function bottom_terminal_job_running()
  if not bottom_terminal_buf or not vim.api.nvim_buf_is_valid(bottom_terminal_buf) then
    return false
  end

  local job_id = vim.b[bottom_terminal_buf].terminal_job_id
  return job_id ~= nil and vim.fn.jobwait({ job_id }, 0)[1] == -1
end

local function find_bottom_terminal_win()
  if not bottom_terminal_buf or not vim.api.nvim_buf_is_valid(bottom_terminal_buf) then
    return nil
  end

  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bottom_terminal_buf then
      return win
    end
  end

  return nil
end

local function toggle_bottom_terminal()
  pcall(vim.cmd.stopinsert)

  bottom_terminal_win = find_bottom_terminal_win()
  if bottom_terminal_win and vim.api.nvim_win_is_valid(bottom_terminal_win) then
    if vim.api.nvim_get_current_win() == bottom_terminal_win then
      vim.api.nvim_win_close(bottom_terminal_win, true)
      bottom_terminal_win = nil
      return
    end

    vim.api.nvim_set_current_win(bottom_terminal_win)
    vim.cmd.startinsert()
    return
  end

  vim.cmd("botright " .. bottom_terminal_height .. "split")
  bottom_terminal_win = vim.api.nvim_get_current_win()

  if bottom_terminal_job_running() then
    vim.api.nvim_win_set_buf(bottom_terminal_win, bottom_terminal_buf)
  else
    bottom_terminal_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(bottom_terminal_win, bottom_terminal_buf)
    vim.bo[bottom_terminal_buf].bufhidden = "hide"
    vim.bo[bottom_terminal_buf].swapfile = false
    vim.fn.termopen(vim.o.shell, { cwd = vim.fn.getcwd() })
  end

  vim.wo[bottom_terminal_win].number = false
  vim.wo[bottom_terminal_win].relativenumber = false
  vim.wo[bottom_terminal_win].signcolumn = "no"
  vim.wo[bottom_terminal_win].winfixheight = true
  vim.cmd("resize " .. bottom_terminal_height)
  vim.cmd.startinsert()
end

vim.keymap.set({ "n", "i", "t" }, "<C-t>", toggle_bottom_terminal, { desc = "Toggle bottom terminal", silent = true })
vim.keymap.set("t", "<esc>", [[<C-\><C-n>]], { desc = "Terminal normal mode", silent = true })

local last_file_win

local function leave_insert_or_terminal_mode()
  pcall(vim.cmd.stopinsert)
end

local function is_file_window(win)
  if not vim.api.nvim_win_is_valid(win) then
    return false
  end

  local buf = vim.api.nvim_win_get_buf(win)
  if not vim.api.nvim_buf_is_valid(buf) then
    return false
  end

  return vim.bo[buf].buftype == "" and vim.bo[buf].filetype ~= "netrw"
end

vim.api.nvim_create_autocmd({ "WinEnter", "BufEnter" }, {
  callback = function()
    local win = vim.api.nvim_get_current_win()
    if is_file_window(win) then
      last_file_win = win
    end
  end,
})

local function focus_file_explorer()
  leave_insert_or_terminal_mode()

  local selected_file
  local current_buf = vim.api.nvim_get_current_buf()
  if vim.api.nvim_buf_is_valid(current_buf)
      and vim.bo[current_buf].buftype == ""
      and vim.bo[current_buf].filetype ~= "netrw"
      and vim.api.nvim_buf_get_name(current_buf) ~= "" then
    selected_file = vim.api.nvim_buf_get_name(current_buf)
  elseif last_file_win and is_file_window(last_file_win) then
    selected_file = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(last_file_win))
  end

  local function explore_selected_file()
    if selected_file and selected_file ~= "" then
      vim.cmd("Explore " .. vim.fn.fnameescape(vim.fn.fnamemodify(selected_file, ":p:h")))
      vim.schedule(function()
        local name = vim.fn.fnamemodify(selected_file, ":t")
        if name ~= "" and vim.bo.filetype == "netrw" then
          pcall(vim.fn.search, "\\V" .. vim.fn.escape(name, "\\"), "w")
        end
      end)
    else
      vim.cmd.Explore()
    end
  end

  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == "netrw" then
      if vim.api.nvim_get_current_win() == win then
        vim.api.nvim_win_close(win, true)
        return
      end

      vim.api.nvim_set_current_win(win)
      explore_selected_file()
      return
    end
  end

  local width = math.min(math.max(math.floor(vim.o.columns * (vim.g.netrw_winsize / 100)), 32), vim.o.columns - 4)
  local height = math.max(vim.o.lines - vim.o.cmdheight - 2, 1)
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = 0,
    col = 0,
    width = width,
    height = height,
    border = "rounded",
    style = "minimal",
  })

  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  explore_selected_file()
end

local function focus_file_buffer()
  leave_insert_or_terminal_mode()

  if last_file_win and is_file_window(last_file_win) then
    vim.api.nvim_set_current_win(last_file_win)
    return
  end

  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if is_file_window(win) then
      vim.api.nvim_set_current_win(win)
      return
    end
  end

  vim.notify("No file buffer window found", vim.log.levels.WARN)
end

function _G.nvim_hide_file_explorer_and_focus_file_buffer()
  leave_insert_or_terminal_mode()

  local current_win = vim.api.nvim_get_current_win()
  local current_buf = vim.api.nvim_get_current_buf()
  if vim.api.nvim_buf_is_valid(current_buf) and vim.bo[current_buf].filetype == "netrw" then
    pcall(vim.api.nvim_win_close, current_win, true)
  end

  vim.schedule(focus_file_buffer)
end

local function is_dap_terminal_buffer(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return false
  end

  local ok_is_dap_terminal, is_dap_terminal = pcall(function()
    return vim.b[buf].is_dap_terminal
  end)
  if ok_is_dap_terminal and is_dap_terminal then
    return true
  end

  local filetype = vim.bo[buf].filetype
  local name = vim.api.nvim_buf_get_name(buf)
  return filetype == "dap-repl" or name:find("[dap-terminal]", 1, true) ~= nil
end

local function configure_dap_terminal_escape(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  vim.keymap.set("t", "<M-3>", _G.nvim_focus_dap_terminal, { buffer = buf, desc = "Focus DAP terminal", silent = true })
  vim.keymap.set("t", "<A-3>", _G.nvim_focus_dap_terminal, { buffer = buf, desc = "Focus DAP terminal", silent = true })
  vim.keymap.set("t", "<Esc>3", _G.nvim_focus_dap_terminal, { buffer = buf, desc = "Focus DAP terminal", silent = true })
  vim.keymap.set("t", "<esc>", [[<C-\><C-n>]], { buffer = buf, desc = "Terminal normal mode", silent = true })
  vim.keymap.set("n", "<esc>", focus_file_buffer, { buffer = buf, desc = "Focus file buffer", silent = true })
end

function _G.nvim_focus_dap_terminal()
  leave_insert_or_terminal_mode()

  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if is_dap_terminal_buffer(buf) then
      vim.api.nvim_set_current_win(win)
      if vim.bo[buf].buftype == "terminal" or vim.bo[buf].filetype == "dap-repl" then
        vim.cmd.startinsert()
      end
      return
    end
  end

  vim.notify("No DAP terminal found", vim.log.levels.WARN)
end

vim.keymap.set("n", "<leader>f", focus_file_explorer, { desc = "Toggle file explorer", silent = true })
vim.keymap.set({ "n", "t" }, "<M-2>", focus_file_buffer, { desc = "Focus file buffer", silent = true })
vim.keymap.set({ "n", "t" }, "<M-3>", _G.nvim_focus_dap_terminal, { desc = "Focus DAP terminal", silent = true })
vim.keymap.set({ "n", "t" }, "<A-3>", _G.nvim_focus_dap_terminal, { desc = "Focus DAP terminal", silent = true })
-- <Esc>-prefixed mappings are deliberately NOT set for insert mode: they make
-- every <Esc> wait `timeoutlen` before leaving insert, which wrecks typing flow.
vim.keymap.set({ "n", "t" }, "<Esc>3", _G.nvim_focus_dap_terminal, { desc = "Focus DAP terminal", silent = true })
-- No insert mode here: with <Space> as leader, an insert-mode <leader> mapping
-- makes every typed space ambiguous for `timeoutlen` and " dT" triggers it.
vim.keymap.set({ "n", "t" }, "<leader>dT", _G.nvim_focus_dap_terminal, { desc = "Focus DAP terminal", silent = true })

function _G.open_lazygit()
  local lazygit = vim.env.NVIM_PORTABLE_LAZYGIT or "lazygit"
  if vim.fn.executable(lazygit) ~= 1 then
    vim.notify("lazygit is not installed or not on PATH", vim.log.levels.ERROR)
    return
  end

  local function lazygit_float_config()
    return {
      relative = "editor",
      row = 0,
      col = 0,
      width = vim.o.columns,
      height = vim.o.lines - vim.o.cmdheight,
      border = "none",
      style = "minimal",
    }
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"

  local win = vim.api.nvim_open_win(buf, true, lazygit_float_config())
  local edit_request = vim.fn.tempname()

  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"

  local resize_autocmd
  local function resize_lazygit()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_config(win, lazygit_float_config())
    end
  end

  resize_autocmd = vim.api.nvim_create_autocmd("VimResized", {
    callback = vim.schedule_wrap(resize_lazygit),
    desc = "Resize fullscreen lazygit float",
  })

  local job_id = vim.fn.termopen({ lazygit }, {
    cwd = vim.fn.getcwd(),
    env = {
      LAZYGIT_NVIM_EDIT_REQUEST = edit_request,
    },
    on_exit = vim.schedule_wrap(function()
      local pending_edit
      if vim.fn.filereadable(edit_request) == 1 then
        local lines = vim.fn.readfile(edit_request)
        if lines[1] and lines[1] ~= "" then
          pending_edit = {
            file = lines[1],
            line = math.max(tonumber(lines[2]) or 1, 1),
            col = math.max(tonumber(lines[3]) or 0, 0),
          }
        end
      end
      pcall(vim.fn.delete, edit_request)

      if resize_autocmd then
        pcall(vim.api.nvim_del_autocmd, resize_autocmd)
      end
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
      if pending_edit then
        vim.cmd.edit(vim.fn.fnameescape(pending_edit.file))
        local line_count = math.max(vim.api.nvim_buf_line_count(0), 1)
        local line = math.min(pending_edit.line, line_count)
        local text = vim.api.nvim_buf_get_lines(0, line - 1, line, false)[1] or ""
        pcall(vim.api.nvim_win_set_cursor, 0, { line, math.min(pending_edit.col, #text) })
      end
    end),
  })

  local function send_lazygit_escape()
    if job_id and job_id > 0 then
      vim.api.nvim_chan_send(job_id, "\27")
    end
    if vim.api.nvim_get_mode().mode ~= "t" then
      vim.cmd.startinsert()
    end
  end

  vim.keymap.set({ "t", "n" }, "<esc>", send_lazygit_escape, {
    buffer = buf,
    desc = "Send Esc to lazygit",
    nowait = true,
    silent = true,
  })

  vim.cmd.startinsert()
end

local ctrl_s_format_skip_filetypes = {
  go = true, -- gopls formats Go on BufWritePre below; avoid double-formatting.
}

local function buffer_has_lsp_formatter(buf)
  local get_clients = vim.lsp.get_clients or vim.lsp.get_active_clients
  local clients = get_clients({ bufnr = buf })
  for _, client in ipairs(clients) do
    local supports = (client.supports_method and client:supports_method("textDocument/formatting"))
        or (client.server_capabilities and client.server_capabilities.documentFormattingProvider)
    if supports then
      return true
    end
  end
  return false
end

local function format_current_buffer_before_save()
  local buf = vim.api.nvim_get_current_buf()
  if vim.bo[buf].buftype ~= "" or not vim.bo[buf].modifiable then
    return
  end
  if ctrl_s_format_skip_filetypes[vim.bo[buf].filetype] then
    return
  end
  if not buffer_has_lsp_formatter(buf) then
    return
  end

  local ok, err = pcall(vim.lsp.buf.format, {
    bufnr = buf,
    async = false,
    timeout_ms = 3000,
  })
  if not ok then
    vim.notify("Format before save failed: " .. tostring(err), vim.log.levels.WARN)
  end
end

local function save_all_with_format()
  format_current_buffer_before_save()
  vim.cmd.wall()
end

vim.api.nvim_create_user_command("SaveAllWithFormat", save_all_with_format, {
  desc = "Format current buffer, then save all files",
})

vim.api.nvim_create_autocmd("BufWritePre", {
  pattern = "*.go",
  callback = function(event)
    if buffer_has_lsp_formatter(event.buf) then
      pcall(vim.lsp.buf.format, {
        bufnr = event.buf,
        async = false,
        timeout_ms = 3000,
        filter = function(client)
          return client.name == "gopls"
        end,
      })
    end
  end,
  desc = "Format Go files with gopls before write",
})

vim.keymap.set("i", "<C-s>", "<C-g>u<Cmd>SaveAllWithFormat<CR>", { desc = "Format current buffer and save all files" })
vim.keymap.set("v", "<C-s>", "<esc><cmd>SaveAllWithFormat<cr>", { desc = "Format current buffer and save all files" })
vim.keymap.set("n", "<esc>", function()
  if vim.bo.buftype == "terminal" then
    focus_file_buffer()
    return
  end
  if require("predict").dismiss() then
    return
  end
  vim.cmd.nohlsearch()
end, { desc = "Dismiss prediction / clear search highlight / leave terminal" })

-- Built-in file explorer (netrw)
vim.g.netrw_banner = 0
vim.g.netrw_liststyle = 3
-- Open files from the sidebar explorer in the previous/main file window
-- instead of replacing the floating netrw sidebar buffer.
vim.g.netrw_browse_split = 4
vim.g.netrw_winsize = 35

local function netrw_open_in_main_and_close_sidebar()
  local sidebar_win = vim.api.nvim_get_current_win()
  local sidebar_buf = vim.api.nvim_get_current_buf()
  local keys = vim.api.nvim_replace_termcodes("<Plug>NetrwLocalBrowseCheck", true, false, true)

  -- Let netrw perform its normal Enter action.  With netrw_browse_split=4,
  -- files are opened in the previous/main window; directories stay in netrw.
  vim.api.nvim_feedkeys(keys, "mx", false)

  vim.schedule(function()
    if not vim.api.nvim_win_is_valid(sidebar_win) then
      return
    end
    if vim.api.nvim_get_current_win() == sidebar_win then
      return
    end
    if not vim.api.nvim_buf_is_valid(sidebar_buf) or vim.bo[sidebar_buf].filetype ~= "netrw" then
      return
    end
    pcall(vim.api.nvim_win_close, sidebar_win, true)
  end)
end

function _G.nvim_netrw_create_file_in_main_and_close_sidebar()
  local sidebar_win = vim.api.nvim_get_current_win()
  local dir = vim.b.netrw_curdir or vim.fn.getcwd()
  local input_path = vim.fn.input("New file or directory (end directory with /): ", dir .. "/", "file")
  if input_path == "" then
    return
  end

  local create_directory = input_path:sub(-1) == "/"
  local path = vim.fn.fnamemodify(input_path, ":p")

  if create_directory then
    vim.fn.mkdir(path, "p")
    local refresh = vim.api.nvim_replace_termcodes("<Plug>NetrwRefresh", true, false, true)
    vim.api.nvim_feedkeys(refresh, "mx", false)
    return
  end

  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  if vim.fn.filereadable(path) == 0 then
    vim.fn.writefile({}, path)
  end

  local target_win = (last_file_win and is_file_window(last_file_win)) and last_file_win or nil
  local alternate_win = vim.fn.win_getid(vim.fn.winnr("#"))
  if not target_win and is_file_window(alternate_win) then
    target_win = alternate_win
  end
  if not target_win then
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if win ~= sidebar_win and is_file_window(win) then
        target_win = win
        break
      end
    end
  end

  if target_win and vim.api.nvim_win_is_valid(target_win) then
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    vim.api.nvim_win_set_buf(target_win, buf)
    vim.api.nvim_set_current_win(target_win)
    last_file_win = target_win
  else
    vim.cmd.edit(vim.fn.fnameescape(path))
    if is_file_window(vim.api.nvim_get_current_win()) then
      last_file_win = vim.api.nvim_get_current_win()
    end
  end

  if vim.api.nvim_win_is_valid(sidebar_win) and sidebar_win ~= last_file_win then
    pcall(vim.api.nvim_win_close, sidebar_win, true)
  end
end

vim.api.nvim_create_autocmd("FileType", {
  pattern = "netrw",
  group = vim.api.nvim_create_augroup("NetrwSystemOpenShortcut", { clear = true }),
  callback = function(event)
    -- Netrw bakes b:netrw_curdir into its buffer-local D mapping.  In tree
    -- view that directory changes while browsing, so the stale mapping can
    -- try to remove paths such as `.vscode/.vscode/`.  Keep netrw's own
    -- confirmation/removal implementation, but pass the current directory.
    -- FileType fires before netrw has finished installing its buffer-local
    -- mappings.  Defer this lookup or maparg() sees the unrelated global D
    -- mapping and gives us the wrong script ID.
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(event.buf) then
        return
      end

      vim.api.nvim_buf_call(event.buf, function()
        local delete_map = vim.fn.maparg("D", "n", false, true)
        local delete_function = type(delete_map) == "table"
            and tonumber(delete_map.sid) and delete_map.sid > 0
            and ("<SNR>" .. delete_map.sid .. "_NetrwLocalRm")

        if not delete_function or vim.fn.exists("*" .. delete_function) ~= 1 then
          -- A second queued FileType callback may already see our Lua mapping.
          return
        end

        local function delete_netrw_entry()
          vim.fn[delete_function](vim.b[event.buf].netrw_curdir or vim.fn.getcwd())
        end

        vim.keymap.set("n", "d", delete_netrw_entry, {
          buffer = event.buf,
          desc = "Delete file/directory with confirmation",
          silent = true,
        })
        pcall(vim.keymap.del, "n", "D", { buffer = event.buf })
      end)
    end)

    vim.keymap.set("n", "o", "x", {
      buffer = event.buf,
      desc = "Open with system default application",
      remap = true,
      silent = true,
    })
    vim.keymap.set("n", "r", "R", {
      buffer = event.buf,
      desc = "Rename file/directory",
      remap = true,
      silent = true,
    })
    vim.keymap.set("n", "%", _G.nvim_netrw_create_file_in_main_and_close_sidebar, {
      buffer = event.buf,
      desc = "Create file in main window and close explorer",
      silent = true,
    })
    vim.keymap.set("n", "<CR>", netrw_open_in_main_and_close_sidebar, {
      buffer = event.buf,
      desc = "Open file in main window and close explorer",
      silent = true,
    })
    vim.keymap.set("n", "<esc>", _G.nvim_hide_file_explorer_and_focus_file_buffer, {
      buffer = event.buf,
      desc = "Hide file explorer and focus file buffer",
      silent = true,
    })
  end,
})
vim.keymap.set("n", "<leader>e", function()
  references_view.project_errors()
end, { desc = "Project errors view" })

local function short_display_path(path)
  local normalized = vim.fn.fnamemodify(path, ":p")
  local app_path = normalized:match(".*/(app/.*)")
  if app_path then
    return app_path
  end

  local cwd = vim.fn.getcwd():gsub("/$", "")
  if normalized:sub(1, #cwd + 1) == cwd .. "/" then
    return normalized:sub(#cwd + 2)
  end

  return vim.fn.fnamemodify(path, ":~:.")
end

-- Keep generated fuzzy candidates unique without NUL bytes; Vim's
-- matchfuzzy/matchfuzzypos stop matching strings containing \0.
local fuzzy_candidate_separator = "\31"

local function compact_fuzzy_text(text)
  -- Make common separators optional for fuzzy matching, so queries like
  -- "flowcoll" match "flow_coll", "flow-coll", "flow.coll", etc.
  return vim.fn.substitute(vim.fn.tolower(tostring(text or "")), [=[\v[^[:alnum:]]+]=], "", "g")
end

local function fuzzy_filter_items(source_items, query, filter_item)
  query = query or ""
  if query == "" then
    return vim.list_slice(source_items)
  end

  filter_item = filter_item or tostring
  local query_l = query:lower()
  local compact_query = compact_fuzzy_text(query)
  local ranked = {}
  local fuzzy_candidates = {}
  local fuzzy_index_by_line = {}

  for i, item in ipairs(source_items) do
    local filter_line = tostring(filter_item(item))
    local lower_line = filter_line:lower()
    local compact_line = compact_fuzzy_text(filter_line)
    local pos = lower_line:find(query_l, 1, true)
    local compact_pos = compact_query ~= "" and compact_line:find(compact_query, 1, true) or nil

    if pos then
      table.insert(ranked, {
        index = i,
        score = 1000000 - (pos * 1000) - math.min(#filter_line, 999),
      })
    elseif compact_pos then
      table.insert(ranked, {
        index = i,
        score = 900000 - (compact_pos * 1000) - math.min(#filter_line, 999),
      })
    else
      local unique_line = lower_line .. " " .. compact_line .. fuzzy_candidate_separator .. tostring(i)
      table.insert(fuzzy_candidates, unique_line)
      fuzzy_index_by_line[unique_line] = i
    end
  end

  local fuzzy_query = compact_query ~= "" and compact_query or query_l
  local ok, fuzzy = pcall(vim.fn.matchfuzzypos, fuzzy_candidates, fuzzy_query)
  if ok and type(fuzzy) == "table" and type(fuzzy[1]) == "table" and type(fuzzy[3]) == "table" then
    for pos, line in ipairs(fuzzy[1]) do
      local index = fuzzy_index_by_line[line]
      if index then
        table.insert(ranked, {
          index = index,
          score = (tonumber(fuzzy[3][pos]) or 0) - 1000000,
        })
      end
    end
  else
    for rank, line in ipairs(vim.fn.matchfuzzy(fuzzy_candidates, fuzzy_query)) do
      local index = fuzzy_index_by_line[line]
      if index then
        table.insert(ranked, {
          index = index,
          score = -1000000 - rank,
        })
      end
    end
  end

  table.sort(ranked, function(a, b)
    if a.score == b.score then
      return a.index < b.index
    end
    return a.score > b.score
  end)

  local filtered = {}
  for _, match in ipairs(ranked) do
    table.insert(filtered, source_items[match.index])
  end
  return filtered
end

local floating_select
local open_file_symbol_dialog

-- Simple built-in fuzzy file picker
local function fuzzy_files()
  local include_ignored_hidden = false
  local files = {}

  local function load_files()
    local excluded_dirs = {
      ".git",
      "node_modules",
      "dist",
      "build",
      ".next",
      "coverage",
      ".venv",
      "target",
      "vendor",
      "pack/plugins",
    }

    -- Prefer Git's index in repositories. Unlike fd/rg, `git ls-files` does
    -- not hide tracked files that also match a .gitignore rule (common for Go
    -- command directories such as cmd/<name>/main.go).
    if not include_ignored_hidden and vim.fn.executable("git") == 1 then
      files = vim.fn.systemlist({ "git", "ls-files", "--cached", "--others", "--exclude-standard" })
      if vim.v.shell_error == 0 then
        return
      end
    end

    if vim.fn.executable("fd") == 1 then
      local cmd = { "fd", "--type", "f" }
      if include_ignored_hidden then
        vim.list_extend(cmd, { "--hidden", "--no-ignore" })
      end
      for _, dir in ipairs(excluded_dirs) do
        vim.list_extend(cmd, { "--exclude", dir })
      end
      files = vim.fn.systemlist(cmd)
    else
      local cmd = { "rg", "--files" }
      if include_ignored_hidden then
        vim.list_extend(cmd, { "--hidden", "--no-ignore" })
      end
      for _, dir in ipairs(excluded_dirs) do
        table.insert(cmd, "--glob")
        table.insert(cmd, "!" .. dir)
        table.insert(cmd, "--glob")
        table.insert(cmd, "!" .. dir .. "/**")
      end
      files = vim.fn.systemlist(cmd)
    end
  end

  load_files()

  if vim.v.shell_error ~= 0 or #files == 0 then
    vim.notify("No files found", vim.log.levels.WARN)
    return
  end

  local function file_display(path)
    local display_path = short_display_path(path)
    local name = vim.fn.fnamemodify(display_path, ":t")
    local dir = vim.fn.fnamemodify(display_path, ":h")
    if dir == "." or dir == "" then
      return name
    end
    return string.format("%-36s  %s", name, dir)
  end

  open_file_symbol_dialog(files, {
    prompt = "Find files",
    placeholder = "Search files...",
    width_ratio = 0.62,
    max_height = 24,
    line_parts = function(path)
      local display = file_display(path)
      local name = vim.fn.fnamemodify(short_display_path(path), ":t")
      local name_end = math.min(#name, #display)
      return display, {
        { start_col = 0, end_col = name_end, hl = "SymbolDialogName" },
        { start_col = name_end, end_col = #display, hl = "SymbolDialogMuted" },
      }
    end,
    filter_text = function(path)
      local display_path = short_display_path(path)
      local name = vim.fn.fnamemodify(display_path, ":t")
      return name .. " " .. display_path
    end,
    extra_keymaps = function(buf, picker)
      vim.keymap.set("n", "<M-i>", function()
        include_ignored_hidden = not include_ignored_hidden
        load_files()
        picker.set_items(files)
        vim.notify(include_ignored_hidden and "Including ignored and hidden files" or "Default file search", vim.log.levels.INFO)
      end, { buffer = buf, desc = "Toggle ignored/hidden files" })
    end,
  }, function(file)
    vim.cmd.edit(vim.fn.fnameescape(file))
  end)
end

vim.keymap.set("n", "<leader><leader>", fuzzy_files, { desc = "Fuzzy find files" })

local function fuzzy_buffers()
  local buffers = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].buflisted then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name == "" then
        name = "[No Name]"
      else
        name = vim.fn.fnamemodify(name, ":~:.")
      end
      table.insert(buffers, { bufnr = bufnr, name = name })
    end
  end

  if #buffers == 0 then
    vim.notify("No open buffers", vim.log.levels.WARN)
    return
  end

  open_file_symbol_dialog(buffers, {
    prompt = "Buffers",
    placeholder = "Search buffers...",
    width_ratio = 0.75,
    max_height = 18,
    line_parts = function(item)
      local number = tostring(item.bufnr)
      local line = string.format("%-5s  %s", number, item.name)
      return line, {
        { start_col = 0, end_col = #number, hl = "SymbolDialogMuted" },
        { start_col = 7, end_col = #line, hl = "SymbolDialogName" },
      }
    end,
    filter_text = function(item)
      return item.name .. " " .. tostring(item.bufnr)
    end,
  }, function(item)
    if vim.api.nvim_buf_is_valid(item.bufnr) then
      vim.cmd.buffer(item.bufnr)
    end
  end)
end

vim.keymap.set("n", "<leader>,", fuzzy_buffers, { desc = "Fuzzy find buffers" })

_G.nvim_keymap_search_groups = {
  {
    section = "Core",
    items = {
      { "<leader>s k", "Search keymaps" },
      { "<leader>", "Show leader shortcut menu" },
      { "<leader>w", "Toggle line wrap" },
      { "<leader>yy", "Copy current file and line location" },
      { "<leader>ya", "Paste current file and line location into active chat" },
      { "<C-s>", "Format current buffer and save all files" },
      { ":SaveAllWithFormat", "Format current buffer and save all files" },
      { "<Ctrl-h/j/k/l>", "Move focus left/down/up/right window" },
      { "[-b / ]-b", "Previous / next buffer" },
      { "00", "First non-blank character" },
      { "44", "End of line" },
      { "5", "Matching pair" },
      { "d0 / c0 / y0", "Delete / change / yank until first non-blank character" },
      { "d4 / c4 / y4", "Delete / change / yank until end of line" },
      { "d5 / c5 / y5", "Delete / change / yank until matching pair" },
      { "<leader>x", "Code actions list" },
      { "<leader>b d", "Close buffer" },
      { "<leader>b l", "Close buffers to the left" },
      { "<leader>b r", "Close buffers to the right" },
      { "<leader>b o", "Close other buffers" },
      { "<leader>q", "Quit window" },
      { "<Ctrl-t>", "Toggle bottom terminal" },
      { "<Alt-2>", "Focus file buffer" },
      { "<Alt-3>", "Focus DAP terminal" },
      { "<Alt-i>", "Increase selection at cursor" },
      { "<Shift-Alt-i>", "Decrease selection at cursor" },
      { "<Esc>", "Clear search highlight / leave terminal" },
      { "scrolloff=999", "Keep cursor vertically centered" },
    },
  },
  {
    section = "Terminal controls",
    items = {
      { "<Ctrl-t>", "Toggle bottom terminal" },
      { "<Esc>", "Terminal normal mode" },
      { "<Esc> in DAP term", "Focus file buffer" },
    },
  },
  {
    section = "Files + buffers",
    items = {
      { "<leader><leader>", "Find files" },
      { "<leader>,", "Find open buffers" },
      { "ff / fb", "Search word under cursor forward/backward" },
      { "s", "Jump to a visible word" },
      { "<leader>s s", "Search text in project" },
      { "<leader>s w", "Search word under cursor" },
      { "visual <leader>s w", "Search selection" },
      { "<leader>o / <leader>go", "Search symbols in project" },
      { "<leader>e", "Project errors view" },
      { "<leader>f", "Toggle file explorer" },
      { "<leader>gb", "Git blame current line" },
      { "<leader>gg", "Open lazygit" },
    },
  },
  {
    section = "Prompt picker controls",
    items = {
      { "Type", "Filter files/buffers/search results" },
      { "<Down> / <C-n>", "Next item" },
      { "<Up> / <C-p>", "Previous item" },
      { "<Enter>", "Open selected item" },
      { "<Alt-i>", "Find files: include ignored/hidden files" },
      { "<Esc>", "Close picker" },
    },
  },
  {
    section = "File explorer controls",
    items = {
      { "<Enter>", "Open file / enter directory" },
      { "o", "Open with system default application" },
      { "-", "Go up directory" },
      { "c", "Set current directory" },
      { "%", "Create file" },
      { "d", "Delete file/directory, asking first" },
      { "r", "Rename file/directory" },
      { "R", "Rename" },
      { "<Esc>", "Focus current file buffer" },
      { "D", "Delete" },
    },
  },
  {
    section = "LSP navigation",
    items = {
      { "gd", "Definitions view" },
      { "gD", "Declarations, jump if single" },
      { "gr", "References view" },
      { "ge", "Current file errors view" },
      { "gi", "Implementations, jump if single" },
      { "gt", "Type definitions, jump if single" },
      { "go", "File symbols in floating box" },
      { "<leader>o / <leader>go", "Project symbols in floating box" },
      { "winbar", "Shows current function signature" },
    },
  },
  {
    section = "Location view controls",
    items = {
      { "j / k", "Next / previous location" },
      { "Enter / e", "Open selected file" },
      { "o", "Open all result files as buffers" },
      { "q / <Esc>", "Close view" },
    },
  },
  {
    section = "LSP actions",
    items = {
      { "K / <leader>k", "Symbol info popup" },
      { "<leader>c r", "Rename symbol" },
      { "<leader>x", "Code actions list" },
      { "<leader>c c", "Type check project" },
      { "<leader>cf", "Format buffer" },
      { "]d", "Next diagnostic" },
      { "[d", "Previous diagnostic" },
      { "]e / ]-e", "Next error in file" },
      { "<C-e>", "Next error, then next diagnostic" },
      { "[e / [-e", "Previous error in file" },
      { "<leader>cl", "Line diagnostic" },
      { ":LspStatus", "Show active LSP clients" },
      { ":TypeScriptCheck", "Run tsc --noEmit into quickfix" },
      { ":TypescriptCheck", "Alias for :TypeScriptCheck" },
      { ":TscCheck", "Alias for :TypeScriptCheck" },
    },
  },
  {
    section = "Debugging",
    items = {
      { "<F2>", "Save all + select/start/continue/restart debugger" },
      { "<leader><F2>", "Stop debug session" },
      { "<S-F2>", "Select and run a JS/TS configuration" },
      { "<leader>rc", "Select and run a JS/TS configuration" },
      { "<leader>rr", "Restart running application" },
      { "<leader>rs", "Stop running application" },
      { "<leader>rk", "Kill running application" },
      { "<leader>rl", "Rerun last application" },
      { "<F3>", "Toggle scopes" },
      { "<S-F3>", "Toggle callstack" },
      { "<F4>", "Toggle debug REPL" },
      { "<F9>", "Toggle breakpoint" },
      { "<S-F9>", "Conditional breakpoint" },
      { "Up/Down/Right/Left", "Continue/over/into/out while debugging" },
      { "<leader>dc", "Select and start a debug configuration" },
      { "<leader>dd", "Restart active debugger" },
      { "<leader>db", "Toggle breakpoint" },
      { "<leader>dB", "Conditional breakpoint" },
      { "<leader>dp", "Log point" },
      { "<leader>di", "Step into" },
      { "<leader>do", "Step over" },
      { "<leader>dO", "Step out" },
      { "<leader>dr", "Open REPL" },
      { "<leader>dl", "Run last debug session" },
      { "<leader>dt", "Terminate session" },
      { "<leader>dh", "Hover value" },
      { "<leader>de", "Evaluate expression (selection in visual mode)" },
      { "<leader>dy", "Copy runtime value to clipboard" },
      { ":DapValue {expression}", "Evaluate expression in a popup" },
      { "<leader>ds", "Show scopes" },
      { ":DapInstallJsDebug", "Install JS/TS debug adapter" },
      { ":DapJsDebugInstallLog", "Show JS/TS adapter install log" },
    },
  },
  {
    section = "Floating select boxes",
    items = {
      { "j / <Down> / <C-n>", "Next item" },
      { "k / <Up> / <C-p>", "Previous item" },
      { "PgUp/PgDn", "Move one page" },
      { "<C-d>/<C-u>", "Move half page" },
      { "/", "Open narrow input when typing is not direct" },
      { "type", "Code actions/symbol boxes: filter visible items directly" },
      { "<BS>/<Del>/<C-h>", "Remove filter character" },
      { "<C-w>", "Remove filter word" },
      { "<Tab>", "Toggle all symbols in file-symbol box" },
      { "<Enter>", "Select item" },
      { "q", "Close box when typing is not direct" },
      { "<Esc>", "Close box" },
    },
  },
  {
    section = "Floating inputs",
    items = {
      { "<Enter>", "Confirm input" },
      { "<Esc> / <C-c>", "Cancel input" },
    },
  },
  {
    section = "Agent",
    items = {
      { "<leader>aa", "Agent: toggle chats (open at last active chat)" },
      { "<leader>as", "Agent: manage presets and choose default" },
      { "<leader>ai", "Implementation prompt with default preset (background)" },
      { "<leader>at", "Implement todo with default preset (background)" },
      { "<leader>ae", "Fix error with default preset (background)" },
      { "<C-p>/<C-n>", "In chat: previous / next chat (Ctrl-n past last creates new)" },
      { "<C-g>", "In chat: hide all chats" },
      { "<C-d>", "In chat: delete chat" },
    },
  },
}

_G.nvim_keymap_search_dialog = function()
  local items = {}
  for _, group in ipairs(_G.nvim_keymap_search_groups) do
    for _, item in ipairs(group.items) do
      table.insert(items, {
        section = group.section,
        keys = item[1],
        desc = item[2],
      })
    end
  end

  open_file_symbol_dialog(items, {
    prompt = "Keymaps",
    placeholder = "Search keymaps...",
    width_ratio = 0.86,
    line_parts = function(item)
      local line = string.format("%-22s  %-24s  %s", item.section, item.keys, item.desc)
      return line, {
        { start_col = 0, end_col = 22, hl = "SymbolDialogKind" },
        { start_col = 24, end_col = 48, hl = "SymbolDialogName" },
        { start_col = 50, end_col = #line, hl = "SymbolDialogDetail" },
      }
    end,
    filter_text = function(item)
      return table.concat({ item.section, item.keys, item.desc }, " ")
    end,
  }, function(item)
    vim.notify(item.keys .. "  " .. item.desc, vim.log.levels.INFO)
  end)
end

vim.keymap.set("n", "<leader>sk", _G.nvim_keymap_search_dialog, { desc = "Search keymaps" })

-- Lightweight which-key style popup for configured key prefixes.
-- Press <leader>, g, or s to browse shortcuts available in the current buffer.
local which_key = {
  namespace = vim.api.nvim_create_namespace("leader_which_key"),
  win = nil,
  buf = nil,
  group_desc = {
    [" a"] = "Agent",
    [" as"] = "Agent selectors",
    [" b"] = "Buffers",
    [" c"] = "Code / LSP",
    [" d"] = "Debug",
    [" g"] = "Git / views",
    [" r"] = "Run",
    [" s"] = "Search",
  },
}

local function which_key_close()
  if which_key.win and vim.api.nvim_win_is_valid(which_key.win) then
    vim.api.nvim_win_close(which_key.win, true)
  end
  if which_key.buf and vim.api.nvim_buf_is_valid(which_key.buf) then
    pcall(vim.api.nvim_buf_delete, which_key.buf, { force = true })
  end
  which_key.win = nil
  which_key.buf = nil
end

local function which_key_tokenize(lhs)
  lhs = lhs:gsub("<[Ll]eader>", vim.g.mapleader or " ")
  lhs = lhs:gsub("<[Ll]ocal[Ll]eader>", vim.g.maplocalleader or " ")

  local tokens = {}
  local i = 1
  while i <= #lhs do
    local char = lhs:sub(i, i)
    if char == "<" then
      local close = lhs:find(">", i, true)
      if close then
        table.insert(tokens, lhs:sub(i, close))
        i = close + 1
      else
        table.insert(tokens, char)
        i = i + 1
      end
    else
      table.insert(tokens, char)
      i = i + 1
    end
  end
  return tokens
end

local function which_key_token_label(token)
  if token == " " then
    return "<Space>"
  end
  return token
end

local function which_key_prefix_label(tokens)
  local labels = {}
  for i, token in ipairs(tokens) do
    if i == 1 and token == (vim.g.mapleader or " ") then
      table.insert(labels, "<leader>")
    else
      table.insert(labels, which_key_token_label(token))
    end
  end
  return table.concat(labels, " ")
end

local function which_key_same_prefix(tokens, prefix)
  if #tokens <= #prefix then
    return false
  end
  for i, token in ipairs(prefix) do
    if tokens[i] ~= token then
      return false
    end
  end
  return true
end

local function which_key_collect(prefix)
  local maps = {}

  local function add_maps(source)
    for _, map in ipairs(source) do
      if map.lhs and not (map.desc or ""):match("^which%-key") then
        table.insert(maps, {
          tokens = which_key_tokenize(map.lhs),
          desc = map.desc or map.rhs or "Mapped key",
        })
      end
    end
  end

  add_maps(vim.api.nvim_get_keymap("n"))
  local ok, buf_maps = pcall(vim.api.nvim_buf_get_keymap, 0, "n")
  if ok then
    add_maps(buf_maps)
  end

  local grouped = {}
  for _, map in ipairs(maps) do
    if which_key_same_prefix(map.tokens, prefix) then
      local next_key = map.tokens[#prefix + 1]
      local label = which_key_token_label(next_key)
      grouped[label] = grouped[label] or { key = label, direct = nil, more = false }

      if #map.tokens == #prefix + 1 then
        grouped[label].direct = grouped[label].direct or map.desc
      else
        grouped[label].more = true
      end
    end
  end

  local rows = {}
  for _, row in pairs(grouped) do
    if row.more and row.direct then
      row.desc = row.direct .. "  (+ more)"
    elseif row.more then
      local tokens = vim.deepcopy(prefix)
      table.insert(tokens, row.key == "<Space>" and " " or row.key)
      row.desc = which_key.group_desc[table.concat(tokens, "")] or "+ group"
    else
      row.desc = row.direct or ""
    end
    table.insert(rows, row)
  end

  table.sort(rows, function(a, b)
    if a.desc ~= b.desc then
      return a.desc < b.desc
    end
    return a.key < b.key
  end)
  return rows
end

local function which_key_show(prefix)
  local rows = which_key_collect(prefix)
  if #rows == 0 then
    which_key_close()
    return
  end

  apply_picker_highlights()
  which_key_close()

  local lines = { "Prefix: " .. which_key_prefix_label(prefix), "" }
  local key_width = 1
  for _, row in ipairs(rows) do
    key_width = math.max(key_width, vim.fn.strdisplaywidth(row.key))
  end
  for _, row in ipairs(rows) do
    table.insert(lines, string.format("  %-" .. key_width .. "s  %s", row.key, row.desc))
  end

  local content_width = 0
  for _, line in ipairs(lines) do
    content_width = math.max(content_width, vim.fn.strdisplaywidth(line))
  end
  local width = math.min(math.max(content_width + 2, 32), math.max(vim.o.columns - 4, 20))
  local height = math.min(#lines, math.max(vim.o.lines - 4, 1))
  local row = vim.o.lines - height - vim.o.cmdheight - 2
  local col = vim.o.columns - width - 2

  which_key.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[which_key.buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(which_key.buf, 0, -1, false, lines)
  vim.bo[which_key.buf].modifiable = false

  which_key.win = vim.api.nvim_open_win(which_key.buf, false, {
    relative = "editor",
    row = math.max(row, 0),
    col = math.max(col, 0),
    width = width,
    height = height,
    border = "rounded",
    title = " Which key ",
    title_pos = "center",
    style = "minimal",
  })
  vim.wo[which_key.win].number = false
  vim.wo[which_key.win].relativenumber = false
  vim.wo[which_key.win].signcolumn = "no"
  vim.wo[which_key.win].winhighlight = "Normal:PiPickerNormal,FloatBorder:PiPickerBorder,FloatTitle:PiPickerTitle"

  vim.api.nvim_buf_add_highlight(which_key.buf, which_key.namespace, "PiPickerTitle", 0, 0, -1)
  vim.cmd.redraw()
end

local function which_key_tokens_equal(a, b)
  if #a ~= #b then
    return false
  end
  for i, token in ipairs(a) do
    if token ~= b[i] then
      return false
    end
  end
  return true
end

local function which_key_find_exact(tokens)
  local function find_in(maps)
    for _, map in ipairs(maps) do
      if map.lhs and not (map.desc or ""):match("^which%-key") then
        if which_key_tokens_equal(which_key_tokenize(map.lhs), tokens) then
          return map
        end
      end
    end
  end

  local ok, buf_maps = pcall(vim.api.nvim_buf_get_keymap, 0, "n")
  if ok then
    local map = find_in(buf_maps)
    if map then
      return map
    end
  end
  return find_in(vim.api.nvim_get_keymap("n"))
end

local function which_key_execute_map(map)
  if map.callback then
    map.callback()
    return
  end
  if map.rhs then
    local keys = vim.api.nvim_replace_termcodes(map.rhs, true, false, true)
    vim.api.nvim_feedkeys(keys, "m", false)
  end
end

local function which_key_getchar_token()
  local ok, key = pcall(vim.fn.getcharstr)
  if not ok or not key then
    return nil
  end

  local token = vim.fn.keytrans(key)
  if token == "<Space>" then
    return " "
  end
  return token
end

local function which_key_prompt(initial_prefix, fallback)
  local prefix = vim.deepcopy(initial_prefix)

  while true do
    which_key_show(prefix)

    local token = which_key_getchar_token()
    if not token or token == "<Esc>" or token == "<C-c>" then
      which_key_close()
      return
    end

    table.insert(prefix, token)

    local exact = which_key_find_exact(prefix)
    if exact then
      which_key_close()
      which_key_execute_map(exact)
      return
    end

    if #which_key_collect(prefix) == 0 then
      which_key_close()
      if fallback then
        fallback(prefix)
      end
      return
    end
  end
end

local function which_key_feed_native(tokens)
  local keys = vim.api.nvim_replace_termcodes(table.concat(tokens, ""), true, false, true)
  vim.api.nvim_feedkeys(keys, "n", false)
end

vim.keymap.set("n", "<leader>", function()
  which_key_prompt({ vim.g.mapleader or " " })
end, {
  desc = "which-key leader prefix",
  nowait = true,
  silent = true,
})

-- Built-in LSP support for JS/TS and Go
local function floating_input(opts, on_confirm)
  opts = opts or {}
  apply_picker_highlights()

  local width = math.min(72, math.max(44, vim.o.columns - 8))
  local row = math.floor((vim.o.lines - 3) / 2)
  local col = math.floor((vim.o.columns - width) / 2)
  local default = opts.default or ""

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { default })
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = 1,
    border = "rounded",
    title = " " .. (opts.prompt or "Input") .. " ",
    title_pos = "center",
    style = "minimal",
  })

  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].winhighlight = "Normal:PiPickerNormal,FloatBorder:PiPickerBorder,FloatTitle:PiPickerTitle"

  local done = false
  local function finish(value)
    if done then return end
    done = true
    pcall(vim.cmd.stopinsert)
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if on_confirm then
      on_confirm(value)
    end
  end

  local function submit()
    finish(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or "")
  end

  local function cancel()
    finish(nil)
  end

  if opts.on_change then
    local function changed()
      opts.on_change(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or "")
    end
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
      buffer = buf,
      callback = changed,
    })
  end

  vim.keymap.set({ "i", "n" }, "<cr>", submit, { buffer = buf })
  vim.keymap.set({ "i", "n" }, "<esc>", cancel, { buffer = buf })
  vim.keymap.set({ "i", "n" }, "<c-c>", cancel, { buffer = buf })

  local default_chars = vim.fn.strchars(default)
  local cursor_col = default_chars > 0 and vim.str_byteindex(default, default_chars - 1) or 0
  vim.api.nvim_win_set_cursor(win, { 1, cursor_col })
  if default_chars > 0 then
    vim.cmd("startinsert!")
  else
    vim.cmd.startinsert()
  end
end

vim.ui.input = floating_input

local function floating_popup_options(opts)
  opts = vim.tbl_extend("force", {}, opts or {})
  local width_cap = opts.width_cap or 96
  local height_cap = opts.height_cap or 24
  local width_ratio = opts.width_ratio or 0.78
  local height_ratio = opts.height_ratio or 0.55
  opts.width_cap = nil
  opts.height_cap = nil
  opts.width_ratio = nil
  opts.height_ratio = nil
  opts.border = opts.border or "rounded"
  opts.max_width = opts.max_width or math.max(24, math.min(width_cap, math.floor(vim.o.columns * width_ratio)))
  opts.max_height = opts.max_height or math.max(4, math.min(height_cap, math.floor(vim.o.lines * height_ratio)))
  return opts
end

local function apply_floating_winhighlight(win)
  if win and vim.api.nvim_win_is_valid(win) then
    vim.wo[win].winhighlight = "Normal:PiPickerNormal,FloatBorder:PiPickerBorder,FloatTitle:PiPickerTitle"
  end
end

local function configure_dap_hover_view(view)
  if not view then return end
  apply_floating_winhighlight(view.win)
  if view.buf and vim.api.nvim_buf_is_valid(view.buf) then
    vim.keymap.set("n", "<Esc>", function()
      view.close()
    end, { buffer = view.buf, nowait = true, silent = true, desc = "Close debug value" })
  end
end

local function lsp_hover_popup()
  apply_picker_highlights()
  local ok_dap, dap = pcall(require, "dap")
  if ok_dap and dap.session() ~= nil then
    local ok_widgets, widgets = pcall(require, "dap.ui.widgets")
    if ok_widgets then
      local view = widgets.hover(nil, {
        border = "rounded",
        title = " Debug value ",
      })
      configure_dap_hover_view(view)
      return
    end
  end
  vim.lsp.buf.hover(floating_popup_options({
    title = " Symbol info ",
  }))
end

vim.lsp.handlers["textDocument/hover"] = function(err, result, ctx, config)
  config = vim.tbl_deep_extend("force", config or {}, floating_popup_options())
  return vim.lsp.handlers.hover(err, result, ctx, config)
end

vim.lsp.handlers["textDocument/signatureHelp"] = function(err, result, ctx, config)
  config = vim.tbl_deep_extend("force", config or {}, floating_popup_options({
    height_cap = 12,
    height_ratio = 0.35,
  }))
  return vim.lsp.handlers.signature_help(err, result, ctx, config)
end

-- Keep routine LSP chatter out of the command line. Server info/log messages
-- are often emitted while opening buffers and otherwise cause hit-enter prompts.
vim.lsp.handlers["window/showMessage"] = function(_, result, ctx)
  if not result or result.type == 3 or result.type == 4 then
    return
  end

  local client = ctx and ctx.client_id and vim.lsp.get_client_by_id(ctx.client_id)
  local prefix = client and (client.name .. ": ") or "LSP: "
  local message = prefix .. tostring(result.message or "")
  message = message:gsub("%s+", " ")
  if #message > 160 then
    message = message:sub(1, 157) .. "..."
  end

  local level = result.type == 1 and vim.log.levels.ERROR or vim.log.levels.WARN
  vim.notify(message, level)
end

floating_select = function(items, opts, on_choice)
  opts = opts or {}
  if opts.direct_filter == nil then
    local prompt = tostring(opts.prompt or opts.title or ""):lower()
    opts.direct_filter = prompt:find("configuration", 1, true)
      or prompt:find("debug", 1, true)
      or prompt:find("run", 1, true)
      or prompt:find("pick", 1, true)
  end
  if not items or #items == 0 then
    vim.notify("No items", vim.log.levels.INFO)
    return
  end

  apply_picker_highlights()

  local format_item = opts.format_item or tostring
  local filter_item = opts.filter_text or opts.filter_item or format_item
  local source_items = items
  local source_raw_lines = {}
  local source_filter_lines = {}
  local source_lower_lines = {}
  local source_compact_lines = {}
  local filter_query = ""
  local raw_lines = {}
  local function rebuild_source_lines()
    source_raw_lines = {}
    source_filter_lines = {}
    source_lower_lines = {}
    source_compact_lines = {}
    for i, item in ipairs(source_items) do
      local line = tostring(format_item(item))
      local filter_line = tostring(filter_item(item))
      source_raw_lines[i] = line
      source_filter_lines[i] = filter_line
      source_lower_lines[i] = filter_line:lower()
      source_compact_lines[i] = compact_fuzzy_text(filter_line)
    end
  end
  local function show_source_items()
    items = source_items
    raw_lines = source_raw_lines
  end
  rebuild_source_lines()
  show_source_items()

  local base_win = vim.api.nvim_get_current_win()
  local available_width = vim.api.nvim_win_get_width(base_win)
  local available_height = vim.api.nvim_win_get_height(base_win)
  local width = math.min(math.max(76, math.floor(available_width * 0.86)), available_width - 6)
  local max_height = math.max(8, math.floor(available_height * 0.68))
  local height = math.min(math.max(8, #raw_lines), max_height)
  local row = math.floor((available_height - height - 2) / 2)
  -- Floating windows positioned relative to a window already start at the text
  -- area, so center within that area. Subtracting the gutter pushes wide boxes
  -- too far left when line numbers/sign columns are visible.
  local col = math.max(0, math.floor((available_width - width) / 2))
  local selected = 1
  local top = 1
  local is_selectable = opts.is_selectable or function() return true end
  local title_prefix = opts.title or opts.prompt or "Select"
  local function picker_title()
    if filter_query ~= "" then
      return string.format(" %s  %d/%d item%s  filter: %s ", title_prefix, #items, #source_items, #items == 1 and "" or "s", filter_query)
    end
    return string.format(" %s  %d item%s ", title_prefix, #items, #items == 1 and "" or "s")
  end

  local function first_selectable_index()
    for i, item in ipairs(items) do
      if is_selectable(item, i) then
        return i
      end
    end
    return 1
  end

  local buf = vim.api.nvim_create_buf(false, true)
  local footer_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[footer_buf].modifiable = false
  vim.bo[footer_buf].bufhidden = "wipe"

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "win",
    win = base_win,
    row = row,
    col = col,
    width = width,
    height = height,
    border = "rounded",
    title = picker_title(),
    title_pos = "center",
    style = "minimal",
  })
  local footer_win = vim.api.nvim_open_win(footer_buf, false, {
    relative = "win",
    win = base_win,
    row = row + height + 1,
    col = col,
    width = width,
    height = 1,
    border = "rounded",
    style = "minimal",
  })

  for _, picker_win in ipairs({ win, footer_win }) do
    vim.wo[picker_win].number = false
    vim.wo[picker_win].relativenumber = false
    vim.wo[picker_win].signcolumn = "no"
    vim.wo[picker_win].winhighlight = "Normal:PiPickerNormal,FloatBorder:PiPickerBorder,FloatTitle:PiPickerTitle,CursorLine:PiPickerSelected"
  end
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false
  vim.wo[footer_win].winhighlight = "Normal:PiPickerMuted,FloatBorder:PiPickerBorder"

  local function fit(text)
    text = tostring(text):gsub("\t", "  ")
    if vim.fn.strdisplaywidth(text) <= width - 4 then
      return text
    end
    return vim.fn.strcharpart(text, 0, width - 6) .. "…"
  end

  local function render()
    local display = {}
    for i = 1, height do
      local index = top + i - 1
      if raw_lines[index] then
        display[i] = fit((index == selected and "▸ " or "  ") .. raw_lines[index])
      else
        display[i] = ""
      end
    end

    vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, display)
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

    vim.api.nvim_set_option_value("modifiable", true, { buf = footer_buf })
    local default_footer = opts.direct_filter
      and "  ↑/↓ move   PgUp/PgDn page   C-d/u half   type to narrow   Backspace erase   Enter open   Esc close"
      or "  ↑/↓ j/k move   PgUp/PgDn page   C-d/u half   / narrow   Enter open   q/Esc close"
    local footer = opts.footer or default_footer
    vim.api.nvim_buf_set_lines(footer_buf, 0, -1, false, { footer })
    vim.api.nvim_set_option_value("modifiable", false, { buf = footer_buf })

    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_set_config, win, { title = picker_title(), title_pos = "center" })
      vim.api.nvim_win_set_cursor(win, { selected - top + 1, 0 })
    end
  end

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if vim.api.nvim_win_is_valid(footer_win) then
      vim.api.nvim_win_close(footer_win, true)
    end
  end

  local function focus_index(index)
    selected = math.max(1, math.min(#items, index))
    if selected < top then
      top = selected
    elseif selected > top + height - 1 then
      top = selected - height + 1
    end
    render()
  end

  local function move(delta)
    if #items == 0 then return end
    local index = selected
    for _ = 1, #items do
      index = math.max(1, math.min(#items, index + delta))
      if is_selectable(items[index], index) then
        focus_index(index)
        return
      end
      if index == 1 or index == #items then
        return
      end
    end
  end

  local function move_page(delta, page_size)
    if #items == 0 then return end

    local step = delta > 0 and 1 or -1
    local page = math.max(1, page_size or height)
    local max_top = math.max(1, #items - height + 1)
    local row = selected - top
    local new_top = math.max(1, math.min(max_top, top + page * step))
    local target = new_top == top and (delta > 0 and #items or 1) or (new_top + row)
    target = math.max(1, math.min(#items, target))

    local page_min = new_top
    local page_max = math.min(#items, new_top + height - 1)
    local function selectable_near(index, direction)
      index = math.max(page_min, math.min(page_max, index))
      local cursor = index
      while cursor >= page_min and cursor <= page_max do
        if is_selectable(items[cursor], cursor) then
          return cursor
        end
        cursor = cursor + direction
      end
      cursor = index - direction
      while cursor >= page_min and cursor <= page_max do
        if is_selectable(items[cursor], cursor) then
          return cursor
        end
        cursor = cursor - direction
      end
    end

    local new_selected = selectable_near(target, step)
    if not new_selected then
      return
    end

    top = new_top
    selected = new_selected
    render()
  end

  local function apply_filter(query)
    filter_query = query or ""
    local query_l = filter_query:lower()
    local compact_query = compact_fuzzy_text(filter_query)
    if query_l == "" then
      show_source_items()
    else
      local ranked = {}
      local fuzzy_candidates = {}
      local fuzzy_index_by_line = {}
      for i, _ in ipairs(source_items) do
        local filter_line = source_filter_lines[i] or ""
        local lower_line = source_lower_lines[i] or ""
        local compact_line = source_compact_lines[i] or ""
        local pos = lower_line:find(query_l, 1, true)
        local compact_pos = compact_query ~= "" and compact_line:find(compact_query, 1, true) or nil
        if pos then
          table.insert(ranked, {
            index = i,
            score = 1000000 - (pos * 1000) - math.min(#filter_line, 999),
          })
        elseif compact_pos then
          table.insert(ranked, {
            index = i,
            score = 900000 - (compact_pos * 1000) - math.min(#filter_line, 999),
          })
        else
          local unique_line = lower_line .. " " .. compact_line .. fuzzy_candidate_separator .. tostring(i)
          table.insert(fuzzy_candidates, unique_line)
          fuzzy_index_by_line[unique_line] = i
        end
      end

      local fuzzy_query = compact_query ~= "" and compact_query or query_l
      local ok, fuzzy = pcall(vim.fn.matchfuzzypos, fuzzy_candidates, fuzzy_query)
      if ok and type(fuzzy) == "table" and type(fuzzy[1]) == "table" and type(fuzzy[3]) == "table" then
        for pos, line in ipairs(fuzzy[1]) do
          local index = fuzzy_index_by_line[line]
          if index then
            table.insert(ranked, {
              index = index,
              score = (tonumber(fuzzy[3][pos]) or 0) - 1000000,
            })
          end
        end
      else
        for rank, line in ipairs(vim.fn.matchfuzzy(fuzzy_candidates, fuzzy_query)) do
          local index = fuzzy_index_by_line[line]
          if index then
            table.insert(ranked, {
              index = index,
              score = -1000000 - rank,
            })
          end
        end
      end

      table.sort(ranked, function(a, b)
        if a.score == b.score then
          return a.index < b.index
        end
        return a.score > b.score
      end)

      local filtered = {}
      local filtered_lines = {}
      for _, match in ipairs(ranked) do
        table.insert(filtered, source_items[match.index])
        table.insert(filtered_lines, source_raw_lines[match.index] or "")
      end
      items = filtered
      raw_lines = filtered_lines
    end

    selected = 1
    top = 1
    selected = first_selectable_index()
    render()
  end

  local function narrow_picker()
    floating_input({
      prompt = "Narrow list",
      default = filter_query,
      on_change = apply_filter,
    }, function(query)
      if query ~= nil then
        apply_filter(query)
      end
    end)
  end

  local function choose()
    local item = items[selected]
    if not item or not is_selectable(item, selected) then
      move(1)
      return
    end
    close()
    on_choice(item, selected)
  end

  local function set_items(new_items)
    source_items = new_items or {}
    rebuild_source_lines()
    apply_filter(filter_query)
  end

  selected = first_selectable_index()
  render()
  vim.keymap.set("n", "<cr>", choose, { buffer = buf })
  if not opts.no_q_close then
    vim.keymap.set("n", "q", close, { buffer = buf })
  end
  vim.keymap.set("n", "<esc>", close, { buffer = buf })
  vim.keymap.set("n", "j", function() move(1) end, { buffer = buf })
  vim.keymap.set("n", "k", function() move(-1) end, { buffer = buf })
  vim.keymap.set("n", "<down>", function() move(1) end, { buffer = buf })
  vim.keymap.set("n", "<up>", function() move(-1) end, { buffer = buf })
  vim.keymap.set("n", "<c-n>", function() move(1) end, { buffer = buf })
  vim.keymap.set("n", "<c-p>", function() move(-1) end, { buffer = buf })
  for _, key in ipairs({ "<PageDown>", "<kPageDown>" }) do
    vim.keymap.set("n", key, function() move_page(1) end, { buffer = buf })
  end
  for _, key in ipairs({ "<PageUp>", "<kPageUp>" }) do
    vim.keymap.set("n", key, function() move_page(-1) end, { buffer = buf })
  end
  vim.keymap.set("n", "<C-d>", function() move_page(1, math.floor(height / 2)) end, { buffer = buf })
  vim.keymap.set("n", "<C-u>", function() move_page(-1, math.floor(height / 2)) end, { buffer = buf })
  if opts.direct_filter then
    local function append_filter(text)
      apply_filter(filter_query .. text)
    end
    local function remove_filter_char()
      if filter_query ~= "" then
        apply_filter(vim.fn.strcharpart(filter_query, 0, math.max(vim.fn.strchars(filter_query) - 1, 0)))
      end
    end
    local function remove_filter_word()
      if filter_query ~= "" then
        apply_filter((filter_query:gsub("%s*%S+$", "")))
      end
    end

    for code = string.byte("a"), string.byte("z") do
      local lower = string.char(code)
      local upper = lower:upper()
      vim.keymap.set("n", lower, function() append_filter(lower) end, { buffer = buf, nowait = true })
      vim.keymap.set("n", upper, function() append_filter(upper) end, { buffer = buf, nowait = true })
    end
    for code = string.byte("0"), string.byte("9") do
      local digit = string.char(code)
      vim.keymap.set("n", digit, function() append_filter(digit) end, { buffer = buf, nowait = true })
    end
    for _, key in ipairs({ "<space>", "-", "_", ".", ":", "/", "\\", "(", ")", "[", "]", "{", "}", "@", "+", "#", "," }) do
      local char = key == "<space>" and " " or key
      vim.keymap.set("n", key, function() append_filter(char) end, { buffer = buf, nowait = true })
    end
    vim.keymap.set("n", "<bs>", remove_filter_char, { buffer = buf, nowait = true })
    vim.keymap.set("n", "<del>", remove_filter_char, { buffer = buf, nowait = true })
    vim.keymap.set("n", "<c-h>", remove_filter_char, { buffer = buf, nowait = true })
    vim.keymap.set("n", "<c-w>", remove_filter_word, { buffer = buf, nowait = true })
  else
    vim.keymap.set("n", "/", narrow_picker, { buffer = buf })
  end
  if opts.extra_keymaps then
    opts.extra_keymaps(buf, { set_items = set_items, render = render, close = close })
  end
end

local function jump_to_location_item(item)
  vim.cmd("normal! m'")
  vim.cmd.edit(vim.fn.fnameescape(item.filename))
  vim.api.nvim_win_set_cursor(0, { item.lnum, math.max(item.col - 1, 0) })
  vim.cmd.normal({ "zz", bang = true })
end

local function project_grep(query)
  query = vim.trim(query or "")
  if query == "" then
    vim.notify("No search text", vim.log.levels.INFO)
    return
  end

  if vim.fn.executable("rg") ~= 1 then
    vim.notify("ripgrep (rg) not found", vim.log.levels.ERROR)
    return
  end

  local lines = vim.fn.systemlist({
    "rg",
    "--vimgrep",
    "--smart-case",
    "--hidden",
    "--glob",
    "!.git",
    "--fixed-strings",
    "--",
    query,
  })

  if vim.v.shell_error > 1 then
    vim.notify(table.concat(lines, "\n"), vim.log.levels.ERROR)
    return
  end

  local items = {}
  for _, line in ipairs(lines) do
    local filename, lnum, col, text = line:match("^(.-):(%d+):(%d+):(.*)$")
    if filename and lnum and col then
      table.insert(items, {
        filename = vim.fn.fnamemodify(filename, ":p"),
        lnum = tonumber(lnum),
        col = tonumber(col),
        text = text,
      })
    end
  end

  if #items == 0 then
    vim.notify("No matches for " .. query, vim.log.levels.INFO)
    return
  end

  references_view.search(items, query)
end

local function project_grep_prompt()
  floating_input({ prompt = "Search project" }, function(query)
    if query ~= nil then
      project_grep(query)
    end
  end)
end

local function visual_selection_text()
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local start_row, start_col = start_pos[2], start_pos[3]
  local end_row, end_col = end_pos[2], end_pos[3]

  if start_row > end_row or (start_row == end_row and start_col > end_col) then
    start_row, end_row = end_row, start_row
    start_col, end_col = end_col, start_col
  end

  local mode = vim.fn.visualmode()
  local text
  if mode == "V" then
    text = table.concat(vim.api.nvim_buf_get_lines(0, start_row - 1, end_row, false), "\n")
  else
    text = table.concat(vim.api.nvim_buf_get_text(0, start_row - 1, start_col - 1, end_row - 1, end_col, {}), "\n")
  end

  return vim.trim((text or ""):gsub("%s+", " "))
end

local function project_grep_word()
  local query = vim.fn.expand("<cword>")
  project_grep(query)
end

local function project_grep_selection()
  local query = visual_selection_text()
  project_grep(query)
end

vim.keymap.set("n", "<leader>ss", project_grep_prompt, { desc = "Search text in project" })
vim.keymap.set("n", "<leader>sw", project_grep_word, { desc = "Search word in project" })
vim.keymap.set("x", "<leader>sw", project_grep_selection, { desc = "Search selection in project" })
vim.keymap.set("n", "ff", "*", { desc = "Search word under cursor forward" })
vim.keymap.set("n", "fb", "#", { desc = "Search word under cursor backward" })

local function typescript_project_root()
  return vim.fs.root(0, { "tsconfig.json", "package.json", ".git" }) or vim.fn.getcwd()
end

local function typescript_check_command(root)
  local local_tsc = root .. "/node_modules/.bin/tsc"
  if vim.uv.fs_stat(local_tsc) then
    return { local_tsc, "--noEmit", "--pretty", "false" }
  end

  if vim.fn.executable("npx") == 1 then
    return { "npx", "--no-install", "tsc", "--noEmit", "--pretty", "false" }
  end

  if vim.fn.executable("tsc") == 1 then
    return { "tsc", "--noEmit", "--pretty", "false" }
  end

  return nil
end

local function parse_typescript_check_output(lines, root)
  local items = {}
  local last_item

  for _, line in ipairs(lines) do
    line = tostring(line or "")
    if line ~= "" then
      local filename, lnum, col, text = line:match("^(.-)%((%d+),(%d+)%):%s+(error TS%d+:%s+.*)$")
      if not filename then
        filename, lnum, col, text = line:match("^(.-):(%d+):(%d+):%s*(error TS%d+:%s+.*)$")
      end
      if filename then
        local full_path = filename
        if not full_path:match("^/") then
          full_path = root .. "/" .. full_path
        end
        last_item = {
          filename = vim.fn.fnamemodify(full_path, ":p"),
          lnum = tonumber(lnum) or 1,
          col = tonumber(col) or 1,
          text = text,
        }
        table.insert(items, last_item)
      elseif last_item and line:match("^%s+") then
        last_item.text = last_item.text .. " " .. vim.trim(line)
      elseif line:match("^error TS%d+:") then
        table.insert(items, { text = line, lnum = 1, col = 1 })
        last_item = nil
      end
    end
  end

  return items
end

local function typescript_check_project()
  local root = typescript_project_root()
  local command = typescript_check_command(root)
  if not command then
    vim.notify("TypeScript compiler not found. Install typescript locally, or add npx/tsc to PATH.", vim.log.levels.ERROR)
    return
  end

  vim.notify("Running TypeScript check...", vim.log.levels.INFO)
  vim.fn.setqflist({}, "r", { title = "TypeScript check", items = {} })

  local output = {}
  local function collect(_, data)
    for _, line in ipairs(data or {}) do
      if line ~= "" then
        table.insert(output, line)
      end
    end
  end

  vim.fn.jobstart(command, {
    cwd = root,
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = collect,
    on_stderr = collect,
    on_exit = vim.schedule_wrap(function(_, code)
      local items = parse_typescript_check_output(output, root)
      vim.fn.setqflist({}, "r", {
        title = "TypeScript check",
        items = items,
      })

      if #items > 0 then
        vim.cmd("botright copen " .. math.min(12, math.max(4, #items)))
        vim.notify(string.format("TypeScript check found %d error%s", #items, #items == 1 and "" or "s"), vim.log.levels.ERROR)
      elseif code == 0 then
        pcall(vim.cmd.cclose)
        vim.notify("TypeScript check passed", vim.log.levels.INFO)
      else
        vim.cmd("botright copen 6")
        vim.fn.setqflist({}, "r", {
          title = "TypeScript check output",
          lines = output,
        })
        vim.notify("TypeScript check failed; raw output added to quickfix", vim.log.levels.ERROR)
      end
    end),
  })
end

vim.api.nvim_create_user_command("TypeScriptCheck", typescript_check_project, { desc = "Run tsc --noEmit and fill quickfix with errors" })
vim.api.nvim_create_user_command("TypescriptCheck", typescript_check_project, { desc = "Run tsc --noEmit and fill quickfix with errors" })
vim.api.nvim_create_user_command("TscCheck", typescript_check_project, { desc = "Run tsc --noEmit and fill quickfix with errors" })
vim.keymap.set("n", "<leader>cc", typescript_check_project, { desc = "Type check project" })

local function dedupe_location_items(items)
  local seen = {}
  local deduped = {}
  for _, item in ipairs(items) do
    if item.filename and item.lnum and item.col then
      local key = table.concat({ vim.fn.fnamemodify(item.filename, ":p"), item.lnum, item.col, item.text or "" }, "\0")
      if not seen[key] then
        seen[key] = true
        table.insert(deduped, item)
      end
    end
  end
  return deduped
end

local symbol_kind_names

local function workspace_symbol_to_location_item(symbol)
  local location = symbol and symbol.location
  local uri = location and (location.uri or location.targetUri)
  local range = location and (location.range or location.targetSelectionRange or location.targetRange)
  if not uri or not range then
    return nil
  end

  local start = range.start or {}
  local kind = symbol_kind_names and symbol_kind_names[symbol.kind] or "Symbol"
  local detail = symbol.containerName or symbol.detail or ""
  return {
    name = symbol.name or "[symbol]",
    detail = detail,
    kind = kind,
    filename = vim.uri_to_fname(uri),
    lnum = (start.line or 0) + 1,
    col = (start.character or 0) + 1,
    text = table.concat(vim.tbl_filter(function(part) return part ~= "" end, { kind, symbol.name or "", detail }), "  "),
  }
end

symbol_kind_names = {
  [1] = "File",
  [2] = "Module",
  [3] = "Namespace",
  [4] = "Package",
  [5] = "Class",
  [6] = "Method",
  [7] = "Property",
  [8] = "Field",
  [9] = "Constructor",
  [10] = "Enum",
  [11] = "Interface",
  [12] = "Function",
  [13] = "Variable",
  [14] = "Constant",
  [15] = "String",
  [16] = "Number",
  [17] = "Boolean",
  [18] = "Array",
  [19] = "Object",
  [20] = "Key",
  [21] = "Null",
  [22] = "EnumMember",
  [23] = "Struct",
  [24] = "Event",
  [25] = "Operator",
  [26] = "TypeParameter",
}

local function_context_symbols = {}
local function_context_pending = {}
local function_context_ticks = {}

local function is_context_symbol(kind)
  return kind == 5 or kind == 6 or kind == 9 or kind == 11 or kind == 12 or kind == 23
end

local function range_contains_position(range, line, character)
  if not range or not range.start or not range["end"] then
    return false
  end

  local start_line = range.start.line or 0
  local start_char = range.start.character or 0
  local end_line = range["end"].line or start_line
  local end_char = range["end"].character or 0

  if line < start_line or line > end_line then
    return false
  end
  if line == start_line and character < start_char then
    return false
  end
  if line == end_line and character > end_char then
    return false
  end
  return true
end

local function compact_signature(text)
  text = (text or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  local brace = text:find("%s{%s*")
  if brace then
    text = text:sub(1, brace - 1)
  end
  local arrow = text:find("%s=>%s")
  if arrow then
    text = text:sub(1, arrow - 1)
  end
  text = text:gsub("%s+$", "")
  if vim.fn.strdisplaywidth(text) > 110 then
    text = vim.fn.strcharpart(text, 0, 107) .. "..."
  end
  return text
end

local function signature_line_span(buf, symbol)
  local range = symbol.declaration_range or symbol.range
  if not range or not range.start then
    return nil, nil, nil
  end

  local start_line = range.start.line
  local max_line = math.min((range["end"] and range["end"].line or start_line), start_line + 12)
  local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, start_line, max_line + 1, false)
  if not ok or not lines or #lines == 0 then
    return nil, nil, nil
  end

  local end_line = start_line
  for index, line_text in ipairs(lines) do
    end_line = start_line + index - 1
    if line_text:find("{")
      or line_text:find("=>")
      or line_text:find(":%s*$")
      or line_text:find("%)%s*[,;]?$")
      or line_text:find("%)%s*[:%-][^{}=>]*[,;]?$")
      or line_text:find("%)%s+[%w_%*%[%]%.]+%s*[,;]?$")
    then
      break
    end
  end

  local signature_lines = vim.list_slice(lines, 1, end_line - start_line + 1)
  return start_line, end_line, signature_lines
end

local function declaration_signature(buf, symbol)
  local _, _, lines = signature_line_span(buf, symbol)
  if not lines or #lines == 0 then
    return nil
  end

  local text = compact_signature(table.concat(lines, " "))
  if text == "" or not text:find(symbol.name or "", 1, true) then
    return nil
  end
  return text
end

local function symbol_signature(buf, symbol)
  local label = declaration_signature(buf, symbol) or (symbol.name or "[symbol]")

  if label == symbol.name and symbol.detail and symbol.detail ~= "" then
    if symbol.detail:sub(1, 1) == "(" or symbol.detail:sub(1, 1) == ":" then
      label = label .. symbol.detail
    else
      label = label .. " " .. symbol.detail
    end
  end

  local parents = {}
  local parent = symbol.parent
  while parent do
    table.insert(parents, 1, parent.name or "[symbol]")
    parent = parent.parent
  end

  label = compact_signature(label)
  if #parents > 0 then
    label = table.concat(parents, " › ") .. " › " .. label
  end
  return label
end

local treesitter_function_nodes = {
  arrow_function = true,
  function_declaration = true,
  function_definition = true,
  function_expression = true,
  generator_function_declaration = true,
  method_declaration = true,
  method_definition = true,
}

local treesitter_parent_context_nodes = {
  class_declaration = true,
  class_definition = true,
  interface_declaration = true,
  struct_declaration = true,
}

local function node_range(node)
  local start_line, start_col, end_line, end_col = node:range()
  return {
    start = { line = start_line, character = start_col },
    ["end"] = { line = end_line, character = end_col },
  }
end

local function node_text(buf, node)
  local ok, text = pcall(vim.treesitter.get_node_text, node, buf)
  return ok and text or ""
end

local function named_field_text(buf, node, fields)
  for _, field in ipairs(fields) do
    local nodes = node:field(field)
    if nodes and nodes[1] then
      local text = node_text(buf, nodes[1])
      if text ~= "" then
        return text
      end
    end
  end
  return nil
end

local function treesitter_node_name(buf, node)
  local direct = named_field_text(buf, node, { "name", "property", "key" })
  if direct then
    return direct
  end

  local parent = node:parent()
  if parent and (node:type() == "arrow_function" or node:type() == "function_expression") then
    local parent_name = named_field_text(buf, parent, { "name", "property", "key" })
    if parent_name then
      return parent_name
    end
  end

  return node:type():gsub("_", " ")
end

local function treesitter_declaration_node(node)
  local declaration = node
  local parent = node:parent()

  if node:type() == "arrow_function" or node:type() == "function_expression" then
    if parent and (parent:type() == "variable_declarator" or parent:type() == "pair" or parent:type() == "assignment_expression") then
      declaration = parent
      local grandparent = parent:parent()
      if grandparent and (grandparent:type() == "lexical_declaration" or grandparent:type() == "variable_declaration") then
        declaration = grandparent
      end
    end
  end

  local declaration_parent = declaration:parent()
  if declaration_parent and declaration_parent:type() == "export_statement" then
    declaration = declaration_parent
  end

  return declaration
end

local function treesitter_parent_chain(buf, node)
  local chain = {}
  local parent = node:parent()
  while parent do
    local type_name = parent:type()
    if treesitter_parent_context_nodes[type_name] then
      table.insert(chain, 1, {
        name = treesitter_node_name(buf, parent),
        range = node_range(parent),
        declaration_range = node_range(treesitter_declaration_node(parent)),
      })
    elseif treesitter_function_nodes[type_name] then
      table.insert(chain, 1, {
        name = treesitter_node_name(buf, parent),
        range = node_range(parent),
        declaration_range = node_range(treesitter_declaration_node(parent)),
      })
    end
    parent = parent:parent()
  end

  local previous
  for _, item in ipairs(chain) do
    item.parent = previous
    previous = item
  end
  return previous
end

local function treesitter_current_context_symbol(buf, line, character)
  local ok, parser = pcall(vim.treesitter.get_parser, buf)
  if not ok or not parser then
    return nil
  end
  pcall(function() parser:parse() end)

  local ok_node, node = pcall(vim.treesitter.get_node, {
    bufnr = buf,
    pos = { line, character },
    ignore_injections = true,
  })
  if not ok_node then
    return nil
  end

  while node do
    if treesitter_function_nodes[node:type()] then
      return {
        name = treesitter_node_name(buf, node),
        range = node_range(node),
        declaration_range = node_range(treesitter_declaration_node(node)),
        parent = treesitter_parent_chain(buf, node),
      }
    end
    node = node:parent()
  end

  return nil
end

-- Custom text objects and function motions (treesitter based) ---------------
-- af/if function, aa/ia argument, ai/ii indentation, [f/]f jump function.

local treesitter_argument_list_nodes = {
  arguments = true,
  argument_list = true,
  formal_parameters = true,
  parameters = true,
  parameter_list = true,
  parameter_declaration_list = true,
  tuple = true,
}

local function textobject_node_at_cursor(buf)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local ok, node = pcall(vim.treesitter.get_node, {
    bufnr = buf,
    pos = { cursor[1] - 1, cursor[2] },
  })
  if not ok then
    return nil
  end
  return node
end

local function select_range_linewise(start_row, end_row)
  pcall(vim.cmd, "normal! \27")
  vim.api.nvim_win_set_cursor(0, { start_row + 1, 0 })
  vim.cmd("normal! V")
  vim.api.nvim_win_set_cursor(0, { end_row + 1, 0 })
end

-- Function -------------------------------------------------------------------

local function textobject_find_function(node)
  while node do
    if treesitter_function_nodes[node:type()] then
      return node
    end
    node = node:parent()
  end
  return nil
end

local function textobject_function(buf, inside)
  local node = textobject_find_function(textobject_node_at_cursor(buf))
  if not node then
    return
  end

  if inside then
    local body = node:field("body")[1]
    if not body then
      return
    end
    local start_row, _, end_row = body:range()
    -- Drop the enclosing braces so we select only the body lines.
    local inner_start = start_row + 1
    local inner_end = end_row - 1
    if inner_end < inner_start then
      -- Single-line body: fall back to selecting the body line itself.
      select_range_linewise(start_row, end_row)
      return
    end
    select_range_linewise(inner_start, inner_end)
    return
  end

  local declaration = treesitter_declaration_node(node)
  local start_row, _, end_row = declaration:range()
  select_range_linewise(start_row, end_row)
end

-- Argument -------------------------------------------------------------------

local function textobject_find_argument(node)
  while node do
    local parent = node:parent()
    if parent and treesitter_argument_list_nodes[parent:type()] and node:named() then
      return node
    end
    node = parent
  end
  return nil
end

local function textobject_argument(buf, inside)
  local arg = textobject_find_argument(textobject_node_at_cursor(buf))
  if not arg then
    return
  end

  local start_row, start_col, end_row, end_col = arg:range()

  if not inside then
    local next_sibling = arg:next_sibling()
    if next_sibling and next_sibling:type() == "," then
      -- Swallow the trailing comma and whitespace up to the next argument.
      local after = next_sibling:next_sibling()
      if after then
        end_row, end_col = after:range()
      else
        local _, _, cr, cc = next_sibling:range()
        end_row, end_col = cr, cc
      end
    else
      local prev_sibling = arg:prev_sibling()
      if prev_sibling and prev_sibling:type() == "," then
        start_row, start_col = prev_sibling:range()
      end
    end
  end

  select_buffer_range(buf, { start_row, start_col, end_row, end_col })
end

-- Indentation ----------------------------------------------------------------

local function textobject_line_indent(buf, row)
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
  if not line then
    return nil, true
  end
  if line:match("^%s*$") then
    return nil, true
  end
  return #(line:match("^%s*")), false
end

-- Does the block continue past a run of blank lines starting at `row`, in the
-- given direction, at or above `base` indentation?
local function textobject_block_continues(buf, row, step, base, line_count)
  while row >= 0 and row < line_count do
    local indent, blank = textobject_line_indent(buf, row)
    if blank then
      row = row + step
    else
      return indent >= base
    end
  end
  return false
end

local function textobject_indentation(buf, inside)
  local line_count = vim.api.nvim_buf_line_count(buf)
  local base_row = vim.api.nvim_win_get_cursor(0)[1] - 1

  local indent, blank = textobject_line_indent(buf, base_row)
  if blank then
    local row = base_row
    while row < line_count do
      indent, blank = textobject_line_indent(buf, row)
      if not blank then
        base_row = row
        break
      end
      row = row + 1
    end
    if blank then
      return
    end
  end

  local base = indent
  local top = base_row
  while top > 0 do
    local i, b = textobject_line_indent(buf, top - 1)
    if b then
      if textobject_block_continues(buf, top - 2, -1, base, line_count) then
        top = top - 1
      else
        break
      end
    elseif i >= base then
      top = top - 1
    else
      break
    end
  end

  local bottom = base_row
  while bottom < line_count - 1 do
    local i, b = textobject_line_indent(buf, bottom + 1)
    if b then
      if textobject_block_continues(buf, bottom + 2, 1, base, line_count) then
        bottom = bottom + 1
      else
        break
      end
    elseif i >= base then
      bottom = bottom + 1
    else
      break
    end
  end

  if not inside and top > 0 then
    -- Around: include the header line that opens the block.
    local _, header_blank = textobject_line_indent(buf, top - 1)
    if not header_blank then
      top = top - 1
    end
  end

  select_range_linewise(top, bottom)
end

vim.keymap.set({ "x", "o" }, "af", function()
  textobject_function(vim.api.nvim_get_current_buf(), false)
end, { desc = "Around function" })
vim.keymap.set({ "x", "o" }, "if", function()
  textobject_function(vim.api.nvim_get_current_buf(), true)
end, { desc = "Inside function" })
vim.keymap.set({ "x", "o" }, "aa", function()
  textobject_argument(vim.api.nvim_get_current_buf(), false)
end, { desc = "Around argument" })
vim.keymap.set({ "x", "o" }, "ia", function()
  textobject_argument(vim.api.nvim_get_current_buf(), true)
end, { desc = "Inside argument" })
vim.keymap.set({ "x", "o" }, "ai", function()
  textobject_indentation(vim.api.nvim_get_current_buf(), false)
end, { desc = "Around indentation" })
vim.keymap.set({ "x", "o" }, "ii", function()
  textobject_indentation(vim.api.nvim_get_current_buf(), true)
end, { desc = "Inside indentation" })

-- Function motions -----------------------------------------------------------

local function textobject_function_starts(buf)
  local ok, parser = pcall(vim.treesitter.get_parser, buf)
  if not ok or not parser then
    return {}
  end
  local ok_parse, trees = pcall(function()
    return parser:parse()
  end)
  if not ok_parse or not trees then
    return {}
  end

  local starts = {}
  local function walk(node)
    if treesitter_function_nodes[node:type()] then
      local sr, sc = node:range()
      table.insert(starts, { sr, sc })
    end
    for child in node:iter_children() do
      walk(child)
    end
  end
  for _, tree in ipairs(trees) do
    walk(tree:root())
  end

  table.sort(starts, function(a, b)
    if a[1] == b[1] then
      return a[2] < b[2]
    end
    return a[1] < b[1]
  end)
  return starts
end

local function textobject_goto_function(forward)
  local buf = vim.api.nvim_get_current_buf()
  local starts = textobject_function_starts(buf)
  if #starts == 0 then
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local row, col = cursor[1] - 1, cursor[2]
  local target
  if forward then
    for _, pos in ipairs(starts) do
      if pos[1] > row or (pos[1] == row and pos[2] > col) then
        target = pos
        break
      end
    end
  else
    for i = #starts, 1, -1 do
      local pos = starts[i]
      if pos[1] < row or (pos[1] == row and pos[2] < col) then
        target = pos
        break
      end
    end
  end

  if target then
    vim.api.nvim_win_set_cursor(0, { target[1] + 1, target[2] })
  end
end

vim.keymap.set({ "n", "x", "o" }, "]f", function()
  textobject_goto_function(true)
end, { desc = "Next function" })
vim.keymap.set({ "n", "x", "o" }, "[f", function()
  textobject_goto_function(false)
end, { desc = "Previous function" })
vim.keymap.set({ "n", "x", "o" }, "<C-f>", function()
  textobject_goto_function(true)
end, { desc = "Next function" })
vim.keymap.set({ "n", "x", "o" }, "<C-b>", function()
  textobject_goto_function(false)
end, { desc = "Previous function" })

local refresh_function_context_winbar

local function update_function_context_symbols(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if function_context_pending[buf] or not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "" then
    return
  end

  local params = { textDocument = vim.lsp.util.make_text_document_params(buf) }
  function_context_pending[buf] = true
  vim.lsp.buf_request_all(buf, "textDocument/documentSymbol", params, function(responses)
    function_context_pending[buf] = nil
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end

    local symbols = {}
    local function add_symbol(symbol, parent)
      local range = symbol.range or symbol.selectionRange or (symbol.location and symbol.location.range)
      local selection_range = symbol.selectionRange or range
      if range and is_context_symbol(symbol.kind) then
        local item = {
          name = symbol.name or "[symbol]",
          detail = symbol.detail or "",
          kind = symbol.kind,
          range = range,
          selection_range = selection_range,
          declaration_range = symbol.range or range,
          parent = parent,
        }
        table.insert(symbols, item)
        parent = item
      end
      for _, child in ipairs(symbol.children or {}) do
        add_symbol(child, parent)
      end
    end

    for _, response in pairs(responses or {}) do
      for _, symbol in ipairs(response.result or {}) do
        add_symbol(symbol, nil)
      end
    end

    function_context_symbols[buf] = symbols
    function_context_ticks[buf] = vim.api.nvim_buf_get_changedtick(buf)

    if refresh_function_context_winbar then
      for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        refresh_function_context_winbar(win)
      end
    end
  end)
end

local function current_function_context()
  local buf = vim.api.nvim_get_current_buf()
  if vim.bo[buf].buftype ~= "" then
    return ""
  end

  if function_context_ticks[buf] ~= vim.api.nvim_buf_get_changedtick(buf) then
    update_function_context_symbols(buf)
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = cursor[1] - 1
  local character = cursor[2]
  local best

  for _, symbol in ipairs(function_context_symbols[buf] or {}) do
    if range_contains_position(symbol.range, line, character) then
      if not best or range_contains_position(best.range, symbol.range.start.line, symbol.range.start.character or 0) then
        best = symbol
      end
    end
  end

  if not best then
    best = treesitter_current_context_symbol(buf, line, character)
  end

  if not best then
    return ""
  end

  local start_line = signature_line_span(buf, best)
  local signature_start = start_line or (best.declaration_range and best.declaration_range.start and best.declaration_range.start.line) or (best.range and best.range.start and best.range.start.line)
  local jump_hint = ""
  if signature_start then
    local distance = math.abs(line - signature_start)
    local direction = line >= signature_start and "k" or "j"
    jump_hint = "%#FunctionContextWinbarLine#  " .. tostring(distance) .. direction .. "  "
  end

  local text = symbol_signature(buf, best):gsub("%%", "%%%%")
  return jump_hint .. "%#FunctionContextWinbar#" .. text
end

_G.NvimCurrentFunctionContext = current_function_context

refresh_function_context_winbar = function(win)
  win = win or vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(win) then
    return
  end

  local ok, context = pcall(vim.api.nvim_win_call, win, current_function_context)
  vim.wo[win].winbar = (ok and context and context ~= "") and context or ""
end

-- Never runs while typing: no TextChangedI/CursorMovedI here. Symbol requests
-- and the treesitter fallback parse are too costly per keystroke; the winbar
-- stays slightly stale during insert and catches up on InsertLeave.
vim.api.nvim_create_autocmd({ "BufEnter", "TextChanged", "InsertLeave", "LspAttach", "CursorMoved", "WinScrolled" }, {
  group = vim.api.nvim_create_augroup("FunctionContextWinbar", { clear = true }),
  callback = function(event)
    if vim.api.nvim_get_mode().mode:find("i") then
      return
    end
    if event.event ~= "CursorMoved" and event.event ~= "WinScrolled" then
      update_function_context_symbols(event.buf)
    end
    refresh_function_context_winbar(vim.api.nvim_get_current_win())
  end,
})

local function import_statement_finished(statement_lines)
  local text = table.concat(statement_lines, " ")
  local opens = select(2, text:gsub("{", ""))
  local closes = select(2, text:gsub("}", ""))
  if opens > closes then
    return false
  end
  if text:find(";", 1, true) then
    return true
  end
  if text:match("^%s*import%s+['\"][^'\"]+['\"]") then
    return true
  end
  return text:match("%f[%w]from%f[%W]%s*['\"][^'\"]+['\"]") ~= nil
end

local function import_offset_to_position(statement_lines, start_lnum, offset)
  local line_start = 1
  for index, line in ipairs(statement_lines) do
    local line_end = line_start + #line
    if offset <= line_end then
      return start_lnum + index - 1, offset - line_start + 1
    end
    line_start = line_end + 1
  end
  return start_lnum, 1
end

local function find_matching_import_brace(text, open_pos, limit)
  local depth = 0
  for pos = open_pos, limit or #text do
    local char = text:sub(pos, pos)
    if char == "{" then
      depth = depth + 1
    elseif char == "}" then
      depth = depth - 1
      if depth == 0 then
        return pos
      end
    end
  end
end

local function collect_import_symbol_items(filename)
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local items = {}
  local seen = {}
  local ident_pattern = "([%a_$][%w_$]*)"

  local function add_item(name, source, statement_lines, start_lnum, offset)
    if not name or name == "" then
      return
    end
    local lnum, col = import_offset_to_position(statement_lines, start_lnum, offset)
    local key = lnum .. ":" .. col .. ":" .. name
    if seen[key] then
      return
    end
    seen[key] = true
    table.insert(items, {
      name = name,
      detail = source and ('from "' .. source .. '"') or "",
      kind = "Import",
      depth = 0,
      filename = filename,
      lnum = lnum,
      col = col,
    })
  end

  local function parse_statement(statement_lines, start_lnum)
    local text = table.concat(statement_lines, "\n")
    local _, import_end = text:find("^%s*import%f[%W]")
    if not import_end then
      return
    end

    local source = text:match("%f[%w]from%f[%W]%s*['\"]([^'\"]+)['\"]")
      or text:match("^%s*import%s+['\"]([^'\"]+)['\"]")
    local from_start = text:find("%f[%w]from%f[%W]%s*['\"][^'\"]+['\"]") or (#text + 1)
    local spec_start = import_end + 1
    local spec_end = from_start - 1

    while spec_start <= spec_end and text:sub(spec_start, spec_start):match("%s") do
      spec_start = spec_start + 1
    end
    if text:sub(spec_start, spec_start):match("['\"]") then
      return
    end

    local type_start, type_end = text:find("type%f[%W]", spec_start)
    if type_start == spec_start then
      spec_start = type_end + 1
      while spec_start <= spec_end and text:sub(spec_start, spec_start):match("%s") do
        spec_start = spec_start + 1
      end
    end

    local spec = text:sub(spec_start, spec_end)
    local namespace_rel, namespace_name = spec:match("%*%s+as%s+()" .. ident_pattern)
    if namespace_rel then
      add_item(namespace_name, source, statement_lines, start_lnum, spec_start + namespace_rel - 1)
    end

    local default_limit = spec_end
    for _, delimiter in ipairs({ ",", "{", "*" }) do
      local delimiter_pos = text:find(delimiter, spec_start, true)
      if delimiter_pos and delimiter_pos - 1 < default_limit then
        default_limit = delimiter_pos - 1
      end
    end
    local default_chunk = text:sub(spec_start, default_limit)
    local default_rel, default_name = default_chunk:match("^%s*()" .. ident_pattern)
    if default_name and default_name ~= "type" then
      add_item(default_name, source, statement_lines, start_lnum, spec_start + default_rel - 1)
    end

    local brace_start = text:find("{", spec_start, true)
    if not brace_start or brace_start > spec_end then
      return
    end
    local brace_end = find_matching_import_brace(text, brace_start, spec_end)
    if not brace_end then
      return
    end

    local content_start = brace_start + 1
    local content = text:sub(content_start, brace_end - 1)
    local entry_start = 1
    while entry_start <= #content do
      local comma = content:find(",", entry_start, true) or (#content + 1)
      local entry = content:sub(entry_start, comma - 1)
      local entry_abs = content_start + entry_start - 1
      local alias_rel, alias_name = entry:match("%f[%w_]as%f[^%w_]%s+()" .. ident_pattern)
      if alias_name then
        add_item(alias_name, source, statement_lines, start_lnum, entry_abs + alias_rel - 1)
      else
        for name_rel, name in entry:gmatch("()" .. ident_pattern) do
          if name ~= "type" and name ~= "as" then
            add_item(name, source, statement_lines, start_lnum, entry_abs + name_rel - 1)
            break
          end
        end
      end
      entry_start = comma + 1
    end
  end

  local index = 1
  while index <= #lines do
    local line = lines[index]
    if line:match("^%s*import%f[%W]") and not line:match("^%s*import%s*[%(.]") then
      local start_lnum = index
      local statement_lines = { line }
      while index < #lines and not import_statement_finished(statement_lines) do
        index = index + 1
        table.insert(statement_lines, lines[index])
      end
      parse_statement(statement_lines, start_lnum)
    end
    index = index + 1
  end

  return items
end

local symbol_dialog_namespace = vim.api.nvim_create_namespace("file_symbol_dialog")

local function apply_symbol_dialog_highlights()
  apply_picker_highlights()
  vim.api.nvim_set_hl(0, "SymbolDialogPrompt", { link = "PiPickerMuted" })
  vim.api.nvim_set_hl(0, "SymbolDialogPromptText", { link = "PiPickerNormal" })
  vim.api.nvim_set_hl(0, "SymbolDialogSelected", { link = "PiPickerSelected" })
  vim.api.nvim_set_hl(0, "SymbolDialogKind", { link = "Type" })
  vim.api.nvim_set_hl(0, "SymbolDialogName", { link = "Identifier" })
  vim.api.nvim_set_hl(0, "SymbolDialogDetail", { link = "Normal" })
  vim.api.nvim_set_hl(0, "SymbolDialogMuted", { link = "Comment" })
end

local function file_symbol_kind_label(item)
  if item.kind == "Function" or item.kind == "Method" or item.kind == "Constructor" then
    return "func"
  end
  if item.kind == "Class" or item.kind == "Struct" or item.kind == "Interface" or item.kind == "Enum" or item.kind == "TypeParameter" then
    return "type"
  end
  if item.kind == "Constant" then
    return "const"
  end
  if item.kind == "Variable" then
    return "var"
  end
  if item.kind == "Import" then
    return "import"
  end
  if item.kind == "Module" or item.kind == "Package" or item.kind == "Namespace" then
    return item.kind:lower()
  end
  return ""
end

local function file_symbol_line_parts(item)
  local indent = string.rep("  ", item.depth or 0)
  local kind = file_symbol_kind_label(item)
  local detail = item.detail or ""
  local name = item.name or "[symbol]"
  local line = indent
  local marks = {}

  local function append(text, hl)
    if text == "" then
      return
    end
    local start_col = #line
    line = line .. text
    table.insert(marks, { start_col = start_col, end_col = #line, hl = hl })
  end

  if kind ~= "" then
    append(kind, "SymbolDialogKind")
    append(" ", "SymbolDialogDetail")
  end

  if item.kind == "Method" and detail:match("^%s*%(") then
    append(vim.trim(detail), "SymbolDialogDetail")
    append(" ", "SymbolDialogDetail")
    append(name, "SymbolDialogName")
  else
    append(name, "SymbolDialogName")
    if detail ~= "" and item.kind ~= "Field" and item.kind ~= "Property" then
      append(" " .. detail, "SymbolDialogDetail")
    end
  end

  return line, marks
end

open_file_symbol_dialog = function(source_items, opts, on_choice)
  opts = opts or {}
  apply_symbol_dialog_highlights()

  local line_parts = opts.line_parts or file_symbol_line_parts
  local filter_text = opts.filter_text or function(item)
    return table.concat(vim.tbl_filter(function(part) return part ~= "" end, {
      item.name or "",
      item.kind or "",
      item.detail or "",
      item.filename and short_display_path(item.filename) or "",
    }), " ")
  end
  local source_raw_lines = {}
  local source_marks = {}
  local source_filter_lines = {}
  local source_lower_lines = {}
  local source_compact_lines = {}
  local filter_query = ""
  local items = {}
  local raw_lines = {}
  local raw_marks = {}
  local filter_mode = true
  local completed = false

  local function rebuild_source_lines()
    source_raw_lines = {}
    source_marks = {}
    source_filter_lines = {}
    source_lower_lines = {}
    source_compact_lines = {}
    for i, item in ipairs(source_items or {}) do
      local line, marks = line_parts(item)
      local filter_line = tostring(filter_text(item))
      source_raw_lines[i] = line
      source_marks[i] = marks or {}
      source_filter_lines[i] = filter_line
      source_lower_lines[i] = filter_line:lower()
      source_compact_lines[i] = compact_fuzzy_text(filter_line)
    end
  end

  local function show_source_items()
    items = source_items or {}
    raw_lines = source_raw_lines
    raw_marks = source_marks
  end

  rebuild_source_lines()
  show_source_items()

  local base_win = vim.api.nvim_get_current_win()
  local available_width = vim.api.nvim_win_get_width(base_win)
  local available_height = vim.api.nvim_win_get_height(base_win)
  local width = math.min(math.max(opts.min_width or 58, math.floor(available_width * (opts.width_ratio or 0.58))), math.max(24, available_width - 8))
  local height = math.min(math.max(10, math.min(#raw_lines + 2, opts.max_height or 24)), math.max(6, available_height - 4))
  local row = math.max(0, math.floor((available_height - height - 2) / 2))
  local col = math.max(0, math.floor((available_width - width) / 2))
  local list_height = math.max(1, height - 2)
  local footer_text = opts.footer or "↑/↓ move   C-d/u half   / search   Backspace erase   Enter open   Esc unfocus   2x Esc close"
  local footer_lines = { "" }
  for _, entry in ipairs(vim.split(footer_text, "%s%s+", { trimempty = true })) do
    local separator = footer_lines[#footer_lines] == "" and "" or "   "
    if vim.fn.strdisplaywidth(footer_lines[#footer_lines] .. separator .. entry) <= width - 4 then
      footer_lines[#footer_lines] = footer_lines[#footer_lines] .. separator .. entry
    else
      table.insert(footer_lines, entry)
    end
  end
  for index, line in ipairs(footer_lines) do
    local padding = math.max(0, math.floor((width - vim.fn.strdisplaywidth(line)) / 2))
    footer_lines[index] = string.rep(" ", padding) .. line
  end
  local initial_index = tonumber(opts.initial_index) or 1
  local selected = #items > 0 and math.max(1, math.min(#items, initial_index)) or 0
  local top = math.max(1, selected - math.max(1, height - 2) + 1)

  local buf = vim.api.nvim_create_buf(false, true)
  local footer_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = vim.bo[0].filetype
  vim.bo[footer_buf].modifiable = false
  vim.bo[footer_buf].bufhidden = "wipe"

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "win",
    win = base_win,
    row = row,
    col = col,
    width = width,
    height = height,
    border = "rounded",
    style = "minimal",
  })
  local footer_win = vim.api.nvim_open_win(footer_buf, false, {
    relative = "win",
    win = base_win,
    row = row + height + 1,
    col = col,
    width = width,
    height = #footer_lines,
    border = "rounded",
    style = "minimal",
  })
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].cursorline = false
  vim.wo[win].wrap = false
  vim.wo[win].winhighlight = "Normal:PiPickerNormal,FloatBorder:PiPickerBorder"
  vim.wo[footer_win].number = false
  vim.wo[footer_win].relativenumber = false
  vim.wo[footer_win].signcolumn = "no"
  vim.wo[footer_win].wrap = false
  vim.wo[footer_win].winhighlight = "Normal:PiPickerMuted,FloatBorder:PiPickerBorder"

  local function fit(text)
    text = tostring(text):gsub("\t", "  ")
    if vim.fn.strdisplaywidth(text) <= width - 2 then
      return text
    end
    return vim.fn.strcharpart(text, 0, width - 4) .. "..."
  end

  local function render()
    local lines = {}
    lines[1] = filter_query == "" and (opts.placeholder or "Search...") or filter_query
    lines[2] = string.rep("─", width)
    for row_index = 1, list_height do
      local item_index = top + row_index - 1
      lines[row_index + 2] = raw_lines[item_index] and fit(raw_lines[item_index]) or ""
    end

    vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_buf_clear_namespace(buf, symbol_dialog_namespace, 0, -1)
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

    vim.api.nvim_set_option_value("modifiable", true, { buf = footer_buf })
    vim.api.nvim_buf_set_lines(footer_buf, 0, -1, false, footer_lines)
    vim.api.nvim_set_option_value("modifiable", false, { buf = footer_buf })

    vim.api.nvim_buf_set_extmark(buf, symbol_dialog_namespace, 0, 0, {
      line_hl_group = "SymbolDialogPrompt",
      end_col = #lines[1],
      hl_group = filter_query == "" and "SymbolDialogPrompt" or "SymbolDialogPromptText",
      priority = 90,
    })
    if not filter_mode then
      vim.api.nvim_buf_add_highlight(buf, symbol_dialog_namespace, "SymbolDialogMuted", 0, 0, -1)
    end
    vim.api.nvim_buf_add_highlight(buf, symbol_dialog_namespace, "SymbolDialogMuted", 1, 0, -1)

    for row_index = 1, list_height do
      local item_index = top + row_index - 1
      local line = lines[row_index + 2] or ""
      if item_index == selected then
        vim.api.nvim_buf_set_extmark(buf, symbol_dialog_namespace, row_index + 1, 0, {
          line_hl_group = "SymbolDialogSelected",
          priority = 80,
        })
      end
      for _, mark in ipairs(raw_marks[item_index] or {}) do
        if mark.start_col < #line then
          vim.api.nvim_buf_add_highlight(buf, symbol_dialog_namespace, mark.hl, row_index + 1, mark.start_col, math.min(mark.end_col, #line))
        end
      end
    end

    if vim.api.nvim_win_is_valid(win) then
      local cursor_row = selected > 0 and (selected - top + 3) or 1
      pcall(vim.api.nvim_win_set_cursor, win, { math.max(1, math.min(height, cursor_row)), 0 })
    end
  end

  local function close(is_choice)
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if vim.api.nvim_win_is_valid(footer_win) then
      vim.api.nvim_win_close(footer_win, true)
    end
    if not is_choice and not completed then
      completed = true
      if opts.on_close then
        opts.on_close()
      end
    end
  end

  local function focus_index(index)
    if #items == 0 then
      selected = 0
      top = 1
      render()
      return
    end
    selected = math.max(1, math.min(#items, index))
    if selected < top then
      top = selected
    elseif selected > top + list_height - 1 then
      top = selected - list_height + 1
    end
    render()
  end

  local function move(delta)
    if #items == 0 then
      return
    end
    focus_index(selected + delta)
  end

  local function apply_filter(query)
    filter_query = query or ""
    local query_l = filter_query:lower()
    local compact_query = compact_fuzzy_text(filter_query)
    if query_l == "" then
      show_source_items()
    elseif opts.preserve_order_on_filter then
      local included = {}
      local function matches_index(index)
        local lower_line = source_lower_lines[index] or ""
        local compact_line = source_compact_lines[index] or ""
        if lower_line:find(query_l, 1, true) then
          return true
        end
        if compact_query ~= "" and compact_line:find(compact_query, 1, true) then
          return true
        end
        return false
      end

      for index, item in ipairs(source_items or {}) do
        if matches_index(index) then
          included[index] = true
          local parent_index = item.parent_index
          while parent_index and source_items[parent_index] do
            included[parent_index] = true
            parent_index = source_items[parent_index].parent_index
          end
        end
      end

      items = {}
      raw_lines = {}
      raw_marks = {}
      for index, item in ipairs(source_items or {}) do
        if included[index] then
          table.insert(items, item)
          table.insert(raw_lines, source_raw_lines[index] or "")
          table.insert(raw_marks, source_marks[index] or {})
        end
      end
    else
      local ranked = {}
      local fuzzy_candidates = {}
      local fuzzy_index_by_line = {}
      for i, _ in ipairs(source_items or {}) do
        local filter_line = source_filter_lines[i] or ""
        local lower_line = source_lower_lines[i] or ""
        local compact_line = source_compact_lines[i] or ""
        local pos = lower_line:find(query_l, 1, true)
        local compact_pos = compact_query ~= "" and compact_line:find(compact_query, 1, true) or nil
        if pos then
          table.insert(ranked, { index = i, score = 1000000 - (pos * 1000) - math.min(#filter_line, 999) })
        elseif compact_pos then
          table.insert(ranked, { index = i, score = 900000 - (compact_pos * 1000) - math.min(#filter_line, 999) })
        else
          local unique_line = lower_line .. " " .. compact_line .. fuzzy_candidate_separator .. tostring(i)
          table.insert(fuzzy_candidates, unique_line)
          fuzzy_index_by_line[unique_line] = i
        end
      end

      local fuzzy_query = compact_query ~= "" and compact_query or query_l
      local ok, fuzzy = pcall(vim.fn.matchfuzzypos, fuzzy_candidates, fuzzy_query)
      if ok and type(fuzzy) == "table" and type(fuzzy[1]) == "table" and type(fuzzy[3]) == "table" then
        for pos, line in ipairs(fuzzy[1]) do
          local index = fuzzy_index_by_line[line]
          if index then
            table.insert(ranked, { index = index, score = (tonumber(fuzzy[3][pos]) or 0) - 1000000 })
          end
        end
      else
        for rank, line in ipairs(vim.fn.matchfuzzy(fuzzy_candidates, fuzzy_query)) do
          local index = fuzzy_index_by_line[line]
          if index then
            table.insert(ranked, { index = index, score = -1000000 - rank })
          end
        end
      end

      table.sort(ranked, function(a, b)
        return a.score == b.score and a.index < b.index or a.score > b.score
      end)

      items = {}
      raw_lines = {}
      raw_marks = {}
      for _, match in ipairs(ranked) do
        table.insert(items, source_items[match.index])
        table.insert(raw_lines, source_raw_lines[match.index] or "")
        table.insert(raw_marks, source_marks[match.index] or {})
      end
    end
    selected = #items > 0 and 1 or 0
    top = 1
    render()
  end

  local function choose()
    local item = selected > 0 and items[selected] or nil
    if not item then
      return
    end
    completed = true
    close(true)
    on_choice(item)
  end

  local function set_items(new_items)
    source_items = new_items or {}
    rebuild_source_lines()
    apply_filter(filter_query)
  end

  render()

  local map_opts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set("n", "<cr>", choose, map_opts)
  vim.keymap.set("n", "<esc>", function()
    if filter_mode then
      filter_mode = false
      render()
    else
      close()
    end
  end, map_opts)
  vim.keymap.set("n", "q", function()
    if filter_mode then
      apply_filter(filter_query .. "q")
    else
      close()
    end
  end, map_opts)
  vim.keymap.set("n", "<down>", function() move(1) end, map_opts)
  vim.keymap.set("n", "<up>", function() move(-1) end, map_opts)
  vim.keymap.set("n", "<c-n>", function() move(1) end, map_opts)
  vim.keymap.set("n", "<c-p>", function() move(-1) end, map_opts)
  vim.keymap.set("n", "<C-d>", function()
    if not filter_mode then
      move(math.max(1, math.floor(list_height / 2)))
    end
  end, map_opts)
  vim.keymap.set("n", "<C-u>", function()
    if not filter_mode then
      move(-math.max(1, math.floor(list_height / 2)))
    end
  end, map_opts)
  vim.keymap.set("n", "<bs>", function()
    if filter_query ~= "" then
      filter_mode = true
      apply_filter(vim.fn.strcharpart(filter_query, 0, math.max(vim.fn.strchars(filter_query) - 1, 0)))
    end
  end, map_opts)
  vim.keymap.set("n", "<del>", function()
    if filter_query ~= "" then
      filter_mode = true
      apply_filter(vim.fn.strcharpart(filter_query, 0, math.max(vim.fn.strchars(filter_query) - 1, 0)))
    end
  end, map_opts)
  vim.keymap.set("n", "<c-h>", function()
    if filter_query ~= "" then
      filter_mode = true
      apply_filter(vim.fn.strcharpart(filter_query, 0, math.max(vim.fn.strchars(filter_query) - 1, 0)))
    end
  end, map_opts)
  vim.keymap.set("n", "<c-w>", function()
    if filter_query ~= "" then
      filter_mode = true
      apply_filter((filter_query:gsub("%s*%S+$", "")))
    end
  end, map_opts)

  local function append_filter(text)
    filter_mode = true
    apply_filter(filter_query .. text)
  end
  for code = string.byte("a"), string.byte("z") do
    local lower = string.char(code)
    local upper = lower:upper()
    vim.keymap.set("n", lower, function()
      if not filter_mode and lower == "j" then
        move(1)
      elseif not filter_mode and lower == "k" then
        move(-1)
      elseif not filter_mode and lower == "q" then
        close()
      else
        append_filter(lower)
      end
    end, map_opts)
    vim.keymap.set("n", upper, function() append_filter(upper) end, map_opts)
  end
  for code = string.byte("0"), string.byte("9") do
    local digit = string.char(code)
    vim.keymap.set("n", digit, function() append_filter(digit) end, map_opts)
  end
  for _, key in ipairs({ "<space>", "-", "_", ".", ":", "/", "\\", "(", ")", "[", "]", "{", "}", "@", "+", "#", "," }) do
    local char = key == "<space>" and " " or key
    vim.keymap.set("n", key, function()
      if key == "/" and not filter_mode then
        filter_mode = true
        render()
      else
        append_filter(char)
      end
    end, map_opts)
  end

  if opts.extra_keymaps then
    opts.extra_keymaps(buf, { set_items = set_items, close = close, render = render })
  end
end

-- Adapter for callers that use Neovim's generic selection API. Keeping this
-- thin means file, symbol, and plugin-provided choices share one dialog UI.
local function searchable_ui_select(source_items, opts, on_choice)
  opts = opts or {}
  if not source_items or #source_items == 0 then
    on_choice(nil, nil)
    return
  end

  local format_item = opts.format_item or tostring
  local entries = {}
  for index, item in ipairs(source_items) do
    table.insert(entries, {
      value = item,
      original_index = index,
      display = tostring(format_item(item)),
    })
  end

  local prompt = vim.trim(tostring(opts.prompt or opts.title or "item"):gsub(":%s*$", ""))
  local placeholder = opts.placeholder or ("Search " .. prompt:lower() .. "...")
  open_file_symbol_dialog(entries, {
    placeholder = placeholder,
    width_ratio = opts.width_ratio,
    min_width = opts.min_width,
    max_height = opts.max_height,
    initial_index = opts.initial_index,
    footer = opts.footer,
    line_parts = function(entry)
      return entry.display, {
        { start_col = 0, end_col = #entry.display, hl = "SymbolDialogDetail" },
      }
    end,
    filter_text = function(entry)
      return entry.display
    end,
    on_close = function()
      on_choice(nil, nil)
    end,
    extra_keymaps = opts.extra_keymaps,
  }, function(entry)
    on_choice(entry.value, entry.original_index)
  end)
end

vim.ui.select = searchable_ui_select

local function lsp_document_symbols_picker()
  local params = { textDocument = vim.lsp.util.make_text_document_params(0) }

  vim.lsp.buf_request_all(0, "textDocument/documentSymbol", params, function(responses)
    local items = {}
    local filename = vim.api.nvim_buf_get_name(0)

    local function add_symbol(symbol, depth, parent_item)
      local range = symbol.selectionRange or symbol.range or (symbol.location and symbol.location.range)
      if not range then return end

      local item_filename = filename
      if symbol.location and symbol.location.uri then
        item_filename = vim.uri_to_fname(symbol.location.uri)
      end

      local item = {
        name = symbol.name or "[symbol]",
        detail = symbol.detail or "",
        kind = symbol_kind_names[symbol.kind] or "Symbol",
        depth = depth,
        parent_item = parent_item,
        filename = item_filename,
        lnum = range.start.line + 1,
        col = range.start.character + 1,
      }
      table.insert(items, item)

      for _, child in ipairs(symbol.children or {}) do
        add_symbol(child, depth + 1, item)
      end
    end

    for _, response in pairs(responses) do
      for _, symbol in ipairs(response.result or {}) do
        add_symbol(symbol, 0, nil)
      end
    end
    items = vim.tbl_filter(function(item)
      return item.kind ~= "Import"
    end, items)
    table.sort(items, function(a, b)
      if a.filename == b.filename then
        return a.lnum == b.lnum and a.col < b.col or a.lnum < b.lnum
      end
      return a.filename < b.filename
    end)
    local item_indexes = {}
    for index, item in ipairs(items) do
      item_indexes[item] = index
    end
    for _, item in ipairs(items) do
      item.parent_index = item.parent_item and item_indexes[item.parent_item] or nil
      item.parent_item = nil
    end

    if #items == 0 then
      vim.notify("No symbols found", vim.log.levels.INFO)
      return
    end

    local show_all_symbols = true
    local default_symbol_kinds = {
      Class = true,
      Constant = true,
      Function = true,
      Method = true,
      Interface = true,
      Struct = true,
      Variable = true,
    }
    local function visible_items()
      if show_all_symbols then
        return items
      end

      local filtered = {}
      for _, item in ipairs(items) do
        if item.depth == 0 and default_symbol_kinds[item.kind] then
          table.insert(filtered, item)
        end
      end
      return filtered
    end

    open_file_symbol_dialog(visible_items(), {
      prompt = "File symbols",
      placeholder = "Search buffer symbols...",
      extra_keymaps = function(buf, picker)
        vim.keymap.set("n", "<tab>", function()
          show_all_symbols = not show_all_symbols
          picker.set_items(visible_items())
          vim.notify(show_all_symbols and "Showing all symbols" or "Showing top-level imports/consts/vars/functions/classes", vim.log.levels.INFO)
        end, { buffer = buf, desc = "Toggle all symbols" })
      end,
    }, function(item)
      vim.cmd("normal! m'")
      vim.cmd.edit(vim.fn.fnameescape(item.filename))
      vim.api.nvim_win_set_cursor(0, { item.lnum, math.max(item.col - 1, 0) })
      vim.cmd.normal({ "zz", bang = true })
    end)
  end)
end

local function sort_project_symbol_items(items)
  table.sort(items, function(a, b)
    if a.name == b.name then
      if a.filename == b.filename then
        return a.lnum == b.lnum and a.col < b.col or a.lnum < b.lnum
      end
      return a.filename < b.filename
    end
    return a.name < b.name
  end)
end

local project_symbol_excluded_extensions = {
  css = true,
  html = true,
  ico = true,
  jpeg = true,
  jpg = true,
  json = true,
  lock = true,
  map = true,
  md = true,
  pdf = true,
  png = true,
  svg = true,
  toml = true,
  webp = true,
  xml = true,
  yaml = true,
  yml = true,
}

local function project_symbol_file_allowed(filename)
  local lower = tostring(filename or ""):lower()
  for part in lower:gmatch("[^/\\]+") do
    if part:sub(1, 1) == "." then
      return false
    end
    if part == "vendor" or part == "out" or part == "tmp" or part == "temp"
        or part == "generated" or part == "__generated__" then
      return false
    end
  end
  local basename = vim.fn.fnamemodify(lower, ":t")
  if lower:match("%.min%.js$")
      or lower:match("%.d%.ts$")
      or basename == "config.js"
      or basename == "schema.graphql"
      or basename:match("^tsconfig")
      or basename:match("%.generated%.")
      or basename:match("%.gen%.") then
    return false
  end
  local ext = vim.fn.fnamemodify(lower, ":e"):lower()
  return not project_symbol_excluded_extensions[ext]
end

local function open_project_symbol_items(items, source)
  items = vim.tbl_filter(function(item)
    return project_symbol_file_allowed(item.filename)
  end, items or {})
  items = dedupe_location_items(items)
  sort_project_symbol_items(items)

  if #items == 0 then
    vim.notify("No project symbols found", vim.log.levels.INFO)
    return
  end

  open_file_symbol_dialog(items, {
    prompt = source and ("Project symbols (" .. source .. ")") or "Project symbols",
    placeholder = "Search project symbols...",
    width_ratio = 0.68,
    max_height = 24,
    line_parts = function(item)
      local kind = file_symbol_kind_label(item)
      if kind == "" then
        kind = tostring(item.kind or "symbol"):lower()
      end
      local name = tostring(item.name or "[symbol]")
      local path = item.filename and string.format("  %s:%d:%d", short_display_path(item.filename), item.lnum or 1, item.col or 1) or ""
      local detail = (item.detail or "") ~= "" and ("  " .. item.detail) or ""
      local line = kind .. " " .. name .. path .. detail
      return line, {
        { start_col = 0, end_col = #kind, hl = "SymbolDialogKind" },
        { start_col = #kind + 1, end_col = #kind + 1 + #name, hl = "SymbolDialogName" },
        { start_col = #kind + 1 + #name, end_col = #line, hl = "SymbolDialogMuted" },
      }
    end,
    filter_text = function(item)
      return table.concat(vim.tbl_filter(function(part) return part ~= "" end, {
        item.name or "",
        item.kind or "",
        item.detail or "",
        item.filename and short_display_path(item.filename) or "",
      }), " ")
    end,
  }, function(item)
    jump_to_location_item(item)
  end)
end

local function lsp_workspace_symbols_picker_lsp()
  vim.notify("Loading project symbols from LSP...", vim.log.levels.INFO)
  vim.lsp.buf_request_all(0, "workspace/symbol", { query = "" }, function(responses)
    local items = {}
    for _, response in pairs(responses) do
      for _, symbol in ipairs(response.result or {}) do
        local item = workspace_symbol_to_location_item(symbol)
        if item then
          table.insert(items, item)
        end
      end
    end

    open_project_symbol_items(items, "LSP")
  end)
end

local function ctags_symbol_to_location_item(tag, root)
  if not tag or tag._type ~= "tag" or not tag.name or not tag.path or not tag.line then
    return nil
  end

  local path = tostring(tag.path)
  local filename = path:sub(1, 1) == "/" and path or (root .. "/" .. path)
  if not project_symbol_file_allowed(filename) then
    return nil
  end
  local kind = tostring(tag.kindName or tag.kind or "Symbol")
  kind = kind:gsub("^%l", string.upper)
  local detail = tostring(tag.scope or tag.scopeName or tag.typeref or "")

  return {
    name = tostring(tag.name),
    detail = detail,
    kind = kind,
    filename = filename,
    lnum = tonumber(tag.line) or 1,
    col = tonumber(tag.column) or 1,
    text = table.concat(vim.tbl_filter(function(part) return part ~= "" end, { kind, tostring(tag.name), detail }), "  "),
  }
end

local function lsp_workspace_symbols_picker_ctags()
  if vim.fn.executable("ctags") ~= 1 then
    return false
  end

  local root = vim.fs.root(0, { "package.json", "tsconfig.json", "jsconfig.json", "go.work", "go.mod", "compile_commands.json", "compile_flags.txt", "CMakeLists.txt", "Makefile", "makefile", ".git" }) or vim.fn.getcwd()
  local stdout = {}
  local stderr = {}
  local cmd = {
    "ctags",
    "--output-format=json",
    "--fields=+nK",
    "--extras=-q",
    "--exclude=.git",
    "--exclude=node_modules",
    "--exclude=dist",
    "--exclude=build",
    "--exclude=.next",
    "--exclude=coverage",
    "--exclude=.venv",
    -- Do not use `--exclude=.*`: Universal Ctags also matches the traversal
    -- root (`.`), which suppresses every tag. Hidden paths are filtered when
    -- the resulting location items are opened.
    "--exclude=target",
    "--exclude=vendor",
    "--exclude=out",
    "--exclude=tmp",
    "--exclude=temp",
    "--exclude=generated",
    "--exclude=__generated__",
    "--exclude=pack/plugins",
    "--exclude=*.css",
    "--exclude=*.html",
    "--exclude=*.json",
    "--exclude=*.md",
    "--exclude=*.min.js",
    "--exclude=*.d.ts",
    "--exclude=*.generated.*",
    "--exclude=*.gen.*",
    "--exclude=*.map",
    "--exclude=*.lock",
    "--exclude=*.yaml",
    "--exclude=*.yml",
    "--exclude=*.toml",
    "--exclude=*.xml",
    "--exclude=*.svg",
    "--exclude=*.png",
    "--exclude=*.jpg",
    "--exclude=*.jpeg",
    "--exclude=*.webp",
    "--exclude=*.ico",
    "--exclude=*.pdf",
    "--exclude=schema.graphql",
    "--exclude=config.js",
    "--exclude=*.log",
    "--exclude=tsconfig*",
    "-R",
    "-f",
    "-",
    ".",
  }

  vim.notify("Loading project symbols with ctags...", vim.log.levels.INFO)
  local job_id = vim.fn.jobstart(cmd, {
    cwd = root,
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      stdout = data or {}
    end,
    on_stderr = function(_, data)
      stderr = data or {}
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if code ~= 0 and #stdout == 0 then
          local message = table.concat(vim.tbl_filter(function(line) return line and line ~= "" end, stderr), " ")
          vim.notify("ctags project symbols failed" .. (message ~= "" and (": " .. message) or "; falling back to LSP"), vim.log.levels.WARN)
          lsp_workspace_symbols_picker_lsp()
          return
        end

        local items = {}
        for _, line in ipairs(stdout) do
          if line ~= "" then
            local ok, tag = pcall(vim.json.decode, line)
            if ok then
              local item = ctags_symbol_to_location_item(tag, root)
              if item then
                table.insert(items, item)
              end
            end
          end
        end

        if #items == 0 then
          lsp_workspace_symbols_picker_lsp()
          return
        end

        open_project_symbol_items(items, "ctags")
      end)
    end,
  })

  return job_id > 0
end

local function lsp_workspace_symbols_picker()
  if lsp_workspace_symbols_picker_ctags() then
    return
  end

  lsp_workspace_symbols_picker_lsp()
end

-- Keep project symbols available (and visible in which-key) even before an LSP
-- attaches. LspAttach may install a buffer-local version of the same mapping.
vim.keymap.set("n", "<leader>go", lsp_workspace_symbols_picker, { desc = "Project symbols" })

local function lsp_client_supports_method(client, method, bufnr)
  if client.supports_method then
    local ok, supported = pcall(client.supports_method, client, method, bufnr)
    if ok then
      return supported
    end

    ok, supported = pcall(client.supports_method, client, method)
    if ok then
      return supported
    end
  end

  local capabilities = client.server_capabilities or {}
  if method == "textDocument/codeAction" then
    return capabilities.codeActionProvider ~= nil
  end
  if method == "codeAction/resolve" then
    return type(capabilities.codeActionProvider) == "table" and capabilities.codeActionProvider.resolveProvider == true
  end
  return false
end

local function lsp_client_diagnostics(buf, client, lnum)
  local diagnostics = {}
  local seen = {}

  local function add_diagnostic(diagnostic)
    local lsp_diagnostic = diagnostic.user_data and diagnostic.user_data.lsp or diagnostic
    local key = vim.inspect(lsp_diagnostic.range or {}) .. "\0" .. tostring(lsp_diagnostic.message or "")
    if not seen[key] then
      seen[key] = true
      table.insert(diagnostics, lsp_diagnostic)
    end
  end

  local function diagnostics_from_namespace(namespace)
    local opts = { namespace = namespace }
    if lnum ~= nil then
      opts.lnum = lnum
    end
    for _, diagnostic in ipairs(vim.diagnostic.get(buf, opts)) do
      add_diagnostic(diagnostic)
    end
  end

  if vim.lsp.diagnostic and vim.lsp.diagnostic.get_namespace then
    diagnostics_from_namespace(vim.lsp.diagnostic.get_namespace(client.id))

    if client._provider_foreach then
      pcall(function()
        client:_provider_foreach("textDocument/diagnostic", function(capability)
          diagnostics_from_namespace(vim.lsp.diagnostic.get_namespace(client.id, true, capability.identifier))
        end)
      end)
    end
  end

  if #diagnostics == 0 then
    local opts = {}
    if lnum ~= nil then
      opts.lnum = lnum
    end
    for _, diagnostic in ipairs(vim.diagnostic.get(buf, opts)) do
      add_diagnostic(diagnostic)
    end
  end

  return diagnostics
end

local function code_action_title(action)
  local title = tostring(action.title or action.command or "[code action]")
      :gsub("\r\n", "\\r\\n")
      :gsub("\n", "\\n")
  if action.disabled then
    title = title .. " (disabled)"
  end
  return title
end

local function code_action_item_label(item)
  return code_action_title(item.action)
end

local function code_action_key(action, client_id)
  local command = action.command
  if type(command) == "table" then
    command = command.command
  end
  return table.concat({
    tostring(client_id),
    code_action_title(action),
    tostring(action.kind or ""),
    tostring(command or ""),
    action.data and vim.inspect(action.data) or "",
  }, "\0")
end

local function execute_lsp_command(client, command, ctx)
  if client.exec_cmd then
    client:exec_cmd(command, ctx)
    return
  end

  if client.commands and client.commands[command.command] then
    client.commands[command.command](command, ctx)
    return
  end

  client:request("workspace/executeCommand", command, function(err)
    if err then
      vim.notify("LSP command failed: " .. (err.message or tostring(err)), vim.log.levels.ERROR)
    end
  end, ctx.bufnr)
end

local function apply_lsp_code_action(item)
  if item.run then
    item.run()
    return
  end

  local client = vim.lsp.get_client_by_id(item.ctx.client_id)
  if not client then
    vim.notify("LSP client is no longer available", vim.log.levels.WARN)
    return
  end

  local function apply_action(action)
    if action.edit then
      vim.lsp.util.apply_workspace_edit(action.edit, client.offset_encoding or "utf-16")
    end

    local command = action.command
    if command then
      execute_lsp_command(client, type(command) == "table" and command or action, item.ctx)
    elseif not action.edit then
      vim.notify("Code action has no edit or command", vim.log.levels.INFO)
    end
  end

  local action = item.action
  if type(action.command) == "string" then
    apply_action(action)
    return
  end

  if action.disabled then
    vim.notify(action.disabled.reason or "Code action is disabled", vim.log.levels.ERROR)
    return
  end

  if not (action.edit and action.command) and lsp_client_supports_method(client, "codeAction/resolve", item.ctx.bufnr) then
    client:request("codeAction/resolve", action, function(err, resolved_action)
      if err then
        if action.edit or action.command then
          apply_action(action)
        else
          vim.notify("Could not resolve code action: " .. (err.message or tostring(err)), vim.log.levels.ERROR)
        end
        return
      end
      apply_action(resolved_action or action)
    end, item.ctx.bufnr)
    return
  end

  apply_action(action)
end

local function open_code_action_list_picker(actions)
  if #actions == 0 then
    vim.notify("No code actions available", vim.log.levels.INFO)
    return
  end

  table.sort(actions, function(a, b)
    return code_action_title(a.action):lower() < code_action_title(b.action):lower()
  end)

  open_file_symbol_dialog(actions, {
    prompt = "Code actions:",
    placeholder = "Search code actions...",
    line_parts = function(item)
      local line = code_action_item_label(item)
      return line, {
        { start_col = 0, end_col = #line, hl = "SymbolDialogDetail" },
      }
    end,
    filter_text = code_action_item_label,
  }, function(item)
    if not item then
      return
    end

    if item.ctx and item.ctx.bufnr and vim.api.nvim_buf_is_valid(item.ctx.bufnr) then
      local wins = vim.fn.win_findbuf(item.ctx.bufnr)
      if wins[1] and vim.api.nvim_win_is_valid(wins[1]) then
        vim.api.nvim_set_current_win(wins[1])
      end
    end

    apply_lsp_code_action(item)
  end)
end

local function lsp_code_actions_list()
  local buf = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  local get_clients = vim.lsp.get_clients or vim.lsp.get_active_clients
  local clients = vim.tbl_filter(function(client)
    return lsp_client_supports_method(client, "textDocument/codeAction", buf)
  end, get_clients({ bufnr = buf }))

  local actions = {}

  if #clients == 0 then
    open_code_action_list_picker(actions)
    return
  end

  local trigger_kind = vim.lsp.protocol.CodeActionTriggerKind and vim.lsp.protocol.CodeActionTriggerKind.Invoked or 1
  local cursor_lnum = vim.api.nvim_win_get_cursor(win)[1] - 1
  local pending = #clients * 2
  local seen = {}

  local function finish_one()
    pending = pending - 1
    if pending == 0 then
      open_code_action_list_picker(actions)
    end
  end

  local function add_action(action, client, scope, ctx)
    if not action then
      return
    end

    local key = code_action_key(action, client.id)
    local existing = seen[key]
    if existing then
      if not existing.scope:find(scope, 1, true) then
        existing.scope = existing.scope .. " + " .. scope
        existing.label = code_action_item_label(existing)
      end
      return
    end

    local item = {
      action = action,
      scope = scope,
      client_name = client.name,
      ctx = ctx,
    }
    item.label = code_action_item_label(item)
    seen[key] = item
    table.insert(actions, item)
  end

  local function request_actions(client, scope, only, diagnostic_lnum)
    local context = {
      diagnostics = lsp_client_diagnostics(buf, client, diagnostic_lnum),
      triggerKind = trigger_kind,
    }
    if only then
      context.only = only
    end

    local params = vim.lsp.util.make_range_params(win, client.offset_encoding or "utf-16")
    params.context = context

    local ctx = {
      bufnr = buf,
      client_id = client.id,
      method = "textDocument/codeAction",
    }

    local ok, request_id = pcall(client.request, client, "textDocument/codeAction", params, function(err, result)
      if not err then
        for _, action in ipairs(result or {}) do
          add_action(action, client, scope, ctx)
        end
      end
      finish_one()
    end, buf)

    if not ok or not request_id then
      finish_one()
    end
  end

  for _, client in ipairs(clients) do
    request_actions(client, "Cursor", nil, cursor_lnum)
    request_actions(client, "File/project", { "source" }, nil)
  end
end

local function diagnostic_float_options(opts)
  return floating_popup_options(vim.tbl_deep_extend("force", {
    title = " Diagnostics ",
    header = "",
    prefix = "● ",
    source = "if_many",
    focusable = false,
    close_events = { "BufLeave", "CursorMoved", "CursorMovedI", "InsertEnter", "FocusLost" },
    height_cap = 14,
    height_ratio = 0.38,
  }, opts or {}))
end

local function open_diagnostic_float(opts)
  apply_picker_highlights()
  local buf, win = vim.diagnostic.open_float(diagnostic_float_options(opts))
  apply_floating_winhighlight(win)
  return buf, win
end

vim.diagnostic.config({
  virtual_text = true,
  underline = true,
  signs = true,
  update_in_insert = false,
  float = diagnostic_float_options({ scope = "line" }),
})

-- Same-variable highlight: when the cursor rests on a symbol, highlight its
-- other occurrences like VS Code's word/document highlight.
;(function()
  local same_variable_group = vim.api.nvim_create_augroup("PiSameVariableHighlight", { clear = true })

  local function apply_same_variable_highlights()
    vim.api.nvim_set_hl(0, "PiSameWord", { link = "LspReferenceText" })
  end

  apply_same_variable_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = same_variable_group,
    callback = apply_same_variable_highlights,
  })

  local same_word_namespace = vim.api.nvim_create_namespace("pi_same_word")
  local same_word_last_buf
  local same_lsp_last_buf
  local same_variable_timer
  local same_variable_generation = 0
  local same_variable_last_key

  local function clear_same_word_highlight()
    if same_word_last_buf and vim.api.nvim_buf_is_valid(same_word_last_buf) then
      vim.api.nvim_buf_clear_namespace(same_word_last_buf, same_word_namespace, 0, -1)
    end
    same_word_last_buf = nil
  end

  local function lsp_client_supports_document_highlight(client, bufnr)
    if not client then
      return false
    end
    if client.supports_method then
      local ok, supported = pcall(client.supports_method, client, "textDocument/documentHighlight", bufnr)
      if ok then
        return supported
      end
      ok, supported = pcall(client.supports_method, client, "textDocument/documentHighlight")
      if ok then
        return supported
      end
    end
    return client.server_capabilities and client.server_capabilities.documentHighlightProvider ~= nil
  end

  local function document_highlight_clients(bufnr)
    local clients = {}
    local get_clients = vim.lsp.get_clients or vim.lsp.get_active_clients
    for _, client in ipairs(get_clients({ bufnr = bufnr })) do
      if lsp_client_supports_document_highlight(client, bufnr) then
        table.insert(clients, client)
      end
    end
    return clients
  end

  local function is_same_word_char(char)
    return char ~= "" and char:match("[%w_]") ~= nil
  end

  local function fallback_same_word_highlight(bufnr, win, word)
    if word == "" or not word:match("[%w_]") then
      return
    end

    local top = math.max(vim.fn.line("w0", win) - 1, 0)
    local bottom = math.min(vim.fn.line("w$", win) - 1, vim.api.nvim_buf_line_count(bufnr) - 1)
    local lines = vim.api.nvim_buf_get_lines(bufnr, top, bottom + 1, false)

    for i, line in ipairs(lines) do
      local lnum = top + i - 1
      local start_at = 1
      while true do
        local start_col, end_col = line:find(word, start_at, true)
        if not start_col then
          break
        end
        local before = line:sub(start_col - 1, start_col - 1)
        local after = line:sub(end_col + 1, end_col + 1)
        if not is_same_word_char(before) and not is_same_word_char(after) then
          vim.api.nvim_buf_set_extmark(bufnr, same_word_namespace, lnum, start_col - 1, {
            end_col = end_col,
            hl_group = "PiSameWord",
            priority = 150,
          })
        end
        start_at = end_col + 1
      end
    end

    same_word_last_buf = bufnr
  end

  local function cancel_same_variable_timer()
    if same_variable_timer then
      same_variable_timer:stop()
      same_variable_timer:close()
      same_variable_timer = nil
    end
  end

  local function clear_lsp_reference_highlight()
    -- No tracked highlight means nothing to clear; skip the LSP call so the
    -- CursorMovedI clear path stays free while typing.
    if not same_lsp_last_buf then
      return
    end
    if vim.api.nvim_buf_is_valid(same_lsp_last_buf) then
      pcall(vim.lsp.util.buf_clear_references, same_lsp_last_buf)
    end
    same_lsp_last_buf = nil
  end

  local function clear_same_variable_highlight()
    same_variable_generation = same_variable_generation + 1
    same_variable_last_key = nil
    cancel_same_variable_timer()
    clear_same_word_highlight()
    clear_lsp_reference_highlight()
  end

  local function apply_lsp_document_highlight(bufnr, win, clients)
    same_variable_generation = same_variable_generation + 1
    local generation = same_variable_generation
    local pending = #clients
    local responses = {}

    local function finish_one()
      pending = pending - 1
      if pending > 0 then
        return
      end
      vim.schedule(function()
        if generation ~= same_variable_generation or not vim.api.nvim_buf_is_valid(bufnr) then
          return
        end
        clear_same_word_highlight()
        clear_lsp_reference_highlight()
        for _, response in ipairs(responses) do
          pcall(vim.lsp.util.buf_highlight_references, bufnr, response.result, response.encoding)
        end
        if #responses > 0 then
          same_lsp_last_buf = bufnr
        end
      end)
    end

    for _, client in ipairs(clients) do
      local encoding = client.offset_encoding or "utf-16"
      local params = vim.lsp.util.make_position_params(win, encoding)
      local ok = pcall(client.request, client, "textDocument/documentHighlight", params, function(err, result)
        if generation ~= same_variable_generation then
          return
        end
        if not err and result and #result > 0 then
          table.insert(responses, { result = result, encoding = encoding })
        end
        finish_one()
      end, bufnr)
      if not ok then
        finish_one()
      end
    end
  end

  local function update_same_variable_highlight()
    if vim.fn.mode():sub(1, 1) == "i" then
      clear_same_variable_highlight()
      return
    end

    local bufnr = vim.api.nvim_get_current_buf()
    local win = vim.api.nvim_get_current_win()
    if vim.bo[bufnr].buftype ~= "" or vim.api.nvim_get_option_value("modifiable", { buf = bufnr }) == false then
      clear_same_variable_highlight()
      return
    end

    local cursor = vim.api.nvim_win_get_cursor(win)
    local word = vim.fn.expand("<cword>")
    local key = table.concat({
      bufnr,
      win,
      cursor[1],
      cursor[2],
      vim.b[bufnr].changedtick or 0,
      vim.fn.line("w0", win),
      vim.fn.line("w$", win),
      word,
    }, ":")
    if same_variable_last_key == key then
      return
    end
    same_variable_last_key = key

    local clients = document_highlight_clients(bufnr)
    if #clients > 0 then
      apply_lsp_document_highlight(bufnr, win, clients)
      return
    end

    same_variable_generation = same_variable_generation + 1
    clear_same_word_highlight()
    clear_lsp_reference_highlight()
    fallback_same_word_highlight(bufnr, win, word)
  end

  local function schedule_same_variable_highlight(delay)
    cancel_same_variable_timer()
    local uv = vim.uv or vim.loop
    same_variable_timer = uv.new_timer()
    same_variable_timer:start(delay, 0, function()
      local timer = same_variable_timer
      same_variable_timer = nil
      if timer then
        timer:stop()
        timer:close()
      end
      vim.schedule(update_same_variable_highlight)
    end)
  end

  vim.api.nvim_create_autocmd("CursorHold", {
    group = same_variable_group,
    callback = function()
      schedule_same_variable_highlight(0)
    end,
  })
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = same_variable_group,
    callback = function()
      schedule_same_variable_highlight(120)
    end,
  })
  vim.api.nvim_create_autocmd({ "CursorMovedI", "InsertEnter", "WinLeave", "BufLeave" }, {
    group = same_variable_group,
    callback = clear_same_variable_highlight,
  })
end)()

local function diagnostic_jump(count, severity)
  vim.diagnostic.jump({
    count = count,
    severity = severity,
    on_jump = function(_, bufnr)
      open_diagnostic_float({ bufnr = bufnr, scope = "cursor" })
    end,
  })
end

local function next_error_or_diagnostic()
  local next_error = vim.diagnostic.get_next({
    severity = vim.diagnostic.severity.ERROR,
    wrap = false,
  })
  diagnostic_jump(1, next_error and vim.diagnostic.severity.ERROR or nil)
end

vim.keymap.set("n", "]d", function() diagnostic_jump(1) end, { desc = "Next diagnostic" })
vim.keymap.set("n", "[d", function() diagnostic_jump(-1) end, { desc = "Previous diagnostic" })
vim.keymap.set("n", "]e", function() diagnostic_jump(1, vim.diagnostic.severity.ERROR) end, { desc = "Next error in file" })
vim.keymap.set("n", "[e", function() diagnostic_jump(-1, vim.diagnostic.severity.ERROR) end, { desc = "Previous error in file" })
vim.keymap.set("n", "]-e", function() diagnostic_jump(1, vim.diagnostic.severity.ERROR) end, { desc = "Next error in file" })
vim.keymap.set("n", "[-e", function() diagnostic_jump(-1, vim.diagnostic.severity.ERROR) end, { desc = "Previous error in file" })
vim.keymap.set("n", "<C-e>", next_error_or_diagnostic, { desc = "Next error, then next diagnostic" })
vim.keymap.set("n", "<leader>cl", function()
  open_diagnostic_float({ scope = "line" })
end, { desc = "Line diagnostic" })

local notify_lsp_ready

vim.api.nvim_create_autocmd("LspAttach", {
  callback = function(event)
    local opts = { buffer = event.buf }
    local client = event.data and vim.lsp.get_client_by_id(event.data.client_id)
    if client then
      notify_lsp_ready(client.id)
      if client.server_capabilities
          and client.server_capabilities.completionProvider
          and vim.lsp.completion then
        -- autotrigger stays off: built-in 'autocomplete' already sources LSP
        -- via the "o" flag in 'complete'; two trigger paths make the popup
        -- flicker and reopen. enable() is kept for accept-side extras
        -- (snippet expansion, auto-imports on CompleteDone).
        vim.lsp.completion.enable(true, client.id, event.buf, { autotrigger = false })
      end
    end
    vim.keymap.set("n", "gd", function() references_view.definitions() end, vim.tbl_extend("force", opts, { desc = "Definitions view" }))
    vim.keymap.set("n", "gD", vim.lsp.buf.declaration, vim.tbl_extend("force", opts, { desc = "Go to declaration" }))
    vim.keymap.set("n", "gr", function() references_view.open() end, vim.tbl_extend("force", opts, { desc = "References view" }))
    vim.keymap.set("n", "ge", function() references_view.errors() end, vim.tbl_extend("force", opts, { desc = "Current file errors view" }))
    vim.keymap.set("n", "gi", vim.lsp.buf.implementation, vim.tbl_extend("force", opts, { desc = "Implementations" }))
    vim.keymap.set("n", "gt", vim.lsp.buf.type_definition, vim.tbl_extend("force", opts, { desc = "Type definition" }))
    vim.keymap.set("n", "go", lsp_document_symbols_picker, vim.tbl_extend("force", opts, { desc = "File symbols" }))
    vim.keymap.set("n", "<leader>o", lsp_workspace_symbols_picker, vim.tbl_extend("force", opts, { desc = "Project symbols" }))
    vim.keymap.set("n", "<leader>go", lsp_workspace_symbols_picker, vim.tbl_extend("force", opts, { desc = "Project symbols" }))
    vim.keymap.set("n", "K", lsp_hover_popup, vim.tbl_extend("force", opts, { desc = "Hover" }))
    vim.keymap.set("n", "<leader>k", lsp_hover_popup, vim.tbl_extend("force", opts, { desc = "Hover" }))
    vim.keymap.set("n", "<leader>cr", vim.lsp.buf.rename, vim.tbl_extend("force", opts, { desc = "Rename" }))
    vim.keymap.set({ "n", "x" }, "<leader>x", lsp_code_actions_list, vim.tbl_extend("force", opts, { desc = "Code actions list" }))
    vim.keymap.set("n", "<leader>cf", function() vim.lsp.buf.format({ async = true }) end, vim.tbl_extend("force", opts, { desc = "Format" }))
  end,
})

local function root_dir(markers)
  return vim.fs.root(0, markers) or vim.fn.getcwd()
end

local lsp_ready_notified = {}

local function lsp_status_message(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local get_clients = vim.lsp.get_clients or vim.lsp.get_active_clients
  local clients = get_clients({ bufnr = buf })
  if #clients == 0 then
    return "No LSP clients attached"
  end

  local names = {}
  for _, client in ipairs(clients) do
    table.insert(names, client.name)
  end
  table.sort(names)
  return "LSP: " .. table.concat(names, ", ")
end

vim.api.nvim_create_user_command("LspStatus", function()
  vim.notify(lsp_status_message(), vim.log.levels.INFO)
end, { desc = "Show attached LSP clients" })

notify_lsp_ready = function(client_id)
  if not client_id or lsp_ready_notified[client_id] then
    return
  end

  local attempts = 0
  local function check_ready()
    local client = vim.lsp.get_client_by_id(client_id)
    if not client then
      return
    end

    if client.initialized then
      lsp_ready_notified[client_id] = true
      return
    end

    attempts = attempts + 1
    if attempts < 100 then
      vim.defer_fn(check_ready, 100)
    end
  end

  check_ready()
end

local function start_lsp(config)
  if vim.fn.executable(config.cmd[1]) ~= 1 then
    vim.notify(config.cmd[1] .. " not found. Install it to enable LSP.", vim.log.levels.WARN)
    return
  end

  local client_id = vim.lsp.start(config)
  if client_id then
    notify_lsp_ready(client_id)
  end
end

vim.api.nvim_create_autocmd("FileType", {
  pattern = { "javascript", "javascriptreact", "typescript", "typescriptreact" },
  callback = function()
    start_lsp({
      name = "typescript-language-server",
      cmd = { "typescript-language-server", "--stdio" },
      root_dir = root_dir({ "package.json", "tsconfig.json", "jsconfig.json", ".git" }),
    })
  end,
})

vim.api.nvim_create_autocmd("FileType", {
  pattern = { "c", "cpp", "objc", "objcpp" },
  callback = function()
    start_lsp({
      name = "clangd",
      cmd = { "clangd", "--background-index", "--clang-tidy", "--completion-style=detailed", "--header-insertion=iwyu" },
      root_dir = root_dir({ "compile_commands.json", "compile_flags.txt", "CMakeLists.txt", "Makefile", "makefile", ".git" }),
      init_options = {
        clangdFileStatus = true,
      },
    })
  end,
})

vim.api.nvim_create_autocmd("FileType", {
  pattern = "go",
  callback = function()
    start_lsp({
      name = "gopls",
      cmd = { "gopls" },
      root_dir = root_dir({ "go.work", "go.mod", ".git" }),
    })
  end,
})

-- Debugging support for JS/TS and Go (bundled nvim-dap)
local nvim_dap_dir = config_dir .. "/nvim-dap"

local function ensure_nvim_dap()
  if vim.uv.fs_stat(nvim_dap_dir) then
    vim.opt.runtimepath:prepend(nvim_dap_dir)
    return pcall(require, "dap")
  end
  return false
end

local js_debug_install_log = vim.fn.stdpath("data") .. "/dap_adapters/vscode-js-debug-install.log"

local function append_js_debug_install_log(lines)
  vim.fn.mkdir(vim.fn.fnamemodify(js_debug_install_log, ":h"), "p")
  if type(lines) == "string" then
    lines = vim.split(lines, "\n", { plain = true })
  end
  lines = vim.tbl_filter(function(line) return line ~= nil and line ~= "" end, lines or {})
  if #lines > 0 then
    vim.fn.writefile(lines, js_debug_install_log, "a")
  end
end

local function open_js_debug_install_log()
  if vim.uv.fs_stat(js_debug_install_log) then
    vim.cmd.edit(vim.fn.fnameescape(js_debug_install_log))
  else
    vim.notify("No JS debug install log yet: " .. js_debug_install_log, vim.log.levels.INFO)
  end
end

local function install_js_debug_adapter()
  vim.fn.mkdir(vim.fn.fnamemodify(js_debug_install_log, ":h"), "p")
  vim.fn.writefile({ "== vscode-js-debug install " .. os.date("%Y-%m-%d %H:%M:%S") .. " ==" }, js_debug_install_log)

  if vim.fn.executable("git") ~= 1 or vim.fn.executable("npm") ~= 1 then
    append_js_debug_install_log("git and npm are required to install vscode-js-debug")
    vim.notify("git and npm are required to install vscode-js-debug. Log: " .. js_debug_install_log, vim.log.levels.ERROR)
    return
  end

  local install_dir = vim.fn.stdpath("data") .. "/dap_adapters/vscode-js-debug"
  if not vim.uv.fs_stat(install_dir) then
    vim.fn.mkdir(vim.fn.fnamemodify(install_dir, ":h"), "p")
    vim.notify("Cloning vscode-js-debug...", vim.log.levels.INFO)
    append_js_debug_install_log("Cloning into " .. install_dir)
    local clone = vim.fn.system({ "git", "clone", "--filter=blob:none", "https://github.com/microsoft/vscode-js-debug.git", install_dir })
    append_js_debug_install_log(clone)
    if vim.v.shell_error ~= 0 then
      vim.notify("Could not clone vscode-js-debug. Run :DapJsDebugInstallLog", vim.log.levels.ERROR)
      return
    end
  end

  vim.notify("Building vscode-js-debug. This can take a few minutes... Log: " .. js_debug_install_log, vim.log.levels.INFO)
  append_js_debug_install_log({ "Building with: npm install && npx gulp dapDebugServer", "cwd: " .. install_dir })
  vim.fn.jobstart({ "sh", "-c", "npm install && npx gulp dapDebugServer" }, {
    cwd = install_dir,
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data) append_js_debug_install_log(data) end,
    on_stderr = function(_, data) append_js_debug_install_log(data) end,
    on_exit = vim.schedule_wrap(function(_, code)
      append_js_debug_install_log("Exit code: " .. code)
      if code == 0 then
        vim.notify("vscode-js-debug installed. Restart Neovim or run :source %.", vim.log.levels.INFO)
      else
        vim.notify("vscode-js-debug build failed. Run :DapJsDebugInstallLog", vim.log.levels.ERROR)
      end
    end),
  })
end

local function setup_debugging()
  if not ensure_nvim_dap() then
    return
  end

  local ok, dap = pcall(require, "dap")
  if not ok then
    vim.notify("nvim-dap not available", vim.log.levels.WARN)
    return
  end

  local dap_widgets = require("dap.ui.widgets")

  local function dap_switchbuf_without_hidden_tabs(bufnr, line, column)
    if column == 0 then
      column = 1
    end

    local current_win = vim.api.nvim_get_current_win()
    local target_win = current_win
    local current_buf = vim.api.nvim_get_current_buf()
    local ok_source_buf, is_source_buf = pcall(vim.api.nvim_buf_get_var, current_buf, "dap_source_buf")
    local current_is_source_like = vim.bo[current_buf].buftype == ""
      or vim.bo[current_buf].filetype == vim.bo[bufnr].filetype
      or (ok_source_buf and is_source_buf)

    if not current_is_source_like then
      local alternate_win = vim.fn.win_getid(vim.fn.winnr("#"))
      if alternate_win and alternate_win ~= 0 and vim.api.nvim_win_is_valid(alternate_win) then
        target_win = alternate_win
      end
    end

    pcall(vim.api.nvim_win_set_buf, target_win, bufnr)
    if vim.api.nvim_win_is_valid(target_win) then
      local max_line = math.max(1, vim.api.nvim_buf_line_count(bufnr))
      local target_line = math.max(1, math.min(line or 1, max_line))
      local target_col = math.max(0, (column or 1) - 1)
      pcall(vim.api.nvim_win_set_cursor, target_win, { target_line, target_col })
    end
  end

  dap.defaults.fallback.switchbuf = dap_switchbuf_without_hidden_tabs

  local dap_scopes_view
  local dap_frames_view
  local restarting_managed_debug = false
  local stop_managed_debug_jobs = function() end
  local bun_debug_websocket_address
  local tsx_debug_websocket_address

  local function is_managed_debug_session(session)
    if not session or not session.config then
      return false
    end
    return session.config.managedDebug == true or session.config.bunDebug == true or session.config.tsxDebug == true
  end

  local function close_dap_session_hierarchy(session)
    if not session then
      return
    end

    local root = session
    while root.parent do
      root = root.parent
    end

    local seen = {}
    local function close_session_tree(item)
      if not item or seen[item.id] then
        return
      end
      seen[item.id] = true

      local children = {}
      for _, child in pairs(item.children or {}) do
        table.insert(children, child)
      end
      for _, child in ipairs(children) do
        close_session_tree(child)
      end

      if not item.closed then
        pcall(function()
          item:close()
        end)
      end
    end

    close_session_tree(root)
    pcall(dap.set_session, nil)
  end

  local function restart_dap_session()
    local session = dap.session()
    if not session then
      return
    end

    if is_managed_debug_session(session) then
      restarting_managed_debug = true
      local config_dap = vim.deepcopy(session.config)
      local managed_debug_file = config_dap.managedDebugFile
      local bun_mode = config_dap.bunDebugMode
      if config_dap.bunDebug and not bun_mode then
        bun_mode = tostring(config_dap.name or ""):lower():find("test", 1, true) and "test" or "file"
      end
      if bun_mode and bun_debug_websocket_address then
        config_dap.bunDebug = true
        config_dap.bunDebugMode = bun_mode
        config_dap.websocketAddress = bun_debug_websocket_address(bun_mode, managed_debug_file)
      elseif config_dap.tsxDebug and tsx_debug_websocket_address then
        config_dap.websocketAddress = tsx_debug_websocket_address(managed_debug_file, {
          wait_for_module = config_dap.tsxDebugWaitForModule,
          ready_pattern = config_dap.tsxDebugReadyPattern,
          timeout_ms = config_dap.tsxDebugReadyTimeoutMs,
        })
      end
      local filetype = session.filetype or vim.bo.filetype

      -- Managed attach targets report ECONNRESET if the debuggee is killed
      -- while vscode-js-debug is still attached. Close the DAP adapter/session
      -- first without sending a DAP disconnect request, then restart the target.
      close_dap_session_hierarchy(session)
      vim.defer_fn(function()
        stop_managed_debug_jobs()
        vim.defer_fn(function()
          dap.run(config_dap, { filetype = filetype, new = true })
          vim.defer_fn(function()
            restarting_managed_debug = false
          end, 1000)
        end, 150)
      end, 50)
      return
    end

    if session.config.type ~= "go" and dap.restart then
      dap.restart()
      return
    end

    local config_dap = vim.deepcopy(session.config)
    local filetype = session.filetype or vim.bo.filetype
    dap.terminate({
      on_done = vim.schedule_wrap(function()
        dap.run(config_dap, { filetype = filetype, new = true })
      end),
    })
  end

  local active_run_terminal
  local last_run_terminal

  local function open_run_terminal(command, opts, focus_win)
    opts = opts or {}
    local height = opts.height or 12
    local source_win = focus_win or vim.api.nvim_get_current_win()
    vim.cmd("botright " .. height .. "new")
    local buf = vim.api.nvim_get_current_buf()
    local win = vim.api.nvim_get_current_win()
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].buflisted = false
    vim.b[buf].is_dap_terminal = true
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].winfixheight = true
    vim.wo[win].winbar = "%=" .. (opts.title or " Run ") .. "%="
    local job_id
    job_id = vim.fn.termopen(command, {
      cwd = opts.cwd or vim.fn.getcwd(),
      env = opts.env,
      on_exit = function()
        if active_run_terminal and active_run_terminal.job_id == job_id then
          active_run_terminal = nil
        end
      end,
    })
    active_run_terminal = {
      job_id = job_id,
      buf = buf,
      command = vim.deepcopy(command),
      opts = vim.deepcopy(opts),
    }
    last_run_terminal = {
      command = vim.deepcopy(command),
      opts = vim.deepcopy(opts),
    }
    configure_dap_terminal_escape(buf)
    pcall(vim.api.nvim_win_set_cursor, win, { vim.api.nvim_buf_line_count(buf), 0 })
    vim.schedule(function()
      if vim.api.nvim_win_is_valid(win) and vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.api.nvim_win_set_cursor, win, { vim.api.nvim_buf_line_count(buf), 0 })
      end
    end)
    if vim.api.nvim_win_is_valid(source_win) then
      vim.api.nvim_set_current_win(source_win)
    end
  end

  local function restart_run_terminal()
    local run = active_run_terminal
    if not run or vim.fn.jobwait({ run.job_id }, 0)[1] ~= -1 then
      return false
    end

    local source_win = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_get_buf(source_win) == run.buf then
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if win ~= source_win and not is_dap_terminal_buffer(vim.api.nvim_win_get_buf(win)) then
          source_win = win
          break
        end
      end
    end

    -- Clear this first so the old terminal's on_exit callback cannot discard
    -- the replacement job started below.
    active_run_terminal = nil
    pcall(vim.fn.jobstop, run.job_id)
    if vim.api.nvim_buf_is_valid(run.buf) then
      pcall(vim.api.nvim_buf_delete, run.buf, { force = true })
    end
    vim.schedule(function()
      open_run_terminal(run.command, run.opts, source_win)
    end)
    return true
  end

  local function stop_run_terminal()
    local run = active_run_terminal
    if not run or vim.fn.jobwait({ run.job_id }, 0)[1] ~= -1 then
      vim.notify("No application is running", vim.log.levels.INFO)
      return
    end
    vim.fn.chansend(run.job_id, "\003")
  end

  local function restart_active_run_terminal()
    if not restart_run_terminal() then
      vim.notify("No application is running", vim.log.levels.INFO)
    end
  end

  local function kill_run_terminal()
    local run = active_run_terminal
    if not run or vim.fn.jobwait({ run.job_id }, 0)[1] ~= -1 then
      vim.notify("No application is running", vim.log.levels.INFO)
      return
    end
    active_run_terminal = nil
    pcall(vim.fn.jobstop, run.job_id)
  end

  local function rerun_last_run_terminal()
    if active_run_terminal and vim.fn.jobwait({ active_run_terminal.job_id }, 0)[1] == -1 then
      restart_run_terminal()
      return
    end
    if not last_run_terminal then
      vim.notify("No previous application run", vim.log.levels.INFO)
      return
    end
    open_run_terminal(last_run_terminal.command, last_run_terminal.opts)
  end

  local dap_console_height = 8

  local function set_dap_console_height(win)
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_set_height, win, dap_console_height)
      pcall(vim.api.nvim_set_option_value, "winfixheight", true, { win = win })
    end
  end

  local function is_dap_console_buffer(buf)
    return is_dap_terminal_buffer(buf)
  end

  local function resize_dap_console_windows()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local buf = vim.api.nvim_win_get_buf(win)
      if is_dap_console_buffer(buf) then
        set_dap_console_height(win)
      end
    end
  end

  local function configure_open_dap_console_buffers()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local buf = vim.api.nvim_win_get_buf(win)
      if is_dap_console_buffer(buf) then
        configure_dap_terminal_escape(buf)
        pcall(vim.api.nvim_win_set_cursor, win, { vim.api.nvim_buf_line_count(buf), 0 })
      end
    end
  end

  local function open_dap_console_win()
    local current = vim.api.nvim_get_current_win()
    vim.cmd("botright " .. dap_console_height .. "new")
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_get_current_buf()
    vim.bo[buf].buflisted = false
    vim.b[buf].is_dap_terminal = true
    configure_dap_terminal_escape(buf)
    set_dap_console_height(win)
    pcall(vim.api.nvim_win_set_cursor, win, { vim.api.nvim_buf_line_count(buf), 0 })
    if vim.api.nvim_win_is_valid(current) then
      vim.api.nvim_set_current_win(current)
    end
    return buf, win
  end

  local function open_dap_repl_bottom()
    local current = vim.api.nvim_get_current_win()
    local has_console = false
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local buf = vim.api.nvim_win_get_buf(win)
      if is_dap_console_buffer(buf) then
        has_console = true
      end
    end
    if not has_console then
      dap.repl.open({ height = dap_console_height, winfixheight = true }, "botright split")
    end
    configure_open_dap_console_buffers()
    resize_dap_console_windows()
    vim.schedule(resize_dap_console_windows)
    if vim.api.nvim_win_is_valid(current) then
      vim.api.nvim_set_current_win(current)
    end
  end

  local function close_dap_consoles()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local buf = vim.api.nvim_win_get_buf(win)
      if is_dap_console_buffer(buf) then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
  end

  vim.fn.sign_define("DapBreakpoint", { text = "●", texthl = "DapBreakpointSign", linehl = "DapBreakpointLine", numhl = "DapBreakpointNumber" })
  vim.fn.sign_define("DapBreakpointCondition", { text = "◆", texthl = "DapBreakpointConditionSign", linehl = "DapBreakpointLine", numhl = "DapBreakpointNumber" })
  vim.fn.sign_define("DapLogPoint", { text = "◆", texthl = "DiagnosticInfo", linehl = "DapBreakpointLine", numhl = "DapBreakpointNumber" })
  vim.fn.sign_define("DapStopped", { text = "▶", texthl = "DapStoppedSign", linehl = "DapStoppedLine", numhl = "DapStoppedNumber" })
  vim.fn.sign_define("DapBreakpointRejected", { text = "○", texthl = "DapBreakpointRejectedSign", linehl = "DapBreakpointLine", numhl = "DapBreakpointNumber" })

  dap.adapters.go = function(callback, config_dap)
    if vim.fn.executable("dlv") ~= 1 then
      vim.notify("dlv not found. Install Delve: go install github.com/go-delve/delve/cmd/dlv@latest", vim.log.levels.ERROR)
      return
    end
    local port = config_dap.port or "${port}"
    callback({
      type = "server",
      host = "127.0.0.1",
      port = port,
      executable = { command = "dlv", args = { "dap", "-l", "127.0.0.1:" .. port } },
      options = { max_retries = 30, initialize_timeout_sec = 10 },
    })
  end

  dap.configurations.go = {
    { type = "go", name = "Debug package", request = "launch", program = "${fileDirname}", outputMode = "remote" },
    { type = "go", name = "Debug current file", request = "launch", program = "${file}", outputMode = "remote" },
    { type = "go", name = "Debug test", request = "launch", mode = "test", program = "${fileDirname}", outputMode = "remote" },
    { type = "go", name = "Attach to process", request = "attach", mode = "local", processId = require("dap.utils").pick_process },
  }

  local function c_project_root()
    return vim.fs.root(0, { "compile_commands.json", "compile_flags.txt", "CMakeLists.txt", "Makefile", "makefile", ".git" }) or vim.fn.getcwd()
  end

  local function c_debug_program()
    local file_root = vim.fn.expand("%:t:r")
    local candidates = {
      c_project_root() .. "/build/" .. file_root,
      c_project_root() .. "/" .. file_root,
      vim.fn.expand("%:p:r"),
    }
    local default = candidates[#candidates]
    for _, candidate in ipairs(candidates) do
      if vim.fn.executable(candidate) == 1 then
        default = candidate
        break
      end
    end

    local program = vim.fn.input("Path to executable: ", default, "file")
    if program == "" then
      return dap.ABORT
    end
    return program
  end

  local function c_debug_args()
    local args = vim.fn.input("Arguments: ")
    if args == "" then
      return {}
    end
    return vim.fn.shellsplit(args)
  end

  dap.adapters.codelldb = function(callback)
    if vim.fn.executable("codelldb") == 1 then
      callback({
        type = "server",
        host = "127.0.0.1",
        port = "${port}",
        executable = { command = "codelldb", args = { "--port", "${port}" } },
      })
      return
    end

    if vim.fn.executable("lldb-dap") == 1 then
      callback({ type = "executable", command = "lldb-dap" })
      return
    end

    if vim.fn.executable("lldb-vscode") == 1 then
      callback({ type = "executable", command = "lldb-vscode" })
      return
    end

    vim.notify("C debug adapter not found. Install codelldb or lldb-dap for C debugging.", vim.log.levels.ERROR)
  end

  dap.configurations.c = {
    { type = "codelldb", name = "Launch executable", request = "launch", program = c_debug_program, cwd = c_project_root, args = c_debug_args, stopOnEntry = false },
    { type = "codelldb", name = "Attach to process", request = "attach", pid = require("dap.utils").pick_process, cwd = c_project_root },
  }
  dap.configurations.cpp = dap.configurations.c
  dap.configurations.objc = dap.configurations.c
  dap.configurations.objcpp = dap.configurations.c

  local function js_debug_server()
    local candidates = {
      vim.fn.stdpath("data") .. "/dap_adapters/vscode-js-debug/dist/src/dapDebugServer.js",
      vim.fn.stdpath("data") .. "/dap_adapters/vscode-js-debug/src/dapDebugServer.js",
      vim.fn.stdpath("data") .. "/dap_adapters/vscode-js-debug/out/src/dapDebugServer.js",
      vim.fn.expand("~/.vscode/extensions/ms-vscode.js-debug-nightly") .. "/src/dapDebugServer.js",
    }
    local extension_dirs = vim.fn.glob(vim.fn.expand("~/.vscode/extensions/ms-vscode.js-debug-*/src/dapDebugServer.js"), false, true)
    vim.list_extend(candidates, extension_dirs)
    for _, path in ipairs(candidates) do
      if vim.uv.fs_stat(path) then
        return path
      end
    end
    return nil
  end

  local function js_adapter(callback)
    local js_debug_path = js_debug_server()
    if not js_debug_path then
      vim.notify("JS/TS debug adapter not found. Run :DapInstallJsDebug.", vim.log.levels.ERROR)
      return
    end
    if vim.fn.executable("node") ~= 1 then
      vim.notify("node not found. Install Node.js for JS/TS debugging.", vim.log.levels.ERROR)
      return
    end
    callback({
      type = "server",
      host = "127.0.0.1",
      port = "${port}",
      executable = { command = "node", args = { js_debug_path, "${port}", "127.0.0.1" } },
    })
  end

  dap.adapters["pwa-node"] = js_adapter
  dap.adapters["pwa-chrome"] = js_adapter
  dap.defaults["pwa-node"].focus_terminal = false
  dap.defaults["pwa-node"].terminal_win_cmd = open_dap_console_win
  dap.defaults["pwa-chrome"].focus_terminal = false
  dap.defaults["pwa-chrome"].terminal_win_cmd = open_dap_console_win

  local node_compile_cache = vim.fn.stdpath("cache") .. "/node-compile-cache"
  vim.fn.mkdir(node_compile_cache, "p")
  local node_debug_env = { NODE_COMPILE_CACHE = node_compile_cache }

  local function js_debug_cwd()
    return vim.fs.root(0, { "package.json", "tsconfig.json", "jsconfig.json", ".git" }) or vim.fn.getcwd()
  end

  local auto_continue_managed_attach_sessions = {}

  dap.listeners.after.event_initialized["open_bottom_console"] = function(session)
    if is_managed_debug_session(session) and session.config.continueOnAttach then
      auto_continue_managed_attach_sessions[session.id] = true
    end
    vim.schedule(open_dap_repl_bottom)
  end
  dap.listeners.after.event_stopped["auto_continue_managed_attach"] = function(session, body)
    if not session or not body or not auto_continue_managed_attach_sessions[session.id] then
      return
    end

    auto_continue_managed_attach_sessions[session.id] = nil
    if body.reason ~= "entry" and body.reason ~= "pause" then
      return
    end

    local thread_id = body.threadId
    if not thread_id then
      return
    end

    vim.defer_fn(function()
      if session.closed then
        return
      end
      if session.stopped_thread_id == thread_id then
        session:_step("continue")
      else
        session:request("continue", { threadId = thread_id }, function() end)
      end
    end, 100)
  end
  dap.listeners.after.event_terminated["close_bottom_console"] = function(session)
    if session then
      auto_continue_managed_attach_sessions[session.id] = nil
    end
    if not restarting_managed_debug then
      vim.schedule(close_dap_consoles)
    end
  end
  dap.listeners.after.event_exited["close_bottom_console"] = function(session)
    if session then
      auto_continue_managed_attach_sessions[session.id] = nil
    end
    if not restarting_managed_debug then
      vim.schedule(close_dap_consoles)
    end
  end

  local js_configs = {
    {
      type = "pwa-node",
      request = "launch",
      name = "Launch JS file",
      program = "${file}",
      cwd = "${workspaceFolder}",
      sourceMaps = true,
      console = "internalConsole",
      internalConsoleOptions = "openOnSessionStart",
      outputCapture = "std",
      skipFiles = { "<node_internals>/**", "${workspaceFolder}/node_modules/**/*.js" },
    },
    { type = "pwa-node", request = "launch", name = "Launch npm start", runtimeExecutable = "npm", runtimeArgs = { "start" }, cwd = "${workspaceFolder}", sourceMaps = true, console = "integratedTerminal" },
    { type = "pwa-node", request = "attach", name = "Attach to Node process", processId = require("dap.utils").pick_process, cwd = "${workspaceFolder}", sourceMaps = true },
    { type = "pwa-chrome", request = "launch", name = "Launch Chrome", url = "http://localhost:3000", webRoot = "${workspaceFolder}" },
  }

  local managed_debug_jobs = {}

  local function is_managed_debug_output_buffer(buf)
    if not vim.api.nvim_buf_is_valid(buf) then
      return false
    end

    local ok_managed_output, is_managed_output = pcall(function()
      return vim.b[buf].is_managed_debug_output
    end)
    if ok_managed_output and is_managed_output then
      return true
    end

    local name = vim.api.nvim_buf_get_name(buf)
    if name:find("[dap-terminal] bun", 1, true) ~= nil or name:find("[dap-terminal] tsx", 1, true) ~= nil then
      return true
    end

    -- Older versions could fail to name the replacement log buffer, leaving an
    -- unnamed [scratch] split with the managed debug output.
    local ok_dap_terminal, is_dap_terminal = pcall(function()
      return vim.b[buf].is_dap_terminal
    end)
    return ok_dap_terminal and is_dap_terminal and name == "" and vim.bo[buf].buftype == "nofile"
  end

  local function close_managed_debug_output_buffers()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local buf = vim.api.nvim_win_get_buf(win)
      if is_managed_debug_output_buffer(buf) then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end

    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if is_managed_debug_output_buffer(buf) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
  end

  stop_managed_debug_jobs = function()
    for job_id in pairs(managed_debug_jobs) do
      pcall(vim.fn.jobstop, job_id)
      managed_debug_jobs[job_id] = nil
    end
  end

  local function debug_target_output_buffer(label)
    close_managed_debug_output_buffers()

    label = label or "debug"
    local current = vim.api.nvim_get_current_win()
    local buf, win = open_dap_console_win()
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].buflisted = false
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.b[buf].is_dap_terminal = true
    vim.b[buf].is_managed_debug_output = true
    pcall(vim.api.nvim_buf_set_name, buf, "[dap-terminal] " .. label)
    vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Starting " .. label .. " debug target..." })
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
    configure_dap_terminal_escape(buf)
    if vim.api.nvim_win_is_valid(win) then
      vim.wo[win].wrap = false
      pcall(vim.api.nvim_win_set_cursor, win, { vim.api.nvim_buf_line_count(buf), 0 })
    end
    if vim.api.nvim_win_is_valid(current) then
      vim.api.nvim_set_current_win(current)
    end
    return buf
  end

  local function append_debug_target_output(buf, data)
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    local lines = {}
    for _, line in ipairs(data or {}) do
      if line ~= "" then
        table.insert(lines, line)
      end
    end
    if #lines == 0 then
      return
    end
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
      vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
      vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

      local last_line = vim.api.nvim_buf_line_count(buf)
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(win) == buf then
          pcall(vim.api.nvim_win_set_cursor, win, { last_line, 0 })
        end
      end
    end)
  end

  bun_debug_websocket_address = function(mode, file_override)
    return function()
      return coroutine.create(function(dap_run_co)
        if vim.fn.executable("bun") ~= 1 then
          vim.notify("bun not found. Install Bun for Bun TS debugging.", vim.log.levels.ERROR)
          coroutine.resume(dap_run_co, dap.ABORT)
          return
        end

        local file = file_override or vim.fn.expand("%:p")
        if file == "" then
          vim.notify("Save the current TypeScript file before debugging with Bun.", vim.log.levels.ERROR)
          coroutine.resume(dap_run_co, dap.ABORT)
          return
        end

        vim.cmd.wall()
        stop_managed_debug_jobs()

        local token = string.format("nvim-bun-%d-%d", os.time(), math.random(100000, 999999))
        local inspect_arg = "--inspect=127.0.0.1:0/" .. token
        local cmd = { "bun", inspect_arg }
        if mode == "test" then
          table.insert(cmd, "test")
        end
        table.insert(cmd, file)

        local buf = debug_target_output_buffer(mode == "test" and "bun test" or "bun")
        append_debug_target_output(buf, { "> " .. table.concat(cmd, " ") })

        local done = false
        local job_id
        local timer = vim.uv.new_timer()

        local function finish(value)
          if done then
            return
          end
          done = true
          if timer then
            timer:stop()
            timer:close()
          end
          vim.schedule(function()
            coroutine.resume(dap_run_co, value)
          end)
        end

        local function handle_output(_, data)
          append_debug_target_output(buf, data)
          for _, line in ipairs(data or {}) do
            local websocket = line:match("(ws://%S+)")
            if websocket then
              finish(websocket)
              return
            end
          end
        end

        job_id = vim.fn.jobstart(cmd, {
          cwd = js_debug_cwd(),
          stdout_buffered = false,
          stderr_buffered = false,
          on_stdout = handle_output,
          on_stderr = handle_output,
          on_exit = function(_, code)
            if job_id then
              managed_debug_jobs[job_id] = nil
            end
            if not done then
              vim.schedule(function()
                vim.notify("Bun debug target exited before inspector started (exit " .. code .. ").", vim.log.levels.ERROR)
              end)
              finish(dap.ABORT)
            end
          end,
        })

        if job_id <= 0 then
          vim.notify("Failed to start Bun debug target.", vim.log.levels.ERROR)
          finish(dap.ABORT)
          return
        end

        managed_debug_jobs[job_id] = true
        if timer then
          timer:start(7000, 0, vim.schedule_wrap(function()
            if done then
              return
            end
            vim.notify("Timed out waiting for Bun inspector websocket URL.", vim.log.levels.ERROR)
            pcall(vim.fn.jobstop, job_id)
            finish(dap.ABORT)
          end))
        end
      end)
    end
  end

  tsx_debug_websocket_address = function(file_override, opts)
    opts = opts or {}
    return function()
      return coroutine.create(function(dap_run_co)
        if vim.fn.executable("node") ~= 1 then
          vim.notify("node not found. Install Node.js for TSX debugging.", vim.log.levels.ERROR)
          coroutine.resume(dap_run_co, dap.ABORT)
          return
        end

        local file = file_override or vim.fn.expand("%:p")
        if file == "" then
          vim.notify("Save the current TypeScript file before debugging with TSX.", vim.log.levels.ERROR)
          coroutine.resume(dap_run_co, dap.ABORT)
          return
        end

        vim.cmd.wall()
        stop_managed_debug_jobs()

        local module_ready_marker = opts.wait_for_module and "__NVIM_DAP_MODULE_READY__" or nil
        local ready_pattern = module_ready_marker or opts.ready_pattern
        local cmd
        if module_ready_marker then
          local bootstrap = 'import { pathToFileURL } from "node:url"; '
            .. 'await import(pathToFileURL(process.argv[1]).href); '
            .. 'console.log("' .. module_ready_marker .. '");'
          cmd = {
            "node",
            "--inspect=127.0.0.1:0",
            "--no-warnings",
            "--import",
            "tsx",
            "--input-type=module",
            "--eval",
            bootstrap,
            file,
          }
        else
          cmd = { "node", "--inspect=127.0.0.1:0", "--no-warnings", "--import", "tsx", file }
        end
        local buf = debug_target_output_buffer("tsx")
        append_debug_target_output(buf, { "> " .. table.concat(cmd, " ") })

        local done = false
        local job_id
        local timer = vim.uv.new_timer()
        local websocket_address
        local app_is_ready = ready_pattern == nil

        local function finish(value)
          if done then
            return
          end
          done = true
          if timer then
            timer:stop()
            timer:close()
          end
          vim.schedule(function()
            coroutine.resume(dap_run_co, value)
          end)
        end

        local function handle_output(_, data)
          local visible_output = {}
          for _, line in ipairs(data or {}) do
            if line ~= module_ready_marker then
              table.insert(visible_output, line)
            end
          end
          append_debug_target_output(buf, visible_output)
          for _, line in ipairs(data or {}) do
            if not websocket_address then
              websocket_address = line:match("(ws://%S+)")
              if websocket_address and ready_pattern then
                local waiting_for = module_ready_marker and "TypeScript module loading" or ('"' .. ready_pattern .. '"')
                append_debug_target_output(buf, { "Inspector ready; waiting for " .. waiting_for .. " before attaching debugger..." })
              end
            end
            if ready_pattern and line:find(ready_pattern, 1, true) then
              app_is_ready = true
            end
            if websocket_address and app_is_ready then
              finish(websocket_address)
              return
            end
          end
        end

        job_id = vim.fn.jobstart(cmd, {
          cwd = js_debug_cwd(),
          env = node_debug_env,
          stdout_buffered = false,
          stderr_buffered = false,
          on_stdout = handle_output,
          on_stderr = handle_output,
          on_exit = function(_, code)
            if job_id then
              managed_debug_jobs[job_id] = nil
            end
            if not done then
              vim.schedule(function()
                vim.notify("TSX debug target exited before debugger attached (exit " .. code .. ").", vim.log.levels.ERROR)
              end)
              finish(dap.ABORT)
            end
          end,
        })

        if job_id <= 0 then
          vim.notify("Failed to start TSX debug target.", vim.log.levels.ERROR)
          finish(dap.ABORT)
          return
        end

        managed_debug_jobs[job_id] = true
        if timer then
          timer:start(opts.timeout_ms or 7000, 0, vim.schedule_wrap(function()
            if done then
              return
            end
            if websocket_address and ready_pattern and not app_is_ready then
              local waiting_for = module_ready_marker and "TypeScript module loading" or ('app readiness output: "' .. ready_pattern .. '"')
              vim.notify("Timed out waiting for " .. waiting_for .. ".", vim.log.levels.ERROR)
            else
              vim.notify("Timed out waiting for Node inspector websocket URL.", vim.log.levels.ERROR)
            end
            pcall(vim.fn.jobstop, job_id)
            finish(dap.ABORT)
          end))
        end
      end)
    end
  end

  dap.listeners.after.event_terminated["stop_managed_debug_jobs"] = function()
    if not restarting_managed_debug then
      vim.schedule(stop_managed_debug_jobs)
    end
  end
  dap.listeners.after.event_exited["stop_managed_debug_jobs"] = function()
    if not restarting_managed_debug then
      vim.schedule(stop_managed_debug_jobs)
    end
  end

  local ts_configs = {
    {
      type = "pwa-node",
      request = "attach",
      name = "Launch TS file (bun)",
      bunDebug = true,
      bunDebugMode = "file",
      managedDebugFile = "${file}",
      websocketAddress = bun_debug_websocket_address("file"),
      cwd = "${workspaceFolder}",
      localRoot = "${workspaceFolder}",
      remoteRoot = "${workspaceFolder}",
      continueOnAttach = true,
      sourceMaps = true,
      pauseForSourceMap = false,
      sourceMapRenames = false,
      enableContentValidation = false,
      resolveSourceMapLocations = { "${workspaceFolder}/**", "!**/node_modules/**" },
      skipFiles = { "<node_internals>/**", "${workspaceFolder}/node_modules/**/*.js" },
    },
    {
      type = "pwa-node",
      request = "attach",
      name = "Launch TS test (bun)",
      bunDebug = true,
      bunDebugMode = "test",
      managedDebugFile = "${file}",
      websocketAddress = bun_debug_websocket_address("test"),
      cwd = "${workspaceFolder}",
      localRoot = "${workspaceFolder}",
      remoteRoot = "${workspaceFolder}",
      continueOnAttach = true,
      sourceMaps = true,
      pauseForSourceMap = false,
      sourceMapRenames = false,
      enableContentValidation = false,
      resolveSourceMapLocations = { "${workspaceFolder}/**", "!**/node_modules/**" },
      skipFiles = { "<node_internals>/**", "${workspaceFolder}/node_modules/**/*.js" },
    },
    {
      type = "pwa-node",
      request = "attach",
      name = "Launch TS app (tsx, attach after module load)",
      managedDebug = true,
      tsxDebug = true,
      tsxDebugWaitForModule = true,
      tsxDebugReadyTimeoutMs = 30000,
      managedDebugFile = "${file}",
      websocketAddress = tsx_debug_websocket_address(nil, {
        wait_for_module = true,
        timeout_ms = 30000,
      }),
      cwd = "${workspaceFolder}",
      localRoot = "${workspaceFolder}",
      remoteRoot = "${workspaceFolder}",
      continueOnAttach = true,
      sourceMaps = true,
      pauseForSourceMap = false,
      sourceMapRenames = false,
      enableContentValidation = false,
      resolveSourceMapLocations = { "${workspaceFolder}/**", "!**/node_modules/**" },
      skipFiles = { "<node_internals>/**", "${workspaceFolder}/node_modules/**/*.js" },
    },
    {
      type = "pwa-node",
      request = "attach",
      name = "Launch TS file (tsx, immediate attach)",
      managedDebug = true,
      tsxDebug = true,
      managedDebugFile = "${file}",
      websocketAddress = tsx_debug_websocket_address(),
      cwd = "${workspaceFolder}",
      localRoot = "${workspaceFolder}",
      remoteRoot = "${workspaceFolder}",
      continueOnAttach = true,
      sourceMaps = true,
      pauseForSourceMap = false,
      sourceMapRenames = false,
      enableContentValidation = false,
      resolveSourceMapLocations = { "${workspaceFolder}/**", "!**/node_modules/**" },
      skipFiles = { "<node_internals>/**", "${workspaceFolder}/node_modules/**/*.js" },
    },
    {
      type = "pwa-node",
      request = "launch",
      name = "Launch TS file (tsx legacy launch)",
      program = "${file}",
      cwd = "${workspaceFolder}",
      runtimeExecutable = "node",
      runtimeArgs = { "--no-warnings", "--import", "tsx" },
      env = node_debug_env,
      sourceMaps = true,
      pauseForSourceMap = false,
      sourceMapRenames = false,
      enableContentValidation = false,
      console = "internalConsole",
      internalConsoleOptions = "openOnSessionStart",
      outputCapture = "std",
      resolveSourceMapLocations = { "${workspaceFolder}/**", "!**/node_modules/**" },
      skipFiles = { "<node_internals>/**", "${workspaceFolder}/node_modules/**/*.js" },
    },
    {
      type = "pwa-node",
      request = "launch",
      name = "Launch TS file watch (tsx)",
      program = "${file}",
      cwd = "${workspaceFolder}",
      runtimeExecutable = "node",
      runtimeArgs = { "--watch", "--no-warnings", "--import", "tsx" },
      env = node_debug_env,
      sourceMaps = true,
      pauseForSourceMap = false,
      sourceMapRenames = false,
      enableContentValidation = false,
      console = "integratedTerminal",
      resolveSourceMapLocations = { "${workspaceFolder}/**", "!**/node_modules/**" },
      skipFiles = { "<node_internals>/**", "${workspaceFolder}/node_modules/**/*.js" },
    },
    { type = "pwa-node", request = "launch", name = "Launch npm start", runtimeExecutable = "npm", runtimeArgs = { "start" }, cwd = "${workspaceFolder}", sourceMaps = true, console = "integratedTerminal" },
    { type = "pwa-node", request = "attach", name = "Attach to Node process", processId = require("dap.utils").pick_process, cwd = "${workspaceFolder}", sourceMaps = true },
    { type = "pwa-chrome", request = "launch", name = "Launch Chrome", url = "http://localhost:3000", webRoot = "${workspaceFolder}" },
  }

  dap.configurations.javascript = js_configs
  dap.configurations.javascriptreact = js_configs
  dap.configurations.typescript = ts_configs
  dap.configurations.typescriptreact = ts_configs

  vim.api.nvim_create_user_command("DapInstallJsDebug", install_js_debug_adapter, { desc = "Install vscode-js-debug for JS/TS debugging" })
  vim.api.nvim_create_user_command("DapJsDebugInstallLog", open_js_debug_install_log, { desc = "Open vscode-js-debug install log" })

  local function restart_or_start_debugger()
    vim.cmd.wall()
    if dap.session() ~= nil then
      restart_dap_session()
    elseif not restart_run_terminal() then
      dap.continue()
    end
  end

  vim.keymap.set({ "n", "t" }, "<F2>", restart_or_start_debugger,
    { desc = "Restart run/debug session or start debugger" })

  vim.keymap.set("n", "<leader><F2>", function()
    dap.terminate({ hierarchy = true })
    dap.disconnect()
    stop_managed_debug_jobs()
    dap.repl.close()
    close_dap_consoles()
  end, { desc = "Debug stop" })

  local function select_run_configuration()
    local ft = vim.bo.filetype
    if ft ~= "javascript" and ft ~= "javascriptreact" and ft ~= "typescript" and ft ~= "typescriptreact" then
      vim.notify("Not a JS/TS file", vim.log.levels.WARN)
      return
    end

    local file = vim.fn.expand("%:p")
    local runners = {
      {
        name = "node --import tsx",
        executable = "node",
        command = { "node", "--no-warnings", "--import", "tsx", file },
        title = " node --import tsx ",
      },
      {
        name = "node --import tsx --watch",
        executable = "node",
        command = { "node", "--watch", "--no-warnings", "--import", "tsx", file },
        title = " node --import tsx --watch ",
      },
      {
        name = "bun",
        executable = "bun",
        command = { "bun", file },
        title = " bun ",
      },
      {
        name = "bun --watch",
        executable = "bun",
        command = { "bun", "--watch", file },
        title = " bun --watch ",
      },
      {
        name = "bun test",
        executable = "bun",
        command = { "bun", "test", file },
        title = " bun test ",
      },
      {
        name = "npm start",
        executable = "npm",
        command = { "npm", "start" },
        title = " npm start ",
      },
    }

    vim.ui.select(runners, {
      prompt = "Run configuration",
      placeholder = "Search run configurations...",
      format_item = function(item)
        return item.name
      end,
    }, function(runner)
      if not runner then
        return
      end
      if vim.fn.executable(runner.executable) ~= 1 then
        vim.notify(runner.executable .. " not found on $PATH", vim.log.levels.ERROR)
        return
      end

      vim.cmd.wall()
      open_run_terminal(runner.command, {
        title = runner.title,
        cwd = js_debug_cwd(),
        env = node_debug_env,
      })
    end)
  end

  local run_configuration_map_opts = { desc = "Select and run a JS/TS configuration" }
  vim.keymap.set("n", "<leader>rc", select_run_configuration, run_configuration_map_opts)
  vim.keymap.set("n", "<leader>rr", restart_active_run_terminal, { desc = "Run restart" })
  vim.keymap.set("n", "<leader>rs", stop_run_terminal, { desc = "Run stop" })
  vim.keymap.set("n", "<leader>rk", kill_run_terminal, { desc = "Run kill" })
  vim.keymap.set("n", "<leader>rl", rerun_last_run_terminal, { desc = "Run last" })
  vim.keymap.set("n", "<S-F2>", select_run_configuration, run_configuration_map_opts)
  -- Alacritty's terminfo reports Shift-F2 as F14 (CSI 1;2Q).
  vim.keymap.set("n", "<F14>", select_run_configuration, run_configuration_map_opts)

  vim.keymap.set("n", "<F3>", function()
    if dap_scopes_view ~= nil then
      if dap_scopes_view.win and vim.api.nvim_win_is_valid(dap_scopes_view.win) then
        dap_scopes_view.close()
        dap_scopes_view = nil
        return
      end
      dap_scopes_view = nil
    end

    local ok_view, view = pcall(dap_widgets.centered_float, dap_widgets.scopes)
    if ok_view then
      dap_scopes_view = view
    else
      vim.notify("Failed to open DAP scopes: " .. tostring(view), vim.log.levels.ERROR)
    end
  end, { desc = "Debug toggle scopes" })

  vim.keymap.set("n", "<S-F3>", function()
    if dap_frames_view ~= nil then
      if dap_frames_view.win and vim.api.nvim_win_is_valid(dap_frames_view.win) then
        dap_frames_view.close()
        dap_frames_view = nil
        return
      end
      dap_frames_view = nil
    end

    local ok_view, view = pcall(dap_widgets.centered_float, dap_widgets.frames)
    if ok_view then
      dap_frames_view = view
    else
      vim.notify("Failed to open DAP callstack: " .. tostring(view), vim.log.levels.ERROR)
    end
  end, { desc = "Debug toggle callstack" })

  vim.keymap.set("n", "<F4>", function()
    dap.repl.toggle({ height = dap_console_height, winfixheight = true }, "botright split")
    configure_open_dap_console_buffers()
    resize_dap_console_windows()
    vim.schedule(resize_dap_console_windows)
  end, { desc = "Debug toggle REPL" })

  vim.keymap.set("n", "<F9>", dap.toggle_breakpoint, { desc = "Debug toggle breakpoint" })
  vim.keymap.set("n", "<S-F9>", function()
    floating_input({ prompt = "Breakpoint condition" }, function(condition)
      if condition and condition ~= "" then
        dap.set_breakpoint(condition)
      end
    end)
  end, { desc = "Debug conditional breakpoint" })

  vim.keymap.set({ "n", "v", "x" }, "<Up>", function()
    if dap.session() ~= nil then dap.continue() end
  end, { noremap = true, silent = true, desc = "Debug continue" })
  vim.keymap.set({ "n", "v", "x" }, "<Down>", function()
    if dap.session() ~= nil then dap.step_over() end
  end, { noremap = true, silent = true, desc = "Debug step over" })
  vim.keymap.set({ "n", "v", "x" }, "<Right>", function()
    if dap.session() ~= nil then dap.step_into() end
  end, { noremap = true, silent = true, desc = "Debug step into" })
  vim.keymap.set({ "n", "v", "x" }, "<Left>", function()
    if dap.session() ~= nil then dap.step_out() end
  end, { noremap = true, silent = true, desc = "Debug step out" })

  local function auto_install_js_debug_adapter_once()
    if js_debug_server() or #vim.api.nvim_list_uis() == 0 then
      return
    end

    local marker = vim.fn.stdpath("data") .. "/dap_adapters/.vscode-js-debug-auto-install-attempted"
    if vim.uv.fs_stat(marker) then
      return
    end

    vim.fn.mkdir(vim.fn.fnamemodify(marker, ":h"), "p")
    vim.fn.writefile({ os.date("%Y-%m-%d %H:%M:%S") }, marker)
    vim.defer_fn(install_js_debug_adapter, 1000)
  end

  auto_install_js_debug_adapter_once()

  vim.keymap.set("n", "<leader>dc", function()
    dap.continue({ new = true })
  end, { desc = "Select and start debug configuration" })
  vim.keymap.set("n", "<leader>dd", function()
    if dap.session() == nil then
      vim.notify("No active debug session", vim.log.levels.INFO)
      return
    end
    restart_dap_session()
  end, { desc = "Debug restart" })
  vim.keymap.set("n", "<leader>db", dap.toggle_breakpoint, { desc = "Debug toggle breakpoint" })
  vim.keymap.set("n", "<leader>dB", function() floating_input({ prompt = "Breakpoint condition" }, function(condition) if condition and condition ~= "" then dap.set_breakpoint(condition) end end) end, { desc = "Debug conditional breakpoint" })
  vim.keymap.set("n", "<leader>dp", function() floating_input({ prompt = "Log point message" }, function(message) if message and message ~= "" then dap.set_breakpoint(nil, nil, message) end end) end, { desc = "Debug log point" })
  vim.keymap.set("n", "<leader>di", dap.step_into, { desc = "Debug step into" })
  vim.keymap.set("n", "<leader>do", dap.step_over, { desc = "Debug step over" })
  vim.keymap.set("n", "<leader>dO", dap.step_out, { desc = "Debug step out" })
  vim.keymap.set("n", "<leader>dr", function()
    dap.repl.open({ height = dap_console_height, winfixheight = true }, "botright split")
    configure_open_dap_console_buffers()
    resize_dap_console_windows()
    vim.schedule(resize_dap_console_windows)
  end, { desc = "Debug REPL" })
  vim.keymap.set("n", "<leader>dl", dap.run_last, { desc = "Debug run last" })
  vim.keymap.set("n", "<leader>dt", dap.terminate, { desc = "Debug terminate" })
  local function debug_hover(expression)
    if dap.session() == nil then
      vim.notify("No active debug session", vim.log.levels.WARN)
      return
    end
    local view = dap_widgets.hover(expression, {
      border = "rounded",
      title = " Debug value ",
    })
    configure_dap_hover_view(view)
  end

  local function prompt_debug_expression()
    floating_input({ prompt = "Debug expression", default = vim.fn.expand("<cexpr>") }, function(expression)
      if expression and expression ~= "" then
        debug_hover(expression)
      end
    end)
  end

  local function copy_debug_value(expression)
    local session = dap.session()
    if session == nil then
      vim.notify("No active debug session", vim.log.levels.WARN)
      return
    end

    expression = expression or vim.fn.expand("<cexpr>")
    local frame = session.current_frame or {}
    session:evaluate({
      expression = expression,
      frameId = frame.id,
      context = "clipboard",
    }, function(err, result)
      if err or not result then
        vim.notify("Could not evaluate '" .. expression .. "': " .. tostring(err), vim.log.levels.ERROR)
        return
      end
      vim.fn.setreg("+", result.result)
      vim.notify("Copied " .. expression .. " = " .. result.result, vim.log.levels.INFO)
    end)
  end

  local function selected_debug_expression()
    local start_pos = vim.fn.getpos("v")
    local end_pos = vim.fn.getpos(".")
    local start_row, start_col = start_pos[2], start_pos[3]
    local end_row, end_col = end_pos[2], end_pos[3]
    if end_row < start_row or (end_row == start_row and end_col < start_col) then
      start_row, end_row = end_row, start_row
      start_col, end_col = end_col, start_col
    end
    local lines = vim.api.nvim_buf_get_text(0, start_row - 1, start_col - 1, end_row - 1, end_col, {})
    return table.concat(lines, "\n")
  end

  vim.api.nvim_create_user_command("DapValue", function(opts)
    if opts.args == "" then
      prompt_debug_expression()
    else
      debug_hover(opts.args)
    end
  end, { nargs = "*", desc = "Evaluate a debug expression in a popup", force = true })

  vim.keymap.set("n", "<leader>dh", function() debug_hover() end, { desc = "Debug hover value" })
  vim.keymap.set("n", "<leader>de", prompt_debug_expression, { desc = "Debug evaluate expression" })
  vim.keymap.set("x", "<leader>de", function() debug_hover() end, { desc = "Debug evaluate selection" })
  vim.keymap.set("n", "<leader>dy", function() copy_debug_value() end, { desc = "Debug copy value" })
  vim.keymap.set("x", "<leader>dy", function() copy_debug_value(selected_debug_expression()) end, { desc = "Debug copy selected value" })
  vim.keymap.set("n", "<leader>ds", function()
    local widgets = require("dap.ui.widgets")
    widgets.centered_float(widgets.scopes)
  end, { desc = "Debug scopes" })
end

setup_debugging()

local git_diff_view = require("views.git_diff")
require("views.search")

local function git_blame_current_line()
  local path = vim.api.nvim_buf_get_name(0)
  if path == "" then
    vim.notify("Current buffer has no file path", vim.log.levels.WARN)
    return
  end

  local line = math.max(1, vim.api.nvim_win_get_cursor(0)[1])
  local output = vim.fn.systemlist({
    "git", "-C", vim.fn.fnamemodify(path, ":h"), "blame",
    "-L", line .. "," .. line, "--date=short", "--", vim.fn.fnamemodify(path, ":t"),
  })
  if vim.v.shell_error ~= 0 then
    vim.notify(table.concat(output, "\n"), vim.log.levels.ERROR)
    return
  end

  apply_picker_highlights()
  local _, win = vim.lsp.util.open_floating_preview(output, "text", floating_popup_options({
    title = " Git blame ",
    focusable = false,
    close_events = { "BufLeave", "CursorMoved", "CursorMovedI", "InsertEnter", "FocusLost" },
    height_cap = 8,
    height_ratio = 0.2,
  }))
  apply_floating_winhighlight(win)
end

vim.keymap.set("n", "<leader>gb", git_blame_current_line, { desc = "Git blame current line" })
vim.keymap.set("n", "<leader>gg", _G.open_lazygit, { desc = "Open lazygit" })
vim.keymap.set("n", "<leader>ge", function()
  references_view.project_errors()
end, { desc = "Project errors" })

require("agent").setup()

require("predict").setup()
vim.keymap.set("n", "<leader>ap", "<cmd>PredictToggle<cr>", { desc = "Prediction: toggle edit" })

vim.keymap.set("n", "<leader>aa", function()
  require("agent").toggle()
end, { desc = "Agent: toggle chats" })
vim.keymap.set("n", "<leader>ya", function()
  require("agent").paste_location()
end, { desc = "Agent: paste current location into active chat" })
vim.keymap.set("n", "<leader>as", function()
  require("agent").manage_presets()
end, { desc = "Agent: manage presets and choose default" })
vim.keymap.set("n", "<leader>ai", function()
  require("agent").implement_prompt()
end, { desc = "Agent: implementation prompt with default preset (background)" })
vim.keymap.set("n", "<leader>at", function()
  require("agent").implement_todo()
end, { desc = "Agent: implement todo with default preset (background)" })
vim.keymap.set("n", "<leader>ae", function()
  require("agent").fix_error()
end, { desc = "Agent: fix error with default preset (background)" })

-- Register the g-prefix browser after modules install their mappings.
for _, prefix in ipairs({ "g" }) do
  vim.keymap.set("n", prefix, function()
    which_key_prompt({ prefix }, which_key_feed_native)
  end, {
    desc = "which-key " .. prefix .. " prefix",
    nowait = true,
    silent = true,
  })
end
