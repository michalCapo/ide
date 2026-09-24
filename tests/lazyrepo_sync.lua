local root, remote, peer = vim.fn.tempname(), vim.fn.tempname(), vim.fn.tempname()
local function command(args)
  local result = vim.system(args, { text = true }):wait()
  assert(result.code == 0, result.stderr)
end
local function git(dir, ...)
  command({ "git", "-C", dir, ... })
end
local function commit(dir, name)
  vim.fn.writefile({ name }, dir .. "/" .. name)
  git(dir, "add", name)
  git(dir, "commit", "-qm", name)
end

vim.fn.mkdir(root, "p")
git(root, "init", "-q", "-b", "main")
git(root, "config", "user.email", "test@example.com")
git(root, "config", "user.name", "Test")
commit(root, "initial")
command({ "git", "init", "--bare", "-q", remote })
git(root, "remote", "add", "origin", remote)
git(root, "push", "-qu", "origin", "main")
git(root, "branch", "other")
git(root, "push", "-qu", "-u", "origin", "other")
command({ "git", "--git-dir", remote, "symbolic-ref", "HEAD", "refs/heads/main" })
command({ "git", "clone", "-q", remote, peer })
git(peer, "config", "user.email", "test@example.com")
git(peer, "config", "user.name", "Test")

vim.cmd.cd(vim.fn.fnameescape(root))
vim.g.lazyrepo_fetch_interval_ms = 3600000
local lazyrepo = require("views.lazyrepo")
lazyrepo.launch()
assert(vim.wait(3000, function()
  return lazyrepo._state.watch_state ~= nil and lazyrepo._state.fetch_request == nil
end, 20), "initial fetch did not finish")

commit(peer, "remote-main")
git(peer, "push", "-q", "origin", "main")
git(peer, "switch", "-q", "-c", "other", "origin/other")
commit(peer, "remote-other")
git(peer, "push", "-q", "origin", "other")
for _, branch in ipairs(lazyrepo._state.panels.locals.items) do
  assert(branch.behind == 0, "remote change appeared before manual sync")
end

local locals = lazyrepo._state.panels.locals
vim.api.nvim_set_current_win(lazyrepo._state.panels.files.win)
vim.api.nvim_feedkeys("S", "x", false)
assert(vim.wait(5000, function() return lazyrepo._state.message_dialog ~= nil end, 20), "sync result did not appear")
local dialog = lazyrepo._state.message_dialog
local summary = table.concat(vim.api.nvim_buf_get_lines(dialog.buf, 0, -1, false), "\n")
assert(summary:find("main ← origin/main  ↓1", 1, true), summary)
assert(summary:find("other ← origin/other  ↓1", 1, true), summary)
for _, branch in ipairs(locals.items) do
  assert(branch.behind == 1, branch.name .. " did not refresh")
end

vim.fn.delete(root, "rf")
vim.fn.delete(remote, "rf")
vim.fn.delete(peer, "rf")
print("lazyrepo sync tests: ok")
