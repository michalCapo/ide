local lazyrepo = require("views.lazyrepo")

vim.o.columns = 120
vim.o.lines = 40
lazyrepo.launch()

local state = lazyrepo._state
assert(not state.compact)
assert(#vim.api.nvim_tabpage_list_wins(0) == 5)

local files_col = vim.api.nvim_win_get_position(state.panels.files.win)[2]
local branches_col = vim.api.nvim_win_get_position(state.panels.locals.win)[2]
local commits_col = vim.api.nvim_win_get_position(state.panels.commits.win)[2]
assert(files_col < branches_col and branches_col < commits_col)
assert(vim.api.nvim_win_get_position(state.panels.remotes.win)[2] == branches_col)
assert(vim.api.nvim_win_get_position(state.panels.stashes.win)[2] == branches_col)

vim.o.columns = 80
vim.api.nvim_exec_autocmds("VimResized", {})
assert(vim.wait(1000, function() return state.compact end))
assert(state.compact)
assert(#vim.api.nvim_tabpage_list_wins(0) == 1)

vim.api.nvim_feedkeys("l", "x", false)
assert(state.active == 2)
assert(vim.api.nvim_get_current_buf() == state.panels.locals.buf)

vim.api.nvim_feedkeys("-", "x", false)
assert(state.maximized_tab and vim.api.nvim_tabpage_is_valid(state.maximized_tab))
vim.api.nvim_feedkeys("l", "x", false)
assert(state.active == 3)
vim.api.nvim_feedkeys("-", "x", false)
assert(not state.maximized_tab)
assert(vim.api.nvim_get_current_buf() == state.panels.remotes.buf)

vim.o.columns = 120
vim.api.nvim_exec_autocmds("VimResized", {})
assert(vim.wait(1000, function() return not state.compact end))
assert(not state.compact)
assert(#vim.api.nvim_tabpage_list_wins(0) == 5)
assert(vim.api.nvim_win_get_position(state.panels.files.win)[2]
  < vim.api.nvim_win_get_position(state.panels.locals.win)[2])
assert(vim.api.nvim_win_get_position(state.panels.locals.win)[2]
  < vim.api.nvim_win_get_position(state.panels.commits.win)[2])

print("lazyrepo responsive layout tests: ok")
