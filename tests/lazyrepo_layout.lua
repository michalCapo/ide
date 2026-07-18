local lazyrepo = require("views.lazyrepo")

vim.o.columns = 120
vim.o.lines = 40
lazyrepo.launch()

local state = lazyrepo._state
assert(state.content_panel == "files")
assert(#vim.api.nvim_tabpage_list_wins(0) == 4)

local files_col = vim.api.nvim_win_get_position(state.panels.files.win)[2]
local branches_col = vim.api.nvim_win_get_position(state.panels.locals.win)[2]
assert(files_col < branches_col)
assert(vim.api.nvim_win_get_position(state.panels.remotes.win)[2] == branches_col)
assert(vim.api.nvim_win_get_position(state.panels.stashes.win)[2] == branches_col)
assert(state.panels.commits.win == nil)

vim.api.nvim_feedkeys("l", "x", false)
assert(state.active == 2)
assert(vim.api.nvim_get_current_buf() == state.panels.locals.buf)

vim.api.nvim_feedkeys("\r", "x", false)
assert(state.content_panel == "commits")
assert(state.active == 5)
assert(state.panels.commits.index == 1)
assert(vim.api.nvim_get_current_buf() == state.panels.commits.buf)
assert(vim.api.nvim_win_get_cursor(state.panels.commits.win)[1] == 1)
assert(vim.api.nvim_win_get_cursor(state.panels.locals.win)[1] == state.panels.locals.index)
assert(#vim.api.nvim_tabpage_list_wins(0) == 4)
assert(state.panels.files.win == nil)
assert(vim.api.nvim_win_get_position(state.panels.locals.win)[2]
  < vim.api.nvim_win_get_position(state.panels.commits.win)[2])

vim.api.nvim_feedkeys("\r", "x", false)
assert(state.commit_files ~= nil)
vim.api.nvim_feedkeys("\27", "x", false)
assert(state.commit_files == nil)
assert(state.content_panel == "commits")
assert(state.active == 5)
assert(vim.api.nvim_get_current_buf() == state.panels.commits.buf)

vim.api.nvim_feedkeys("\27", "x", false)
assert(state.content_panel == "files")
assert(state.active == 2)
assert(vim.api.nvim_get_current_buf() == state.panels.locals.buf)
assert(#vim.api.nvim_tabpage_list_wins(0) == 4)
assert(state.panels.commits.win == nil)
assert(vim.api.nvim_win_get_position(state.panels.files.win)[2]
  < vim.api.nvim_win_get_position(state.panels.locals.win)[2])

vim.o.columns = 80
vim.api.nvim_exec_autocmds("VimResized", {})
assert(vim.wait(1000, function() return #vim.api.nvim_tabpage_list_wins(0) == 4 end))
assert(#vim.api.nvim_tabpage_list_wins(0) == 4)

print("lazyrepo two-column layout tests: ok")
