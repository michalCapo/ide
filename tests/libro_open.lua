-- Run with LIBRO_PANEL_ID set and LIBRO_BIN pointing at a script that appends
-- its arguments to $LIBRO_OPEN_LOG, as a Libro terminal would provide.
assert(vim.env.LIBRO_PANEL_ID and vim.env.LIBRO_BIN and vim.env.LIBRO_OPEN_LOG, "set LIBRO_PANEL_ID, LIBRO_BIN, and LIBRO_OPEN_LOG")
local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/docs", "p")
vim.fn.writefile({ "<h1>Hi</h1>" }, root .. "/docs/page.html")
vim.fn.writefile({ "x" }, root .. "/notes.docx")
vim.cmd.packadd("netrw")
vim.cmd.runtime("plugin/netrwPlugin.vim")

local system_calls = {}
local function logged()
  return vim.fn.filereadable(vim.env.LIBRO_OPEN_LOG) == 1 and vim.fn.readfile(vim.env.LIBRO_OPEN_LOG) or {}
end

local function find_line(text)
  for row, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
    if line == text then
      return row
    end
  end
end

local function press(key)
  vim.api.nvim_feedkeys(vim.keycode(key), "x", false)
end

vim.cmd("Explore " .. vim.fn.fnameescape(root))
assert(vim.wait(2000, function() return find_line("| docs/") ~= nil end, 10), "docs directory was not listed")
vim.api.nvim_win_set_cursor(0, { find_line("| docs/"), 0 })
press("l")
assert(vim.wait(2000, function() return find_line("| | page.html") ~= nil end, 10), "docs directory did not expand")
vim.api.nvim_win_set_cursor(0, { find_line("| | page.html"), 0 })
press("o")
assert(vim.wait(2000, function() return #logged() == 1 end, 10), "o did not open the HTML file in Libro")
assert(logged()[1] == "open " .. root .. "/docs/page.html", "Libro got the wrong file: " .. tostring(logged()[1]))

-- Files the Browser panel cannot show keep using the default app.
local libro_open = vim.ui.open
vim.system = function(cmd)
  table.insert(system_calls, cmd)
  return { wait = function() return { code = 0 } end }
end
libro_open(root .. "/notes.docx")
assert(#logged() == 1 and #system_calls == 1 and system_calls[1][1] ~= vim.env.LIBRO_BIN, "a document went to Libro")

-- A caller's own viewer wins, and env variables in paths are expanded.
libro_open(root .. "/docs/page.html", { cmd = { "my-viewer" } })
assert(#logged() == 1 and system_calls[2][1] == "my-viewer", "a custom viewer was ignored")
vim.env.LIBRO_TEST_ROOT = root
libro_open("$LIBRO_TEST_ROOT/docs/page.html")
assert(system_calls[3][1] == vim.env.LIBRO_BIN and system_calls[3][3] == root .. "/docs/page.html", "an env variable path did not reach Libro")

vim.fn.delete(root, "rf")
print("libro open tests: ok")
