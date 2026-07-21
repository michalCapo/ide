local root = assert(vim.env.TEST_LAZYDATA_ROOT, "TEST_LAZYDATA_ROOT is required")
local db = root .. "/people.db"
vim.fn.mkdir(root .. "/lazydata", "p")

local sqlite = vim.system({ "sqlite3", db, [[
  CREATE TABLE people (id INTEGER PRIMARY KEY, team TEXT, note TEXT);
  INSERT INTO people(team, note) VALUES ('core', 'one complete value that is longer than a rendered table cell'), ('core', 'two'), (NULL, 'three');
  CREATE TABLE teams (id INTEGER PRIMARY KEY, name TEXT);
  INSERT INTO teams(name) VALUES ('core');
]] }, { text = true }):wait()
assert(sqlite.code == 0, sqlite.stderr)

local config = {
  version = 1,
  page_size = 200,
  connections = {
    {
      id = "test-sqlite",
      name = "Test SQLite",
      driver = "sqlite",
      path = db,
      timeout_ms = 5000,
    },
  },
}
vim.fn.writefile({ vim.json.encode(config) }, root .. "/lazydata/connections.json")
vim.fn.setfperm(root .. "/lazydata/connections.json", "rw-------")

local lazydata = require("views.lazydata")
assert(lazydata._value_filetype({ type = "text" }, [[{"name":"LazyData"}]]) == "json", "JSON content in a text column was not detected")
assert(lazydata._value_filetype({ type = "jsonb" }, "not yet valid") == "json", "JSON column type was not detected")
assert(lazydata._value_filetype({ type = "text" }, [[<?xml version="1.0"?><root/>]]) == "xml", "XML content was not detected")
assert(lazydata._value_filetype({ name = "script.sh", type = "text" }, "echo hello") == "sh", "filename hint was not detected")
assert(lazydata._value_filetype({ type = "text" }, "plain text") == "text", "plain text was misdetected")
local formatted_json = assert(lazydata._format_value("json", [[{"data":{"id":6,"active":true},"skills":[]}]]))
assert(formatted_json:find('\n  "data": {', 1, true), "JSON formatter did not indent an object")
assert(formatted_json:find('\n    "id": 6,', 1, true), "JSON formatter did not indent nested fields")
local formatted_xml = assert(lazydata._format_value("xml", [[<?xml version="1.0"?><root><item id="1">value</item></root>]]))
assert(formatted_xml:find('\n  <item id="1">', 1, true), "XML formatter did not indent a child element")
assert(not lazydata._format_value("json", [[{"broken":}]]), "invalid JSON was formatted")
lazydata.launch()
local state = lazydata._state

assert(vim.wait(3000, function() return #state.profiles == 1 end, 20), "profiles did not load")
assert(state.profiles[1].name == "Test SQLite")

vim.api.nvim_feedkeys("e", "x", false)
assert(vim.wait(1000, function() return state.form and state.form.win and vim.api.nvim_win_is_valid(state.form.win) end, 20), "connection dialog did not open")
local form_text = table.concat(vim.api.nvim_buf_get_lines(state.form.buf, 0, -1, false), "\n")
assert(form_text:find("Test connection", 1, true), "connection dialog has no test action")
vim.api.nvim_feedkeys(string.char(20), "x", false)
assert(vim.wait(3000, function() return state.form and state.form.status_kind == "success" end, 20), "connection test did not succeed")
vim.api.nvim_feedkeys("\27", "x", false)
assert(state.form == nil, "connection dialog did not close")

local picked
lazydata._open_picker("Switch database", { "alpha", "beta", "gamma" }, tostring, function(value) picked = value end)
assert(state.picker and vim.api.nvim_win_is_valid(state.picker.win), "database picker did not open")
local picker_text = table.concat(vim.api.nvim_buf_get_lines(state.picker.buf, 0, -1, false), "\n")
assert(picker_text:find("filter", 1, true), "database picker has no filter help")
local selected_mark
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(state.picker.buf, -1, 0, -1, { details = true })) do
  if mark[4].line_hl_group == "LazyDataSelected" then selected_mark = mark break end
end
assert(selected_mark and selected_mark[2] == state.picker.item_row - 1, "picker selection is not on the first value")
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Down>", true, false, true), "x", false)
assert(state.picker.index == 2, "database picker Down mapping did not move")
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-p>", true, false, true), "x", false)
assert(state.picker.index == 1, "database picker Ctrl-P mapping did not move")
vim.api.nvim_feedkeys("/", "x", false)
assert(state.picker and state.picker.editing, "database picker did not enter filter mode")
state.picker.set_filter("bet")
assert(state.picker and state.picker.filter == "bet", "database picker did not capture filter text")
assert(vim.wait(500, function() return state.picker and #state.picker.filtered == 1 end, 10), "database picker did not redraw filtered values")
state.picker.delete_filter();state.picker.delete_filter();state.picker.delete_filter()
assert(vim.wait(500, function() return state.picker and state.picker.filter == "" and #state.picker.filtered == 3 end, 10), "database picker could not clear its filter")
state.picker.set_filter("bet")
assert(vim.wait(500, function() return state.picker and state.picker.filter == "bet" and #state.picker.filtered == 1 end, 10), "database picker did not reapply its filter")
vim.api.nvim_feedkeys("\r", "x", false)
assert(vim.wait(500, function() return picked == "beta" and state.picker == nil end, 10), "database picker did not filter and select with Vim keys")

vim.api.nvim_feedkeys("\r", "x", false)
assert(vim.wait(3000, function() return state.screen == "workspace" and #state.tables == 2 end, 20), "table list did not load")
assert(state.tables[1].name == "people")

vim.api.nvim_feedkeys("\r", "x", false)
assert(vim.wait(3000, function()
  local item = state.workspaces[1]
  return item and item.data and #item.data.rows == 3
end, 20), "table rows did not load")
assert(#state.workspaces[1].columns == 3)
assert(state.workspaces[1].columns[1].name == "id", "id is not the first table column")
assert(state.workspaces[1].data.columns[1] == "id", "id is not the first row-data column")
assert(#vim.api.nvim_tabpage_list_wins(0) == 1 and state.sidebar.win == nil, "table sidebar did not hide after focusing the table")

vim.api.nvim_feedkeys("c", "x", false)
assert(state.picker and state.picker.title == "Jump to column", "column picker did not open")
assert(state.picker.editing, "column picker did not enter filter mode")
state.picker.set_filter("team")
assert(vim.wait(500, function() return state.picker and state.picker.filter == "team" and #state.picker.filtered == 1 end, 10), "column picker did not filter")
vim.api.nvim_feedkeys("\r", "x", false)
assert(vim.wait(500, function() return state.picker == nil and state.workspaces[1].active_col == 2 end, 10), "column picker did not select team")
assert(vim.wait(500, function() local position=vim.api.nvim_win_get_cursor(state.main.win);return position[2]==vim.fn.virtcol2col(state.main.win,position[1],state.workspaces[1].cell_starts[2]+1)-1 end, 10), "column picker did not move the table cursor")
local cursor = vim.api.nvim_win_get_cursor(state.main.win)
local expected_column = vim.fn.virtcol2col(state.main.win, cursor[1], state.workspaces[1].cell_starts[2] + 1) - 1
vim.api.nvim_feedkeys("j", "x", false)
cursor = vim.api.nvim_win_get_cursor(state.main.win)
expected_column = vim.fn.virtcol2col(state.main.win, cursor[1], state.workspaces[1].cell_starts[2] + 1) - 1
assert(cursor[1] == 4 and cursor[2] == expected_column, "j did not preserve the active table column")
vim.api.nvim_feedkeys("k", "x", false)
cursor = vim.api.nvim_win_get_cursor(state.main.win)
expected_column = vim.fn.virtcol2col(state.main.win, cursor[1], state.workspaces[1].cell_starts[2] + 1) - 1
assert(cursor[1] == 3 and cursor[2] == expected_column, "k did not preserve the active table column")

vim.api.nvim_feedkeys("u", "x", false)
assert(vim.wait(3000, function() return state.picker and state.picker.title == "Filter team" end, 20), "distinct-value picker did not open")
assert(state.picker.editing, "distinct-value picker did not start in filter mode")
state.picker.set_filter("core")
assert(vim.wait(500, function() return state.picker and state.picker.filter == "core" and #state.picker.filtered == 1 end, 10), "distinct-value picker did not narrow results")
vim.api.nvim_feedkeys("\r", "x", false)
assert(vim.wait(3000, function() return state.picker == nil and #state.workspaces[1].predicates == 1 and #state.workspaces[1].data.rows == 2 end, 20), "distinct-value filter was not applied")
vim.api.nvim_feedkeys("F", "x", false)
assert(vim.wait(3000, function() return #state.workspaces[1].predicates == 0 and #state.workspaces[1].data.rows == 3 end, 20), "distinct-value filter was not cleared")

vim.api.nvim_feedkeys("l", "x", false)
assert(state.workspaces[1].active_col == 3, "could not select the note column")
vim.api.nvim_feedkeys("v", "x", false)
assert(state.viewer and state.viewer.win and vim.api.nvim_win_is_valid(state.viewer.win), "full-value viewer did not open")
assert(table.concat(vim.api.nvim_buf_get_lines(state.viewer.buf, 0, -1, false), "\n") == "one complete value that is longer than a rendered table cell", "full-value viewer truncated the cell")
local has_format_mapping = false
for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(state.viewer.buf, "n")) do if mapping.lhs == "=" then has_format_mapping = true break end end
assert(has_format_mapping, "full-value viewer has no format mapping")
local viewer_config = vim.api.nvim_win_get_config(state.viewer.win)
assert(viewer_config.width >= vim.o.columns - 8 and viewer_config.height >= vim.o.lines - vim.o.cmdheight - 7, "full-value viewer is not near fullscreen")
assert(vim.bo[state.viewer.buf].readonly and not vim.bo[state.viewer.buf].modifiable, "full-value viewer is not read-only")
vim.api.nvim_feedkeys("q", "x", false)
assert(state.viewer == nil and vim.api.nvim_get_current_win() == state.main.win, "full-value viewer did not close back to the table")

vim.api.nvim_feedkeys("2", "x", false)
assert(state.workspaces[1].mode == "columns")
vim.api.nvim_feedkeys("1", "x", false)
assert(state.workspaces[1].mode == "rows")

vim.api.nvim_feedkeys("\t", "x", false)
assert(state.active_panel == "sidebar")
assert(state.sidebar.win and vim.api.nvim_win_is_valid(state.sidebar.win), "Tab did not restore the table sidebar")
assert(#vim.api.nvim_tabpage_list_wins(0) == 2, "restored table sidebar did not use a separate panel")
state.table_index = 2
vim.api.nvim_feedkeys("\r", "x", false)
assert(vim.wait(3000, function() return state.workspaces[2] and state.workspaces[2].data end, 20), "second table did not open")
assert(state.workspaces[2].table == "teams")
assert(state.sidebar.win == nil and #vim.api.nvim_tabpage_list_wins(0) == 1, "opening a table did not hide the sidebar")
vim.api.nvim_feedkeys("[t", "x", false)
assert(state.workspace_index == 1)
vim.api.nvim_feedkeys("]t", "x", false)
assert(state.workspace_index == 2)

vim.o.columns = 70
lazydata.apply_layout(true)
assert(#vim.api.nvim_tabpage_list_wins(0) == 1, "narrow layout did not collapse")
vim.o.columns = 120
lazydata.apply_layout(true)

vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<BS>", true, false, true), "x", false)
assert(state.screen == "profiles", "Backspace did not return to connections")
assert(vim.api.nvim_win_get_buf(state.main.win) == state.main.buf, "connections screen kept the table buffer")
assert(vim.wait(3000, function() return #state.profiles == 1 end, 20), "profiles did not reload")
vim.api.nvim_feedkeys("\r", "x", false)
assert(vim.wait(3000, function() return state.screen == "workspace" and #state.tables == 2 end, 20), "reconnect after Backspace failed")

vim.api.nvim_feedkeys(string.char(5), "x", false)
assert(vim.wait(1000, function() return #state.workspaces == 3 end, 20), "query tab did not open")
local query = state.workspaces[3]
vim.bo[query.buf].modifiable = true
vim.api.nvim_buf_set_lines(query.buf, 0, -1, false, { "SELECT team, COUNT(*) AS count FROM people GROUP BY team ORDER BY count DESC" })
vim.cmd.stopinsert()
vim.api.nvim_feedkeys(string.char(18), "x", false)
assert(vim.wait(3000, function() return query.results and query.results[1] and #query.results[1].rows == 2 end, 20), "query results did not load")

assert(state.job and state.job > 0, "backend process is not running")
print("lazydata end-to-end tests: ok")
