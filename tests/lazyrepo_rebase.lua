local root, remote, peer = vim.fn.tempname(), vim.fn.tempname(), vim.fn.tempname()
local function command(args)
  local result = vim.system(args, { text = true }):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout)
end
local function git(dir, ...)
  return command({ "git", "-C", dir, ... })
end

vim.fn.mkdir(root, "p")
git(root, "init", "-q", "-b", "master")
git(root, "config", "user.email", "test@example.com")
git(root, "config", "user.name", "Test")
vim.fn.writefile({ "initial" }, root .. "/file.txt")
git(root, "add", "file.txt")
git(root, "commit", "-qm", "initial")
git(root, "branch", "test")
command({ "git", "init", "--bare", "-q", remote })
git(root, "remote", "add", "origin", remote)
git(root, "push", "-qu", "origin", "master")
command({ "git", "--git-dir", remote, "symbolic-ref", "HEAD", "refs/heads/master" })
command({ "git", "clone", "-q", remote, peer })
git(peer, "config", "user.email", "test@example.com")
git(peer, "config", "user.name", "Test")
vim.fn.writefile({ "remote change" }, peer .. "/remote.txt")
git(peer, "add", "remote.txt")
git(peer, "commit", "-qm", "remote change")
git(peer, "push", "-q", "origin", "master")
git(root, "fetch", "-q", "origin")
git(root, "switch", "-q", "test")

vim.cmd.cd(vim.fn.fnameescape(root))
vim.g.lazyrepo_fetch_interval_ms = 3600000
local lazyrepo = require("views.lazyrepo")
lazyrepo.launch()
local state = lazyrepo._state
local locals = state.panels.locals
assert(locals.items[1].name == "test" and locals.items[2].name == "master")
assert(locals.items[2].behind == 1)
vim.api.nvim_set_current_win(locals.win)
vim.api.nvim_feedkeys("jr", "x", false)
assert(state.confirm_dialog, "rebase must ask for confirmation")
vim.api.nvim_feedkeys("y", "x", false)
assert(vim.wait(3000, function() return state.message_dialog ~= nil end, 20), "rebase result did not appear")
local message = table.concat(vim.api.nvim_buf_get_lines(state.message_dialog.buf, 0, -1, false), "\n")
assert(vim.api.nvim_win_get_config(state.message_dialog.win).title[1][1] == " Lazyrepo warning ")
assert(message:find("Select origin/master under", 1, true) and message:find("press r", 1, true), message)

vim.api.nvim_feedkeys("q", "x", false)
vim.fn.writefile({ "local change" }, root .. "/local.txt")
git(root, "add", "local.txt")
git(root, "commit", "-qm", "local change")
lazyrepo.refresh()
local remotes = state.panels.remotes
vim.api.nvim_set_current_win(remotes.win)
for index, branch in ipairs(remotes.items) do
  if branch.name == "origin/master" then
    remotes.index = index
    vim.api.nvim_win_set_cursor(remotes.win, { index, 0 })
    break
  end
end
vim.api.nvim_feedkeys("ry", "x", false)
assert(vim.wait(3000, function()
  return not state.busy and git(root, "rev-parse", "test~1") == git(root, "rev-parse", "origin/master")
end, 20), "remote rebase did not finish")
assert(git(root, "log", "-1", "--format=%s", "test") == "local change")
assert(state.message_dialog == nil, "successful rebase must not show a dialog")

vim.api.nvim_feedkeys("ry", "x", false)
assert(vim.wait(3000, function() return state.message_dialog ~= nil end, 20), "unchanged rebase did not warn")
message = table.concat(vim.api.nvim_buf_get_lines(state.message_dialog.buf, 0, -1, false), "\n")
assert(message:find("Nothing changed", 1, true), message)

vim.fn.delete(root, "rf")
vim.fn.delete(remote, "rf")
vim.fn.delete(peer, "rf")
print("lazyrepo rebase tests: ok")
