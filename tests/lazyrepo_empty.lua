local test_root = vim.fn.tempname()
vim.fn.mkdir(test_root, "p")

local result = vim.system({ "git", "-C", test_root, "init", "-q" }, { text = true }):wait()
assert(result.code == 0, result.stderr)
vim.fn.writefile({ "uncommitted" }, test_root .. "/new.txt")
vim.cmd.cd(vim.fn.fnameescape(test_root))

local lazyrepo = require("views.lazyrepo")
lazyrepo.launch()

local state = lazyrepo._state
assert(state.message_dialog == nil, "an empty repository must not show a Git error")
assert(state.panels.commits.title == "Changed files")
assert(state.panels.commits.items[1].path == "new.txt")
assert(state.panels.locals.items[1].placeholder == "(empty)")

vim.fn.delete(test_root, "rf")
print("lazyrepo empty repository tests: ok")
