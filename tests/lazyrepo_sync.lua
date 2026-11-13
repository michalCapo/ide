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
local function sync()
  vim.api.nvim_set_current_win(lazyrepo._state.panels.files.win)
  vim.api.nvim_feedkeys("S", "x", false)
  assert(vim.wait(5000, function() return not lazyrepo._state.busy end, 20), "sync did not finish")
end
local function counts()
  local result = {}
  for _, branch in ipairs(locals.items) do result[branch.name] = { branch.ahead, branch.behind } end
  return result
end
local function rev(dir, ref)
  return vim.trim(vim.system({ "git", "-C", dir, "rev-parse", ref }, { text = true }):wait().stdout)
end

-- Behind branches are fast-forwarded: the checked-out one and the other one.
sync()
local c = counts()
assert(c.main[1] == 0 and c.main[2] == 0, "current branch was not fast-forwarded")
assert(c.other[1] == 0 and c.other[2] == 0, "other branch was not fast-forwarded")
assert(vim.fn.filereadable(root .. "/remote-main") == 1, "work tree was not updated")
assert(lazyrepo._state.message_dialog == nil, "successful sync must not show a dialog")

-- Ahead branches are pushed.
commit(root, "local-main")
lazyrepo.refresh()
assert(counts().main[1] == 1, "local commit is not ahead")
sync()
assert(counts().main[1] == 0, "ahead branch was not pushed")
assert(rev(remote, "main") == rev(root, "main"), "remote main was not updated")
assert(lazyrepo._state.message_dialog == nil, "successful push must not show a dialog")

-- Diverged branches are left alone and reported.
git(root, "switch", "-q", "other")
commit(root, "local-other")
git(peer, "switch", "-q", "other")
git(peer, "pull", "-q", "--ff-only")
commit(peer, "remote-other-2")
git(peer, "push", "-q", "origin", "other")
local before = rev(root, "other")
sync()
assert(rev(root, "other") == before, "diverged branch changed")
assert(lazyrepo._state.message_dialog ~= nil, "diverged branch was not reported")
assert(lazyrepo._state.message_dialog.message:find("other: ↑1 ↓1", 1, true), "diverged report is missing the branch")

-- A branch that tracks a local branch follows it after that branch is fast-forwarded,
-- even when a tag has the same name as the branch.
git(root, "switch", "-q", "main")
git(root, "branch", "-q", "--track", "feature", "main")
git(root, "tag", "feature")
git(peer, "switch", "-q", "main")
git(peer, "pull", "-q", "--ff-only")
commit(peer, "remote-main-2")
git(peer, "push", "-q", "origin", "main")
sync()
assert(rev(root, "refs/heads/main") == rev(remote, "main"), "main was not fast-forwarded")
assert(rev(root, "refs/heads/feature") == rev(remote, "main"), "feature did not follow local main")

-- A removed upstream is reported.
git(peer, "push", "-q", "origin", "--delete", "other")
sync()
assert(lazyrepo._state.message_dialog.message:find("other: upstream origin/other no longer exists", 1, true),
  "gone upstream was not reported")

vim.fn.delete(root, "rf")
vim.fn.delete(remote, "rf")
vim.fn.delete(peer, "rf")
print("lazyrepo sync tests: ok")
