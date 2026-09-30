local test_root = vim.fn.tempname()
vim.fn.mkdir(test_root .. "/nested", "p")
local result = vim.system({ "git", "-C", test_root, "init", "-q" }, { text = true }):wait()
assert(result.code == 0, result.stderr)
vim.fn.writefile({ "preview" }, test_root .. "/nested/preview file.html")
vim.cmd.cd(vim.fn.fnameescape(test_root))

local lazyrepo = require("views.lazyrepo")
lazyrepo.launch()
local state = lazyrepo._state
local original_open = vim.ui.open
local opened = {}
vim.ui.open = function(path) opened[#opened + 1] = path end

vim.api.nvim_feedkeys("o", "x", false)
assert(#opened == 0, "folders must not open")
vim.api.nvim_feedkeys("jo", "x", false)
assert(#opened == 1 and opened[1] == test_root .. "/nested/preview file.html")
assert(vim.api.nvim_get_current_buf() == state.panels.files.buf, "dashboard must stay open")
vim.api.nvim_feedkeys("lo", "x", false)
assert(#opened == 1, "branches must not open")

vim.api.nvim_set_current_win(state.panels.files.win)
vim.ui.open = function() return nil, "No default application" end
vim.api.nvim_feedkeys("o", "x", false)
assert(state.message_dialog, "open errors must be shown")
local message = table.concat(vim.api.nvim_buf_get_lines(state.message_dialog.buf, 0, -1, false), "\n")
assert(message:find("No default application", 1, true))
vim.api.nvim_feedkeys("q", "x", false)

vim.ui.open = function() error("Cannot launch application") end
vim.api.nvim_feedkeys("o", "x", false)
assert(state.message_dialog, "launcher exceptions must be shown")
vim.api.nvim_feedkeys("q", "x", false)

vim.ui.open = original_open
vim.fn.delete(test_root, "rf")
print("lazyrepo default application tests: ok")
