local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/src/api", "p")
vim.fn.mkdir(root .. "/src/empty", "p")
vim.fn.writefile({ "return true" }, root .. "/src/api/init.lua")
vim.cmd.packadd("netrw")
vim.cmd.runtime("plugin/netrwPlugin.vim")

local function lines()
  return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

local function find_line(text)
  for row, line in ipairs(lines()) do
    if line == text then
      return row
    end
  end
end

local function press(key)
  vim.api.nvim_feedkeys(vim.keycode(key), "x", false)
end

local function wait_for(predicate, message)
  assert(vim.wait(2000, predicate, 10), message)
end

vim.cmd("Explore " .. vim.fn.fnameescape(root))
wait_for(function()
  return vim.bo.filetype == "netrw" and vim.fn.maparg("l", "n", false, true).desc == "Expand directory or open file"
end, "file explorer mappings were not installed")

local src_row = assert(find_line("| src/"), "src directory was not listed")
vim.api.nvim_win_set_cursor(0, { src_row, 0 })
press("l")
wait_for(function() return find_line("| | api/") ~= nil end, "l did not expand the selected directory")

local expanded_lines = #lines()
press("l")
vim.wait(50)
assert(#lines() == expanded_lines, "l collapsed an already expanded directory")

local api_row = assert(find_line("| | api/"), "nested api directory was not listed")
vim.api.nvim_win_set_cursor(0, { api_row, 0 })
press("l")
wait_for(function() return find_line("| | | init.lua") ~= nil end, "l did not expand a nested directory")
press("h")
wait_for(function() return find_line("| | | init.lua") == nil end, "h did not collapse a nested directory")

src_row = assert(find_line("| src/"), "src directory disappeared after collapsing its child")
vim.api.nvim_win_set_cursor(0, { src_row, 0 })
press("h")
wait_for(function() return find_line("| | api/") == nil end, "h did not collapse the selected directory")

local collapsed_lines = #lines()
press("h")
vim.wait(50)
assert(#lines() == collapsed_lines, "h expanded an already collapsed directory")

local parent = vim.fs.dirname(root)
press("<BS>")
wait_for(function() return vim.w.netrw_treetop == parent end, "Backspace did not move to the parent directory")

vim.fn.delete(root, "rf")
print("netrw keymap tests: ok")
