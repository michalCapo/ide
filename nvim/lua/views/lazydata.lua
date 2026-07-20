local M = {}

local S = {
  job = nil, request_seq = 0, pending = {}, stdout_tail = "", busy = 0,
  screen = "profiles", profiles = {}, profile_index = 1, profile_filter = "",
  profile = nil, database = nil, tables = {}, table_index = 1, table_filter = "",
  workspaces = {}, workspace_index = 0, active_panel = "sidebar",
  sidebar = {}, main = {}, result = {}, group = nil, current_request = nil,
  form = nil, picker = nil, viewer = nil,
}

local ns = vim.api.nvim_create_namespace("lazydata")
local form_ns = vim.api.nvim_create_namespace("lazydata_form")
local picker_ns = vim.api.nvim_create_namespace("lazydata_picker")
local configure, cancel_request, switch_workspace, close_workspace, quit, focus, open_picker, jump_to_column, open_value_viewer

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "lazydata" })
end

local function setup_highlights()
  local hl = vim.api.nvim_set_hl
  hl(0, "LazyDataAccent", { link = "Added" })
  hl(0, "LazyDataMuted", { link = "Comment" })
  hl(0, "LazyDataHeader", { link = "Title" })
  hl(0, "LazyDataNull", { link = "DiagnosticWarn" })
  hl(0, "LazyDataError", { link = "DiagnosticError" })
  hl(0, "LazyDataSuccess", { link = "DiagnosticOk" })
  hl(0, "LazyDataSelected", { link = "Visual" })
  hl(0, "LazyDataKey", { link = "Identifier" })
end

local function set_lines(buf, lines, modifiable)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, #lines > 0 and lines or { "" })
  vim.bo[buf].modifiable = modifiable == true
end

local function make_buf(name, modifiable)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "lazydata://" .. name .. "/" .. tostring(buf))
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = modifiable == true
  return buf
end

local function backend_error(err)
  if type(err) ~= "table" then return tostring(err or "Unknown error") end
  local message = err.message or "Database operation failed"
  if err.detail and err.detail ~= "" then message = message .. ": " .. err.detail end
  return message
end

local function receive_line(line)
  if line == "" then return end
  local ok, response = pcall(vim.json.decode, line)
  if not ok or type(response) ~= "table" then
    notify("Invalid backend response", vim.log.levels.ERROR)
    return
  end
  local pending = S.pending[tostring(response.id or "")]
  if not pending then return end
  S.pending[tostring(response.id)] = nil
  S.busy = math.max(0, S.busy - 1)
  if S.current_request == tostring(response.id) then S.current_request = nil end
  vim.schedule(function()
    if response.ok then pending(response.result, nil) else pending(nil, response.error or {}) end
  end)
end

local function on_stdout(_, data)
  if not data then return end
  local text = S.stdout_tail .. table.concat(data, "\n")
  local complete = data[#data] == ""
  local lines = vim.split(text, "\n", { plain = true })
  S.stdout_tail = complete and "" or table.remove(lines)
  for _, line in ipairs(lines) do receive_line(line) end
end

local function backend_path()
  return vim.env.LAZYDATA_SQL or vim.env.LAZYDATA_BACKEND or "lazydata-sql"
end

local function start_backend()
  if S.job and S.job > 0 then return true end
  local executable = backend_path()
  if vim.fn.executable(executable) ~= 1 then
    notify("Backend is not installed or executable: " .. executable, vim.log.levels.ERROR)
    return false
  end
  S.job = vim.fn.jobstart({ executable }, {
    stdin = "pipe",
    stdout_buffered = false,
    on_stdout = on_stdout,
    on_stderr = function(_, data)
      local message = table.concat(data or {}, "\n"):gsub("\n+$", "")
      if message ~= "" then vim.schedule(function() notify(message, vim.log.levels.ERROR) end) end
    end,
    on_exit = function(_, code)
      local pending = S.pending
      S.pending, S.job, S.busy, S.current_request = {}, nil, 0, nil
      vim.schedule(function()
        for _, callback in pairs(pending) do callback(nil, { message = "Backend stopped", detail = "exit " .. code }) end
      end)
    end,
  })
  return S.job and S.job > 0
end

local function request(method, params, callback, tracked)
  if not start_backend() then return nil end
  S.request_seq = S.request_seq + 1
  local id = tostring(S.request_seq)
  S.pending[id] = callback or function() end
  S.busy = S.busy + 1
  if tracked then S.current_request = id end
  local payload = vim.json.encode({ id = id, method = method, params = params or {} }) .. "\n"
  if vim.fn.chansend(S.job, payload) == 0 then
    S.pending[id] = nil
    S.busy = math.max(0, S.busy - 1)
    notify("Could not write to backend", vim.log.levels.ERROR)
    return nil
  end
  return id
end

local function selected_profile()
  local visible = {}
  local needle = S.profile_filter:lower()
  for _, p in ipairs(S.profiles) do
    if needle == "" or p.name:lower():find(needle, 1, true) then visible[#visible + 1] = p end
  end
  return visible[S.profile_index], visible
end

local function selected_table()
  local visible = {}
  local needle = S.table_filter:lower()
  for _, t in ipairs(S.tables) do
    local label = (t.schema ~= "" and t.schema .. "." or "") .. t.name
    if needle == "" or label:lower():find(needle, 1, true) then visible[#visible + 1] = t end
  end
  return visible[S.table_index], visible
end

local function workspace() return S.workspaces[S.workspace_index] end

local function title_tabs()
  if #S.workspaces == 0 then return " No open tables · Enter opens selected table " end
  local parts = {}
  for i, item in ipairs(S.workspaces) do
    local marker = i == S.workspace_index and "●" or "○"
    parts[#parts + 1] = string.format(" %s %s ", marker, item.title)
  end
  return table.concat(parts, "│")
end

local function decorate()
  local busy = S.busy > 0 and "  [working…]" or ""
  if S.screen == "profiles" then
    if S.main.win and vim.api.nvim_win_is_valid(S.main.win) then
      vim.wo[S.main.win].winbar = " LazyData · Connections" .. busy .. " %= n new · e edit · d delete · Enter connect · ? help "
      vim.wo[S.main.win].winhighlight = "WinBar:LazyDataAccent,WinBarNC:LazyDataMuted"
    end
    return
  end
  if S.sidebar.win and vim.api.nvim_win_is_valid(S.sidebar.win) then
    local focus = S.active_panel == "sidebar" and "LazyDataAccent" or "LazyDataMuted"
    vim.wo[S.sidebar.win].winbar = " " .. (S.profile and S.profile.name or "Connection") .. " · " .. (S.database or "") .. busy .. " %=" .. #S.tables .. " tables "
    vim.wo[S.sidebar.win].winhighlight = "WinBar:" .. focus .. ",WinBarNC:LazyDataMuted"
  end
  if S.main.win and vim.api.nvim_win_is_valid(S.main.win) then
    local focus = S.active_panel == "main" and "LazyDataAccent" or "LazyDataMuted"
    vim.wo[S.main.win].winbar = title_tabs()
    vim.wo[S.main.win].winhighlight = "WinBar:" .. focus .. ",WinBarNC:LazyDataMuted"
  end
  if S.result.win and vim.api.nvim_win_is_valid(S.result.win) then
    local item=workspace();local suffix=item and item.kind=="query"and #(item.results or {})>1 and string.format(" · %d/%d",item.result_index or 1,#item.results)or""
    vim.wo[S.result.win].winbar = " Results" .. suffix .. " "
    vim.wo[S.result.win].winhighlight = "WinBar:" .. (S.active_panel == "result" and "LazyDataAccent" or "LazyDataMuted") .. ",WinBarNC:LazyDataMuted"
  end
end

local function configure_window(win)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
end

local function render_profiles()
  local _, visible = selected_profile()
  S.profile_index = math.max(1, math.min(S.profile_index, math.max(1, #visible)))
  local lines = {}
  if S.profile_filter ~= "" then lines[#lines + 1] = "  Filter: " .. S.profile_filter; lines[#lines + 1] = "" end
  if #visible == 0 then
    lines[#lines + 1] = #S.profiles == 0 and "  No connections yet. Press n to create one." or "  No matching connections."
  else
    for _, p in ipairs(visible) do
      local detail = p.driver == "sqlite" and p.path or string.format("%s@%s:%s/%s", p.user or "", p.host or "", p.port or "", p.database or "")
      lines[#lines + 1] = string.format("  %-22s  %-8s  %s%s", p.name, p.driver, detail, p.read_only and "  [read-only]" or "")
    end
  end
  set_lines(S.main.buf, lines)
  if S.main.win and vim.api.nvim_win_is_valid(S.main.win) then
    local row = S.profile_index + (S.profile_filter ~= "" and 2 or 0)
    pcall(vim.api.nvim_win_set_cursor, S.main.win, { math.max(row, 1), 0 })
  end
  decorate()
end

local function render_tables()
  local _, visible = selected_table()
  S.table_index = math.max(1, math.min(S.table_index, math.max(1, #visible)))
  local lines = {}
  if S.table_filter ~= "" then lines[#lines + 1] = "  / " .. S.table_filter; lines[#lines + 1] = "" end
  if #visible == 0 then lines[#lines + 1] = "  No matching tables." end
  for _, t in ipairs(visible) do lines[#lines + 1] = "  " .. (t.schema ~= "" and t.schema .. "." or "") .. t.name end
  set_lines(S.sidebar.buf, lines)
  if S.sidebar.win and vim.api.nvim_win_is_valid(S.sidebar.win) then
    pcall(vim.api.nvim_win_set_cursor, S.sidebar.win, { S.table_index + (S.table_filter ~= "" and 2 or 0), 0 })
  end
  decorate()
end

local function value_text(value)
  if value == vim.NIL or value == nil then return "NULL" end
  local text = type(value) == "table" and vim.json.encode(value) or tostring(value)
  text = text:gsub("[\r\n\t]", " ")
  return vim.fn.strcharpart(text, 0, 32)
end

local function render_result_set(buf, result)
  result = result or {}
  if not result.columns or #result.columns == 0 then
    set_lines(buf, { "", "  " .. (result.message or "No results") })
    return {}
  end
  local widths = {}
  for i, name in ipairs(result.columns) do widths[i] = math.min(32, math.max(3, vim.fn.strdisplaywidth(name))) end
  for _, row in ipairs(result.rows or {}) do
    for i, value in ipairs(row) do widths[i] = math.min(32, math.max(widths[i], vim.fn.strdisplaywidth(value_text(value)))) end
  end
  local function line(row)
    local cells = {}
    for i, value in ipairs(row) do
      local text = value_text(value)
      cells[i] = text .. string.rep(" ", math.max(0, widths[i] - vim.fn.strdisplaywidth(text)))
    end
    return " " .. table.concat(cells, " │ ") .. " "
  end
  local lines = { line(result.columns) }
  local rule = {}
  for i, width in ipairs(widths) do rule[i] = string.rep("─", width) end
  lines[#lines + 1] = "─" .. table.concat(rule, "─┼─") .. "─"
  for _, row in ipairs(result.rows or {}) do lines[#lines + 1] = line(row) end
  if #(result.rows or {}) == 0 then lines[#lines + 1] = "  No rows." end
  set_lines(buf, lines)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  pcall(vim.api.nvim_buf_add_highlight, buf, ns, "LazyDataHeader", 0, 0, -1)
  local starts, col = {}, 1
  for i, width in ipairs(widths) do starts[i], col = col, col + width + 3 end
  return starts
end

local function filter_summary(item)
  local parts = {}
  if item.raw_where and item.raw_where ~= "" then parts[#parts + 1] = "(" .. item.raw_where .. ")" end
  for _, p in ipairs(item.predicates or {}) do
    parts[#parts + 1] = p.column .. (p.is_null and " IS NULL" or " = " .. value_text(p.value))
  end
  return #parts > 0 and table.concat(parts, " AND ") or "none"
end

local function cell_byte_col(win,row,visual_col)
  local byte_col=vim.fn.virtcol2col(win,row,(visual_col or 0)+1)
  return math.max(0,byte_col-1)
end

local function render_table(item)
  if item.mode == "columns" then
    local rows = {}
    local needle = (item.column_filter or ""):lower()
    for _, c in ipairs(item.columns or {}) do
      if needle == "" or c.name:lower():find(needle, 1, true) then
        rows[#rows + 1] = { c.name, c.type, c.nullable and "yes" or "no", c.primary and "primary" or "", value_text(c.default) }
      end
    end
    item.cell_starts = render_result_set(item.buf, { columns = { "column", "type", "nullable", "key", "default" }, rows = rows })
  else
    item.cell_starts = render_result_set(item.buf, item.data or { columns = {}, rows = {} })
  end
  if S.main.win and vim.api.nvim_win_is_valid(S.main.win) then
    vim.api.nvim_win_set_buf(S.main.win, item.buf)
    if vim.api.nvim_buf_line_count(item.buf) >= 3 and vim.api.nvim_win_get_cursor(S.main.win)[1] <= 2 then
      local visual_col=(item.cell_starts or {})[item.active_col or 1]or 0
      pcall(vim.api.nvim_win_set_cursor,S.main.win,{3,cell_byte_col(S.main.win,3,visual_col)})
    end
    local mode = item.mode == "columns" and "columns" or string.format("rows · page %d%s", (item.page or 0) + 1, item.data and item.data.has_more and "+" or "")
    local column = item.columns and item.columns[item.active_col or 1]
    vim.wo[S.main.win].statusline = " " .. item.title:gsub("%%", "%%%%") .. "  " .. mode .. (column and "  column: " .. column.name:gsub("%%", "%%%%") or "") .. "  filter: " .. filter_summary(item):gsub("%%", "%%%%") .. " "
  end
  decorate()
end

local function render_query(item)
  if S.main.win and vim.api.nvim_win_is_valid(S.main.win) then vim.api.nvim_win_set_buf(S.main.win, item.buf) end
  if item.result_buf then render_result_set(item.result_buf, item.results and item.results[item.result_index or 1] or { message = "Press Ctrl-R to execute" }) end
  decorate()
end

local function switch_result(delta)
  local item=workspace();if not item or item.kind~="query"or #(item.results or {})<2 then return end
  item.result_index=((item.result_index or 1)-1+delta)%#item.results+1;render_query(item)
end

local function render_workspace()
  if S.screen == "workspace" and vim.o.columns < 80 and S.active_panel == "sidebar" then decorate(); return end
  local item = workspace()
  if not item then
    set_lines(S.main.buf, { "", "  Select a table and press Enter, or press Ctrl-E for a SQL query." })
    if S.main.win and vim.api.nvim_win_is_valid(S.main.win) then vim.api.nvim_win_set_buf(S.main.win, S.main.buf) end
    decorate(); return
  end
  if item.kind == "query" then render_query(item) else render_table(item) end
end

local function base_params(item)
  return { profile_id = item.profile.id, database = item.database, schema = item.schema, table = item.table }
end

local function load_rows(item)
  local params = base_params(item)
  params.raw_where, params.predicates, params.page, params.page_size = item.raw_where or "", item.predicates or {}, item.page or 0, 200
  request("rows", params, function(result, err)
    if err then notify(backend_error(err), vim.log.levels.ERROR); return end
    item.data = result
    if workspace() == item then render_table(item) end
  end, true)
end

local function load_columns(item, after)
  request("columns", base_params(item), function(result, err)
    if err then notify(backend_error(err), vim.log.levels.ERROR); return end
    item.columns = result or {}
    if after then after() elseif workspace() == item then render_table(item) end
  end, true)
end

local function set_main_buffer_maps(buf)
  local opts = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set("n", "1", function() local w=workspace();if w and w.kind=="table"then w.mode="rows";render_table(w)end end, opts)
  vim.keymap.set("n", "2", function() local w=workspace();if w and w.kind=="table"then w.mode="columns";render_table(w)end end, opts)
  vim.keymap.set("n", "c", function() jump_to_column() end, opts)
  vim.keymap.set("n", "v", function() open_value_viewer() end, opts)
end

local function open_table()
  local t = selected_table()
  if not t then return end
  for i, item in ipairs(S.workspaces) do
    if item.kind == "table" and item.profile.id == S.profile.id and item.database == S.database and item.schema == t.schema and item.table == t.name then
      S.workspace_index = i; S.active_panel = "main"; render_workspace(); return
    end
  end
  local label = (t.schema ~= "" and t.schema .. "." or "") .. t.name
  local item = { kind="table", title=label, profile=S.profile, database=S.database, schema=t.schema, table=t.name,
    mode="rows", page=0, predicates={}, raw_where="", buf=make_buf("table/"..label, false) }
  configure(item.buf)
  set_main_buffer_maps(item.buf)
  S.workspaces[#S.workspaces + 1] = item; S.workspace_index = #S.workspaces; S.active_panel = "main"
  M.apply_layout(true); load_columns(item, function() load_rows(item) end)
end

local function query_text(item)
  local mode = vim.api.nvim_get_mode().mode
  if mode:find("[vV\22]") then
    local start_pos, end_pos = vim.fn.getpos("v"), vim.fn.getpos(".")
    local first, last = math.min(start_pos[2], end_pos[2]), math.max(start_pos[2], end_pos[2])
    return table.concat(vim.api.nvim_buf_get_lines(item.buf, first - 1, last, false), "\n")
  end
  return table.concat(vim.api.nvim_buf_get_lines(item.buf, 0, -1, false), "\n")
end

local function read_looking(sql)
  local cleaned = sql:gsub("^%s*%-%-[^\n]*\n", ""):gsub("^%s*/%*.-%*/", "")
  local token = cleaned:match("^%s*(%a+)")
  return token and ({select=true,show=true,explain=true,describe=true,values=true})[token:lower()] or false
end

local function execute_query()
  local item = workspace(); if not item or item.kind ~= "query" then return end
  local sql = query_text(item)
  if vim.trim(sql) == "" then notify("Query is empty", vim.log.levels.WARN); return end
  if not read_looking(sql) then
    local answer = vim.fn.confirm("This query may modify data or schema. Run it?", "&Run\n&Cancel", 2)
    if answer ~= 1 then return end
  end
  local params = { profile_id=item.profile.id, database=item.database, sql=sql }
  request("query", params, function(results, err)
    if err then
      item.results = { { message = backend_error(err) } }; render_query(item); notify(backend_error(err), vim.log.levels.ERROR); return
    end
    item.results = results or {};item.result_index=1; vim.bo[item.buf].modified = false; render_query(item)
  end, true)
end

local function open_query()
  if not S.profile then notify("Connect to a database first", vim.log.levels.WARN); return end
  local number = 1; for _, w in ipairs(S.workspaces) do if w.kind == "query" then number = number + 1 end end
  local item = { kind="query", title="query "..number, profile=S.profile, database=S.database, buf=make_buf("query/"..number, true), result_buf=make_buf("results/"..number, false) }
  vim.bo[item.buf].buftype = "acwrite"; vim.bo[item.buf].filetype = "sql"
  vim.api.nvim_create_autocmd("BufWriteCmd", { buffer=item.buf, callback=function() execute_query() end })
  local opts={buffer=item.buf,silent=true}
  vim.keymap.set({"n","v"},"<C-r>",execute_query,opts)
  vim.keymap.set({"n","i"},"<C-r>",function() vim.cmd.stopinsert();execute_query() end,opts)
  vim.keymap.set("n","<C-c>",cancel_request or function() end,opts)
  vim.keymap.set("n","[t",function()switch_workspace(-1)end,opts);vim.keymap.set("n","]t",function()switch_workspace(1)end,opts)
  vim.keymap.set("n","[r",function()switch_result(-1)end,opts);vim.keymap.set("n","]r",function()switch_result(1)end,opts)
  vim.keymap.set("n","X",close_workspace,opts);vim.keymap.set("n","q",quit or function() end,opts)
  vim.keymap.set("n","<Tab>",function()focus(1)end,opts);vim.keymap.set("n","<S-Tab>",function()focus(-1)end,opts)
  configure(item.result_buf)
  S.workspaces[#S.workspaces+1]=item;S.workspace_index=#S.workspaces;S.active_panel="main";M.apply_layout(true)
  if S.main.win and vim.api.nvim_win_is_valid(S.main.win) then vim.api.nvim_set_current_win(S.main.win);vim.cmd.startinsert() end
end

switch_workspace = function(delta)
  if #S.workspaces == 0 then return end
  S.workspace_index = ((S.workspace_index - 1 + delta) % #S.workspaces) + 1
  M.apply_layout(true)
end

close_workspace = function()
  local item=workspace();if not item then return end
  if item.kind=="query" and vim.bo[item.buf].modified and vim.fn.confirm("Discard modified query?","&Discard\n&Keep",2)~=1 then return end
  if item.buf and vim.api.nvim_buf_is_valid(item.buf) then vim.api.nvim_buf_delete(item.buf,{force=true}) end
  if item.result_buf and vim.api.nvim_buf_is_valid(item.result_buf) then vim.api.nvim_buf_delete(item.result_buf,{force=true}) end
  table.remove(S.workspaces,S.workspace_index);S.workspace_index=math.min(S.workspace_index,#S.workspaces);M.apply_layout(true)
end

local function move(delta)
  if S.screen=="profiles" then local _,v=selected_profile();S.profile_index=math.max(1,math.min(#v,S.profile_index+delta));render_profiles();return end
  if S.active_panel=="sidebar" then local _,v=selected_table();S.table_index=math.max(1,math.min(#v,S.table_index+delta));render_tables();return end
  local win=S.active_panel=="result" and S.result.win or S.main.win
  if win and vim.api.nvim_win_is_valid(win) then
    local cursor=vim.api.nvim_win_get_cursor(win);local count=vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win));local item=workspace();local first=item and item.kind=="table"and 3 or 1;local row=math.max(first,math.min(count,cursor[1]+delta));local col=cursor[2]
    if item and item.kind=="table"and item.mode=="rows"and win==S.main.win then col=cell_byte_col(win,row,(item.cell_starts or{})[item.active_col or 1]or 0)end
    pcall(vim.api.nvim_win_set_cursor,win,{row,col})
  end
end

local function jump(last)
  if S.screen=="profiles" then local _,v=selected_profile();S.profile_index=last and #v or 1;render_profiles();return end
  if S.active_panel=="sidebar" then local _,v=selected_table();S.table_index=last and #v or 1;render_tables();return end
  local win=S.active_panel=="result" and S.result.win or S.main.win;if win and vim.api.nvim_win_is_valid(win)then local item=workspace();local count=vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win));local row=last and count or(item and item.kind=="table"and 3 or 1);local col=vim.api.nvim_win_get_cursor(win)[2];if item and item.kind=="table"and item.mode=="rows"and win==S.main.win then col=cell_byte_col(win,row,(item.cell_starts or{})[item.active_col or 1]or 0)end;pcall(vim.api.nvim_win_set_cursor,win,{row,col})end
end

local function input(label, default, secret)
  if secret then return vim.fn.inputsecret(label) end
  return vim.fn.input(label, default or "")
end

local driver_labels = { postgres = "PostgreSQL", mssql = "SQL Server", sqlite = "SQLite" }
local driver_order = { "postgres", "mssql", "sqlite" }
local render_form, close_form, commit_form_edit, test_form, save_form

local function form_fields(form)
  local values = form.values
  local fields = {
    { key="driver", label="Driver", type="choice", options=driver_order },
    { key="name", label="Connection name", type="text" },
  }
  if values.driver == "sqlite" then
    fields[#fields+1]={key="path",label="Database file",type="text"}
  else
    fields[#fields+1]={key="host",label="Host",type="text"}
    fields[#fields+1]={key="port",label="Port",type="text"}
    fields[#fields+1]={key="user",label="User",type="text"}
    fields[#fields+1]={key="password",label="Password",type="password"}
    fields[#fields+1]={key="database",label="Database",type="text"}
    if values.driver=="postgres" then fields[#fields+1]={key="ssl_mode",label="SSL mode",type="choice",options={"disable","allow","prefer","require","verify-ca","verify-full"}}
    else fields[#fields+1]={key="encrypt",label="Encrypt",type="boolean"};fields[#fields+1]={key="trust_server_certificate",label="Trust certificate",type="boolean"} end
  end
  fields[#fields+1]={key="read_only",label="Read-only",type="boolean"}
  fields[#fields+1]={key="test",label="Test connection",type="action",shortcut="Ctrl-T"}
  fields[#fields+1]={key="save",label="Save connection",type="action",shortcut="Ctrl-S"}
  return fields
end

local function form_profile(form)
  local v=form.values
  local profile={id=v.id,name=vim.trim(v.name or ""),driver=v.driver,read_only=v.read_only==true,timeout_ms=tonumber(v.timeout_ms)or 30000}
  if v.driver=="sqlite"then profile.path=vim.trim(v.path or "") else
    profile.host=vim.trim(v.host or "");profile.port=tonumber(v.port);profile.user=v.user or "";profile.password=v.password or "";profile.database=vim.trim(v.database or "")
    if v.driver=="postgres"then profile.ssl_mode=v.ssl_mode or"prefer"else profile.encrypt=v.encrypt==true;profile.trust_server_certificate=v.trust_server_certificate==true end
  end
  return profile
end

local function form_display(field,value)
  if field.type=="choice"and field.key=="driver"then return driver_labels[value]or tostring(value or"") end
  if field.type=="boolean"then return value and "● on"or"○ off" end
  if field.type=="password"then return string.rep("•",vim.fn.strchars(value or"")) end
  return tostring(value or"")
end

local function set_form_status(form,message,kind)
  if S.form~=form then return end
  form.status=message;form.status_kind=kind or"muted";render_form(form)
end

local function form_float_config(form,height)
  local width=math.max(24,math.min(72,vim.o.columns-4));height=math.max(5,math.min(height,vim.o.lines-vim.o.cmdheight-4))
  return {relative="editor",style="minimal",border="rounded",title=form.values.id and" Edit connection "or" New connection ",title_pos="center",width=width,height=height,row=math.max(1,math.floor((vim.o.lines-vim.o.cmdheight-height)/2)),col=math.max(1,math.floor((vim.o.columns-width)/2)),zindex=60}
end

render_form = function(form)
  if S.form~=form or not vim.api.nvim_buf_is_valid(form.buf)then return end
  form.fields=form_fields(form);form.index=math.max(1,math.min(form.index or 1,#form.fields))
  local lines={"  Connection details",""};local rows={}
  for i,field in ipairs(form.fields)do
    if field.type=="action"and not form.actions_started then lines[#lines+1]="";lines[#lines+1]="  Actions";form.actions_started=true end
    local row=#lines+1;rows[i]=row;field.row=row
    if field.type=="action"then lines[row]=string.format("  [ %-21s ]  %s",field.label,field.shortcut)
    else lines[row]=string.format("  %-19s %s",field.label,form_display(field,form.values[field.key])) end
  end
  form.actions_started=nil
  lines[#lines+1]="";lines[#lines+1]="  Tab move · Enter edit/select · Ctrl-T test · Ctrl-S save · Esc cancel"
  form.status_row=#lines+1;lines[#lines+1]="  "..(form.status or"Ready")
  local config=form_float_config(form,#lines)
  if form.win and vim.api.nvim_win_is_valid(form.win)then vim.api.nvim_win_set_config(form.win,config)end
  vim.bo[form.buf].modifiable=true;vim.api.nvim_buf_set_lines(form.buf,0,-1,false,lines);vim.bo[form.buf].modifiable=false;vim.bo[form.buf].modified=false
  vim.api.nvim_buf_clear_namespace(form.buf,form_ns,0,-1)
  vim.api.nvim_buf_set_extmark(form.buf,form_ns,0,2,{end_col=#lines[1],hl_group="LazyDataHeader"})
  local actions_heading=nil
  for row,line in ipairs(lines)do if line=="  Actions"then actions_heading=row;vim.api.nvim_buf_set_extmark(form.buf,form_ns,row-1,2,{end_col=#line,hl_group="LazyDataHeader"})end end
  for i,field in ipairs(form.fields)do
    local row=rows[i]-1
    vim.api.nvim_buf_set_extmark(form.buf,form_ns,row,0,{line_hl_group=i==form.index and"LazyDataSelected"or nil})
    if field.type=="action"then vim.api.nvim_buf_set_extmark(form.buf,form_ns,row,2,{end_col=28,hl_group="LazyDataAccent"})
    else vim.api.nvim_buf_set_extmark(form.buf,form_ns,row,2,{end_col=21,hl_group="LazyDataMuted"})end
  end
  local status_hl=form.status_kind=="success"and"LazyDataSuccess"or form.status_kind=="error"and"LazyDataError"or form.status_kind=="working"and"LazyDataAccent"or"LazyDataMuted"
  vim.api.nvim_buf_set_extmark(form.buf,form_ns,form.status_row-1,2,{end_col=#lines[form.status_row],hl_group=status_hl})
  if form.win and vim.api.nvim_win_is_valid(form.win)then pcall(vim.api.nvim_win_set_cursor,form.win,{rows[form.index],0})end
end

local function mask_form_password(form,field)
  if field.type~="password"or not form.editing then return end
  local value=form.values[field.key]or"";local prefix=string.format("  %-19s ",field.label);local row=field.row-1
  vim.api.nvim_buf_clear_namespace(form.buf,form_ns,row,row+1)
  local chars=vim.fn.strchars(value)
  for i=0,chars-1 do local start=vim.str_byteindex(value,i);local finish=vim.str_byteindex(value,i+1);vim.api.nvim_buf_set_extmark(form.buf,form_ns,row,#prefix+start,{end_col=#prefix+finish,conceal="•"})end
end

local function begin_form_edit(form)
  local field=form.fields[form.index];if not field or(field.type~="text"and field.type~="password")then return end
  form.editing=true;form.edit_original=form.values[field.key]or"";form.edit_prefix=string.format("  %-19s ",field.label)
  vim.bo[form.buf].modifiable=true;vim.api.nvim_buf_set_lines(form.buf,field.row-1,field.row,false,{form.edit_prefix..form.edit_original});vim.bo[form.buf].modified=false
  vim.api.nvim_win_set_cursor(form.win,{field.row,#form.edit_prefix+#form.edit_original});mask_form_password(form,field);vim.cmd.startinsert()
end

commit_form_edit = function(form,cancel)
  if S.form~=form or not form.editing then return end
  local field=form.fields[form.index];local line=vim.api.nvim_buf_get_lines(form.buf,field.row-1,field.row,false)[1]or""
  if not cancel and line:sub(1,#form.edit_prefix)==form.edit_prefix then form.values[field.key]=line:sub(#form.edit_prefix+1)else form.values[field.key]=form.edit_original end
  form.editing=false;vim.bo[form.buf].modifiable=false;vim.bo[form.buf].modified=false;render_form(form)
end

local function move_form(form,delta)
  if form.editing then commit_form_edit(form,false)end
  form.index=((form.index-1+delta)%#form.fields)+1;form.status=form.status_kind=="error"and form.status or"Ready";if form.status_kind~="error"then form.status_kind="muted"end;render_form(form)
end

local function cycle_form_value(form,delta)
  local field=form.fields[form.index];if not field then return end
  if field.type=="boolean"then form.values[field.key]=not form.values[field.key];render_form(form);return end
  if field.type~="choice"then return end
  local current=1;for i,value in ipairs(field.options)do if value==form.values[field.key]then current=i end end
  local previous=form.values.driver;form.values[field.key]=field.options[((current-1+delta)%#field.options)+1]
  if field.key=="driver"then if previous=="postgres"and tostring(form.values.port)=="5432"then form.values.port="1433"elseif previous=="mssql"and tostring(form.values.port)=="1433"then form.values.port="5432"end end
  render_form(form)
end

local function activate_form_field(form)
  if form.submitting then return end
  local field=form.fields[form.index];if not field then return end
  if field.type=="text"or field.type=="password"then begin_form_edit(form)elseif field.type=="choice"or field.type=="boolean"then cycle_form_value(form,1)elseif field.key=="test"then test_form(form)elseif field.key=="save"then save_form(form)end
end

close_form = function(form)
  if not form or S.form~=form then return end
  if form.editing then commit_form_edit(form,true)end
  S.form=nil
  if form.resize_autocmd then pcall(vim.api.nvim_del_autocmd,form.resize_autocmd)end
  if form.win and vim.api.nvim_win_is_valid(form.win)then pcall(vim.api.nvim_win_close,form.win,true)end
  if form.buf and vim.api.nvim_buf_is_valid(form.buf)then pcall(vim.api.nvim_buf_delete,form.buf,{force=true})end
  if S.main.win and vim.api.nvim_win_is_valid(S.main.win)then pcall(vim.api.nvim_set_current_win,S.main.win)end
end

test_form = function(form)
  if S.form~=form or form.submitting then return end
  if form.editing then commit_form_edit(form,false)end
  form.submitting=true;set_form_status(form,"Testing connection…","working")
  request("test_profile",form_profile(form),function(result,err)
    if S.form~=form then return end;form.submitting=false
    if err then set_form_status(form,backend_error(err),"error")else set_form_status(form,string.format("Connected successfully · %d ms",result.elapsed_ms or 0),"success")end
  end,true)
end

save_form = function(form)
  if S.form~=form or form.submitting then return end
  if form.editing then commit_form_edit(form,false)end
  form.submitting=true;set_form_status(form,"Saving connection…","working")
  request("save_profile",form_profile(form),function(saved,err)
    if S.form~=form then return end;form.submitting=false
    if err then set_form_status(form,backend_error(err),"error");return end
    close_form(form);M.load_profiles(saved and saved.id)
  end)
end

local function profile_form(existing)
  if S.form then close_form(S.form)end
  existing=vim.deepcopy(existing or{});local driver=existing.driver or"postgres"
  local form={index=1,status="Ready",status_kind="muted",values={id=existing.id,driver=driver,name=existing.name or"",host=existing.host or"localhost",port=tostring(existing.port or(driver=="mssql"and 1433 or 5432)),user=existing.user or"",password=existing.password or"",database=existing.database or"",path=existing.path or"",ssl_mode=existing.ssl_mode or"prefer",encrypt=existing.encrypt==true,trust_server_certificate=existing.trust_server_certificate==true,read_only=existing.read_only==true,timeout_ms=existing.timeout_ms or 30000}}
  form.buf=make_buf("connection-form",false);form.win=vim.api.nvim_open_win(form.buf,true,form_float_config(form,18));S.form=form
  vim.wo[form.win].cursorline=false;vim.wo[form.win].number=false;vim.wo[form.win].relativenumber=false;vim.wo[form.win].signcolumn="no";vim.wo[form.win].wrap=false;vim.wo[form.win].conceallevel=2;vim.wo[form.win].concealcursor="niv"
  local opts={buffer=form.buf,silent=true,nowait=true}
  vim.keymap.set("n","j",function()move_form(form,1)end,opts);vim.keymap.set("n","k",function()move_form(form,-1)end,opts);vim.keymap.set("n","<Tab>",function()move_form(form,1)end,opts);vim.keymap.set("n","<S-Tab>",function()move_form(form,-1)end,opts)
  vim.keymap.set("n","h",function()cycle_form_value(form,-1)end,opts);vim.keymap.set("n","l",function()cycle_form_value(form,1)end,opts);vim.keymap.set("n","<CR>",function()activate_form_field(form)end,opts)
  vim.keymap.set("n","<C-t>",function()test_form(form)end,opts);vim.keymap.set("n","<C-s>",function()save_form(form)end,opts);vim.keymap.set("n","<Esc>",function()close_form(form)end,opts);vim.keymap.set("n","q",function()close_form(form)end,opts)
  vim.keymap.set("i","<CR>",function()vim.cmd.stopinsert();commit_form_edit(form,false)end,opts);vim.keymap.set("i","<Esc>",function()vim.cmd.stopinsert();commit_form_edit(form,true)end,opts)
  vim.keymap.set("i","<Tab>",function()vim.cmd.stopinsert();commit_form_edit(form,false);move_form(form,1)end,opts);vim.keymap.set("i","<S-Tab>",function()vim.cmd.stopinsert();commit_form_edit(form,false);move_form(form,-1)end,opts)
  vim.keymap.set("i","<C-t>",function()vim.cmd.stopinsert();commit_form_edit(form,false);test_form(form)end,opts);vim.keymap.set("i","<C-s>",function()vim.cmd.stopinsert();commit_form_edit(form,false);save_form(form)end,opts)
  vim.keymap.set("i","<Home>",function()vim.api.nvim_win_set_cursor(form.win,{form.fields[form.index].row,#form.edit_prefix})end,opts)
  vim.keymap.set("i","<Left>",function()if vim.api.nvim_win_get_cursor(form.win)[2]>#form.edit_prefix then return"<Left>"end;return""end,vim.tbl_extend("force",opts,{expr=true}))
  vim.keymap.set("i","<BS>",function()if vim.api.nvim_win_get_cursor(form.win)[2]>#form.edit_prefix then return"<BS>"end;return""end,vim.tbl_extend("force",opts,{expr=true}))
  vim.api.nvim_create_autocmd({"TextChangedI","TextChangedP"},{buffer=form.buf,callback=function()if S.form==form and form.editing then local field=form.fields[form.index];local line=vim.api.nvim_buf_get_lines(form.buf,field.row-1,field.row,false)[1]or"";if line:sub(1,#form.edit_prefix)==form.edit_prefix then form.values[field.key]=line:sub(#form.edit_prefix+1);mask_form_password(form,field)end end end})
  form.resize_autocmd=vim.api.nvim_create_autocmd("VimResized",{callback=function()if S.form==form then vim.schedule(function()render_form(form)end)end end})
  render_form(form)
end

function M.load_profiles(select_id)
  request("profiles",{},function(cfg,err)
    if err then notify(backend_error(err),vim.log.levels.ERROR);return end
    S.profiles=cfg.connections or {};S.profile_index=1
    if select_id then for i,p in ipairs(S.profiles)do if p.id==select_id then S.profile_index=i;break end end end
    render_profiles()
  end)
end

local function connect_profile()
  local p=selected_profile();if not p then return end
  request("test",{profile_id=p.id,database=p.database},function(_,err)
    if err then notify(backend_error(err),vim.log.levels.ERROR);return end
    S.profile=p;S.database=p.driver=="sqlite" and vim.fn.fnamemodify(p.path,":t") or p.database;S.screen="workspace";S.active_panel="sidebar";M.apply_layout(true);M.load_tables()
  end,true)
end

function M.load_tables()
  if not S.profile then return end
  request("tables",{profile_id=S.profile.id,database=S.profile.driver=="sqlite" and "" or S.database},function(result,err)
    if err then notify(backend_error(err),vim.log.levels.ERROR);return end
    S.tables=result or {};S.table_index=1;render_tables();render_workspace()
  end,true)
end

local function delete_profile()
  local p=selected_profile();if not p then return end
  if vim.fn.confirm("Delete connection '"..p.name.."'?","&Delete\n&Cancel",2)~=1 then return end
  request("delete_profile",{id=p.id},function(_,err)if err then notify(backend_error(err),vim.log.levels.ERROR);return end;M.load_profiles()end)
end

local function search_focused()
  if S.screen=="profiles" then S.profile_filter=input("Filter connections: ",S.profile_filter);S.profile_index=1;render_profiles();return end
  if S.active_panel=="sidebar" then S.table_filter=input("Filter tables: ",S.table_filter);S.table_index=1;render_tables();return end
  local item=workspace();if not item or item.kind~="table"then return end
  if item.mode=="columns" then item.column_filter=input("Filter columns: ",item.column_filter or "");render_table(item) else item.raw_where=input("WHERE: ",item.raw_where or "");item.page=0;load_rows(item) end
end

local function current_column(item)
  if not item or item.kind~="table"then return nil end
  if item.mode=="columns" then local row=(S.main.win and vim.api.nvim_win_get_cursor(S.main.win)[1] or 3)-2;local needle=(item.column_filter or ""):lower();local visible={};for _,c in ipairs(item.columns or {})do if needle==""or c.name:lower():find(needle,1,true)then visible[#visible+1]=c end end;return visible[row] end
  local col=item.active_col or 1;return item.columns and item.columns[col]
end

local function distinct_values()
  local item=workspace();local column=current_column(item);if not column then notify("Select a column first",vim.log.levels.WARN);return end
  local params=base_params(item);params.raw_where=item.raw_where or "";params.predicates=item.predicates or {};params.column=column.name
  request("distinct",params,function(values,err)
    if err then notify(backend_error(err),vim.log.levels.ERROR);return end
    local choices={};for _,entry in ipairs(values or {})do entry._label=string.format("%s  (%s)",value_text(entry.value),entry.count);choices[#choices+1]=entry end
    open_picker("Filter "..column.name,choices,function(v)return v._label end,function(choice)item.predicates[#item.predicates+1]={column=column.name,value=choice.value,is_null=choice.is_null};item.page=0;load_rows(item)end)
  end,true)
end

local function manage_filters()
  local item=workspace();if not item or item.kind~="table"then return end
  local choices={};if item.raw_where and item.raw_where~=""then choices[#choices+1]={kind="raw",label="WHERE: "..item.raw_where}end;for i,p in ipairs(item.predicates or {})do choices[#choices+1]={kind="predicate",index=i,label=p.column..(p.is_null and " IS NULL"or" = "..value_text(p.value))}end
  if #choices==0 then notify("No active filters");return end
  open_picker("Remove filter",choices,function(v)return v.label end,function(choice)if choice.kind=="raw"then item.raw_where=""else table.remove(item.predicates,choice.index)end;item.page=0;load_rows(item)end)
end

local function clear_filters()local item=workspace();if item and item.kind=="table"then item.raw_where="";item.predicates={};item.page=0;load_rows(item)end end
local function change_page(delta)local item=workspace();if not item or item.kind~="table"or item.mode~="rows"then return end;local page=math.max(0,(item.page or 0)+delta);if delta>0 and item.data and not item.data.has_more then return end;item.page=page;load_rows(item)end

local render_picker, close_picker

local function picker_items(picker)
  local filtered={};local needle=(picker.filter or""):lower()
  for _,item in ipairs(picker.items)do local label=picker.format(item);if needle==""or label:lower():find(needle,1,true)then filtered[#filtered+1]={item=item,label=label}end end
  return filtered
end

local function picker_config(picker,height)
  local width=math.max(24,math.min(64,vim.o.columns-4));height=math.max(5,math.min(height,vim.o.lines-vim.o.cmdheight-4))
  return {relative="editor",style="minimal",border="rounded",title=" "..picker.title.." ",title_pos="center",width=width,height=height,row=math.max(1,math.floor((vim.o.lines-vim.o.cmdheight-height)/2)),col=math.max(1,math.floor((vim.o.columns-width)/2)),zindex=65}
end

render_picker = function(picker)
  if S.picker~=picker or picker.rendering or not vim.api.nvim_buf_is_valid(picker.buf)then return end
  picker.rendering=true;picker.filtered=picker_items(picker);picker.index=math.max(1,math.min(picker.index or 1,math.max(1,#picker.filtered)))
  local max_rows=math.max(3,math.min(14,vim.o.lines-vim.o.cmdheight-9));local first=math.max(1,math.min(picker.first or 1,math.max(1,#picker.filtered-max_rows+1)))
  if picker.index<first then first=picker.index elseif picker.index>=first+max_rows then first=picker.index-max_rows+1 end;picker.first=first
  local lines={"",string.format("  %-12s %s","Filter",picker.filter or""),""};picker.filter_row=2;picker.item_row=4
  if #picker.filtered==0 then lines[#lines+1]="  No matches."else for i=first,math.min(#picker.filtered,first+max_rows-1)do lines[#lines+1]="  "..picker.filtered[i].label end end
  lines[#lines+1]="";lines[#lines+1]=picker.editing and "  type to filter · Ctrl-N/P move · Enter select · Esc cancel"or"  / filter · j/k move · Enter select · Esc cancel"
  if picker.win and vim.api.nvim_win_is_valid(picker.win)then vim.api.nvim_win_set_config(picker.win,picker_config(picker,#lines))end
  vim.bo[picker.buf].modifiable=true;vim.api.nvim_buf_set_lines(picker.buf,0,-1,false,lines);vim.bo[picker.buf].modifiable=picker.editing==true;vim.bo[picker.buf].modified=false
  vim.api.nvim_buf_clear_namespace(picker.buf,picker_ns,0,-1)
  vim.api.nvim_buf_set_extmark(picker.buf,picker_ns,1,2,{end_col=14,hl_group="LazyDataMuted"})
  if #picker.filtered>0 then local selected_row=picker.item_row+(picker.index-first);vim.api.nvim_buf_set_extmark(picker.buf,picker_ns,selected_row-1,0,{line_hl_group="LazyDataSelected"});if not picker.editing and picker.win and vim.api.nvim_win_is_valid(picker.win)then pcall(vim.api.nvim_win_set_cursor,picker.win,{selected_row,2})end end
  vim.api.nvim_buf_set_extmark(picker.buf,picker_ns,#lines-1,2,{end_col=#lines[#lines],hl_group="LazyDataMuted"})
  if picker.editing and picker.win and vim.api.nvim_win_is_valid(picker.win)then pcall(vim.api.nvim_win_set_cursor,picker.win,{picker.filter_row,#picker.filter_prefix+#(picker.filter or"")})end
  picker.rendering=false
end

close_picker = function(picker,choice)
  if not picker or S.picker~=picker then return end
  S.picker=nil
  if picker.key_ns then pcall(vim.on_key,nil,picker.key_ns)end
  if picker.resize_autocmd then pcall(vim.api.nvim_del_autocmd,picker.resize_autocmd)end
  if picker.win and vim.api.nvim_win_is_valid(picker.win)then pcall(vim.api.nvim_win_close,picker.win,true)end
  if picker.buf and vim.api.nvim_buf_is_valid(picker.buf)then pcall(vim.api.nvim_buf_delete,picker.buf,{force=true})end
  if picker.return_win and vim.api.nvim_win_is_valid(picker.return_win)then pcall(vim.api.nvim_set_current_win,picker.return_win)end
  if choice~=nil then picker.choose(choice)end
end

open_picker = function(title,items,format,choose,start_filter)
  if S.picker then close_picker(S.picker)end
  local picker={title=title,items=items or{},format=format or tostring,choose=choose,filter="",index=1,first=1,return_win=vim.api.nvim_get_current_win()};picker.buf=make_buf("picker",false);picker.win=vim.api.nvim_open_win(picker.buf,true,picker_config(picker,10));S.picker=picker
  vim.wo[picker.win].cursorline=false;vim.wo[picker.win].number=false;vim.wo[picker.win].relativenumber=false;vim.wo[picker.win].signcolumn="no";vim.wo[picker.win].wrap=false
  local opts={buffer=picker.buf,silent=true,nowait=true}
  local function move_picker(delta)picker.index=math.max(1,math.min(#picker.filtered,picker.index+delta));render_picker(picker)end
  local function set_filter(filter)if S.picker~=picker then return end;picker.filter=filter or"";picker.index=1;picker.first=1;render_picker(picker)end
  local function delete_filter()local length=vim.fn.strchars(picker.filter or"");if length>0 then set_filter(vim.fn.strcharpart(picker.filter,0,length-1))end end
  local function begin_filter()if picker.editing then return end;picker.editing=true;picker.filter_prefix=string.format("  %-12s ","Filter");render_picker(picker)end
  picker.set_filter=set_filter;picker.delete_filter=delete_filter
  vim.keymap.set("n","j",function()move_picker(1)end,opts);vim.keymap.set("n","k",function()move_picker(-1)end,opts);vim.keymap.set("n","gg",function()picker.index=1;render_picker(picker)end,opts);vim.keymap.set("n","G",function()picker.index=#picker.filtered;render_picker(picker)end,opts)
  vim.keymap.set("n","<C-n>",function()move_picker(1)end,opts);vim.keymap.set("n","<C-p>",function()move_picker(-1)end,opts);vim.keymap.set("n","<Down>",function()move_picker(1)end,opts);vim.keymap.set("n","<Up>",function()move_picker(-1)end,opts)
  vim.keymap.set("n","<Tab>",function()move_picker(1)end,opts);vim.keymap.set("n","<S-Tab>",function()move_picker(-1)end,opts);vim.keymap.set("n","/",begin_filter,opts)
  vim.keymap.set("n","<CR>",function()local selected=picker.filtered[picker.index];if selected then close_picker(picker,selected.item)end end,opts);vim.keymap.set("n","<Esc>",function()close_picker(picker)end,opts);vim.keymap.set("n","q",function()close_picker(picker)end,opts)
  vim.keymap.set("n","<BS>",delete_filter,opts);vim.keymap.set("n","<C-h>",delete_filter,opts);vim.keymap.set("n","<C-u>",function()set_filter("")end,opts)
  picker.key_ns=vim.api.nvim_create_namespace("lazydata_picker_keys")
  vim.on_key(function(key,typed)if S.picker==picker and picker.editing and typed~=""and key==typed and not typed:find("%c")then picker.filter=(picker.filter or"")..typed;picker.index=1;picker.first=1;render_picker(picker);return""end end,picker.key_ns)
  picker.resize_autocmd=vim.api.nvim_create_autocmd("VimResized",{callback=function()if S.picker==picker then vim.schedule(function()render_picker(picker)end)end end});render_picker(picker);if start_filter~=false then begin_filter()end
end

jump_to_column = function()
  local item=workspace();if not item or item.kind~="table"or #(item.columns or{})==0 then return end
  local choices={};for index,column in ipairs(item.columns)do choices[#choices+1]={index=index,column=column}end
  open_picker("Jump to column",choices,function(choice)
    local column=choice.column
    return column.name.."  "..column.type..(column.primary and "  primary"or"")
  end,function(choice)
    item.mode="rows";item.active_col=choice.index;render_table(item)
    vim.schedule(function()if workspace()==item and S.main.win and vim.api.nvim_win_is_valid(S.main.win)and vim.api.nvim_win_get_buf(S.main.win)==item.buf then local row=math.max(3,math.min(vim.api.nvim_win_get_cursor(S.main.win)[1],vim.api.nvim_buf_line_count(item.buf)));pcall(vim.api.nvim_win_set_cursor,S.main.win,{row,cell_byte_col(S.main.win,row,(item.cell_starts or{})[choice.index]or 0)})end end)
  end,true)
end

local function viewer_config(column)
  local width=math.max(1,vim.o.columns-6);local height=math.max(3,vim.o.lines-vim.o.cmdheight-5)
  return {relative="editor",style="minimal",border="rounded",title=" "..column.name.." ",title_pos="center",footer=" q/Esc close · / search · visual select/yank ",footer_pos="center",width=width,height=height,row=1,col=2,zindex=70}
end

open_value_viewer = function()
  local item=workspace();if not item or item.kind~="table"or item.mode~="rows"or not item.data then return end
  local cursor=S.main.win and vim.api.nvim_win_is_valid(S.main.win)and vim.api.nvim_win_get_cursor(S.main.win)or{3,0};local row_index=cursor[1]-2;local column_index=item.active_col or 1;local row=item.data.rows and item.data.rows[row_index];local column=item.columns and item.columns[column_index]
  if not row or not column then notify("Select a data cell first",vim.log.levels.WARN);return end
  local value=row[column_index];local text
  if value==nil or value==vim.NIL then text="NULL"elseif type(value)=="table"then text=vim.json.encode(value)else text=tostring(value)end
  local lines=vim.split(text,"\n",{plain=true});if #lines==0 then lines={""}end
  if S.viewer and S.viewer.win and vim.api.nvim_win_is_valid(S.viewer.win)then pcall(vim.api.nvim_win_close,S.viewer.win,true)end
  local viewer={column=column,return_win=vim.api.nvim_get_current_win()};viewer.buf=make_buf("value/"..column.name,false);vim.bo[viewer.buf].bufhidden="wipe";set_lines(viewer.buf,lines);vim.bo[viewer.buf].readonly=true
  local column_type=(column.type or""):lower();if column_type:find("json",1,true)then vim.bo[viewer.buf].filetype="json"else vim.bo[viewer.buf].filetype="text"end
  viewer.win=vim.api.nvim_open_win(viewer.buf,true,viewer_config(column));S.viewer=viewer
  vim.wo[viewer.win].number=#lines>1;vim.wo[viewer.win].relativenumber=false;vim.wo[viewer.win].signcolumn="no";vim.wo[viewer.win].wrap=true;vim.wo[viewer.win].linebreak=true;vim.wo[viewer.win].breakindent=true;vim.wo[viewer.win].cursorline=false
  local function close_viewer()if S.viewer~=viewer then return end;S.viewer=nil;if viewer.resize_autocmd then pcall(vim.api.nvim_del_autocmd,viewer.resize_autocmd)end;if viewer.win and vim.api.nvim_win_is_valid(viewer.win)then pcall(vim.api.nvim_win_close,viewer.win,true)end;if viewer.return_win and vim.api.nvim_win_is_valid(viewer.return_win)then pcall(vim.api.nvim_set_current_win,viewer.return_win)end end
  local opts={buffer=viewer.buf,silent=true,nowait=true};vim.keymap.set("n","q",close_viewer,opts);vim.keymap.set("n","<Esc>",close_viewer,opts)
  viewer.resize_autocmd=vim.api.nvim_create_autocmd("VimResized",{callback=function()if S.viewer==viewer and viewer.win and vim.api.nvim_win_is_valid(viewer.win)then vim.api.nvim_win_set_config(viewer.win,viewer_config(column))end end})
end

local function choose_database()
  if not S.profile or S.profile.driver=="sqlite"then notify("SQLite profiles contain one database file");return end
  request("databases",{profile_id=S.profile.id,database=S.database},function(values,err)if err then notify(backend_error(err),vim.log.levels.ERROR);return end;open_picker("Switch database",values,function(value)return tostring(value)end,function(choice)S.database=choice;M.load_tables()end)end,true)
end

local function show_profiles()
  S.screen="profiles";S.active_panel="main";M.apply_layout(true);M.load_profiles(S.profile and S.profile.id)
end

local function show_help()
  notify("Tab/S-Tab focus · j/k gg/G move · Enter open · 1 rows · 2 columns · c jump to column · v view full value · / search/WHERE · u unique values · f remove filter · F clear · [p/]p page · [t/]t tabs · [r/]r results · X close · Ctrl-E query · Ctrl-R run · Ctrl-C cancel · b database · Backspace connections · R refresh · q quit")
end

quit = function()
  for _,item in ipairs(S.workspaces)do if item.kind=="query"and vim.api.nvim_buf_is_valid(item.buf)and vim.bo[item.buf].modified then if vim.fn.confirm("Discard modified queries and quit?","&Quit\n&Cancel",2)~=1 then return end;break end end
  if S.busy>0 and vim.fn.confirm("Queries are still running. Cancel and quit?","&Quit\n&Wait",2)~=1 then return end
  vim.cmd("qa!")
end

focus = function(delta)
  if S.screen=="profiles"then return end
  local order={"sidebar","main"};if S.result.win and vim.api.nvim_win_is_valid(S.result.win)then order[#order+1]="result"end;local current=1;for i,v in ipairs(order)do if v==S.active_panel then current=i end end;S.active_panel=order[((current-1+delta)%#order)+1];local item=workspace();if vim.o.columns<80 or(item and item.kind=="table")then M.apply_layout(true);return end;local panel=S[S.active_panel];if panel.win and vim.api.nvim_win_is_valid(panel.win)then vim.api.nvim_set_current_win(panel.win)end;decorate()
end

cancel_request = function()
  if not S.current_request then notify("No running query");return end
  request("cancel",{request_id=S.current_request},function(result)if result and result.cancelled then notify("Query cancelled")end end)
end

configure = function(buf)
  local function map(modes,key,fn)vim.keymap.set(modes,key,fn,{buffer=buf,silent=true,nowait=true})end
  map("n","j",function()move(1)end);map("n","k",function()move(-1)end);map("n","gg",function()jump(false)end);map("n","G",function()jump(true)end)
  map("n","<Tab>",function()focus(1)end);map("n","<S-Tab>",function()focus(-1)end)
  local function move_cell(delta)local w=workspace();if S.active_panel=="main"and w and w.kind=="table"then w.active_col=math.max(1,math.min(#(w.columns or {}),(w.active_col or 1)+delta));if S.main.win and vim.api.nvim_win_is_valid(S.main.win)then local cursor=vim.api.nvim_win_get_cursor(S.main.win);local visual_col=(w.cell_starts or{})[w.active_col]or 0;pcall(vim.api.nvim_win_set_cursor,S.main.win,{cursor[1],cell_byte_col(S.main.win,cursor[1],visual_col)})end;render_table(w)else focus(delta)end end
  map("n","h",function()move_cell(-1)end);map("n","l",function()move_cell(1)end)
  map("n","<CR>",function()if S.screen=="profiles"then connect_profile()elseif S.active_panel=="sidebar"then open_table()end end)
  map("n","/",search_focused);map("n","n",function()if S.screen=="profiles"then profile_form()end end);map("n","e",function()if S.screen=="profiles"then profile_form(selected_profile())end end);map("n","d",function()if S.screen=="profiles"then delete_profile()end end)
  map("n","u",distinct_values);map("n","f",manage_filters);map("n","F",clear_filters);map("n","[p",function()change_page(-1)end);map("n","]p",function()change_page(1)end)
  map("n","[t",function()switch_workspace(-1)end);map("n","]t",function()switch_workspace(1)end);map("n","X",close_workspace)
  map("n","[r",function()switch_result(-1)end);map("n","]r",function()switch_result(1)end)
  map("n","<C-e>",open_query);map("n","<C-c>",cancel_request);map("n","b",choose_database);map("n","<BS>",show_profiles)
  map("n","R",function()local item=workspace();if S.screen=="profiles"then M.load_profiles()elseif S.active_panel=="sidebar"then M.load_tables()elseif item and item.kind=="table"then load_columns(item,function()load_rows(item)end)end end)
  map("n","?",show_help);map("n","q",quit)
end

function M.apply_layout(force)
  if not S.main.buf or not vim.api.nvim_buf_is_valid(S.main.buf)then return end
  vim.cmd("silent! only");S.sidebar.win=nil;S.result.win=nil;S.main.win=vim.api.nvim_get_current_win();configure_window(S.main.win)
  local layout_item=workspace()
  if S.screen=="profiles"then
    vim.api.nvim_win_set_buf(S.main.win,S.main.buf)
  elseif S.screen=="workspace"and vim.o.columns>=80 and(not layout_item or layout_item.kind=="query"or S.active_panel=="sidebar")then
    vim.api.nvim_set_current_win(S.main.win);vim.cmd("leftabove vsplit");S.sidebar.win=vim.api.nvim_get_current_win();configure_window(S.sidebar.win);vim.api.nvim_win_set_width(S.sidebar.win,math.max(24,math.floor(vim.o.columns*0.28)));vim.api.nvim_win_set_buf(S.sidebar.win,S.sidebar.buf);vim.api.nvim_set_current_win(S.main.win)
  elseif S.screen=="workspace"and S.active_panel=="sidebar" then vim.api.nvim_win_set_buf(S.main.win,S.sidebar.buf);S.sidebar.win=S.main.win else vim.api.nvim_win_set_buf(S.main.win,workspace()and workspace().buf or S.main.buf)end
  local item=workspace();if S.screen=="workspace"and item and item.kind=="query"and vim.o.lines>=20 and (vim.o.columns>=80 or S.active_panel~="sidebar") then vim.api.nvim_set_current_win(S.main.win);vim.cmd("rightbelow split");S.result.win=vim.api.nvim_get_current_win();configure_window(S.result.win);vim.api.nvim_win_set_height(S.result.win,math.max(6,math.floor(vim.o.lines*0.35)));vim.api.nvim_win_set_buf(S.result.win,item.result_buf);vim.api.nvim_set_current_win(S.main.win)end
  if S.screen=="profiles"then render_profiles()else render_tables();render_workspace()end;decorate()
  local active=S[S.active_panel];if active and active.win and vim.api.nvim_win_is_valid(active.win)then pcall(vim.api.nvim_set_current_win,active.win)end
end

function M.launch()
  pcall(function() require("views.lazydiff").setup_standalone_ui() end)
  setup_highlights();vim.api.nvim_create_autocmd("ColorScheme",{callback=setup_highlights})
  vim.o.termguicolors=true;vim.o.laststatus=2;vim.o.showtabline=0
  S.group=vim.api.nvim_create_augroup("LazyData",{clear=true})
  S.main.buf=make_buf("connections",false);S.sidebar.buf=make_buf("tables",false);S.result.buf=make_buf("results",false)
  configure(S.main.buf);configure(S.sidebar.buf);configure(S.result.buf)
  vim.api.nvim_create_autocmd("VimResized",{group=S.group,callback=function()vim.schedule(function()M.apply_layout(true)end)end})
  vim.api.nvim_create_autocmd("VimLeavePre",{group=S.group,once=true,callback=function()if S.job and S.job>0 then vim.fn.jobstop(S.job)end end})
  S.screen="profiles";S.active_panel="main";M.apply_layout(true);M.load_profiles()
end

M._state=S
M._read_looking=read_looking
M._value_text=value_text
M._open_picker=open_picker
return M
