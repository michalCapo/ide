local root = assert(vim.env.TEST_LAZYDATA_ROOT, "TEST_LAZYDATA_ROOT is required")
local db = root .. "/people.db"
vim.fn.mkdir(root .. "/lazydata", "p")

local sqlite = vim.system({ "sqlite3", db, [[
  CREATE TABLE people (id INTEGER PRIMARY KEY, team TEXT, note TEXT, employees_sport TEXT, authorization_method TEXT);
  INSERT INTO people(team, note, employees_sport, authorization_method) VALUES
    ('core', 'one complete value that is longer than a rendered table cell', 'basketball', 'sms'),
    ('core', 'two', 'football', 'sms'),
    (NULL, 'three', 'tennis', 'sms');
  CREATE TABLE teams (id INTEGER PRIMARY KEY, name TEXT);
  INSERT INTO teams(name) VALUES ('core');
  CREATE TABLE z_paged (id INTEGER PRIMARY KEY, value TEXT);
  WITH RECURSIVE sequence(id) AS (
    SELECT 1 UNION ALL SELECT id + 1 FROM sequence WHERE id < 35
  ) INSERT INTO z_paged(id, value) SELECT id, printf('row-%02d', id) FROM sequence;
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
local main_mappings = {}
for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(state.main.buf, "n")) do main_mappings[mapping.lhs] = true end
assert(main_mappings.b, "b back-navigation mapping is missing")
assert(main_mappings.D, "D database-switch mapping is missing")
vim.api.nvim_feedkeys("?", "x", false)
assert(state.message_dialog and vim.api.nvim_win_is_valid(state.message_dialog.win), "help did not open in a LazyData dialog")
local help_lines = vim.api.nvim_buf_get_lines(state.message_dialog.buf, 0, -1, false)
assert(#help_lines > 20, "help dialog did not display one keybinding per row")
for _,heading in ipairs({"Navigation","Table data","Editing","Queries","Workspace"})do
  assert(vim.tbl_contains(help_lines,"  "..heading),"help dialog is missing the "..heading.." group")
end
assert(vim.tbl_contains(help_lines, "    D            switch database"), "help dialog is missing the database keybinding row")
assert(vim.tbl_contains(help_lines, "    yy/y         copy full current/marked rows"), "help dialog is missing the copy keybinding row")
assert(vim.tbl_contains(help_lines, "    Space        mark/unmark row"), "help dialog is missing the row-mark keybinding")
assert(vim.tbl_contains(help_lines, "    e            edit current/marked row cells"), "help dialog is missing the row-edit keybinding")
assert(vim.tbl_contains(help_lines, "    Ctrl-S       stage edit / execute table changes"), "help dialog is missing the contextual row-save keybinding")
assert(vim.tbl_contains(help_lines, "    Ctrl-N       stage NULL in cell editor"), "help dialog is missing the NULL-edit keybinding")
assert(vim.tbl_contains(help_lines, "    U            discard staged table changes"), "help dialog is missing the row-discard keybinding")
assert(vim.tbl_contains(help_lines, "    d            delete marked/current row"), "help dialog is missing the row-delete keybinding")
assert(vim.tbl_contains(help_lines, "    Shift-K/J    sort ascending/descending"), "help dialog is missing grouped sort keybindings")
assert(vim.tbl_contains(help_lines, "    [[/]]        previous/next 30 rows"), "help dialog is missing paged-row keybindings")
assert(vim.tbl_contains(help_lines, "    h/l          previous/next column or panel"), "help dialog is missing horizontal navigation")
assert(vim.tbl_contains(help_lines, "    j/k          move"), "help dialog did not preserve shortcut alignment")
assert(vim.tbl_contains(help_lines, "    Backspace    connections"), "help dialog did not align long shortcuts")
local heading_marks=0
for _,mark in ipairs(vim.api.nvim_buf_get_extmarks(state.message_dialog.buf,-1,0,-1,{details=true}))do if mark[4].hl_group=="LazyDataHeader"then heading_marks=heading_marks+1 end end
assert(heading_marks==5,"help dialog group headings were not highlighted")
vim.api.nvim_feedkeys("\r", "x", false)
assert(state.message_dialog == nil, "Enter did not close the LazyData message dialog")

assert(vim.wait(3000, function() return #state.profiles == 1 end, 20), "profiles did not load")
assert(state.profiles[1].name == "Test SQLite")
state.profile_filter = "Test"
vim.api.nvim_feedkeys("/\r", "x", false)
assert(state.profile_filter == "", "/ did not start with a cleared connection filter")

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
assert(vim.wait(3000, function() return state.screen == "workspace" and #state.tables == 3 end, 20), "table list did not load")
assert(state.tables[1].name == "people")
state.table_filter = "people"
vim.api.nvim_feedkeys("/\r", "x", false)
assert(state.table_filter == "", "/ did not start with a cleared table filter")

vim.api.nvim_feedkeys("\r", "x", false)
assert(vim.wait(3000, function()
  local item = state.workspaces[1]
  return item and item.data and #item.data.rows == 3
end, 20), "table rows did not load")
assert(#state.workspaces[1].columns == 5)
assert(state.workspaces[1].columns[1].name == "id", "id is not the first table column")
assert(state.workspaces[1].data.columns[1] == "id", "id is not the first row-data column")
assert(state.workspaces[1].sort_column == "id" and state.workspaces[1].sort_direction == "desc", "table did not default to descending id order")
assert(state.workspaces[1].data.rows[1][1] == 3, "highest id was not loaded first")
assert(#vim.api.nvim_tabpage_list_wins(0) == 1 and state.sidebar.win == nil, "table sidebar did not hide after focusing the table")
state.workspaces[1].raw_where = "team = 'core'"
vim.api.nvim_feedkeys("/\r", "x", false)
assert(vim.wait(3000, function() return state.workspaces[1].raw_where == "" and #state.workspaces[1].data.rows == 3 end, 20), "/ did not start with a cleared WHERE filter")

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

vim.api.nvim_feedkeys("$", "x", false)
assert(state.workspaces[1].active_col == 5, "$ did not select the last table column")
local last_view = vim.fn.winsaveview()
local last_end = state.workspaces[1].cell_ends[5]
local last_width = vim.api.nvim_win_get_width(state.main.win)
assert(last_view.leftcol > 0 and last_end < last_view.leftcol + last_width, string.format("last table column was clipped (leftcol=%d, end=%d, width=%d)", last_view.leftcol, last_end, last_width))
vim.api.nvim_feedkeys("h", "x", false)
assert(state.workspaces[1].active_col == 4, "h did not continue from the column selected by $")
vim.api.nvim_feedkeys("0", "x", false)
assert(state.workspaces[1].active_col == 1, "0 did not select the first table column")
assert(vim.fn.winsaveview().leftcol <= state.workspaces[1].cell_starts[1], "first table column stayed clipped")
vim.api.nvim_feedkeys("l", "x", false)
assert(state.workspaces[1].active_col == 2, "l did not continue from the column selected by 0")

vim.api.nvim_feedkeys("u", "x", false)
assert(vim.wait(3000, function() return state.picker and state.picker.title == "Filter team" end, 20), "distinct-value picker did not open")
assert(state.picker.editing, "distinct-value picker did not start in filter mode")
state.picker.set_filter("core")
assert(vim.wait(500, function() return state.picker and state.picker.filter == "core" and #state.picker.filtered == 1 end, 10), "distinct-value picker did not narrow results")
vim.api.nvim_feedkeys("\r", "x", false)
assert(state.workspaces[1].loading_rows and vim.wo[state.main.win].statusline:find("executing query", 1, true), "filter query did not show the table loader")
assert(vim.wait(3000, function() return state.picker == nil and #state.workspaces[1].predicates == 1 and #state.workspaces[1].data.rows == 2 end, 20), "distinct-value filter was not applied")
vim.api.nvim_feedkeys("F", "x", false)
assert(state.workspaces[1].loading_rows and vim.wo[state.main.win].statusline:find("executing query", 1, true), "clearing filters did not show the table loader")
assert(vim.wait(3000, function() return #state.workspaces[1].predicates == 0 and #state.workspaces[1].data.rows == 3 end, 20), "distinct-value filter was not cleared")

local sort_cursor = vim.api.nvim_win_get_cursor(state.main.win)
local note_cursor_col = vim.fn.virtcol2col(state.main.win, sort_cursor[1], state.workspaces[1].cell_starts[3] + 1) - 1
vim.api.nvim_win_set_cursor(state.main.win, { sort_cursor[1], note_cursor_col })
assert(state.workspaces[1].active_col == 2, "cursor-only sort setup unexpectedly changed the active column")
vim.api.nvim_feedkeys("K", "x", false)
assert(state.workspaces[1].loading_rows and vim.wo[state.main.win].statusline:find("executing query", 1, true), "sort query did not show the table loader")
assert(vim.wait(3000, function()
  local item = state.workspaces[1]
  return not item.loading_rows and item.active_col == 3 and item.sort_column == "note" and item.sort_direction == "asc" and item.data.rows[1][3]:find("one complete", 1, true)
end, 20), "Shift-K did not sort the cursor column ascending")
assert(not state.workspaces[1].loading_rows and not vim.wo[state.main.win].statusline:find("executing query", 1, true), "sort loader remained after rows loaded")
vim.api.nvim_feedkeys("J", "x", false)
assert(vim.wait(3000, function()
  local item = state.workspaces[1]
  return item.sort_column == "note" and item.sort_direction == "desc" and item.data.rows[1][3] == "two"
end, 20), "Shift-J did not sort the cursor column descending")
vim.api.nvim_feedkeys("K", "x", false)
assert(vim.wait(3000, function()
  local item = state.workspaces[1]
  return item.sort_direction == "asc" and item.data.rows[1][3]:find("one complete", 1, true)
end, 20), "Shift-K did not restore ascending sort")
vim.api.nvim_feedkeys("0K", "x", false)
assert(vim.wait(3000, function()
  local item = state.workspaces[1]
  return item.sort_column == "id" and item.sort_direction == "asc" and item.data.rows[1][1] == 1
end, 20), "could not restore primary-key order after sorting")
vim.api.nvim_feedkeys("ll", "x", false)
assert(state.workspaces[1].active_col == 3, "could not return to the note column after sorting")
local current_row_line="1\tcore\tone complete value that is longer than a rendered table cell\tbasketball\tsms"
vim.api.nvim_feedkeys("yy", "x", false)
assert(vim.fn.getreg("+")==current_row_line,"yy did not copy the current row's complete values")
vim.api.nvim_feedkeys("v", "x", false)
assert(state.viewer and state.viewer.win and vim.api.nvim_win_is_valid(state.viewer.win), "full-value viewer did not open")
assert(table.concat(vim.api.nvim_buf_get_lines(state.viewer.buf, 0, -1, false), "\n") == "one complete value that is longer than a rendered table cell", "full-value viewer truncated the cell")
local has_format_mapping = false
local has_copy_mapping = false
for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(state.viewer.buf, "n")) do if mapping.lhs == "=" then has_format_mapping = true elseif mapping.lhs == "yy" then has_copy_mapping = true end end
assert(has_format_mapping, "full-value viewer has no format mapping")
assert(has_copy_mapping, "full-value viewer has no yy copy mapping")
local viewer_config = vim.api.nvim_win_get_config(state.viewer.win)
assert(viewer_config.width >= vim.o.columns - 8 and viewer_config.height >= vim.o.lines - vim.o.cmdheight - 7, "full-value viewer is not near fullscreen")
assert(vim.bo[state.viewer.buf].readonly and not vim.bo[state.viewer.buf].modifiable, "full-value viewer is not read-only")
vim.api.nvim_feedkeys("yy", "x", false)
assert(vim.fn.getreg("+")=="one complete value that is longer than a rendered table cell","yy did not copy the viewed value line")
vim.api.nvim_feedkeys("q", "x", false)
assert(state.viewer == nil and vim.api.nvim_get_current_win() == state.main.win, "full-value viewer did not close back to the table")

vim.api.nvim_feedkeys("2", "x", false)
assert(state.workspaces[1].mode == "columns")
state.workspaces[1].column_filter = "team"
vim.api.nvim_feedkeys("/\r", "x", false)
assert(state.workspaces[1].column_filter == "", "/ did not start with a cleared column filter")
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
vim.api.nvim_feedkeys("[b", "x", false)
assert(state.workspace_index == 1)
vim.api.nvim_feedkeys("]b", "x", false)
assert(state.workspace_index == 2)

vim.o.columns = 70
lazydata.apply_layout(true)
assert(#vim.api.nvim_tabpage_list_wins(0) == 1, "narrow layout did not collapse")
vim.o.columns = 120
lazydata.apply_layout(true)

local table_line = vim.api.nvim_get_current_line()
vim.api.nvim_win_set_cursor(state.main.win, { vim.api.nvim_win_get_cursor(state.main.win)[1], #table_line - 1 })
local before_b = vim.api.nvim_win_get_cursor(state.main.win)[2]
vim.api.nvim_feedkeys("b", "x", false)
assert(state.active_panel == "main" and vim.api.nvim_win_get_cursor(state.main.win)[2] < before_b, "b did not use native previous-word movement in the table")
vim.api.nvim_feedkeys("\t", "x", false)
assert(state.screen == "workspace" and state.active_panel == "sidebar", "Tab did not focus the table list")
vim.api.nvim_feedkeys("b", "x", false)
assert(state.screen == "profiles", "b did not navigate back from tables to connections")
assert(vim.api.nvim_win_get_buf(state.main.win) == state.main.buf, "connections screen kept the table buffer")
assert(vim.wait(3000, function() return #state.profiles == 1 end, 20), "profiles did not reload")
vim.api.nvim_feedkeys("\r", "x", false)
assert(vim.wait(3000, function() return state.screen == "workspace" and #state.tables == 3 end, 20), "reconnect after back navigation failed")

vim.api.nvim_feedkeys(string.char(5), "x", false)
assert(vim.wait(1000, function() return #state.workspaces == 3 end, 20), "query tab did not open")
local query = state.workspaces[3]
vim.bo[query.buf].modifiable = true
vim.api.nvim_buf_set_lines(query.buf, 0, -1, false, { "SELECT team, COUNT(*) AS count FROM people GROUP BY team ORDER BY count DESC" })
vim.cmd.stopinsert()
vim.api.nvim_feedkeys(string.char(18), "x", false)
assert(query.query_loading, "SQL execution did not expose its loading state")
assert(vim.wo[state.main.win].winbar:find("Executing SQL query", 1, true), "query winbar did not show the running SQL query")
assert(vim.tbl_contains(vim.api.nvim_buf_get_lines(query.result_buf, 0, -1, false), "  Executing SQL query…"), "query results did not show a loader message")
assert(vim.wait(3000, function() return query.results and query.results[1] and #query.results[1].rows == 2 end, 20), "query results did not load")
assert(not query.query_loading, "SQL loading state remained after results loaded")
assert(not vim.wo[state.main.win].winbar:find("Executing SQL query", 1, true), "query loader remained visible after results loaded")

vim.api.nvim_feedkeys("[b[b", "x", false)
assert(state.workspace_index == 1 and state.workspaces[1].table == "people", "could not return to the people table")
local table_mappings = {}
for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(state.workspaces[1].buf, "n")) do table_mappings[mapping.lhs] = true end
assert(table_mappings[" "], "Space row-mark mapping is missing")
assert(table_mappings.yy, "yy row-copy mapping is missing")
assert(table_mappings.y, "y marked-row copy mapping is missing")
assert(table_mappings.e, "e row-edit mapping is missing")
assert(table_mappings["<C-S>"], "Ctrl-S row-save mapping is missing")
assert(table_mappings.U, "U row-discard mapping is missing")
assert(table_mappings.d, "d row-delete mapping is missing")
assert(table_mappings.K, "K ascending-sort mapping is missing")
assert(table_mappings.J, "J descending-sort mapping is missing")
assert(table_mappings["[["], "[[ previous-page mapping is missing")
assert(table_mappings["]]"], "]] next-page mapping is missing")
assert(not table_mappings["[p"] and not table_mappings["]p"], "old page mappings are still present")
vim.api.nvim_win_set_cursor(state.main.win, { 3, 0 })
vim.api.nvim_feedkeys("0l", "x", false)
vim.api.nvim_feedkeys(" ", "x", false)
vim.api.nvim_feedkeys("j ", "x", false)
local marked_row_lines={current_row_line,"2\tcore\ttwo\tfootball\tsms"}
local marked_cursor_line=marked_row_lines[2]
vim.api.nvim_feedkeys("yy", "x", false)
assert(vim.fn.getreg("+")==marked_cursor_line,"yy copied marked rows instead of only the current line")
vim.api.nvim_feedkeys("y", "x", false)
assert(vim.wait(1000,function()return vim.fn.getreg("+")==table.concat(marked_row_lines,"\n")end,10),"y did not copy all marked rows in display order")
vim.api.nvim_feedkeys("e", "x", false)
assert(state.cell_editor and #state.cell_editor.targets == 2 and state.cell_editor.column.name == "team", "multi-row cell editor did not open for the marked rows")
vim.cmd.stopinsert()
vim.api.nvim_buf_set_lines(state.cell_editor.buf, 0, -1, false, { "platform" })
vim.api.nvim_feedkeys(string.char(19), "x", false)
assert(state.cell_editor == nil and vim.tbl_count(state.workspaces[1].pending_updates) == 2, "cell editor did not stage both row updates")
assert(vim.wo[state.main.win].statusline:find("changed: 2 fields / 2 rows", 1, true), "table statusline did not summarize staged updates")
local update_prompt
local original_update_confirm = vim.fn.confirm
vim.fn.confirm = function(prompt, choices, default)
  update_prompt = { prompt = prompt, choices = choices, default = default }
  return 1
end
vim.api.nvim_feedkeys(string.char(19), "x", false)
vim.fn.confirm = original_update_confirm
assert(update_prompt and update_prompt.prompt:find("Execute 2 staged field updates across 2 rows", 1, true), "multi-row update did not request execution confirmation")
assert(update_prompt.choices == "&Execute\n&Cancel" and update_prompt.default == 2, "update confirmation did not default to Cancel")
assert(vim.wait(3000, function()
  local item = state.workspaces[1]
  return item.data and item.data.rows[1][2] == "platform" and item.data.rows[2][2] == "platform"
end, 20), "confirmed multi-row update did not persist the new values")
assert(vim.tbl_count(state.workspaces[1].pending_updates) == 0, "staged updates were not cleared after saving")
if state.message_dialog then vim.api.nvim_feedkeys("\r", "x", false) end
vim.api.nvim_win_set_cursor(state.main.win, { 3, 0 })
vim.api.nvim_feedkeys(" ", "x", false)
vim.api.nvim_feedkeys("j ", "x", false)
assert(vim.tbl_count(state.workspaces[1].marked_rows) == 2, "Space did not mark two rows")
local marked_lines = 0
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(state.workspaces[1].buf, -1, 0, -1, { details = true })) do
  if mark[4].line_hl_group == "LazyDataMarked" then marked_lines = marked_lines + 1 end
end
assert(marked_lines == 2, "marked rows were not highlighted")
local original_confirm = vim.fn.confirm
local delete_prompt
vim.fn.confirm = function(prompt, choices, default)
  delete_prompt = { prompt = prompt, choices = choices, default = default }
  return 1
end
vim.api.nvim_feedkeys("d", "x", false)
vim.fn.confirm = original_confirm
assert(delete_prompt and delete_prompt.prompt:find("Delete 2 marked rows", 1, true), "multi-row delete did not request confirmation")
assert(delete_prompt.choices == "&Delete\n&Cancel" and delete_prompt.default == 2, "delete confirmation did not default to Cancel")
assert(vim.wait(3000, function()
  local item = state.workspaces[1]
  return item.data and #item.data.rows == 1 and item.data.rows[1][1] == 3
end, 20), "confirmed multi-row delete did not remove the marked rows")
assert(vim.tbl_count(state.workspaces[1].marked_rows) == 0, "row marks were not cleared after deletion")
if state.message_dialog then vim.api.nvim_feedkeys("\r", "x", false) end

vim.api.nvim_feedkeys("\t", "x", false)
state.table_index = 3
vim.api.nvim_feedkeys("\r", "x", false)
assert(vim.wait(3000, function()
  local item = state.workspaces[4]
  return item and item.table == "z_paged" and item.data and #item.data.rows == 30 and item.data.has_more
end, 20), "large table did not stop at the first 30 rows")
vim.api.nvim_feedkeys("]]", "x", false)
local paged_item = state.workspaces[4]
assert(paged_item.loading_rows, "]] did not expose the table loading state")
assert(vim.wo[state.main.win].statusline:find("executing query", 1, true), "table statusline did not show the running query")
assert(vim.wait(3000, function()
  local item = state.workspaces[4]
  return item.page == 1 and item.data and #item.data.rows == 5 and item.data.rows[1][1] == 5 and not item.data.has_more
end, 20), "]] did not load the next 30-row page")
assert(not paged_item.loading_rows, "table loading state remained after rows loaded")
assert(not vim.wo[state.main.win].statusline:find("executing query", 1, true), "table loader remained visible after rows loaded")

assert(state.job and state.job > 0, "backend process is not running")
print("lazydata end-to-end tests: ok")
