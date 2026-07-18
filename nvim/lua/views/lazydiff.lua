local M = {}

local state = {
  root = nil,
  files = {},
  index = 1,
  tabpage = nil,
  diff_win = nil,
  diff_buf = nil,
  diff_winbar = nil,
  previous_showtabline = nil,
  change_targets = {},
  change_groups = {},
  source_rows = {},
  commit_prompt_win = nil,
  commit_prompt_buf = nil,
  commit_history = nil,
  commit_history_index = nil,
  diff_cache = {},
  current_only = false,
}

local namespace = vim.api.nvim_create_namespace("git_diff_view")
local KEYMAP_STATUSLINE = table.concat({
  " h/l change  j/k block  [c/]c change  n/N file edge  J/K file ",
  " <Space> stage  d discard  a all  c commit  e edit  <Tab> mode ",
  " <leader>w wrap  R refresh  L gitui  q/Esc close ",
})

local function apply_view_highlights()
  local dark = vim.o.background == "dark"
  vim.api.nvim_set_hl(0, "GitDiffViewInlineAdd", {
    fg = "#ffffff",
    bg = dark and "#1f7a3f" or "#2e7d32",
    bold = true,
  })
  vim.api.nvim_set_hl(0, "GitDiffViewInlineDelete", {
    fg = "#ffffff",
    bg = dark and "#b42318" or "#c62828",
    bold = true,
  })
  vim.api.nvim_set_hl(0, "GitDiffViewFileTab", { link = "TabLineSel" })
  vim.api.nvim_set_hl(0, "GitDiffViewFileTabPath", { link = "TabLine" })
  vim.api.nvim_set_hl(0, "GitDiffViewFileTabAdd", { link = "DiffAdd" })
  vim.api.nvim_set_hl(0, "GitDiffViewFileTabDelete", { link = "DiffDelete" })
end

local function system(args, opts)
  opts = vim.tbl_extend("force", {}, opts or {})
  local allowed_codes = opts.allowed_codes or { 0 }
  opts.allowed_codes = nil
  opts.text = true

  local result = vim.system(args, opts):wait()
  local ok = false
  for _, code in ipairs(allowed_codes) do
    if result.code == code then
      ok = true
      break
    end
  end

  if not ok then
    local message = vim.trim(result.stderr or result.stdout or "")
    return nil, message ~= "" and message or table.concat(args, " ") .. " failed"
  end
  return result.stdout or ""
end

local function git(args, opts)
  local full_args = { "git" }
  if state.root then
    table.insert(full_args, "-C")
    table.insert(full_args, state.root)
  end
  vim.list_extend(full_args, args)
  return system(full_args, opts)
end

local function repo_root()
  local output, err = system({ "git", "rev-parse", "--show-toplevel" })
  if not output then
    return nil, err
  end
  return vim.trim(output)
end

local function current_only_marker(root)
  local directory = vim.fn.stdpath("state") .. "/lazydiff/current-only"
  return directory, directory .. "/" .. vim.fn.sha256(root)
end

local function load_current_only(root)
  local _, marker = current_only_marker(root)
  return vim.fn.filereadable(marker) == 1
end

local function persist_current_only(root, enabled)
  local directory, marker = current_only_marker(root)
  if enabled then
    if vim.fn.mkdir(directory, "p") == 0 and vim.fn.isdirectory(directory) ~= 1 then
      return false
    end
    return pcall(vim.fn.writefile, { root }, marker)
  end
  return vim.fn.delete(marker) == 0 or vim.fn.filereadable(marker) == 0
end

local function split_nul(text)
  local items = {}
  local start = 1
  text = text or ""
  while start <= #text do
    local stop = text:find("\0", start, true)
    if not stop then
      break
    end
    table.insert(items, text:sub(start, stop - 1))
    start = stop + 1
  end
  return items
end

local STAGED_INDEX_STATUS = { M = true, A = true, D = true, R = true, C = true, T = true }

local function status_is_staged(status)
  return STAGED_INDEX_STATUS[status:sub(1, 1)] == true
end

local function status_has_unstaged(status)
  if status:find("%?") then
    return true
  end
  return status:sub(2, 2) ~= " "
end

local function changed_files()
  local output, err = git({ "status", "--porcelain=v1", "-z", "--untracked-files=all" })
  if not output then
    return nil, err
  end

  local files = {}
  local items = split_nul(output)
  local i = 1
  while i <= #items do
    local entry = items[i]
    local status = entry:sub(1, 2)
    local path = entry:sub(4)
    local old_path = nil

    if status:find("R") or status:find("C") then
      i = i + 1
      old_path = items[i]
    end

    if path ~= "" then
      table.insert(files, {
        path = path,
        old_path = old_path,
        status = status,
        label = status,
      })
    end
    i = i + 1
  end

  table.sort(files, function(a, b)
    return a.path < b.path
  end)
  return files
end

local function wipe_buffer(buf)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end

local function close()
  local had_active_view = state.tabpage and vim.api.nvim_tabpage_is_valid(state.tabpage)
      or state.diff_buf and vim.api.nvim_buf_is_valid(state.diff_buf)

  pcall(vim.cmd, "diffoff!")
  if state.previous_showtabline then
    vim.o.showtabline = state.previous_showtabline
  end

  if state.tabpage and vim.api.nvim_tabpage_is_valid(state.tabpage) then
    pcall(vim.api.nvim_set_current_tabpage, state.tabpage)
    pcall(vim.cmd, "tabclose")
  end

  for _, win in ipairs({ state.diff_win, state.commit_prompt_win }) do
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  for _, buf in ipairs({ state.diff_buf, state.commit_prompt_buf }) do
    wipe_buffer(buf)
  end

  state.tabpage = nil
  state.diff_win = nil
  state.diff_buf = nil
  state.diff_winbar = nil
  state.previous_showtabline = nil
  state.change_targets = {}
  state.change_groups = {}
  state.source_rows = {}
  state.commit_prompt_win = nil
  state.commit_prompt_buf = nil
  state.commit_history_index = nil
  state.diff_cache = {}
  state.current_only = false

  if had_active_view then
    vim.schedule(function()
      pcall(vim.cmd, "RereadAllBuffersAndRestartLsp")
    end)
  end
end

local function buffer_safe_lines(lines)
  local safe = {}
  for index, line in ipairs(lines or {}) do
    line = tostring(line or "")
    line = line:gsub("%z", "␀"):gsub("\r", "␍"):gsub("\n", "␊")
    safe[index] = line
  end
  return safe
end

local function set_readonly_buffer(buf, lines, name, filetype)
  vim.api.nvim_set_option_value("readonly", false, { buf = buf })
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, buffer_safe_lines(lines))
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  vim.api.nvim_set_option_value("readonly", true, { buf = buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
  vim.api.nvim_set_option_value("buflisted", false, { buf = buf })
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  if name then
    pcall(vim.api.nvim_buf_set_name, buf, name)
  end
  if filetype ~= nil then
    vim.api.nvim_set_option_value("filetype", filetype, { buf = buf })
  end
end

local function configure_diff_window(win)
  vim.wo[win].number = true
  vim.wo[win].relativenumber = false
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].statusline = KEYMAP_STATUSLINE
end

local diff_end_pad_ns = vim.api.nvim_create_namespace("GitDiffViewEndPad")

-- Blank virtual lines after the last diff line, so recentering (`zz`) near the
-- end of the buffer shows blank padding instead of eob tildes.
local function pad_diff_end(buf, win)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, diff_end_pad_ns, 0, -1)
  local height = 24
  if win and vim.api.nvim_win_is_valid(win) then
    height = vim.api.nvim_win_get_height(win)
  end
  local virt_lines = {}
  for _ = 1, math.max(1, math.floor(height / 2)) do
    table.insert(virt_lines, { { "", "NonText" } })
  end
  pcall(vim.api.nvim_buf_set_extmark, buf, diff_end_pad_ns, vim.api.nvim_buf_line_count(buf) - 1, 0, {
    virt_lines = virt_lines,
  })
end

local function disable_diff_folds(win)
  vim.wo[win].foldenable = false
  vim.wo[win].foldmethod = "manual"
  vim.wo[win].foldcolumn = "0"
end

local function set_change_cursor(target)
  if target then
    pcall(vim.api.nvim_win_set_cursor, 0, { target.row, target.col or 0 })
    -- Keep the cursor line vertically centered while navigating changes.
    -- `zz` (unlike scrolloff) also scrolls past the end of the buffer, so
    -- centering works for the last change of a short diff too.
    vim.cmd("normal! zz")
  end
end

local function adjacent_change_target(backward)
  if not state.change_targets or #state.change_targets == 0 then
    return nil
  end

  local current_row = vim.api.nvim_win_get_cursor(0)[1]
  if backward then
    for index = #state.change_targets, 1, -1 do
      if state.change_targets[index].row < current_row then
        return state.change_targets[index]
      end
    end
  else
    for _, candidate in ipairs(state.change_targets) do
      if candidate.row > current_row then
        return candidate
      end
    end
  end
  return nil
end

local function edge_change_target(backward)
  if not state.change_targets or #state.change_targets == 0 then
    return nil
  end
  return backward and state.change_targets[1] or state.change_targets[#state.change_targets]
end

local function jump_change(backward)
  set_change_cursor(adjacent_change_target(backward) or edge_change_target(backward))
end

local function adjacent_change_group(backward)
  if not state.change_groups or #state.change_groups == 0 then
    return nil
  end

  local current_row = vim.api.nvim_win_get_cursor(0)[1]
  if backward then
    for index = #state.change_groups, 1, -1 do
      if state.change_groups[index].end_row < current_row then
        return state.change_groups[index]
      end
    end
  else
    for _, group in ipairs(state.change_groups) do
      if group.start_row > current_row then
        return group
      end
    end
  end
  return nil
end

local function edge_change_group(backward)
  if not state.change_groups or #state.change_groups == 0 then
    return nil
  end
  return backward and state.change_groups[1] or state.change_groups[#state.change_groups]
end

local function row_inside_group(row, group)
  return group and row >= group.start_row and row <= group.end_row
end

local function change_target_for_row(row)
  for _, target in ipairs(state.change_targets or {}) do
    if target.row == row then
      return target
    end
  end
  return { row = row, col = 0 }
end

local function move_within_change_block(backward)
  if not state.change_groups or #state.change_groups == 0 then
    return
  end

  local current_row = vim.api.nvim_win_get_cursor(0)[1]
  for index, group in ipairs(state.change_groups) do
    if row_inside_group(current_row, group) then
      local target_row = current_row + (backward and -1 or 1)
      if row_inside_group(target_row, group) then
        set_change_cursor(change_target_for_row(target_row))
        return
      end

      local next_group = state.change_groups[index + (backward and -1 or 1)]
      if next_group then
        set_change_cursor(change_target_for_row(backward and next_group.end_row or next_group.start_row))
      end
      return
    end

    if not backward and group.start_row > current_row then
      set_change_cursor(change_target_for_row(group.start_row))
      return
    end
  end

  if backward then
    for index = #state.change_groups, 1, -1 do
      local group = state.change_groups[index]
      if group.end_row < current_row then
        set_change_cursor(change_target_for_row(group.end_row))
        return
      end
    end
  end
end

-- Move between change groups within the current file only. At the first/last
-- change the cursor stays put -- switching files is n/p (or J/K).
local function jump_change_or_file(backward)
  local target = adjacent_change_group(backward)
  if target then
    set_change_cursor(target)
    return
  end

  local edge = edge_change_group(backward)
  if not row_inside_group(vim.api.nvim_win_get_cursor(0)[1], edge) then
    set_change_cursor(edge)
  end
end

local refresh_everything

local function refresh_after_discard(path)
  local files, err = changed_files()
  if not files then
    vim.notify("Git diff view: " .. err, vim.log.levels.ERROR)
    return
  end

  if #files == 0 then
    vim.notify("Git diff view: no changed files", vim.log.levels.INFO)
    close()
    return
  end

  state.files = files

  local next_index = math.min(state.index, #state.files)
  for index, file in ipairs(state.files) do
    if file.path == path then
      next_index = index
      break
    end
  end
  M.select_file(next_index)
end

local function confirm_discard(message)
  return vim.fn.confirm(message, "&Discard\n&Cancel", 2, "Warning") == 1
end

local function current_change_group()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  for _, group in ipairs(state.change_groups or {}) do
    if row_inside_group(row, group) then
      return group
    end
  end
  return nil
end

local function patch_count(count)
  return count == 1 and "1" or tostring(count)
end

local function build_group_patch(file, group)
  local patch = {
    "diff --git a/" .. file.path .. " b/" .. file.path,
    "--- a/" .. (file.old_path or file.path),
    "+++ b/" .. file.path,
    string.format(
      "@@ -%d,%s +%d,%s @@",
      group.old_start,
      patch_count(group.old_count),
      group.new_start,
      patch_count(group.new_count)
    ),
  }

  for _, line in ipairs(group.deletes or {}) do
    table.insert(patch, "-" .. line)
  end
  for _, line in ipairs(group.adds or {}) do
    table.insert(patch, "+" .. line)
  end
  return table.concat(patch, "\n") .. "\n"
end

function M.discard_current_block()
  local file = state.files[state.index]
  if not file then
    return
  end
  if file.status:find("%?") then
    vim.notify("Git diff view: cannot discard a block from an untracked file; discard the whole file instead", vim.log.levels.WARN)
    return
  end

  local group = current_change_group()
  if not group then
    vim.notify("Git diff view: cursor is not inside a changed block", vim.log.levels.WARN)
    return
  end
  if not confirm_discard("Discard this diff block from " .. file.path .. "?") then
    return
  end

  local _, err = git({ "apply", "--reverse", "--unidiff-zero", "--whitespace=nowarn", "-" }, { stdin = build_group_patch(file, group) })
  if err then
    vim.notify("Git diff view: failed to discard block: " .. err, vim.log.levels.ERROR)
    return
  end

  -- Keep the viewer based on HEAD -> worktree. If the same change was staged,
  -- the worktree is now reverted but git status would still show the file as
  -- changed until the index is reset too. This unstages the file without
  -- removing any remaining worktree edits.
  local _, unstage_err = git({ "restore", "--staged", "--", file.path })
  if unstage_err then
    vim.notify("Git diff view: discarded block, but failed to unstage file: " .. unstage_err, vim.log.levels.WARN)
  end

  vim.notify("Git diff view: discarded block from " .. file.path, vim.log.levels.INFO)
  refresh_after_discard(file.path)
end

local function any_staged()
  for _, file in ipairs(state.files) do
    if status_is_staged(file.status) then
      return true
    end
  end
  return false
end

local function after_stage_change()
  local current = state.files[state.index] and state.files[state.index].path
  local files, err = changed_files()
  if not files then
    vim.notify("Git diff view: " .. err, vim.log.levels.ERROR)
    return
  end
  if #files == 0 then
    close()
    return
  end

  state.files = files
  state.index = 1
  for index, file in ipairs(files) do
    if file.path == current then
      state.index = index
      break
    end
  end
end

local function stage_file(file)
  local _, err = git({ "add", "-A", "--", file.path })
  return err
end

function M.stage_current_block()
  local file = state.files[state.index]
  if not file then
    return
  end

  if file.status:find("%?") then
    local err = stage_file(file)
    if err then
      vim.notify("Git diff view: failed to stage file: " .. err, vim.log.levels.ERROR)
      return
    end
    after_stage_change()
    return
  end

  local group = current_change_group()
  if not group then
    vim.notify("Git diff view: cursor is not inside a changed block", vim.log.levels.WARN)
    return
  end

  local _, err = git(
    { "apply", "--cached", "--unidiff-zero", "--whitespace=nowarn", "-" },
    { stdin = build_group_patch(file, group) }
  )
  if err then
    vim.notify("Git diff view: failed to stage block (may already be staged): " .. err, vim.log.levels.ERROR)
    return
  end
  after_stage_change()
end

function M.stage_all()
  if #state.files == 0 then
    return
  end

  local has_unstaged = false
  for _, file in ipairs(state.files) do
    if status_has_unstaged(file.status) then
      has_unstaged = true
      break
    end
  end

  local err
  if has_unstaged then
    _, err = git({ "add", "-A" })
  else
    _, err = git({ "reset", "-q" })
  end
  if err then
    vim.notify("Git diff view: failed to stage all: " .. err, vim.log.levels.ERROR)
    return
  end
  after_stage_change()
end

local function nearest_source_row(row)
  if state.source_rows[row] then
    return state.source_rows[row]
  end
  for candidate = row - 1, 1, -1 do
    if state.source_rows[candidate] then
      return state.source_rows[candidate]
    end
  end
  local last_row = state.diff_buf and vim.api.nvim_buf_is_valid(state.diff_buf) and vim.api.nvim_buf_line_count(state.diff_buf) or row
  for candidate = row + 1, last_row do
    if state.source_rows[candidate] then
      return state.source_rows[candidate]
    end
  end
  return 1
end

local function edit_current_file()
  local file = state.files[state.index]
  local row = 1
  local col = 0

  if state.diff_win and vim.api.nvim_win_is_valid(state.diff_win) then
    local cursor = vim.api.nvim_win_get_cursor(state.diff_win)
    row = nearest_source_row(cursor[1])
    col = math.max((cursor[2] or 0) - 2, 0)
  end

  if not file then
    return
  end

  local full_path = state.root .. "/" .. file.path

  -- Standalone lazydiff runs with -u NORC for a lightweight review UI. Hand
  -- edits back to its wrapper so it can replace this process with the user's
  -- normal Neovim.
  local handoff = vim.env.LAZYDIFF_EDIT_HANDOFF
  if vim.g.lazydiff_standalone and handoff and handoff ~= "" then
    local ok = pcall(vim.fn.writefile, { full_path, tostring(row), tostring(col) }, handoff)
    if not ok then
      vim.notify("Git diff view: could not hand file to editor", vim.log.levels.ERROR)
      return
    end
    vim.cmd("qa!")
    return
  end

  close()
  vim.cmd("edit " .. vim.fn.fnameescape(full_path))
  local line_count = math.max(vim.api.nvim_buf_line_count(0), 1)
  pcall(vim.api.nvim_win_set_cursor, 0, { math.min(math.max(row, 1), line_count), col })
end

local function close_commit_prompt()
  pcall(vim.cmd, "stopinsert")
  if state.commit_prompt_win and vim.api.nvim_win_is_valid(state.commit_prompt_win) then
    pcall(vim.api.nvim_win_close, state.commit_prompt_win, true)
  end
  wipe_buffer(state.commit_prompt_buf)
  state.commit_prompt_win = nil
  state.commit_prompt_buf = nil
  state.commit_history_index = nil
end

local function commit_message_history()
  if state.commit_history then
    return state.commit_history
  end

  local output = git({ "log", "-n", "50", "--format=%B%x00" }, { allowed_codes = { 0, 128 } })
  local history = {}
  local seen = {}
  for _, message in ipairs(split_nul(output or "")) do
    message = message:gsub("\n+$", "")
    if vim.trim(message) ~= "" and not seen[message] then
      table.insert(history, message)
      seen[message] = true
    end
  end
  state.commit_history = history
  return history
end

local function prompt_message(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  return table.concat(lines, "\n"):gsub("\n+$", "")
end

local function set_prompt_message(buf, message)
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(
    buf,
    0,
    -1,
    false,
    buffer_safe_lines(vim.split(message or "", "\n", { plain = true }))
  )
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  vim.api.nvim_win_set_cursor(state.commit_prompt_win, { math.max(vim.api.nvim_buf_line_count(buf), 1), 0 })
end

local function commit_all_changes(message)
  if not any_staged() then
    local _, add_err = git({ "add", "-A" })
    if add_err then
      vim.notify("Git diff view: failed to stage files: " .. add_err, vim.log.levels.ERROR)
      return
    end
  end

  local _, commit_err = git({ "commit", "--file", "-" }, { stdin = message .. "\n" })
  if commit_err then
    vim.notify("Git diff view: failed to commit: " .. commit_err, vim.log.levels.ERROR)
    return
  end

  vim.notify("Git diff view: committed changes", vim.log.levels.INFO)
  close_commit_prompt()
  refresh_everything(nil)
end

-- Reload the working-tree status and diff, keeping the
-- current file selected when it still has changes. Closes the view if nothing
-- is left to show.
function M.refresh()
  local keep = state.files[state.index] and state.files[state.index].path
  -- refresh_everything handles the empty case by showing a "No changes"
  -- placeholder, so the view stays open even when the tree is clean.
  refresh_everything(keep)
  vim.notify("Git diff view: refreshed", vim.log.levels.INFO)
end

-- Hand off to gitui for advanced repo work. Runs it in a full-screen
-- terminal tab in the same window; on exit we return to the diff view and
-- refresh, since gitui may have changed the repo state.
function M.open_gitui()
  local gitui = vim.env.NVIM_PORTABLE_GITUI or "gitui"
  if vim.fn.executable(gitui) ~= 1 then
    vim.notify("Git diff view: gitui is not installed", vim.log.levels.ERROR)
    return
  end

  local root = state.root
  local return_tab = state.tabpage

  vim.cmd("tabnew")
  local gitui_tab = vim.api.nvim_get_current_tabpage()
  local term_buf = vim.api.nvim_get_current_buf()

  vim.fn.jobstart({ gitui }, {
    cwd = root,
    term = true,
    on_exit = function()
      vim.schedule(function()
        if return_tab and vim.api.nvim_tabpage_is_valid(return_tab) then
          pcall(vim.api.nvim_set_current_tabpage, return_tab)
        end
        if vim.api.nvim_tabpage_is_valid(gitui_tab) then
          for _, win in ipairs(vim.api.nvim_tabpage_list_wins(gitui_tab)) do
            pcall(vim.api.nvim_win_close, win, true)
          end
        end
        wipe_buffer(term_buf)
        -- Reload the view; if gitui committed/stashed everything away this
        -- may close it (and, standalone, quit) -- which is the right outcome.
        M.refresh()
      end)
    end,
  })

  vim.cmd("startinsert")
end

local function open_commit_prompt()
  if state.commit_prompt_win and vim.api.nvim_win_is_valid(state.commit_prompt_win) then
    vim.api.nvim_set_current_win(state.commit_prompt_win)
    vim.cmd("startinsert!")
    return
  end

  local width = math.min(math.max(math.floor(vim.o.columns * 0.55), 48), vim.o.columns - 4)
  local height = math.min(8, math.max(3, vim.o.lines - 6))
  local row = math.max(math.floor((vim.o.lines - height) / 2) - 1, 0)
  local col = math.max(math.floor((vim.o.columns - width) / 2), 0)

  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " Commit message ",
    title_pos = "center",
    footer = " Enter: commit  Ctrl-j: newline  Up/Down: history  Esc: cancel ",
    footer_pos = "center",
  })

  state.commit_prompt_buf = buf
  state.commit_prompt_win = win
  state.commit_history_index = 0

  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("buflisted", false, { buf = buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
  vim.api.nvim_set_option_value("filetype", "gitcommit", { buf = buf })
  vim.wo[win].wrap = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false

  set_prompt_message(buf, "")
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })

  local function submit()
    local message = prompt_message(buf)
    if vim.trim(message) == "" then
      vim.notify("Git diff view: commit message is empty", vim.log.levels.WARN)
      return
    end
    commit_all_changes(message)
  end

  local function history(delta)
    local messages = commit_message_history()
    if #messages == 0 then
      return
    end
    state.commit_history_index = math.min(math.max((state.commit_history_index or 0) + delta, 1), #messages)
    set_prompt_message(buf, messages[state.commit_history_index])
    vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  end

  local opts = { buffer = buf, silent = true }
  vim.keymap.set({ "i", "n" }, "<Esc>", close_commit_prompt, opts)
  vim.keymap.set({ "i", "n" }, "<CR>", submit, opts)
  vim.keymap.set("i", "<C-j>", "<CR>", opts)
  vim.keymap.set("n", "<C-j>", "o", opts)
  vim.keymap.set({ "i", "n" }, "<Up>", function() history(1) end, opts)
  vim.keymap.set({ "i", "n" }, "<Down>", function() history(-1) end, opts)

  vim.cmd("startinsert!")
end

local function configure_diff_keymaps(buf)
  local opts = { buffer = buf, silent = true }
  vim.keymap.set("n", "q", close, vim.tbl_extend("force", opts, { desc = "Close git diff view" }))
  vim.keymap.set("n", "h", function() jump_change_or_file(true) end, vim.tbl_extend("force", opts, { desc = "Previous change" }))
  vim.keymap.set("n", "l", function() jump_change_or_file(false) end, vim.tbl_extend("force", opts, { desc = "Next change" }))
  vim.keymap.set("n", "n", function() M.next_file("first_group") end, vim.tbl_extend("force", opts, { desc = "Next file, first change" }))
  vim.keymap.set("n", "N", function() M.previous_file("last_group") end, vim.tbl_extend("force", opts, { desc = "Previous file, last change" }))
  vim.keymap.set("n", "<Esc>", close, vim.tbl_extend("force", opts, { desc = "Close git diff view" }))
  vim.keymap.set("n", "j", function() move_within_change_block(false) end, vim.tbl_extend("force", opts, { desc = "Move within/next diff block" }))
  vim.keymap.set("n", "k", function() move_within_change_block(true) end, vim.tbl_extend("force", opts, { desc = "Move within/previous diff block" }))
  vim.keymap.set("n", "]c", function() jump_change(false) end, vim.tbl_extend("force", opts, { desc = "Next change" }))
  vim.keymap.set("n", "[c", function() jump_change(true) end, vim.tbl_extend("force", opts, { desc = "Previous change" }))
  vim.keymap.set("n", "J", function() M.next_file() end, vim.tbl_extend("force", opts, { desc = "Next changed file" }))
  vim.keymap.set("n", "K", function() M.previous_file() end, vim.tbl_extend("force", opts, { desc = "Previous changed file" }))
  vim.keymap.set("n", "d", M.discard_current_block, vim.tbl_extend("force", opts, { desc = "Discard current diff block" }))
  vim.keymap.set("n", "<Space>", M.stage_current_block, vim.tbl_extend("force", opts, { desc = "Stage current diff block" }))
  vim.keymap.set("n", "<leader>w", function()
    vim.wo.wrap = not vim.wo.wrap
  end, vim.tbl_extend("force", opts, { desc = "Toggle line wrap" }))
  vim.keymap.set("n", "a", M.stage_all, vim.tbl_extend("force", opts, { desc = "Stage/unstage all changes" }))
  vim.keymap.set("n", "R", M.refresh, vim.tbl_extend("force", opts, { desc = "Refresh git diff view" }))
  vim.keymap.set("n", "L", M.open_gitui, vim.tbl_extend("force", opts, { desc = "Open gitui" }))
  vim.keymap.set("n", "c", open_commit_prompt, vim.tbl_extend("force", opts, { desc = "Commit changes" }))
  vim.keymap.set("n", "e", edit_current_file, vim.tbl_extend("force", opts, { desc = "Edit current file and close git diff view" }))
  vim.keymap.set("n", "<Tab>", M.toggle_current_only, vim.tbl_extend("force", opts, { desc = "Toggle diff/current file view" }))
end

local function hide_tabline()
  state.previous_showtabline = state.previous_showtabline or vim.o.showtabline
  vim.o.showtabline = 0
end

local function path_parts(path)
  local parts = {}
  for part in path:gmatch("[^/]+") do
    table.insert(parts, part)
  end
  return parts
end

local function binary_file_placeholder(path)
  return { "[binary file omitted: " .. path .. "]" }
end

local function file_lines_from_worktree(path)
  local full_path = state.root .. "/" .. path
  if vim.fn.filereadable(full_path) ~= 1 then
    return {}
  end

  local ok, lines = pcall(vim.fn.readfile, full_path)
  if not ok then
    return {}
  end

  for _, line in ipairs(lines) do
    if line:find("\n", 1, true) or line:find("\0", 1, true) then
      return binary_file_placeholder(path)
    end
  end
  return lines
end

local function file_lines_from_head(path)
  local output = git({ "show", "HEAD:" .. path })
  if not output then
    return {}
  end
  if output:find("\0", 1, true) then
    return binary_file_placeholder(path)
  end
  output = output:gsub("\n$", "")
  if output == "" then
    return {}
  end
  return vim.split(output, "\n", { plain = true })
end

local function diff_hunks(file)
  if file.status:find("%?") then
    return {}
  end

  local output = git({
    "diff",
    "--no-ext-diff",
    "--no-color",
    "--unified=0",
    "HEAD",
    "--",
    file.path,
  })
  if not output or output == "" then
    return {}
  end

  local hunks = {}
  local current = nil
  for _, line in ipairs(vim.split(output:gsub("\n$", ""), "\n", { plain = true })) do
    local old_start, old_count, new_start, new_count = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
    if old_start then
      current = {
        old_start = tonumber(old_start),
        old_count = old_count == "" and 1 or tonumber(old_count),
        new_start = tonumber(new_start),
        new_count = new_count == "" and 1 or tonumber(new_count),
        lines = {},
      }
      table.insert(hunks, current)
    elseif current and line:sub(1, 1) ~= "\\" then
      table.insert(current.lines, line)
    end
  end

  return hunks
end

local function token_spans(line)
  local spans = {}
  local index = 1
  while index <= #line do
    local char = line:sub(index, index)
    local pattern
    if char:match("%s") then
      pattern = "%s"
    elseif char:match("[%w_]") then
      pattern = "[%w_]"
    end

    local start_index = index
    if pattern then
      while index <= #line and line:sub(index, index):match(pattern) do
        index = index + 1
      end
    else
      index = index + 1
    end

    table.insert(spans, {
      text = line:sub(start_index, index - 1),
      start_col = start_index - 1,
      end_col = index - 1,
    })
  end
  return spans
end

local function changed_token_ranges(old_line, new_line)
  local old_tokens = token_spans(old_line)
  local new_tokens = token_spans(new_line)
  local old_count = #old_tokens
  local new_count = #new_tokens
  local dp = {}

  for i = 0, old_count do
    dp[i] = {}
    for j = 0, new_count do
      dp[i][j] = 0
    end
  end

  for i = old_count - 1, 0, -1 do
    for j = new_count - 1, 0, -1 do
      if old_tokens[i + 1].text == new_tokens[j + 1].text then
        dp[i][j] = dp[i + 1][j + 1] + 1
      else
        dp[i][j] = math.max(dp[i + 1][j], dp[i][j + 1])
      end
    end
  end

  local old_changed = {}
  local new_changed = {}
  local i = 1
  local j = 1
  while i <= old_count or j <= new_count do
    if i <= old_count and j <= new_count and old_tokens[i].text == new_tokens[j].text then
      i = i + 1
      j = j + 1
    elseif j > new_count or (i <= old_count and dp[i][j - 1] >= dp[i - 1][j]) then
      table.insert(old_changed, old_tokens[i])
      i = i + 1
    else
      table.insert(new_changed, new_tokens[j])
      j = j + 1
    end
  end

  local function merge_ranges(tokens)
    local ranges = {}
    for _, token in ipairs(tokens) do
      if #ranges > 0 and token.start_col <= ranges[#ranges].end_col then
        ranges[#ranges].end_col = math.max(ranges[#ranges].end_col, token.end_col)
      else
        table.insert(ranges, { start_col = token.start_col, end_col = token.end_col })
      end
    end
    return ranges
  end

  return merge_ranges(old_changed), merge_ranges(new_changed)
end

local function add_diff_line(result, text, kind, inline_ranges, source_row)
  local prefix = kind == "delete" and "- " or kind == "add" and "+ " or "  "
  table.insert(result.lines, prefix .. text)
  local row = #result.lines
  result.source_rows[row] = source_row

  if kind then
    table.insert(result.line_marks, {
      row = row - 1,
      group = kind == "delete" and "DiffDelete" or "DiffAdd",
    })

    local target_col = 0
    if inline_ranges and inline_ranges[1] then
      target_col = inline_ranges[1].start_col + #prefix
    end
    table.insert(result.change_targets, { row = row, col = target_col })
  end

  for _, range in ipairs(inline_ranges or {}) do
    if range.end_col > range.start_col then
      local fragment = text:sub(range.start_col + 1, range.end_col)
      local whitespace_marker = nil
      if fragment:match("^%s+$") then
        whitespace_marker = fragment:gsub(" ", "·"):gsub("\t", "→")
      end
      table.insert(result.inline_marks, {
        row = row - 1,
        start_col = range.start_col + #prefix,
        end_col = range.end_col + #prefix,
        group = kind == "delete" and "GitDiffViewInlineDelete" or "GitDiffViewInlineAdd",
        whitespace_marker = whitespace_marker,
      })
    end
  end
end

local function add_change_group_target(result, first_target_index, metadata)
  local first = result.change_targets[first_target_index]
  local last = result.change_targets[#result.change_targets]
  if first and last then
    table.insert(result.change_groups, vim.tbl_extend("force", metadata or {}, {
      row = first.row,
      col = first.col,
      start_row = first.row,
      end_row = last.row,
    }))
  end
end

local function full_line_ranges(line)
  return line == "" and {} or { { start_col = 0, end_col = #line } }
end

local function add_changed_group(result, deletes, adds, metadata)
  local first_target_index = #result.change_targets + 1
  local new_start = metadata and metadata.new_start or 1

  -- Unified diffs group adjacent replacements into one block. Pair lines by
  -- position so those replacements still get word-level highlighting; only
  -- genuinely unpaired inserted/deleted lines are highlighted in full.
  local paired_count = math.min(#deletes, #adds)
  local old_ranges = {}
  local new_ranges = {}
  for index = 1, paired_count do
    old_ranges[index], new_ranges[index] = changed_token_ranges(deletes[index], adds[index])
  end

  for index, old_line in ipairs(deletes) do
    add_diff_line(
      result,
      old_line,
      "delete",
      old_ranges[index] or full_line_ranges(old_line),
      new_start
    )
  end
  for index, new_line in ipairs(adds) do
    add_diff_line(
      result,
      new_line,
      "add",
      new_ranges[index] or full_line_ranges(new_line),
      new_start + index - 1
    )
  end
  add_change_group_target(result, first_target_index, metadata)
end

local function build_full_file_diff(file)
  local worktree_lines = file.status:find("D") and {} or file_lines_from_worktree(file.path)
  local result = {
    lines = {},
    line_marks = {},
    inline_marks = {},
    change_targets = {},
    change_groups = {},
    source_rows = {},
  }

  if file.status:find("%?") then
    local first_target_index = #result.change_targets + 1
    for row, line in ipairs(worktree_lines) do
      add_diff_line(result, line, "add", line == "" and {} or { { start_col = 0, end_col = #line } }, row)
    end
    add_change_group_target(result, first_target_index)
    return result
  end

  local hunks = diff_hunks(file)
  if #hunks == 0 then
    local source_lines = #worktree_lines > 0 and worktree_lines or file_lines_from_head(file.old_path or file.path)
    for row, line in ipairs(source_lines) do
      add_diff_line(result, line, nil, nil, row)
    end
    return result
  end

  local worktree_row = 1
  for _, hunk in ipairs(hunks) do
    local copy_until = hunk.new_count == 0 and hunk.new_start or hunk.new_start - 1
    while worktree_row <= copy_until and worktree_row <= #worktree_lines do
      add_diff_line(result, worktree_lines[worktree_row], nil, nil, worktree_row)
      worktree_row = worktree_row + 1
    end

    local deletes = {}
    local adds = {}
    local group_old_start = nil
    local group_new_start = nil
    local old_row = hunk.old_start
    local new_row = hunk.new_start
    local function mark_group_start()
      group_old_start = group_old_start or old_row
      group_new_start = group_new_start or new_row
    end
    local function flush_group()
      if #deletes > 0 or #adds > 0 then
        add_changed_group(result, deletes, adds, {
          old_start = group_old_start or old_row,
          old_count = #deletes,
          new_start = group_new_start or new_row,
          new_count = #adds,
          deletes = vim.deepcopy(deletes),
          adds = vim.deepcopy(adds),
        })
        deletes = {}
        adds = {}
        group_old_start = nil
        group_new_start = nil
      end
    end

    for _, line in ipairs(hunk.lines) do
      local prefix = line:sub(1, 1)
      local text = line:sub(2)
      if prefix == "-" then
        mark_group_start()
        table.insert(deletes, text)
        old_row = old_row + 1
      elseif prefix == "+" then
        mark_group_start()
        table.insert(adds, text)
        new_row = new_row + 1
      elseif prefix == " " then
        flush_group()
        add_diff_line(result, text, nil, nil, new_row)
        old_row = old_row + 1
        new_row = new_row + 1
      end
    end
    flush_group()

    worktree_row = math.max(worktree_row, hunk.new_start + hunk.new_count)
  end

  while worktree_row <= #worktree_lines do
    add_diff_line(result, worktree_lines[worktree_row], nil, nil, worktree_row)
    worktree_row = worktree_row + 1
  end

  return result
end

local function build_current_file_view(file, diff_result)
  local lines = file.status:find("D") and {} or file_lines_from_worktree(file.path)
  local result = {
    lines = lines,
    line_marks = {},
    inline_marks = {},
    change_targets = {},
    change_groups = {},
    source_rows = {},
    current_only = true,
  }

  for row = 1, #lines do
    result.source_rows[row] = row
  end

  local groups = diff_result.change_groups or {}
  if file.status:find("%?") then
    groups = {
      {
        new_start = 1,
        new_count = #lines,
        old_start = 0,
        old_count = 0,
        deletes = {},
        adds = vim.deepcopy(lines),
      },
    }
  end

  for _, group in ipairs(groups) do
    local new_start = group.new_start or 1
    local new_count = group.new_count or 0
    local first_row = math.min(math.max(new_start, 1), math.max(#lines, 1))
    local last_row = first_row

    if new_count > 0 then
      last_row = math.min(new_start + new_count - 1, #lines)
      for row = first_row, last_row do
        table.insert(result.line_marks, {
          row = row - 1,
          group = "DiffAdd",
          start_col = 0,
          end_col = -1,
        })
        table.insert(result.change_targets, { row = row, col = 0 })
      end
    else
      -- A deletion has no current line to color. Keep an invisible navigation
      -- anchor at its former position so block actions still work.
      table.insert(result.change_targets, { row = first_row, col = 0 })
    end

    table.insert(result.change_groups, vim.tbl_extend("force", vim.deepcopy(group), {
      row = first_row,
      col = 0,
      start_row = first_row,
      end_row = last_row,
    }))
  end

  return result
end

local function file_filetype(path)
  local ok, filetype = pcall(vim.filetype.match, { filename = path })
  return ok and filetype or ""
end

local function diff_cache_key(file)
  return table.concat({
    file.path or "",
    file.old_path or "",
    file.status or "",
    file.label or "",
  }, "\0")
end

local function apply_diff_highlights(buf, result)
  apply_view_highlights()
  vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)

  for _, mark in ipairs(result.line_marks) do
    -- Diff mode colors only the +/- marker; current-file mode colors the full
    -- changed line while omitting word-level overlays.
    vim.api.nvim_buf_add_highlight(
      buf,
      namespace,
      mark.group,
      mark.row,
      mark.start_col or 0,
      mark.end_col or 2
    )
  end
  for _, mark in ipairs(result.inline_marks) do
    vim.api.nvim_buf_add_highlight(buf, namespace, mark.group, mark.row, mark.start_col, mark.end_col)
    if mark.whitespace_marker then
      vim.api.nvim_buf_set_extmark(buf, namespace, mark.row, mark.start_col, {
        virt_text = { { mark.whitespace_marker, mark.group } },
        virt_text_pos = "overlay",
        hl_mode = "combine",
        priority = 110,
      })
    end
  end
end

local function winbar_escape(text)
  return (text or ""):gsub("%%", "%%%%")
end

local function diff_stats(result)
  local additions = 0
  local deletions = 0
  for _, mark in ipairs(result.line_marks or {}) do
    if mark.group == "DiffAdd" then
      additions = additions + 1
    elseif mark.group == "DiffDelete" then
      deletions = deletions + 1
    end
  end
  return additions, deletions
end

local function diff_file_winbar(file, result)
  local parts = path_parts(file.path)
  local name = parts[#parts] or file.path
  local parent = #parts > 1 and table.concat(parts, "/", 1, #parts - 1) .. "/" or "./"
  local status = vim.trim(file.label or "")
  local additions, deletions = diff_stats(result)

  return table.concat({
    "%#GitDiffViewFileTab#  ",
    status ~= "" and (status .. " ") or "",
    winbar_escape(name),
    "  %=",
    "%#GitDiffViewFileTabAdd# +",
    tostring(additions),
    "%#GitDiffViewFileTab#  ",
    "%#GitDiffViewFileTabDelete#-",
    tostring(deletions),
    "%#GitDiffViewFileTab#  ",
    "%#GitDiffViewFileTabPath#",
    winbar_escape(parent),
    "%#GitDiffViewFileTab#  %*",
  })
end

local function restore_diff_winbar()
  if state.diff_winbar
      and state.diff_win
      and vim.api.nvim_win_is_valid(state.diff_win)
      and state.diff_buf
      and vim.api.nvim_buf_is_valid(state.diff_buf)
      and vim.api.nvim_win_get_buf(state.diff_win) == state.diff_buf then
    vim.wo[state.diff_win].winbar = state.diff_winbar
  end
end

local function render_file(change_position, source_row)
  local file = state.files[state.index]
  if not file then
    return
  end

  local cache_key = diff_cache_key(file)
  local diff_result = state.diff_cache[cache_key]
  if not diff_result then
    diff_result = build_full_file_diff(file)
    state.diff_cache[cache_key] = diff_result
  end
  local result = state.current_only and build_current_file_view(file, diff_result) or diff_result
  state.change_targets = result.change_targets
  state.change_groups = result.change_groups
  state.source_rows = result.source_rows
  local filetype = state.current_only and file_filetype(file.path) or "diff"
  set_readonly_buffer(state.diff_buf, result.lines, "gitdiff://" .. file.path, filetype)
  apply_diff_highlights(state.diff_buf, result)

  vim.api.nvim_win_set_buf(state.diff_win, state.diff_buf)
  configure_diff_window(state.diff_win)
  pad_diff_end(state.diff_buf, state.diff_win)
  state.diff_winbar = diff_file_winbar(file, diff_result)
  restore_diff_winbar()
  disable_diff_folds(state.diff_win)
  pcall(vim.api.nvim_win_call, state.diff_win, function()
    local target = nil
    if source_row then
      for row, candidate_source_row in ipairs(state.source_rows) do
        if candidate_source_row == source_row then
          target = { row = row, col = 0 }
          break
        end
      end
    end
    if not target then
      local targets = (change_position == "last_group" or change_position == "first_group") and state.change_groups or state.change_targets
      target = (change_position == "last" or change_position == "last_group") and targets[#targets] or targets[1]
    end
    if target then
      vim.api.nvim_win_set_cursor(0, { target.row, target.col or 0 })
      vim.cmd("normal! zz")
    else
      vim.cmd("normal! gg")
    end
  end)
end

function M.toggle_current_only()
  if not (state.diff_win and vim.api.nvim_win_is_valid(state.diff_win)) then
    return
  end
  local cursor_row = vim.api.nvim_win_get_cursor(state.diff_win)[1]
  local source_row = nearest_source_row(cursor_row)
  state.current_only = not state.current_only
  if not persist_current_only(state.root, state.current_only) then
    vim.notify("Git diff view: could not save view mode", vim.log.levels.WARN)
  end
  render_file(nil, source_row)
end

refresh_everything = function(keep_path)
  state.diff_cache = {}
  local files = changed_files() or {}
  state.files = files

  if #files == 0 then
    state.index = 1
    state.change_targets = {}
    state.change_groups = {}
    state.source_rows = {}
    if state.diff_buf and vim.api.nvim_buf_is_valid(state.diff_buf) then
      set_readonly_buffer(state.diff_buf, { "No changes" }, "gitdiff://empty", "")
    end
  else
    state.index = 1
    for index, file in ipairs(files) do
      if file.path == keep_path then
        state.index = index
        break
      end
    end
    render_file()
  end

end

function M.select_file(index, change_position)
  if #state.files == 0 then
    return
  end
  state.index = math.max(1, math.min(index, #state.files))
  render_file(change_position)
end

function M.next_file(change_position)
  M.select_file(state.index + 1, change_position)
end

function M.previous_file(change_position)
  M.select_file(state.index - 1, change_position)
end

local function open_layout()
  vim.cmd("tabnew")
  state.tabpage = vim.api.nvim_get_current_tabpage()
  state.diff_buf = vim.api.nvim_create_buf(false, true)

  state.diff_win = vim.api.nvim_get_current_win()
  local placeholder_buf = vim.api.nvim_win_get_buf(state.diff_win)
  vim.api.nvim_win_set_buf(state.diff_win, state.diff_buf)
  if vim.api.nvim_buf_is_valid(placeholder_buf)
      and vim.api.nvim_buf_get_name(placeholder_buf) == ""
      and not vim.bo[placeholder_buf].modified then
    pcall(vim.api.nvim_buf_delete, placeholder_buf, { force = true })
  end

  configure_diff_keymaps(state.diff_buf)
  vim.api.nvim_set_current_win(state.diff_win)
end

-- opts.allow_empty keeps the viewer open with a "No changes" placeholder.
-- opts.focus_file selects the repo-relative file requested by LazyGit.
function M.open(opts)
  opts = opts or {}
  close()

  local root, root_err = repo_root()
  if not root then
    vim.notify("Git diff view: " .. root_err, vim.log.levels.ERROR)
    return
  end
  state.root = root
  state.current_only = load_current_only(root)

  local files, files_err = changed_files()
  if not files then
    vim.notify("Git diff view: " .. files_err, vim.log.levels.ERROR)
    return
  end
  if #files == 0 and not opts.allow_empty then
    vim.notify("Git diff view: no changed files", vim.log.levels.INFO)
    return
  end

  state.files = files
  state.index = 1
  if type(opts.focus_file) == "string" and opts.focus_file ~= "" then
    for index, file in ipairs(files) do
      if file.path == opts.focus_file then
        state.index = index
        break
      end
    end
  end
  hide_tabline()
  open_layout()
  if #files == 0 then
    state.change_targets = {}
    state.change_groups = {}
    state.source_rows = {}
    if state.diff_buf and vim.api.nvim_buf_is_valid(state.diff_buf) then
      set_readonly_buffer(state.diff_buf, { "No changes" }, "gitdiff://empty", "")
    end
  else
    render_file()
  end
end

local function setup_standalone_ui()
  vim.o.termguicolors = true
  vim.o.showtabline = 0
  vim.o.laststatus = 2
  vim.o.ruler = false
  vim.o.showmode = false
  vim.o.swapfile = false
  vim.o.shada = ""
  vim.g.mapleader = " "

  local config_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
  local bundled_path = config_root .. "/vscode-theme"
  local lazy_path = vim.fn.stdpath("data") .. "/lazy/vscode-theme"
  if vim.uv.fs_stat(bundled_path) then
    vim.opt.runtimepath:prepend(bundled_path)
  elseif vim.uv.fs_stat(lazy_path) then
    vim.opt.runtimepath:prepend(lazy_path)
  end

  local background = "dark"
  local override = vim.env.NVIM_BACKGROUND
  if override == "light" or override == "dark" then
    background = override
  elseif vim.fn.executable("gsettings") == 1 then
    local ok, out = pcall(vim.fn.system, { "gsettings", "get", "org.gnome.desktop.interface", "color-scheme" })
    if ok and vim.v.shell_error == 0 then
      out = tostring(out or ""):lower()
      if out:find("light") or out:find("default") then
        background = "light"
      elseif out:find("dark") then
        background = "dark"
      end
    end
  end

  vim.o.background = background
  local ok, vscode = pcall(require, "vscode")
  if ok then
    vscode.setup({ style = background })
  end
  pcall(vim.cmd.colorscheme, "vscode")
end

-- Launch the same diff view in a lightweight standalone Neovim process.
function M.launch(opts)
  opts = opts or {}
  vim.g.lazydiff_standalone = true
  setup_standalone_ui()

  vim.schedule(function()
    local tabs_before = #vim.api.nvim_list_tabpages()
    local focus_file = opts.focus_file
    if focus_file == "" then
      focus_file = nil
    end
    M.open({ allow_empty = true, focus_file = focus_file })

    if #vim.api.nvim_list_tabpages() <= tabs_before then
      vim.cmd("qa!")
      return
    end

    vim.api.nvim_create_autocmd("TabClosed", {
      callback = function()
        vim.schedule(function()
          if #vim.api.nvim_list_tabpages() > 1 then
            return
          end
          if vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()) ~= "" then
            return
          end
          vim.cmd("qa!")
        end)
      end,
    })
  end)
end

vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter", "WinScrolled" }, {
  group = vim.api.nvim_create_augroup("GitDiffViewWinbar", { clear = true }),
  callback = function()
    if not (state.tabpage and vim.api.nvim_tabpage_is_valid(state.tabpage)) then
      return
    end
    restore_diff_winbar()
  end,
})

vim.api.nvim_create_user_command("GitDiffView", M.open, { desc = "Open read-only git diff viewer" })

return M
