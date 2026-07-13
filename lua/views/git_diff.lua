local M = {}

local state = {
  root = nil,
  files = {},
  tree_entries = {},
  index = 1,
  tabpage = nil,
  sidebar_win = nil,
  sidebar_buf = nil,
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
  branches = {},
  branch_index = 1,
  branches_win = nil,
  branches_buf = nil,
  diff_cache = {},
  sidebar_preview_timer = nil,
  sidebar_pending_file_index = nil,
}

local namespace = vim.api.nvim_create_namespace("git_diff_view")

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
  vim.api.nvim_set_hl(0, "GitDiffViewBranchPush", { link = "DiffAdd" })
  vim.api.nvim_set_hl(0, "GitDiffViewBranchPull", { link = "DiffChange" })
  vim.api.nvim_set_hl(0, "GitDiffViewBranchSynced", { link = "Comment" })
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

local function git_async(args, on_done)
  local full_args = { "git" }
  if state.root then
    table.insert(full_args, "-C")
    table.insert(full_args, state.root)
  end
  vim.list_extend(full_args, args)
  vim.system(full_args, { text = true }, function(result)
    vim.schedule(function()
      on_done(result)
    end)
  end)
end

local function repo_root()
  local output, err = system({ "git", "rev-parse", "--show-toplevel" })
  if not output then
    return nil, err
  end
  return vim.trim(output)
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

local function cancel_sidebar_preview_timer()
  if state.sidebar_preview_timer then
    state.sidebar_preview_timer:stop()
    state.sidebar_preview_timer:close()
    state.sidebar_preview_timer = nil
  end
  state.sidebar_pending_file_index = nil
end

local function close()
  local had_active_view = state.tabpage and vim.api.nvim_tabpage_is_valid(state.tabpage)
      or state.sidebar_buf and vim.api.nvim_buf_is_valid(state.sidebar_buf)
      or state.diff_buf and vim.api.nvim_buf_is_valid(state.diff_buf)

  pcall(vim.cmd, "diffoff!")
  cancel_sidebar_preview_timer()
  if state.previous_showtabline then
    vim.o.showtabline = state.previous_showtabline
  end

  if state.tabpage and vim.api.nvim_tabpage_is_valid(state.tabpage) then
    pcall(vim.api.nvim_set_current_tabpage, state.tabpage)
    pcall(vim.cmd, "tabclose")
  end

  for _, win in ipairs({ state.sidebar_win, state.branches_win, state.diff_win, state.commit_prompt_win }) do
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  for _, buf in ipairs({ state.sidebar_buf, state.branches_buf, state.diff_buf, state.commit_prompt_buf }) do
    wipe_buffer(buf)
  end

  state.tree_entries = {}
  state.tabpage = nil
  state.sidebar_win = nil
  state.sidebar_buf = nil
  state.branches_win = nil
  state.branches_buf = nil
  state.branches = {}
  state.branch_index = 1
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
  if filetype and filetype ~= "" then
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

local build_tree_entries
local show_sidebar
local show_branches
local render_sidebar
local render_branches
local refresh_branches
local refresh_everything
local focus_branches

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
  build_tree_entries()

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

local function discard_file_changes(file)
  if file.status:find("%?") then
    local ok, err = pcall(vim.fn.delete, state.root .. "/" .. file.path, "rf")
    if ok and err ~= 0 then
      return false, "delete failed"
    end
    return ok, err
  end

  local _, err = git({ "restore", "--source=HEAD", "--staged", "--worktree", "--", file.path })
  return err == nil, err
end

function M.discard_file(index)
  index = index or state.index
  local file = state.files[index]
  if not file then
    return
  end
  state.index = index
  if not confirm_discard("Discard all changes in " .. file.path .. "?") then
    return
  end

  local ok, err = discard_file_changes(file)
  if not ok then
    vim.notify("Git diff view: failed to discard file: " .. tostring(err), vim.log.levels.ERROR)
    return
  end

  vim.notify("Git diff view: discarded " .. file.path, vim.log.levels.INFO)
  refresh_after_discard(file.path)
end

function M.discard_folder(path)
  path = path or ""
  local files = {}
  local prefix = path ~= "" and (path .. "/") or nil
  for index, file in ipairs(state.files) do
    if not prefix or file.path:sub(1, #prefix) == prefix then
      table.insert(files, { index = index, file = file })
    end
  end

  local label = path ~= "" and (path .. "/") or "the repository"
  if #files == 0 then
    vim.notify("Git diff view: no changed files in " .. label, vim.log.levels.WARN)
    return
  end
  if not confirm_discard(string.format("Discard all changes in %s (%d files)?", label, #files)) then
    return
  end

  state.index = files[1].index
  local failures = {}
  for _, item in ipairs(files) do
    local ok, err = discard_file_changes(item.file)
    if not ok then
      table.insert(failures, item.file.path .. ": " .. tostring(err))
    end
  end

  if path ~= "" then
    pcall(vim.fn.delete, state.root .. "/" .. path, "d")
  end

  if #failures > 0 then
    vim.notify("Git diff view: failed to discard some files:\n" .. table.concat(failures, "\n"), vim.log.levels.ERROR)
  else
    vim.notify(string.format("Git diff view: discarded %d files in %s", #files, label), vim.log.levels.INFO)
  end
  refresh_after_discard(path)
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
  build_tree_entries()
  state.index = 1
  for index, file in ipairs(files) do
    if file.path == current then
      state.index = index
      break
    end
  end
  render_sidebar()
end

local function stage_file(file)
  local _, err = git({ "add", "-A", "--", file.path })
  return err
end

local function unstage_file(file)
  local _, err = git({ "restore", "--staged", "--", file.path }, { allowed_codes = { 0, 1 } })
  return err
end

local function apply_file_stage(file, stage)
  if stage then
    return stage_file(file)
  end
  return unstage_file(file)
end

function M.toggle_file_stage(index)
  local file = state.files[index or state.index]
  if not file then
    return
  end
  local err = apply_file_stage(file, status_has_unstaged(file.status))
  if err then
    vim.notify("Git diff view: failed to stage file: " .. err, vim.log.levels.ERROR)
    return
  end
  after_stage_change()
end

function M.toggle_folder_stage(path)
  path = path or ""
  local prefix = path ~= "" and (path .. "/") or nil
  local matched = {}
  local stage = false
  for _, file in ipairs(state.files) do
    if not prefix or file.path:sub(1, #prefix) == prefix then
      table.insert(matched, file)
      if status_has_unstaged(file.status) then
        stage = true
      end
    end
  end
  if #matched == 0 then
    vim.notify("Git diff view: no changed files to stage", vim.log.levels.WARN)
    return
  end

  local failures = {}
  for _, file in ipairs(matched) do
    local err = apply_file_stage(file, stage)
    if err then
      table.insert(failures, file.path .. ": " .. err)
    end
  end
  if #failures > 0 then
    vim.notify("Git diff view: failed to stage some files:\n" .. table.concat(failures, "\n"), vim.log.levels.ERROR)
  end
  after_stage_change()
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

  if state.sidebar_win and vim.api.nvim_get_current_win() == state.sidebar_win then
    local entry = state.tree_entries[vim.api.nvim_win_get_cursor(state.sidebar_win)[1]]
    if entry and entry.kind == "file" then
      file = state.files[entry.file_index]
    elseif entry and entry.kind == "dir" then
      vim.notify("Git diff view: select a file to edit", vim.log.levels.WARN)
      return
    end
  elseif state.diff_win and vim.api.nvim_win_is_valid(state.diff_win) then
    local cursor = vim.api.nvim_win_get_cursor(state.diff_win)
    row = nearest_source_row(cursor[1])
    col = math.max((cursor[2] or 0) - 2, 0)
  end

  if not file then
    return
  end

  local full_path = state.root .. "/" .. file.path

  -- When lazydiff is a subprocess of Lazygit running inside Neovim, use the
  -- same parent-editor handoff as Lazygit's built-in `e` action. Otherwise the
  -- lazydiff wrapper would replace itself with a new Neovim, leaving us nested
  -- inside the original Neovim -> Lazygit terminal.
  local parent_edit_request = vim.env.LAZYGIT_NVIM_EDIT_REQUEST
  if vim.g.lazydiff_standalone and parent_edit_request and parent_edit_request ~= "" then
    local helper = vim.fn.expand("~/.config/lazygit/nvim-edit-parent")
    local output = vim.fn.system({ helper, full_path, tostring(row) })
    if vim.v.shell_error ~= 0 then
      local message = vim.trim(output or "")
      if message == "" then
        message = "parent editor handoff failed"
      end
      vim.notify("Git diff view: " .. message, vim.log.levels.ERROR)
      return
    end
    vim.cmd("qa!")
    return
  end

  -- Standalone lazydiff runs with -u NORC for a lightweight review UI. Hand
  -- edits back to its wrapper so it can replace this process with the user's
  -- normal Neovim, matching lazygit's built-in `e` action.
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

local function load_branches()
  local output = git({
    "for-each-ref",
    "--format=%(HEAD)%00%(refname:short)%00%(upstream:short)%00%(upstream:track)",
    "refs/heads",
  }, { allowed_codes = { 0, 128 } })

  local branches = {}
  for _, line in ipairs(vim.split(output or "", "\n", { plain = true })) do
    if line ~= "" then
      local parts = vim.split(line, "\0", { plain = true })
      local name = parts[2]
      if name and name ~= "" then
        local track = parts[4] or ""
        table.insert(branches, {
          current = parts[1] == "*",
          name = name,
          upstream = parts[3] ~= "" and parts[3] or nil,
          ahead = tonumber(track:match("ahead (%d+)")) or 0,
          behind = tonumber(track:match("behind (%d+)")) or 0,
        })
      end
    end
  end
  return branches
end

local function current_branch_name()
  for _, branch in ipairs(state.branches) do
    if branch.current then
      return branch.name
    end
  end
  local output = git({ "rev-parse", "--abbrev-ref", "HEAD" }, { allowed_codes = { 0, 128 } })
  return output and vim.trim(output) or nil
end

local function checkout_branch(name)
  if not name then
    return
  end
  local _, err = git({ "checkout", name })
  if err then
    vim.notify("Git diff view: failed to checkout " .. name .. ": " .. err, vim.log.levels.ERROR)
    return
  end
  vim.notify("Git diff view: checked out " .. name, vim.log.levels.INFO)
  refresh_everything(nil)
end

function M.pull()
  vim.notify("Git diff view: pulling…", vim.log.levels.INFO)
  git_async({ "pull", "--ff-only" }, function(result)
    if result.code ~= 0 then
      vim.notify("Git diff view: pull failed: " .. vim.trim(result.stderr or result.stdout or ""), vim.log.levels.ERROR)
      return
    end
    vim.notify("Git diff view: pulled", vim.log.levels.INFO)
    local keep = state.files[state.index] and state.files[state.index].path
    refresh_everything(keep)
  end)
end

function M.push()
  local branch = current_branch_name()
  vim.notify("Git diff view: pushing…", vim.log.levels.INFO)
  git_async({ "push" }, function(result)
    if result.code == 0 then
      vim.notify("Git diff view: pushed", vim.log.levels.INFO)
      refresh_branches()
      return
    end

    local message = vim.trim(result.stderr or result.stdout or "")
    if branch and message:lower():find("upstream") then
      git_async({ "push", "--set-upstream", "origin", branch }, function(result2)
        if result2.code ~= 0 then
          vim.notify("Git diff view: push failed: " .. vim.trim(result2.stderr or result2.stdout or ""), vim.log.levels.ERROR)
          return
        end
        vim.notify("Git diff view: pushed and set upstream origin/" .. branch, vim.log.levels.INFO)
        refresh_branches()
      end)
      return
    end

    vim.notify("Git diff view: push failed: " .. message, vim.log.levels.ERROR)
  end)
end

-- Reload the working-tree status, diff, and branch state from git, keeping the
-- current file selected when it still has changes. Closes the view if nothing
-- is left to show.
function M.refresh()
  local keep = state.files[state.index] and state.files[state.index].path
  -- refresh_everything handles the empty case by showing a "No changes"
  -- placeholder, so the view stays open even when the tree is clean.
  refresh_everything(keep)
  vim.notify("Git diff view: refreshed", vim.log.levels.INFO)
end

-- Hand off to lazygit for advanced repo work. Runs it in a full-screen
-- terminal tab in the same window; on exit we return to the diff view and
-- refresh, since lazygit may have changed the repo state.
function M.open_lazygit()
  if vim.fn.executable("lazygit") ~= 1 then
    vim.notify("Git diff view: lazygit is not installed", vim.log.levels.ERROR)
    return
  end

  local root = state.root
  local return_tab = state.tabpage

  vim.cmd("tabnew")
  local lazygit_tab = vim.api.nvim_get_current_tabpage()
  local term_buf = vim.api.nvim_get_current_buf()

  vim.fn.jobstart({ "lazygit" }, {
    cwd = root,
    term = true,
    on_exit = function()
      vim.schedule(function()
        if return_tab and vim.api.nvim_tabpage_is_valid(return_tab) then
          pcall(vim.api.nvim_set_current_tabpage, return_tab)
        end
        if vim.api.nvim_tabpage_is_valid(lazygit_tab) then
          for _, win in ipairs(vim.api.nvim_tabpage_list_wins(lazygit_tab)) do
            pcall(vim.api.nvim_win_close, win, true)
          end
        end
        wipe_buffer(term_buf)
        -- Reload the view; if lazygit committed/stashed everything away this
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

focus_branches = function()
  if state.branches_win and vim.api.nvim_win_is_valid(state.branches_win) then
    vim.api.nvim_set_current_win(state.branches_win)
  end
end

local function configure_diff_keymaps(buf)
  local opts = { buffer = buf, silent = true }
  vim.keymap.set("n", "q", close, vim.tbl_extend("force", opts, { desc = "Close git diff view" }))
  vim.keymap.set("n", "h", function() jump_change_or_file(true) end, vim.tbl_extend("force", opts, { desc = "Previous change" }))
  vim.keymap.set("n", "l", function() jump_change_or_file(false) end, vim.tbl_extend("force", opts, { desc = "Next change" }))
  vim.keymap.set("n", "n", function() M.next_file("first_group") end, vim.tbl_extend("force", opts, { desc = "Next file, first change" }))
  vim.keymap.set("n", "N", function() M.previous_file("last_group") end, vim.tbl_extend("force", opts, { desc = "Previous file, last change" }))
  vim.keymap.set("n", "<Esc>", function()
    -- Single-file mode has no file tree; Esc closes the view instead (so a
    -- lazygit-launched review returns to lazygit with either q or Esc).
    if state.single_file then
      close()
    elseif show_sidebar then
      show_sidebar(true)
    end
  end, vim.tbl_extend("force", opts, { desc = "Show file tree" }))
  vim.keymap.set("n", "j", function() move_within_change_block(false) end, vim.tbl_extend("force", opts, { desc = "Move within/next diff block" }))
  vim.keymap.set("n", "k", function() move_within_change_block(true) end, vim.tbl_extend("force", opts, { desc = "Move within/previous diff block" }))
  vim.keymap.set("n", "]c", function() jump_change(false) end, vim.tbl_extend("force", opts, { desc = "Next change" }))
  vim.keymap.set("n", "[c", function() jump_change(true) end, vim.tbl_extend("force", opts, { desc = "Previous change" }))
  vim.keymap.set("n", "J", function() M.next_file() end, vim.tbl_extend("force", opts, { desc = "Next changed file" }))
  vim.keymap.set("n", "K", function() M.previous_file() end, vim.tbl_extend("force", opts, { desc = "Previous changed file" }))
  vim.keymap.set("n", "d", M.discard_current_block, vim.tbl_extend("force", opts, { desc = "Discard current diff block" }))
  vim.keymap.set("n", "<Space>", M.stage_current_block, vim.tbl_extend("force", opts, { desc = "Stage current diff block" }))
  vim.keymap.set("n", "a", M.stage_all, vim.tbl_extend("force", opts, { desc = "Stage/unstage all changes" }))
  vim.keymap.set("n", "p", M.pull, vim.tbl_extend("force", opts, { desc = "Pull" }))
  vim.keymap.set("n", "P", M.push, vim.tbl_extend("force", opts, { desc = "Push" }))
  vim.keymap.set("n", "R", M.refresh, vim.tbl_extend("force", opts, { desc = "Refresh git diff view" }))
  vim.keymap.set("n", "L", M.open_lazygit, vim.tbl_extend("force", opts, { desc = "Open lazygit" }))
  vim.keymap.set("n", "<Tab>", focus_branches, vim.tbl_extend("force", opts, { desc = "Focus local branches" }))
  vim.keymap.set("n", "c", open_commit_prompt, vim.tbl_extend("force", opts, { desc = "Commit changes" }))
  vim.keymap.set("n", "e", edit_current_file, vim.tbl_extend("force", opts, { desc = "Edit current file and close git diff view" }))
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

build_tree_entries = function()
  local entries = {
    {
      kind = "dir",
      depth = 0,
      name = ".",
      path = "",
    },
  }
  local seen_dirs = {}

  for file_index, file in ipairs(state.files) do
    local parts = path_parts(file.path)
    local prefix = {}
    for i = 1, #parts - 1 do
      table.insert(prefix, parts[i])
      local dir_path = table.concat(prefix, "/")
      if not seen_dirs[dir_path] then
        table.insert(entries, {
          kind = "dir",
          depth = i,
          name = parts[i],
          path = dir_path,
        })
        seen_dirs[dir_path] = true
      end
    end

    table.insert(entries, {
      kind = "file",
      depth = #parts,
      name = parts[#parts] or file.path,
      path = file.path,
      file_index = file_index,
      label = file.label,
      status = file.status,
    })
  end

  state.tree_entries = entries
end

local function current_file_tree_row()
  for row, entry in ipairs(state.tree_entries) do
    if entry.file_index == state.index then
      return row
    end
  end
  return 1
end

local function hide_sidebar()
  if state.sidebar_win and vim.api.nvim_win_is_valid(state.sidebar_win) then
    pcall(vim.api.nvim_win_close, state.sidebar_win, true)
  end
  state.sidebar_win = nil
end

local SIDEBAR_INDENT = " "
local SIDEBAR_MIN_WIDTH = 22
local SIDEBAR_MAX_FRACTION = 0.28

local function sidebar_indent(depth)
  return string.rep(SIDEBAR_INDENT, depth)
end

local function truncate_middle(text, max_width)
  text = tostring(text or "")
  if vim.fn.strdisplaywidth(text) <= max_width then
    return text
  end
  if max_width <= 1 then
    return "…"
  end

  local suffix_width = math.max(1, math.floor((max_width - 1) * 0.6))
  local prefix_width = math.max(1, max_width - suffix_width - 1)
  local prefix = text
  local suffix = text

  while vim.fn.strdisplaywidth(prefix) > prefix_width do
    prefix = vim.fn.strcharpart(prefix, 0, math.max(vim.fn.strchars(prefix) - 1, 0))
  end
  while vim.fn.strdisplaywidth(suffix) > suffix_width do
    suffix = vim.fn.strcharpart(suffix, 1)
  end

  return prefix .. "…" .. suffix
end

local function sidebar_window_max_width()
  local max_width = math.max(SIDEBAR_MIN_WIDTH, math.floor(vim.o.columns * SIDEBAR_MAX_FRACTION))
  if vim.o.columns > 60 then
    max_width = math.min(max_width, vim.o.columns - 50)
  end
  return max_width
end

local function sidebar_line(entry, available_width)
  local indent = sidebar_indent(entry.depth)
  if entry.kind == "dir" then
    local suffix = "/"
    local max_name_width = math.max(1, (available_width or sidebar_window_max_width()) - vim.fn.strdisplaywidth(indent) - vim.fn.strdisplaywidth(suffix))
    return indent .. truncate_middle(entry.name, max_name_width) .. suffix
  end

  local prefix = string.format("%s%s ", indent, entry.label)
  local max_name_width = math.max(1, (available_width or sidebar_window_max_width()) - vim.fn.strdisplaywidth(prefix))
  return prefix .. truncate_middle(entry.name, max_name_width)
end

local function sidebar_lines(window_width)
  local available_width = math.max(1, (window_width or sidebar_window_max_width()) - 1)
  local lines = {}
  for _, entry in ipairs(state.tree_entries) do
    table.insert(lines, sidebar_line(entry, available_width))
  end
  return lines
end

local function sidebar_content_width(lines)
  local width = SIDEBAR_MIN_WIDTH
  for _, line in ipairs(lines or sidebar_lines()) do
    width = math.max(width, vim.fn.strdisplaywidth(line) + 1)
  end

  return math.min(width, sidebar_window_max_width())
end

local function resize_sidebar(lines)
  if state.sidebar_win and vim.api.nvim_win_is_valid(state.sidebar_win) then
    pcall(vim.api.nvim_win_set_width, state.sidebar_win, sidebar_content_width(lines))
  end
end

render_sidebar = function()
  if not state.sidebar_buf or not vim.api.nvim_buf_is_valid(state.sidebar_buf) then
    return
  end

  local lines = sidebar_lines()

  vim.api.nvim_set_option_value("readonly", false, { buf = state.sidebar_buf })
  vim.api.nvim_set_option_value("modifiable", true, { buf = state.sidebar_buf })
  vim.api.nvim_buf_set_lines(state.sidebar_buf, 0, -1, false, buffer_safe_lines(lines))
  vim.api.nvim_buf_clear_namespace(state.sidebar_buf, namespace, 0, -1)
  vim.api.nvim_set_option_value("modifiable", false, { buf = state.sidebar_buf })
  vim.api.nvim_set_option_value("readonly", true, { buf = state.sidebar_buf })

  for row, entry in ipairs(state.tree_entries) do
    if entry.kind == "dir" then
      vim.api.nvim_buf_add_highlight(state.sidebar_buf, namespace, "Directory", row - 1, 0, -1)
    else
      local status = entry.status or "  "
      local status_start = #sidebar_indent(entry.depth)
      local untracked = status:find("%?") ~= nil
      local staged = status_is_staged(status)
      local unstaged = status_has_unstaged(status)

      if untracked then
        vim.api.nvim_buf_add_highlight(state.sidebar_buf, namespace, "DiffDelete", row - 1, status_start, status_start + 2)
      else
        if staged then
          vim.api.nvim_buf_add_highlight(state.sidebar_buf, namespace, "DiffAdd", row - 1, status_start, status_start + 1)
        end
        if unstaged then
          local group = status:sub(2, 2) == "D" and "DiffDelete" or "DiffChange"
          vim.api.nvim_buf_add_highlight(state.sidebar_buf, namespace, group, row - 1, status_start + 1, status_start + 2)
        end
      end

      if staged and not unstaged then
        vim.api.nvim_buf_add_highlight(state.sidebar_buf, namespace, "DiffAdd", row - 1, status_start + 3, -1)
      end
    end
  end

  if state.sidebar_win and vim.api.nvim_win_is_valid(state.sidebar_win) then
    resize_sidebar(lines)
    vim.api.nvim_win_set_cursor(state.sidebar_win, { current_file_tree_row(), 0 })
  end
end

-- Build a branch row as a list of {text, group} segments. Byte offsets are
-- derived from the segment lengths so multibyte glyphs highlight correctly.
local function branch_segments(branch)
  local segments = {
    { text = branch.current and "* " or "  " },
    { text = branch.name, group = branch.current and "GitDiffViewBranchSynced" or nil },
  }

  if not branch.upstream then
    segments[#segments + 1] = { text = "  ⚑ no upstream", group = "GitDiffViewBranchSynced" }
  elseif branch.behind == 0 and branch.ahead == 0 then
    segments[#segments + 1] = { text = "  ✓", group = "GitDiffViewBranchSynced" }
  else
    if branch.behind > 0 then
      segments[#segments + 1] = { text = "  ⇣" .. branch.behind, group = "GitDiffViewBranchPull" }
    end
    if branch.ahead > 0 then
      segments[#segments + 1] = { text = "  ⇡" .. branch.ahead, group = "GitDiffViewBranchPush" }
    end
  end

  return segments
end

local function current_branch_row()
  for row, branch in ipairs(state.branches) do
    if branch.current then
      return row
    end
  end
  return 1
end

render_branches = function()
  if not state.branches_buf or not vim.api.nvim_buf_is_valid(state.branches_buf) then
    return
  end

  apply_view_highlights()

  local lines = {}
  local marks = {}
  for row, branch in ipairs(state.branches) do
    local text = ""
    for _, segment in ipairs(branch_segments(branch)) do
      local start_col = #text
      text = text .. segment.text
      if segment.group then
        table.insert(marks, { row = row - 1, start_col = start_col, end_col = #text, group = segment.group })
      end
    end
    lines[row] = text
  end
  if #lines == 0 then
    lines = { "(no local branches)" }
  end

  vim.api.nvim_set_option_value("readonly", false, { buf = state.branches_buf })
  vim.api.nvim_set_option_value("modifiable", true, { buf = state.branches_buf })
  vim.api.nvim_buf_set_lines(state.branches_buf, 0, -1, false, buffer_safe_lines(lines))
  vim.api.nvim_buf_clear_namespace(state.branches_buf, namespace, 0, -1)
  vim.api.nvim_set_option_value("modifiable", false, { buf = state.branches_buf })
  vim.api.nvim_set_option_value("readonly", true, { buf = state.branches_buf })

  for _, mark in ipairs(marks) do
    vim.api.nvim_buf_add_highlight(state.branches_buf, namespace, mark.group, mark.row, mark.start_col, mark.end_col)
  end

  if state.branches_win and vim.api.nvim_win_is_valid(state.branches_win) and #state.branches > 0 then
    state.branch_index = math.max(1, math.min(state.branch_index, #state.branches))
    pcall(vim.api.nvim_win_set_cursor, state.branches_win, { state.branch_index, 0 })
  end
end

refresh_branches = function()
  state.branches = load_branches()
  render_branches()
end

-- Fetch quietly in the background so behind/ahead counts reflect the real
-- remote state (what's available to pull) without blocking the UI.
local function fetch_remote()
  local remotes = git({ "remote" }, { allowed_codes = { 0, 128 } })
  if not remotes or vim.trim(remotes) == "" then
    return
  end
  git_async({ "fetch", "--quiet", "--prune" }, function()
    refresh_branches()
  end)
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
    -- Keep the +/- marker colored without washing the entire changed line.
    vim.api.nvim_buf_add_highlight(buf, namespace, mark.group, mark.row, 0, 2)
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

local function render_file(change_position)
  local file = state.files[state.index]
  if not file then
    return
  end

  local cache_key = diff_cache_key(file)
  local result = state.diff_cache[cache_key]
  if not result then
    result = build_full_file_diff(file)
    state.diff_cache[cache_key] = result
  end
  state.change_targets = result.change_targets
  state.change_groups = result.change_groups
  state.source_rows = result.source_rows
  set_readonly_buffer(state.diff_buf, result.lines, "gitdiff://" .. file.path, "diff")
  apply_diff_highlights(state.diff_buf, result)

  vim.api.nvim_win_set_buf(state.diff_win, state.diff_buf)
  configure_diff_window(state.diff_win)
  pad_diff_end(state.diff_buf, state.diff_win)
  state.diff_winbar = diff_file_winbar(file, result)
  restore_diff_winbar()
  disable_diff_folds(state.diff_win)
  pcall(vim.api.nvim_win_call, state.diff_win, function()
    local targets = (change_position == "last_group" or change_position == "first_group") and state.change_groups or state.change_targets
    local target = (change_position == "last" or change_position == "last_group") and targets[#targets] or targets[1]
    if target then
      vim.api.nvim_win_set_cursor(0, { target.row, target.col or 0 })
      vim.cmd("normal! zz")
    else
      vim.cmd("normal! gg")
    end
  end)
  render_sidebar()
end

refresh_everything = function(keep_path)
  cancel_sidebar_preview_timer()
  state.diff_cache = {}
  local files = changed_files() or {}
  state.files = files
  build_tree_entries()

  if #files == 0 then
    state.index = 1
    state.change_targets = {}
    state.change_groups = {}
    state.source_rows = {}
    if state.diff_buf and vim.api.nvim_buf_is_valid(state.diff_buf) then
      set_readonly_buffer(state.diff_buf, { "No changes" }, "gitdiff://empty", "")
    end
    render_sidebar()
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

  refresh_branches()
end

function M.select_file(index, change_position)
  if #state.files == 0 then
    return
  end
  cancel_sidebar_preview_timer()
  state.index = math.max(1, math.min(index, #state.files))
  render_file(change_position)
end

function M.next_file(change_position)
  M.select_file(state.index + 1, change_position)
end

function M.previous_file(change_position)
  M.select_file(state.index - 1, change_position)
end

local function select_tree_row(row)
  local entry = state.tree_entries[row]
  if entry and entry.kind == "file" then
    cancel_sidebar_preview_timer()
    M.select_file(entry.file_index)
    if state.diff_win and vim.api.nvim_win_is_valid(state.diff_win) then
      vim.api.nvim_set_current_win(state.diff_win)
    end
  end
end

local function preview_sidebar_file(index)
  if not index or index == state.index then
    return
  end

  cancel_sidebar_preview_timer()
  state.sidebar_pending_file_index = index
  local uv = vim.uv or vim.loop
  state.sidebar_preview_timer = uv.new_timer()
  state.sidebar_preview_timer:start(80, 0, function()
    local pending = state.sidebar_pending_file_index
    cancel_sidebar_preview_timer()
    vim.schedule(function()
      if pending
          and state.sidebar_win
          and vim.api.nvim_win_is_valid(state.sidebar_win)
          and state.diff_win
          and vim.api.nvim_win_is_valid(state.diff_win)
          and state.files[pending] then
        M.select_file(pending)
        if state.sidebar_win and vim.api.nvim_win_is_valid(state.sidebar_win) then
          vim.api.nvim_set_current_win(state.sidebar_win)
        end
      end
    end)
  end)
end

local function move_tree_cursor(delta)
  if not state.sidebar_win or not vim.api.nvim_win_is_valid(state.sidebar_win) or #state.tree_entries == 0 then
    return
  end

  local row = vim.api.nvim_win_get_cursor(state.sidebar_win)[1]
  row = math.max(1, math.min(row + delta, #state.tree_entries))
  local entry = state.tree_entries[row]

  if entry and entry.kind == "file" then
    preview_sidebar_file(entry.file_index)
  end
  if state.sidebar_win and vim.api.nvim_win_is_valid(state.sidebar_win) then
    vim.api.nvim_set_current_win(state.sidebar_win)
    vim.api.nvim_win_set_cursor(state.sidebar_win, { row, 0 })
  end
end

local function configure_sidebar()
  set_readonly_buffer(state.sidebar_buf, {}, "gitdiff://files", "gitdiffview")
  vim.wo[state.sidebar_win].number = false
  vim.wo[state.sidebar_win].relativenumber = false
  vim.wo[state.sidebar_win].wrap = false
  vim.wo[state.sidebar_win].cursorline = true
  vim.wo[state.sidebar_win].signcolumn = "no"
  vim.wo[state.sidebar_win].foldcolumn = "0"
  vim.wo[state.sidebar_win].winfixwidth = true
  vim.wo[state.sidebar_win].winbar = " Changed files "

  local opts = { buffer = state.sidebar_buf, silent = true }
  vim.keymap.set("n", "q", close, vim.tbl_extend("force", opts, { desc = "Close git diff view" }))
  vim.keymap.set("n", "j", function() move_tree_cursor(vim.v.count1) end, vim.tbl_extend("force", opts, { desc = "Move down in file tree" }))
  vim.keymap.set("n", "k", function() move_tree_cursor(-vim.v.count1) end, vim.tbl_extend("force", opts, { desc = "Move up in file tree" }))
  vim.keymap.set("n", "l", function()
    if state.diff_win and vim.api.nvim_win_is_valid(state.diff_win) then
      vim.api.nvim_set_current_win(state.diff_win)
    end
  end, vim.tbl_extend("force", opts, { desc = "Go to diff" }))
  vim.keymap.set("n", "<CR>", function()
    select_tree_row(vim.api.nvim_win_get_cursor(state.sidebar_win)[1])
  end, vim.tbl_extend("force", opts, { desc = "Select changed file" }))
  vim.keymap.set("n", "d", function()
    local entry = state.tree_entries[vim.api.nvim_win_get_cursor(state.sidebar_win)[1]]
    if entry and entry.kind == "file" then
      M.discard_file(entry.file_index)
    elseif entry and entry.kind == "dir" then
      M.discard_folder(entry.path)
    else
      vim.notify("Git diff view: select a file or folder to discard", vim.log.levels.WARN)
    end
  end, vim.tbl_extend("force", opts, { desc = "Discard selected file or folder changes" }))
  vim.keymap.set("n", "<Space>", function()
    local entry = state.tree_entries[vim.api.nvim_win_get_cursor(state.sidebar_win)[1]]
    if entry and entry.kind == "file" then
      M.toggle_file_stage(entry.file_index)
    elseif entry and entry.kind == "dir" then
      M.toggle_folder_stage(entry.path)
    else
      vim.notify("Git diff view: select a file or folder to stage", vim.log.levels.WARN)
    end
  end, vim.tbl_extend("force", opts, { desc = "Stage/unstage selected file or folder" }))
  vim.keymap.set("n", "a", M.stage_all, vim.tbl_extend("force", opts, { desc = "Stage/unstage all changes" }))
  vim.keymap.set("n", "p", M.pull, vim.tbl_extend("force", opts, { desc = "Pull" }))
  vim.keymap.set("n", "P", M.push, vim.tbl_extend("force", opts, { desc = "Push" }))
  vim.keymap.set("n", "R", M.refresh, vim.tbl_extend("force", opts, { desc = "Refresh git diff view" }))
  vim.keymap.set("n", "L", M.open_lazygit, vim.tbl_extend("force", opts, { desc = "Open lazygit" }))
  vim.keymap.set("n", "<Tab>", focus_branches, vim.tbl_extend("force", opts, { desc = "Focus local branches" }))
  vim.keymap.set("n", "c", open_commit_prompt, vim.tbl_extend("force", opts, { desc = "Commit changes" }))
  vim.keymap.set("n", "e", edit_current_file, vim.tbl_extend("force", opts, { desc = "Edit selected file and close git diff view" }))
end

local function move_branch_cursor(delta)
  if not state.branches_win or not vim.api.nvim_win_is_valid(state.branches_win) or #state.branches == 0 then
    return
  end
  local row = vim.api.nvim_win_get_cursor(state.branches_win)[1]
  row = math.max(1, math.min(row + delta, #state.branches))
  state.branch_index = row
  vim.api.nvim_win_set_cursor(state.branches_win, { row, 0 })
end

local function focus_sidebar()
  if state.sidebar_win and vim.api.nvim_win_is_valid(state.sidebar_win) then
    vim.api.nvim_set_current_win(state.sidebar_win)
  end
end

local function configure_branches()
  set_readonly_buffer(state.branches_buf, {}, "gitdiff://branches", "gitdiffview")
  vim.wo[state.branches_win].number = false
  vim.wo[state.branches_win].relativenumber = false
  vim.wo[state.branches_win].wrap = false
  vim.wo[state.branches_win].cursorline = true
  vim.wo[state.branches_win].signcolumn = "no"
  vim.wo[state.branches_win].foldcolumn = "0"
  vim.wo[state.branches_win].winfixheight = true
  vim.wo[state.branches_win].winbar = " Local branches "

  local opts = { buffer = state.branches_buf, silent = true }
  vim.keymap.set("n", "q", close, vim.tbl_extend("force", opts, { desc = "Close git diff view" }))
  vim.keymap.set("n", "j", function() move_branch_cursor(vim.v.count1) end, vim.tbl_extend("force", opts, { desc = "Move down in branches" }))
  vim.keymap.set("n", "k", function() move_branch_cursor(-vim.v.count1) end, vim.tbl_extend("force", opts, { desc = "Move up in branches" }))
  vim.keymap.set("n", "<CR>", function()
    local branch = state.branches[vim.api.nvim_win_get_cursor(state.branches_win)[1]]
    if branch then
      checkout_branch(branch.name)
    end
  end, vim.tbl_extend("force", opts, { desc = "Checkout branch" }))
  vim.keymap.set("n", "p", M.pull, vim.tbl_extend("force", opts, { desc = "Pull" }))
  vim.keymap.set("n", "P", M.push, vim.tbl_extend("force", opts, { desc = "Push" }))
  vim.keymap.set("n", "R", M.refresh, vim.tbl_extend("force", opts, { desc = "Refresh git diff view" }))
  vim.keymap.set("n", "L", M.open_lazygit, vim.tbl_extend("force", opts, { desc = "Open lazygit" }))
  vim.keymap.set("n", "<Tab>", focus_sidebar, vim.tbl_extend("force", opts, { desc = "Focus changed files" }))
  vim.keymap.set("n", "<Esc>", focus_sidebar, vim.tbl_extend("force", opts, { desc = "Focus changed files" }))
end

show_branches = function()
  if not state.branches_buf or not vim.api.nvim_buf_is_valid(state.branches_buf) then
    return
  end

  state.branches = load_branches()
  state.branch_index = current_branch_row()

  if not (state.branches_win and vim.api.nvim_win_is_valid(state.branches_win)) then
    if not (state.sidebar_win and vim.api.nvim_win_is_valid(state.sidebar_win)) then
      return
    end
    vim.api.nvim_set_current_win(state.sidebar_win)
    vim.cmd("belowright new")
    state.branches_win = vim.api.nvim_get_current_win()
    local placeholder_buf = vim.api.nvim_win_get_buf(state.branches_win)
    vim.api.nvim_win_set_buf(state.branches_win, state.branches_buf)
    if vim.api.nvim_buf_is_valid(placeholder_buf)
        and vim.api.nvim_buf_get_name(placeholder_buf) == ""
        and not vim.bo[placeholder_buf].modified then
      pcall(vim.api.nvim_buf_delete, placeholder_buf, { force = true })
    end
    configure_branches()
    local height = math.max(4, math.min(#state.branches + 1, 14))
    pcall(vim.api.nvim_win_set_height, state.branches_win, height)
  end

  render_branches()
end

show_sidebar = function(focus)
  if not state.sidebar_buf or not vim.api.nvim_buf_is_valid(state.sidebar_buf) then
    return
  end

  local previous_win = vim.api.nvim_get_current_win()
  if state.sidebar_win and vim.api.nvim_win_is_valid(state.sidebar_win) then
    resize_sidebar()
  else
    vim.cmd("topleft vnew")
    state.sidebar_win = vim.api.nvim_get_current_win()
    local placeholder_buf = vim.api.nvim_win_get_buf(state.sidebar_win)
    vim.api.nvim_win_set_buf(state.sidebar_win, state.sidebar_buf)
    if vim.api.nvim_buf_is_valid(placeholder_buf)
        and vim.api.nvim_buf_get_name(placeholder_buf) == ""
        and not vim.bo[placeholder_buf].modified then
      pcall(vim.api.nvim_buf_delete, placeholder_buf, { force = true })
    end
    configure_sidebar()
    resize_sidebar()
  end

  render_sidebar()
  if focus and state.sidebar_win and vim.api.nvim_win_is_valid(state.sidebar_win) then
    vim.api.nvim_set_current_win(state.sidebar_win)
  elseif previous_win and vim.api.nvim_win_is_valid(previous_win) then
    vim.api.nvim_set_current_win(previous_win)
  end
end

local function open_layout()
  vim.cmd("tabnew")
  state.tabpage = vim.api.nvim_get_current_tabpage()
  state.sidebar_buf = vim.api.nvim_create_buf(false, true)
  state.branches_buf = vim.api.nvim_create_buf(false, true)
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
  if state.single_file then
    vim.api.nvim_set_current_win(state.diff_win)
  else
    show_sidebar(true)
    show_branches()
    focus_sidebar()
  end
end

-- opts.allow_empty keeps the view open with a "No changes" placeholder instead
-- of bailing out when the working tree is clean (used by standalone lazydiff).
-- Note: invoked as a user command, opts is the command table, which has no
-- allow_empty field -- so :GitDiffView keeps its bail-on-empty behavior.
function M.open(opts)
  opts = opts or {}
  close()

  local root, root_err = repo_root()
  if not root then
    vim.notify("Git diff view: " .. root_err, vim.log.levels.ERROR)
    return
  end
  state.root = root

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
  build_tree_entries()
  state.index = 1
  -- opts.focus_file: repo-relative path to select on open (used by the
  -- lazydiff wrapper when invoked from lazygit on a specific file).
  -- opts.single_file: with a matched focus_file, show only that file's diff
  -- full-width -- no file tree or branches panel.
  state.single_file = false
  if type(opts.focus_file) == "string" and opts.focus_file ~= "" then
    for index, file in ipairs(files) do
      if file.path == opts.focus_file then
        state.index = index
        state.single_file = opts.single_file == true
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
    render_sidebar()
  else
    render_file()
  end
  fetch_remote()
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
