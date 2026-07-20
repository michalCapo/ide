local test_root = vim.fn.tempname()
local remote_root = vim.fn.tempname()
local peer_root = vim.fn.tempname()
vim.fn.mkdir(test_root, "p")

local function command(args)
  local result = vim.system(args, { text = true }):wait()
  assert(result.code == 0, result.stderr)
end

command({ "git", "-C", test_root, "init", "-q" })
command({ "git", "-C", test_root, "config", "user.email", "test@example.com" })
command({ "git", "-C", test_root, "config", "user.name", "Test" })
vim.fn.writefile({ "initial" }, test_root .. "/tracked.txt")
command({ "git", "-C", test_root, "add", "tracked.txt" })
command({ "git", "-C", test_root, "commit", "-qm", "initial" })
command({ "git", "init", "--bare", "-q", remote_root })
command({ "git", "-C", test_root, "remote", "add", "origin", remote_root })
command({ "git", "-C", test_root, "push", "-qu", "origin", "HEAD:main" })
command({ "git", "-C", test_root, "branch", "other" })
command({ "git", "-C", test_root, "push", "-qu", "-u", "origin", "other" })
command({ "git", "--git-dir", remote_root, "symbolic-ref", "HEAD", "refs/heads/main" })
command({ "git", "clone", "-q", remote_root, peer_root })
command({ "git", "-C", peer_root, "config", "user.email", "test@example.com" })
command({ "git", "-C", peer_root, "config", "user.name", "Test" })

vim.cmd.cd(vim.fn.fnameescape(test_root))
vim.g.lazyrepo_fetch_interval_ms = 100
local lazyrepo = require("views.lazyrepo")
lazyrepo.launch()

assert(vim.wait(2000, function() return lazyrepo._state.watch_state ~= nil end), "watcher did not initialize")
vim.fn.writefile({ "changed" }, test_root .. "/tracked.txt")
assert(vim.wait(3000, function()
  local item = lazyrepo._state.panels.files.items[1]
  return item and item.path == "tracked.txt" and item.unstaged == true
end, 50), "external file change did not refresh lazyrepo")

command({ "git", "-C", peer_root, "switch", "-q", "other" })
vim.fn.writefile({ "remote change" }, peer_root .. "/remote.txt")
command({ "git", "-C", peer_root, "add", "remote.txt" })
command({ "git", "-C", peer_root, "commit", "-qm", "remote change" })
command({ "git", "-C", peer_root, "push", "-q", "origin", "other" })
assert(vim.wait(5000, function()
  for _, item in ipairs(lazyrepo._state.panels.locals.items) do
    if item.name == "other" then return item.behind == 1 end
  end
  return false
end, 50), "background fetch did not refresh incoming count for another branch")

vim.fn.delete(test_root, "rf")
vim.fn.delete(remote_root, "rf")
vim.fn.delete(peer_root, "rf")
print("lazyrepo auto-refresh tests: ok")
