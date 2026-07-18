local git = require("views.git")
local M = {}

local S = { root = nil, tab = nil, panels = {}, order = { "files", "commits", "locals", "remotes", "stashes" },
  active = 1, collapsed = {}, commit_files = nil, commits_show_changes = false, stash_files = nil, busy = false,
  maximized_tab = nil, dashboard_tab = nil, dashboard_win = nil }

local ns = vim.api.nvim_create_namespace("lazyrepo")

local function setup_highlights()
  local hl = vim.api.nvim_set_hl
  hl(0, "LazyrepoStaged", { link = "Added" })
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  hl(0, "LazyrepoUnstaged", { fg = vim.o.background == "light" and 0x000000 or normal.fg })
  hl(0, "LazyrepoMixed", { link = "DiagnosticWarn" })
  hl(0, "LazyrepoConflict", { link = "DiagnosticError" })
  hl(0, "LazyrepoFolder", { link = "Directory" })
  hl(0, "LazyrepoHash", { link = "Constant" })
  hl(0, "LazyrepoDate", { link = "Special" })
  hl(0, "LazyrepoMuted", { link = "Comment" })
  local added = vim.api.nvim_get_hl(0, { name = "Added", link = false })
  local comment = vim.api.nvim_get_hl(0, { name = "Comment", link = false })
  hl(0, "LazyrepoCurrent", { fg = added.fg, bold = true })
  hl(0, "LazyrepoTitle", { fg = comment.fg })
  hl(0, "LazyrepoTitleActive", { fg = added.fg, bold = true })
end

local function notify_error(message)
  if message and message ~= "" then vim.notify(message, vim.log.levels.ERROR, { title = "lazyrepo: Git error" }) end
end

local function panel(name) return S.panels[name] end
local function selected(name)
  local p = panel(name or S.order[S.active])
  return p and p.items[p.index]
end

-- Returns the rendered line plus highlight spans: { group, start_col, end_col } (byte offsets, -1 = eol).
local function line_for(name, item)
  if item.placeholder then return "  " .. item.placeholder, { { "LazyrepoMuted", 0, -1 } } end
  if item.kind then
    local indent = string.rep("  ", item.depth or 0)
    if item.kind == "folder" then
      local group = item.conflict and "LazyrepoConflict"
        or item.staged and item.unstaged and "LazyrepoMixed"
        or item.staged and "LazyrepoStaged"
        or item.unstaged and "LazyrepoUnstaged"
        or "LazyrepoFolder"
      return indent .. (S.collapsed[item.path] and "▸ " or "▾ ") .. item.name, { { group, #indent, -1 } }
    end
    local status = item.status or "  "
    local group = item.conflict and "LazyrepoConflict"
      or status == "??" and "LazyrepoUnstaged"
      or item.staged and item.unstaged and "LazyrepoMixed"
      or (item.staged and not item.unstaged or item.staged == nil) and "LazyrepoStaged"
      or "LazyrepoUnstaged"
    return indent .. status .. " " .. (item.path:match("[^/]+$") or item.path), { { group, #indent, -1 } }
  elseif name == "commits" then
    return string.format("%s %s %s", item.short, item.date, item.subject),
      { { "LazyrepoHash", 0, #item.short }, { "LazyrepoDate", #item.short + 1, #item.short + 1 + #item.date } }
  elseif name == "locals" then
    local head = (item.current and "* " or "  ") .. item.name
    local line = head .. (item.upstream ~= "" and " → " .. item.upstream or "")
    local spans = {}
    if item.current then spans[#spans + 1] = { "LazyrepoCurrent", 0, #head } end
    if item.upstream ~= "" then spans[#spans + 1] = { "LazyrepoMuted", #head, -1 } end
    return line, spans
  elseif name == "remotes" then return "  " .. item.name, {}
  end
  return string.format("%s %s", item.ref, item.subject), { { "LazyrepoHash", 0, #item.ref } }
end

local function decorate()
  for _, name in ipairs(S.order) do
    local p = panel(name)
    if p and vim.api.nvim_buf_is_valid(p.buf) then
      local active = S.order[S.active] == name
      local title_hl = active and "LazyrepoTitleActive" or "LazyrepoTitle"
      local count = p.items and #p.items > 0 and not (p.items[1] or {}).placeholder
        and string.format("%d of %d ", p.index or 1, #p.items) or ""
      local bar = " " .. p.title:gsub("%%", "%%%%") .. (S.busy and "  [working…]" or "") .. " %=" .. count
      for _, win in ipairs(vim.fn.win_findbuf(p.buf)) do
        if vim.api.nvim_win_is_valid(win) then
          vim.wo[win].winbar = bar
          vim.wo[win].winhighlight = "WinBar:" .. title_hl .. ",WinBarNC:" .. title_hl
        end
      end
    end
  end
end

local function render(name)
  local p = panel(name)
  if not p or not vim.api.nvim_buf_is_valid(p.buf) then return end
  local lines, spans = {}, {}
  for _, item in ipairs(p.items) do
    local line, line_spans = line_for(name, item)
    lines[#lines + 1] = line
    spans[#lines] = line_spans
  end
  if #lines == 0 then
    lines, p.items = { "  (empty)" }, { { placeholder = "(empty)" } }
    spans[1] = { { "LazyrepoMuted", 0, -1 } }
  end
  p.index = math.max(1, math.min(p.index or 1, #p.items))
  vim.bo[p.buf].modifiable = true
  vim.api.nvim_buf_set_lines(p.buf, 0, -1, false, lines)
  vim.bo[p.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(p.buf, ns, 0, -1)
  for row, line_spans in pairs(spans) do
    for _, span in ipairs(line_spans) do
      pcall(vim.api.nvim_buf_set_extmark, p.buf, ns, row - 1, span[2],
        { end_col = span[3] == -1 and #lines[row] or span[3], hl_group = span[1] })
    end
  end
  for _, win in ipairs(vim.fn.win_findbuf(p.buf)) do
    if vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_set_cursor, win, { p.index, 0 }) end
  end
  decorate()
end

local function preserve(p, items, key)
  local old = p.items and p.items[p.index]
  local stable = old and old[key]
  local old_index = p.index or 1
  p.items, p.index = items or {}, math.min(old_index, math.max(1, #(items or {})))
  if stable then for i, item in ipairs(p.items) do if item[key] == stable then p.index = i; break end end end
end

local function load_commits(ref)
  local commits, err = git.commits(S.root, ref or "HEAD")
  if not commits then notify_error(err); commits = {} end
  S.commit_files = nil
  S.commits_show_changes = #commits == 0
  if S.commits_show_changes then
    local files, files_err = git.status(S.root)
    if not files then notify_error(files_err); files = {} end
    preserve(panel("commits"), git.tree(files, S.collapsed), "path")
    panel("commits").title = "Changed files"
  else
    preserve(panel("commits"), commits, "oid")
    panel("commits").title = "Commits"
  end
  render("commits")
end

function M.refresh()
  if not S.root then return end
  local files, ferr = git.status(S.root)
  local locals, lerr = git.refs(S.root, false)
  local remotes, rerr = git.refs(S.root, true)
  local stashes, serr = git.stashes(S.root)
  local errors = { ferr, lerr, rerr, serr }
  preserve(panel("files"), git.tree(files or {}, S.collapsed), "path")
  preserve(panel("locals"), locals or {}, "name")
  preserve(panel("remotes"), remotes or {}, "name")
  preserve(panel("stashes"), stashes or {}, "oid")
  for _, name in ipairs({ "files", "locals", "remotes", "stashes" }) do render(name) end
  local branch = selected("locals")
  load_commits(branch and branch.name or "HEAD")
  for _, err in ipairs(errors) do if err then notify_error(err); break end end
end

local function focus(delta)
  S.active = ((S.active - 1 + delta) % #S.order) + 1
  local p = panel(S.order[S.active])
  if not p then return end
  if S.maximized_tab and vim.api.nvim_tabpage_is_valid(S.maximized_tab)
      and vim.api.nvim_get_current_tabpage() == S.maximized_tab then
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, p.buf)
    pcall(vim.api.nvim_win_set_cursor, win, { p.index, 0 })
  elseif vim.api.nvim_win_is_valid(p.win) then
    vim.api.nvim_set_current_win(p.win)
  end
  decorate()
end

local function move(delta)
  local name, p = S.order[S.active], panel(S.order[S.active])
  p.index = math.max(1, math.min(#p.items, p.index + delta))
  render(name)
  if name == "locals" or name == "remotes" then
    local item = selected(name)
    if item and item.name then load_commits(item.name) end
  end
end

local function run(args, label, async)
  if S.busy then return end
  S.busy = true
  for _, name in ipairs(S.order) do render(name) end
  local done = function(ok, _, err)
    S.busy = false
    if not ok then notify_error((label or "Git operation") .. " failed:\n" .. err) end
    M.refresh()
  end
  if async then git.git_async(S.root, args, done) else
    local out, err = git.git(S.root, args); done(out ~= nil, out or "", err or "")
  end
end

local function confirm(prompt, callback)
  vim.ui.select({ "No", "Yes" }, { prompt = prompt }, function(choice) if choice == "Yes" then callback() end end)
end

local function stage_selection()
  local item = selected("files"); if not item or item.placeholder then return end
  local path = item.path
  local args = item.staged and not item.unstaged and { "restore", "--staged", "--", path } or { "add", "-A", "--", path }
  run(args, "Stage", false)
end

local function stage_all()
  local files = git.status(S.root) or {}
  local has_unstaged = false
  for _, file in ipairs(files) do if file.unstaged then has_unstaged = true; break end end
  run(has_unstaged and { "add", "-A" } or { "reset", "HEAD", "--" }, "Stage all", false)
end

local function discard()
  local item = selected("files"); if not item or item.placeholder then return end
  confirm("Discard changes under " .. item.path .. "?", function()
    local files = git.status(S.root) or {}
    local targets = {}
    for _, file in ipairs(files) do if file.path == item.path or file.path:sub(1, #item.path + 1) == item.path .. "/" then targets[#targets + 1] = file end end
    for _, file in ipairs(targets) do
      if file.status == "??" then vim.fn.delete(S.root .. "/" .. file.path)
      else
        if file.status:sub(1, 1) == "A" then git.git(S.root, { "restore", "--staged", "--", file.path }); vim.fn.delete(S.root .. "/" .. file.path)
        else git.git(S.root, { "restore", "--staged", "--worktree", "--", file.path }) end
      end
    end
    M.refresh()
  end)
end

local function ignore_selection()
  local name = S.order[S.active]
  if name ~= "files" and not (name == "commits" and S.commits_show_changes) then return end
  local item = selected(name)
  if not item or item.placeholder or not item.path then return end
  if item.path:find("\n", 1, true) or item.path:find("\r", 1, true) then
    notify_error("Paths containing newlines cannot be added safely to .gitignore")
    return
  end

  confirm("Ignore and untrack " .. item.path .. "?", function()
    local rule = "/" .. item.path .. (item.kind == "folder" and "/" or "")
    local ignore_path = S.root .. "/.gitignore"
    local lines = vim.fn.filereadable(ignore_path) == 1 and vim.fn.readfile(ignore_path) or {}
    local exists = false
    for _, line in ipairs(lines) do if line == rule then exists = true; break end end
    if not exists then
      local ok, write_err = pcall(vim.fn.writefile, { rule }, ignore_path, "a")
      if not ok then notify_error("Could not update .gitignore: " .. tostring(write_err)); return end
    end

    local _, err = git.git(S.root, { "rm", "--cached", "-r", "--ignore-unmatch", "--", item.path })
    if err then notify_error(err) end
    M.refresh()
  end)
end

local function commit()
  vim.ui.input({ prompt = "Commit message: " }, function(message)
    if message and vim.trim(message) ~= "" then run({ "commit", "-m", message }, "Commit", false) end
  end)
end

local function stash()
  vim.ui.select({ "Everything (including untracked)", "Tracked", "Staged", "Unstaged" }, { prompt = "Stash scope:" }, function(scope)
    if not scope then return end
    vim.ui.input({ prompt = "Optional stash message: " }, function(message)
      local args = { "stash", "push" }
      if scope:match("Everything") then args[#args + 1] = "--include-untracked"
      elseif scope == "Staged" then args[#args + 1] = "--staged"
      elseif scope == "Unstaged" then args[#args + 1] = "--keep-index" end
      if message and message ~= "" then vim.list_extend(args, { "-m", message }) end
      run(args, "Stash", true)
    end)
  end)
end

local function open_diff(path, revision)
  if revision then
    local out, err = git.diff_text(S.root, revision, path)
    if not out then notify_error(err); return end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(out, "\n", { plain = true }))
    vim.bo[buf].filetype = "diff"; vim.bo[buf].modifiable = false
    vim.api.nvim_set_current_buf(buf)
    vim.keymap.set("n", "q", "<cmd>bd!<cr>", { buffer = buf })
    return
  end
  require("views.lazydiff").open({ allow_empty = true, focus_file = path })
  vim.api.nvim_create_autocmd("TabClosed", { once = true, callback = function() vim.schedule(M.refresh) end })
end

local function enter()
  local name, item = S.order[S.active], selected()
  if not item or item.placeholder then return end
  if item.kind == "folder" then
    S.collapsed[item.path] = not S.collapsed[item.path]
    local files, err
    if name == "commits" and S.commit_files then
      files, err = git.changed_paths(S.root, S.commit_files.oid)
    elseif name == "stashes" and S.stash_files then
      files, err = git.changed_paths(S.root, S.stash_files.ref)
    else
      files, err = git.status(S.root)
    end
    if not files then notify_error(err); return end
    preserve(panel(name), git.tree(files, S.collapsed), "path")
    render(name)
    return
  end
  if name == "files" then open_diff(item.path)
  elseif name == "commits" then
    if S.commits_show_changes then
      open_diff(item.path)
    elseif S.commit_files then open_diff(item.path, S.commit_files.oid) else
      local files, err = git.changed_paths(S.root, item.oid)
      if not files then notify_error(err); return end
      S.commit_files = item
      preserve(panel("commits"), git.tree(files, S.collapsed), "path"); render("commits")
    end
  elseif name == "stashes" then
    if S.stash_files then open_diff(item.path, S.stash_files.ref) else
      local files, err = git.changed_paths(S.root, item.ref)
      if not files then notify_error(err); return end
      S.stash_files = item
      preserve(panel("stashes"), git.tree(files, S.collapsed), "path"); render("stashes")
    end
  end
end

local function checkout()
  local name, item = S.order[S.active], selected(); if not item or not item.name then return end
  if name == "locals" then run({ "switch", item.name }, "Checkout", false)
  elseif name == "remotes" then
    local local_name = item.name:match("^[^/]+/(.+)$")
    run({ "switch", "--track", "-c", local_name, item.name }, "Checkout", false)
  end
end

local function branch_op(kind)
  local item = selected(); if not item or not item.name then return end
  local action = function()
    run(kind == "merge" and { "merge", item.name } or { "rebase", item.name }, kind, true)
  end
  if kind == "rebase" then
    confirm("Rebase the current branch onto " .. item.name .. "? This rewrites local history.", action)
  else
    action()
  end
end

local function delete_branch()
  local name, item = S.order[S.active], selected()
  if not item or not item.name or (name ~= "locals" and name ~= "remotes") then return end
  if item.current then notify_error("The checked-out branch cannot be deleted"); return end
  if name == "locals" then
    local choices = item.upstream ~= "" and { "Local and tracked remote", "Local only", "Cancel" } or { "Local only", "Cancel" }
    vim.ui.select(choices, { prompt = "Delete " .. item.name .. ":" }, function(choice)
      if not choice or choice == "Cancel" then return end
      local function remove_local(force)
        local _, err = git.git(S.root, { "branch", force and "-D" or "-d", item.name })
        if err and not force then
          confirm("Branch is not fully merged. Force delete it?", function() remove_local(true) end)
          return
        elseif err then notify_error(err); return end
        if choice:match("remote") then
          local remote, branch = item.upstream:match("^([^/]+)/(.+)$")
          if remote then run({ "push", remote, "--delete", branch }, "Delete remote branch", true); return end
        end
        M.refresh()
      end
      remove_local(false)
    end)
  else
    local remote, branch = item.name:match("^([^/]+)/(.+)$")
    if not remote then return end
    local tracking
    for _, local_ref in ipairs(panel("locals").items) do if local_ref.upstream == item.name then tracking = local_ref.name; break end end
    local choices = tracking and { "Remote and tracking local", "Remote only", "Cancel" } or { "Remote only", "Cancel" }
    vim.ui.select(choices, { prompt = "Delete " .. item.name .. ":" }, function(choice)
      if not choice or choice == "Cancel" then return end
      if choice:match("tracking") then git.git(S.root, { "branch", "-d", tracking }) end
      run({ "push", remote, "--delete", branch }, "Delete remote branch", true)
    end)
  end
end

local function conflict_action(action)
  local map = { continue = { "--continue" }, abort = { "--abort" }, skip = { "--skip" } }
  for _, operation in ipairs({ "rebase", "merge", "cherry-pick", "revert" }) do
    local marker = ({ rebase = { "rebase-merge", "rebase-apply" }, merge = { "MERGE_HEAD" }, ["cherry-pick"] = { "CHERRY_PICK_HEAD" }, revert = { "REVERT_HEAD" } })[operation]
    for _, path in ipairs(marker) do
      local git_dir = git.git(S.root, { "rev-parse", "--git-dir" })
      if git_dir then
        git_dir = vim.trim(git_dir); if git_dir:sub(1, 1) ~= "/" then git_dir = S.root .. "/" .. git_dir end
        if vim.uv.fs_stat(git_dir .. "/" .. path) then
          if action == "skip" and operation ~= "rebase" then notify_error("Skip is only available during rebase"); return end
          local execute = function()
            local args = { operation }; vim.list_extend(args, map[action]); run(args, operation .. " " .. action, true)
          end
          if action == "abort" then
            confirm("Abort the current " .. operation .. " and discard its in-progress changes?", execute)
          elseif action == "skip" then
            confirm("Skip the current rebase commit? Its changes will be omitted.", execute)
          else
            execute()
          end
          return
        end
      end
    end
  end
  notify_error("No merge, rebase, cherry-pick, or revert is in progress")
end

local function stash_op(op)
  local item = selected("stashes"); if not item or not item.ref then return end
  local action = function() run({ "stash", op, item.ref }, "Stash " .. op, true) end
  if op == "drop" then
    confirm("Permanently drop " .. item.ref .. "?", action)
  elseif op == "pop" then
    confirm("Pop " .. item.ref .. "? The stash is removed after a successful apply.", action)
  else
    action()
  end
end

local function push()
  local current = selected("locals")
  if current and current.upstream ~= "" then run({ "push" }, "Push", true); return end
  local remotes = git.git(S.root, { "remote" }) or ""
  local choices = vim.split(vim.trim(remotes), "\n", { trimempty = true })
  vim.ui.select(choices, { prompt = "Push to remote:" }, function(remote)
    if remote then run({ "push", "-u", remote, current and current.name or "HEAD" }, "Push", true) end
  end)
end

local function help()
  vim.notify("h/l or Tab/S-Tab panels · j/k move · - maximize panel · Enter open · Space stage/checkout/apply · a stage all · i ignore · d discard/drop · c commit · s stash · M merge · r rebase · g pop · p pull · P push · R refresh · Esc back · q quit", vim.log.levels.INFO, { title = "lazyrepo keys" })
end

local function toggle_maximize()
  if S.maximized_tab and vim.api.nvim_tabpage_is_valid(S.maximized_tab) then
    local maximized = S.maximized_tab
    S.maximized_tab = nil
    if vim.api.nvim_get_current_tabpage() == maximized then vim.cmd("tabclose") end
    if S.dashboard_tab and vim.api.nvim_tabpage_is_valid(S.dashboard_tab) then
      vim.api.nvim_set_current_tabpage(S.dashboard_tab)
      local active_panel = panel(S.order[S.active])
      if active_panel and vim.api.nvim_win_is_valid(active_panel.win) then
        vim.api.nvim_set_current_win(active_panel.win)
      elseif S.dashboard_win and vim.api.nvim_win_is_valid(S.dashboard_win) then
        vim.api.nvim_set_current_win(S.dashboard_win)
      end
    end
    return
  end

  local current_buf = vim.api.nvim_get_current_buf()
  for index, name in ipairs(S.order) do
    if panel(name).buf == current_buf then S.active = index; break end
  end
  S.dashboard_tab = vim.api.nvim_get_current_tabpage()
  S.dashboard_win = vim.api.nvim_get_current_win()
  vim.cmd("tab split")
  S.maximized_tab = vim.api.nvim_get_current_tabpage()
end

local function back()
  if S.commit_files then S.commit_files = nil; load_commits(selected("locals") and selected("locals").name or "HEAD")
  elseif S.stash_files then S.stash_files = nil; local stashes = git.stashes(S.root) or {}; preserve(panel("stashes"), stashes, "oid"); render("stashes") end
end

local function map(buf, key, fn)
  if type(fn) == "function" then
    local callback = fn
    fn = function()
      local current_buf = vim.api.nvim_get_current_buf()
      for index, name in ipairs(S.order) do
        if panel(name).buf == current_buf then S.active = index; break end
      end
      callback()
    end
  end
  vim.keymap.set("n", key, fn, { buffer = buf, silent = true, nowait = true })
end
local function configure(buf)
  map(buf, "h", function() focus(-1) end); map(buf, "l", function() focus(1) end)
  map(buf, "<Tab>", function() focus(1) end); map(buf, "<S-Tab>", function() focus(-1) end)
  map(buf, "j", function() move(1) end); map(buf, "k", function() move(-1) end)
  map(buf, "<CR>", enter); map(buf, "<Space>", function()
    local name = S.order[S.active]
    if name == "files" then stage_selection() elseif name == "locals" or name == "remotes" then checkout() elseif name == "stashes" then stash_op("apply") end
  end)
  map(buf, "a", stage_all); map(buf, "d", function()
    local name = S.order[S.active]
    if name == "files" then discard() elseif name == "stashes" then stash_op("drop") elseif name == "locals" or name == "remotes" then delete_branch() end
  end)
  map(buf, "i", ignore_selection)
  map(buf, "c", commit); map(buf, "s", stash); map(buf, "M", function() branch_op("merge") end); map(buf, "r", function() branch_op("rebase") end)
  map(buf, "g", function() if S.order[S.active] == "stashes" then stash_op("pop") end end)
  map(buf, "p", function() run({ "pull" }, "Pull", true) end); map(buf, "P", push); map(buf, "R", M.refresh)
  map(buf, "?", help); map(buf, "<Esc>", back); map(buf, "q", "<cmd>qa!<cr>")
  map(buf, "-", toggle_maximize)
  map(buf, "]c", function() conflict_action("continue") end); map(buf, "]s", function() conflict_action("skip") end); map(buf, "]a", function() conflict_action("abort") end)
end

local function create_panel(name, title, win)
  local buf = vim.api.nvim_create_buf(false, true); vim.api.nvim_win_set_buf(win, buf)
  vim.bo[buf].buftype = "nofile"; vim.bo[buf].bufhidden = "wipe"; vim.bo[buf].swapfile = false
  vim.wo[win].number = false; vim.wo[win].cursorline = true; vim.wo[win].wrap = false
  S.panels[name] = { title = title, win = win, buf = buf, items = {}, index = 1 }; configure(buf)
end

function M.launch()
  S.root = git.root()
  if not S.root then notify_error("not inside a Git repository"); vim.cmd("cq"); return end
  pcall(function() require("views.lazydiff").setup_standalone_ui() end)
  setup_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", { callback = setup_highlights })
  vim.o.termguicolors = true; vim.o.laststatus = 2; vim.o.showtabline = 0
  vim.cmd("only"); local left = vim.api.nvim_get_current_win()
  vim.cmd("rightbelow vsplit"); local middle = vim.api.nvim_get_current_win()
  vim.cmd("rightbelow vsplit"); local right_local = vim.api.nvim_get_current_win()
  vim.cmd("rightbelow split"); local right_remote = vim.api.nvim_get_current_win()
  vim.cmd("rightbelow split"); local right_stash = vim.api.nvim_get_current_win()
  create_panel("files", "Files", left); create_panel("commits", "Commits", middle)
  create_panel("locals", "Local branches", right_local); create_panel("remotes", "Remote branches", right_remote); create_panel("stashes", "Stashes", right_stash)
  vim.api.nvim_set_current_win(left); S.active = 1; M.refresh()
end

M._state = S
return M
