local test_root = vim.fn.tempname()
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

vim.cmd.cd(vim.fn.fnameescape(test_root))
local lazyrepo = require("views.lazyrepo")
lazyrepo.launch()

assert(vim.wait(2000, function() return lazyrepo._state.watch_state ~= nil end), "watcher did not initialize")
vim.fn.writefile({ "changed" }, test_root .. "/tracked.txt")
assert(vim.wait(3000, function()
  local item = lazyrepo._state.panels.files.items[1]
  return item and item.path == "tracked.txt" and item.unstaged == true
end, 50), "external file change did not refresh lazyrepo")

vim.fn.delete(test_root, "rf")
print("lazyrepo auto-refresh tests: ok")
