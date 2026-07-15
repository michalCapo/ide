local M = {}

local namespace = vim.api.nvim_create_namespace("references_view")
local ERROR_CONTEXT_LINES = 8

local state = {
  buf = nil,
  origin_buf = nil,
  origin_win = nil,
  origin_cursor = nil,
  root = nil,
  view_win = nil,
  previous_window_options = nil,
  previous_showtabline = nil,
  label = "References",
  context_lines = 2,
  source_lines = {},
  row_sources = {},
  row_targets = {},
  file_rows = {},
  targets = {},
  project_check_run_id = 0,
}

local function apply_highlights()
  vim.api.nvim_set_hl(0, "ReferenceViewHeader", { link = "Folded" })
  vim.api.nvim_set_hl(0, "ReferenceViewHeaderMarker", { link = "Folded" })
  vim.api.nvim_set_hl(0, "ReferenceViewHeaderFile", { link = "Title", bold = true })
  vim.api.nvim_set_hl(0, "ReferenceViewHeaderPath", { link = "Comment" })
  vim.api.nvim_set_hl(0, "ReferenceViewHeaderAction", { link = "Folded" })
  vim.api.nvim_set_hl(0, "ReferenceViewHeaderKey", { link = "Identifier" })
  vim.api.nvim_set_hl(0, "ReferenceViewGap", { link = "Normal" })
  vim.api.nvim_set_hl(0, "ReferenceViewHit", {
    bg = vim.o.background == "light" and "#c7dfef" or "#385f78",
  })
  vim.api.nvim_set_hl(0, "ReferenceViewErrorHit", { link = "DiagnosticUnderlineError" })
  vim.api.nvim_set_hl(0, "ReferenceViewLine", { link = "Normal" })
  -- Preserve source syntax while giving error rows the same subtle background
  -- as the active line in a regular editing buffer.
  vim.api.nvim_set_hl(0, "ReferenceViewErrorLine", { link = "CursorLine" })
  vim.api.nvim_set_hl(0, "ReferenceViewErrorMessage", { link = "DiagnosticVirtualTextError" })
  vim.api.nvim_set_hl(0, "ReferenceViewSeparator", { link = "NonText" })
end

local function clear_state()
  state.buf = nil
  state.origin_buf = nil
  state.origin_win = nil
  state.origin_cursor = nil
  state.root = nil
  state.view_win = nil
  state.previous_window_options = nil
  state.previous_showtabline = nil
  state.label = "References"
  state.context_lines = 2
  state.source_lines = {}
  state.row_sources = {}
  state.row_targets = {}
  state.file_rows = {}
  state.targets = {}
end

function _G.nvim_reference_view_statuscolumn()
  local win = tonumber(vim.g.statusline_winid) or 0
  local ok, buf = pcall(vim.api.nvim_win_get_buf, win)
  if not ok then
    buf = vim.api.nvim_get_current_buf()
  end
  local line = state.buf == buf and state.source_lines[vim.v.lnum] or nil
  if line then
    return string.format("%4d ", line)
  end
  return "     "
end

local function remember_window_options(win)
  state.view_win = win
  state.previous_window_options = {
    statuscolumn = vim.wo[win].statuscolumn,
    number = vim.wo[win].number,
    relativenumber = vim.wo[win].relativenumber,
    wrap = vim.wo[win].wrap,
    linebreak = vim.wo[win].linebreak,
    breakindent = vim.wo[win].breakindent,
    cursorline = vim.wo[win].cursorline,
    signcolumn = vim.wo[win].signcolumn,
    foldcolumn = vim.wo[win].foldcolumn,
    foldenable = vim.wo[win].foldenable,
  }
end

local function restore_window_options()
  local win = state.view_win
  local options = state.previous_window_options
  if not win or not options or not vim.api.nvim_win_is_valid(win) then
    return
  end
  for name, value in pairs(options) do
    pcall(function()
      vim.wo[win][name] = value
    end)
  end
end

local function hide_buffer_tabs()
  if state.previous_showtabline == nil then
    state.previous_showtabline = vim.o.showtabline
  end
  vim.o.showtabline = 0
end

local function restore_buffer_tabs()
  if state.previous_showtabline ~= nil then
    vim.o.showtabline = state.previous_showtabline
    state.previous_showtabline = nil
    pcall(vim.cmd.redrawtabline)
  end
end

local function buffer_safe_lines(lines)
  local safe = {}
  for index, line in ipairs(lines or {}) do
    safe[index] = tostring(line or ""):gsub("%z", " "):gsub("\r", " "):gsub("\n", " ")
  end
  return safe
end

local function loaded_buffer_for_file(filename)
  local normalized = vim.fs.normalize(filename)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.fs.normalize(vim.api.nvim_buf_get_name(buf)) == normalized then
      return buf
    end
  end
end

local function loaded_file_lines(filename)
  local buf = loaded_buffer_for_file(filename)
  if buf then
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end
end

local function read_file_lines(filename)
  local lines = loaded_file_lines(filename)
  if not lines and vim.fn.filereadable(filename) == 1 then
    lines = vim.fn.readfile(filename)
  end
  lines = buffer_safe_lines(lines or {})
  if #lines == 0 then
    lines = { "" }
  end
  return lines
end

local function relpath(filename)
  local path = vim.fs.normalize(filename)
  if state.root then
    local ok, relative = pcall(vim.fs.relpath, state.root, path)
    if ok and relative and relative ~= "" then
      return relative
    end
  end
  return vim.fn.fnamemodify(path, ":~:.")
end

local function filetype_for_path(path)
  local ok, ft = pcall(vim.filetype.match, { filename = path })
  return ok and ft or nil
end

local function path_parts(path)
  local parts = {}
  for part in path:gmatch("[^/]+") do
    table.insert(parts, part)
  end
  return parts
end

local function context_for_line(lines, line)
  for row = math.min(line, #lines), 1, -1 do
    local text = lines[row] or ""
    if text:match("^%s*func%s+") or text:match("^%s*function%s+")
        or text:match("^%s*class%s+") or text:match("^%s*interface%s+")
        or text:match("^%s*type%s+[%w_]+%s+") then
      return vim.trim(text)
    end
    local method = text:match("^%s*[%w_]+%s*[:=]%s*function%s*%(")
    if method then
      return vim.trim(text)
    end
  end
  return ""
end

local function byte_col(line, character, encoding)
  character = math.max(0, tonumber(character) or 0)
  local ok, col = pcall(vim.str_byteindex, line or "", encoding or "utf-16", character, false)
  if ok and col then
    return math.min(math.max(col, 0), #(line or ""))
  end
  ok, col = pcall(vim.str_byteindex, line or "", character, false)
  if ok and col then
    return math.min(math.max(col, 0), #(line or ""))
  end
  return math.min(character, #(line or ""))
end

local function target_key(target)
  return table.concat({
    target.filename,
    tostring(target.line),
    tostring(target.character),
    tostring(target.end_line),
    tostring(target.end_character),
  }, "\0")
end

local function location_target(location, encoding)
  local uri = location.uri or location.targetUri
  local range = location.range or location.targetSelectionRange or location.targetRange
  if not uri or not range or not range.start then
    return nil
  end
  local filename = vim.uri_to_fname(uri)
  local start_line = (range.start.line or 0) + 1
  local end_line = ((range["end"] and range["end"].line) or range.start.line or 0) + 1
  return {
    filename = vim.fs.normalize(filename),
    line = start_line,
    character = range.start.character or 0,
    end_line = end_line,
    end_character = (range["end"] and range["end"].character) or (range.start.character or 0) + 1,
    encoding = encoding or "utf-16",
  }
end

local function result_locations(result)
  if type(result) ~= "table" then
    return {}
  end
  if result.uri or result.targetUri then
    return { result }
  end
  return result
end

local function collect_targets(responses)
  local targets = {}
  local seen = {}
  for client_id, response in pairs(responses or {}) do
    local client = tonumber(client_id) and vim.lsp.get_client_by_id(tonumber(client_id)) or nil
    local encoding = client and client.offset_encoding or "utf-16"
    if type(response) == "table" and type(response.result) == "table" then
      for _, location in ipairs(result_locations(response.result)) do
        local target = location_target(location, encoding)
        if target then
          local key = target_key(target)
          if not seen[key] then
            seen[key] = true
            table.insert(targets, target)
          end
        end
      end
    end
  end

  table.sort(targets, function(a, b)
    if a.filename ~= b.filename then
      return a.filename < b.filename
    end
    if a.line ~= b.line then
      return a.line < b.line
    end
    return a.character < b.character
  end)
  return targets
end

local function group_targets(targets)
  local by_file = {}
  for _, target in ipairs(targets) do
    local file = by_file[target.filename]
    if not file then
      file = {
        filename = target.filename,
        path = relpath(target.filename),
        lines = read_file_lines(target.filename),
        targets = {},
      }
      by_file[target.filename] = file
    end
    table.insert(file.targets, target)
  end

  local files = vim.tbl_values(by_file)
  table.sort(files, function(a, b) return a.path < b.path end)
  for _, file in ipairs(files) do
    table.sort(file.targets, function(a, b)
      return a.line == b.line and a.character < b.character or a.line < b.line
    end)
  end
  return files
end

local function build_intervals(file)
  local intervals = {}
  local context_lines = state.context_lines or 2
  for _, target in ipairs(file.targets) do
    local start_line = math.max(1, target.line - context_lines)
    local end_line = math.min(#file.lines, target.line + context_lines)
    local last = intervals[#intervals]
    if last and start_line <= last.end_line + 1 then
      last.end_line = math.max(last.end_line, end_line)
    else
      table.insert(intervals, { start_line = start_line, end_line = end_line })
    end
  end
  return intervals
end

local function add_header(lines, file, file_index)
  local parts = path_parts(file.path)
  local name = parts[#parts] or file.path
  local parent = #parts > 1 and table.concat(parts, "/", 1, #parts - 1) .. "/" or "./"
  local context = context_for_line(file.lines, file.targets[1] and file.targets[1].line or 1)
  local header = "  v  " .. name .. "  " .. parent
  if context ~= "" then
    header = header .. "  " .. context
  end

  table.insert(lines, header)
  local row = #lines
  state.file_rows[row] = {
    filename = file.filename,
    line = file.targets[1] and file.targets[1].line or 1,
    col = file.targets[1] and file.targets[1].byte_col or 0,
    file_index = file_index,
  }
  return row, #("  v  "), #name, #parent
end

local function prepare_target_columns(file)
  for _, target in ipairs(file.targets) do
    local line = file.lines[target.line] or ""
    if target.byte_col == nil then
      target.byte_col = byte_col(line, target.character, target.encoding)
    else
      target.byte_col = math.min(math.max(tonumber(target.byte_col) or 0, 0), #line)
    end
    if target.end_line == target.line then
      if target.end_byte_col == nil then
        target.end_byte_col = byte_col(line, target.end_character, target.encoding)
      else
        target.end_byte_col = math.min(math.max(tonumber(target.end_byte_col) or 0, 0), #line)
      end
    else
      target.end_byte_col = target.byte_col + 1
    end
    if target.end_byte_col <= target.byte_col then
      target.end_byte_col = math.min(#line, target.byte_col + 1)
    end

    -- Some servers return point-like or single-character locations. Expand
    -- those to the complete identifier so the reference highlight remains
    -- visible even when the cursor is sitting on its first character.
    if target.end_line == target.line and target.end_byte_col <= target.byte_col + 1 then
      local start_col = target.byte_col
      local end_col = target.end_byte_col
      while start_col > 0 and line:sub(start_col, start_col):match("[%w_]") do
        start_col = start_col - 1
      end
      while end_col < #line and line:sub(end_col + 1, end_col + 1):match("[%w_]") do
        end_col = end_col + 1
      end
      target.byte_col = start_col
      target.end_byte_col = end_col
    end
  end
end

local function origin_target()
  if not state.origin_cursor or not state.origin_buf or not vim.api.nvim_buf_is_valid(state.origin_buf) then
    return nil
  end

  local origin_filename = vim.api.nvim_buf_get_name(state.origin_buf)
  if origin_filename == "" then
    return nil
  end

  origin_filename = vim.fs.normalize(origin_filename)
  local origin_line, origin_col = state.origin_cursor[1], state.origin_cursor[2]
  local closest
  local closest_distance = math.huge

  for _, target in ipairs(state.targets) do
    if vim.fs.normalize(target.filename) == origin_filename and target.line == origin_line then
      local start_col = math.max(target.byte_col or 0, 0)
      local end_col = math.max(target.end_byte_col or start_col + 1, start_col + 1)
      if origin_col >= start_col and origin_col <= end_col then
        return target
      end

      local distance = math.min(math.abs(origin_col - start_col), math.abs(origin_col - end_col))
      if distance < closest_distance then
        closest = target
        closest_distance = distance
      end
    end
  end

  return closest
end

local function syntax_file_for_filetype(filetype)
  if type(filetype) ~= "string" or filetype == "" then
    return nil
  end
  if not filetype:match("^[%w_+-]+$") then
    return nil
  end
  return "syntax/" .. filetype .. ".vim"
end

local function apply_source_syntax(buf, source_filetype, code_spans)
  local syntax_file = syntax_file_for_filetype(source_filetype)
  if not syntax_file or #code_spans == 0 then
    return
  end

  if vim.treesitter and vim.treesitter.stop then
    pcall(vim.treesitter.stop, buf)
  end
  vim.api.nvim_buf_call(buf, function()
    vim.cmd("syntax clear")
    vim.bo.syntax = "referenceview"
    local ok = pcall(vim.cmd, "syntax include @ReferenceViewSource " .. syntax_file)
    if not ok then
      return
    end
    for index, span in ipairs(code_spans) do
      vim.cmd(string.format(
        "syntax region ReferenceViewCode%d start=/\\%%%dl/ end=/\\%%%dl/ contains=@ReferenceViewSource keepend",
        index,
        span.start,
        span.finish + 1
      ))
    end
  end)
end

local function render(files, title, scheme)
  apply_highlights()
  state.row_sources = {}
  state.row_targets = {}
  state.file_rows = {}
  state.targets = {}
  state.source_lines = {}

  local lines = {}
  local headers = {}
  local gaps = {}
  local separators = {}
  local hit_marks = {}
  local error_messages = {}
  local code_spans = {}

  local function add_error_message(row, message)
    local messages = error_messages[row] or {}
    error_messages[row] = messages
    local normalized = vim.trim(message):lower()
      :gsub("^[%w_.-]+%b[]:%s*", "")
      :gsub("%s+", " ")
    for index, existing in ipairs(messages) do
      local existing_normalized = vim.trim(existing):lower()
        :gsub("^[%w_.-]+%b[]:%s*", "")
        :gsub("%s+", " ")
      if normalized == existing_normalized then
        -- Prefer the concise form (for example, omit the redundant
        -- "compiler[UndeclaredName]:" prefix from gopls).
        if #message < #existing then
          messages[index] = message
        end
        return
      end
    end
    table.insert(messages, message)
  end

  for file_index, file in ipairs(files) do
    prepare_target_columns(file)
    table.insert(lines, "")
    gaps[#lines] = true

    local header_row, name_start, name_len, parent_len = add_header(lines, file, file_index)
    table.insert(lines, "")
    gaps[#lines] = true
    table.insert(headers, {
      row = header_row,
      top_row = header_row - 1,
      bottom_row = header_row + 1,
      name_start = name_start,
      name_end = name_start + name_len,
      parent_start = name_start + name_len + 2,
      parent_end = name_start + name_len + 2 + parent_len,
    })

    local target_by_line = {}
    for _, target in ipairs(file.targets) do
      target_by_line[target.line] = target_by_line[target.line] or {}
      table.insert(target_by_line[target.line], target)
    end

    for interval_index, interval in ipairs(build_intervals(file)) do
      if interval_index > 1 then
        table.insert(lines, "  " .. string.rep("-", 96))
        separators[#lines] = true
      end
      local code_span
      for source_line = interval.start_line, interval.end_line do
        if not code_span then
          code_span = { start = #lines + 1, finish = #lines + 1 }
          table.insert(code_spans, code_span)
        end
        table.insert(lines, file.lines[source_line] or "")
        local row = #lines
        code_span.finish = row
        state.source_lines[row] = source_line
        state.row_sources[row] = { filename = file.filename, line = source_line, col = 0, file_index = file_index }
        local line_targets = target_by_line[source_line] or {}
        for _, target in ipairs(line_targets) do
          target.row = row
          table.insert(state.targets, target)
          state.row_targets[row] = state.row_targets[row] or {}
          table.insert(state.row_targets[row], target)
          table.insert(hit_marks, target)
        end

        for _, target in ipairs(line_targets) do
          if target.message and target.message ~= "" then
            local detail_lines = { target.message }
            vim.list_extend(detail_lines, target.related_messages or {})
            for _, detail in ipairs(detail_lines) do
              add_error_message(row, detail)
            end
          end
        end
      end
    end
  end

  local buf = vim.api.nvim_create_buf(false, true)
  state.buf = buf
  -- A previous location view can still be visible while a new search is
  -- rendered. Include the buffer id so repeated searches never hit E95.
  vim.api.nvim_buf_set_name(buf, string.format(
    "%s://%s/%d",
    scheme or "locations",
    title or "symbol",
    buf
  ))
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_set_option_value("buflisted", false, { buf = buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
  local source_filetype = filetype_for_path(files[1].filename) or vim.bo[state.origin_buf].filetype
  vim.api.nvim_set_option_value("filetype", source_filetype, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  vim.api.nvim_set_option_value("readonly", true, { buf = buf })
  apply_source_syntax(buf, source_filetype, code_spans)
  hide_buffer_tabs()
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      if state.buf == buf then
        restore_buffer_tabs()
      end
    end,
  })

  for _, header in ipairs(headers) do
    local row = header.row - 1
    for _, padded_row in ipairs({ header.top_row, header.bottom_row }) do
      vim.api.nvim_buf_set_extmark(buf, namespace, padded_row - 1, 0, {
        line_hl_group = "ReferenceViewHeader",
        priority = 120,
      })
    end
    vim.api.nvim_buf_set_extmark(buf, namespace, row, 0, {
      line_hl_group = "ReferenceViewHeader",
      virt_text = { { " Open File ", "ReferenceViewHeaderAction" }, { "e", "ReferenceViewHeaderKey" } },
      virt_text_pos = "right_align",
      priority = 120,
    })
    vim.api.nvim_buf_add_highlight(buf, namespace, "ReferenceViewHeaderMarker", row, 0, header.name_start)
    vim.api.nvim_buf_add_highlight(buf, namespace, "ReferenceViewHeaderFile", row, header.name_start, header.name_end)
    vim.api.nvim_buf_add_highlight(buf, namespace, "ReferenceViewHeaderPath", row, header.parent_start, header.parent_end)
  end

  for row in pairs(gaps) do
    vim.api.nvim_buf_set_extmark(buf, namespace, row - 1, 0, {
      line_hl_group = "ReferenceViewGap",
      priority = 30,
    })
  end

  for row in pairs(separators) do
    vim.api.nvim_buf_add_highlight(buf, namespace, "ReferenceViewSeparator", row - 1, 0, -1)
  end

  for _, target in ipairs(hit_marks) do
    vim.api.nvim_buf_set_extmark(buf, namespace, target.row - 1, math.max(target.byte_col, 0), {
      end_col = math.max(target.end_byte_col, target.byte_col + 1),
      hl_group = target.hl_group or "ReferenceViewHit",
      hl_mode = "combine",
      priority = 160,
    })
    vim.api.nvim_buf_set_extmark(buf, namespace, target.row - 1, 0, {
      line_hl_group = target.line_hl_group or "ReferenceViewLine",
      priority = 40,
    })
  end

  for row, messages in pairs(error_messages) do
    local virtual_lines = {}
    for index = 2, #messages do
      table.insert(virtual_lines, { { "    " .. messages[index], "ReferenceViewErrorMessage" } })
    end
    local mark = {
      virt_text = { { "  ■ " .. messages[1], "ReferenceViewErrorMessage" } },
      virt_text_pos = "eol",
      priority = 180,
    }
    if #virtual_lines > 0 then
      mark.virt_lines = virtual_lines
      mark.virt_lines_above = false
    end
    vim.api.nvim_buf_set_extmark(buf, namespace, row - 1, -1, mark)
  end

  vim.api.nvim_set_current_buf(buf)
  -- Search highlighting can otherwise paint the same identifiers orange and
  -- obscure the viewer's own reference background.
  vim.cmd.nohlsearch()
  local win = vim.api.nvim_get_current_win()
  remember_window_options(win)
  vim.wo[win].number = true
  vim.wo[win].relativenumber = false
  vim.wo[win].statuscolumn = "%!v:lua.nvim_reference_view_statuscolumn()"
  local is_error_view = scheme == "errors"
  vim.wo[win].wrap = is_error_view
  vim.wo[win].linebreak = is_error_view
  vim.wo[win].breakindent = is_error_view
  vim.wo[win].cursorline = true
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].foldenable = false

  M.configure_keymaps(buf)

  local first = origin_target() or state.targets[1]
  if first then
    vim.api.nvim_win_set_cursor(win, { first.row, first.byte_col })
    vim.cmd("normal! zz")
  end
end

local function ordered_target_index(backward)
  if #state.targets == 0 then
    return nil
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row, col = cursor[1], cursor[2]
  if backward then
    for index = #state.targets, 1, -1 do
      local target = state.targets[index]
      if target.row < row or (target.row == row and target.byte_col < col) then
        return index
      end
    end
    return #state.targets
  end
  for index, target in ipairs(state.targets) do
    if target.row > row or (target.row == row and target.byte_col > col) then
      return index
    end
  end
  return 1
end

local function jump_target(backward)
  local index = ordered_target_index(backward)
  local target = index and state.targets[index] or nil
  if target then
    vim.api.nvim_win_set_cursor(0, { target.row, target.byte_col })
    vim.cmd("normal! zz")
  end
end

local function target_for_cursor()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row, col = cursor[1], cursor[2]
  local targets = state.row_targets[row]
  if targets and #targets > 0 then
    local best = targets[1]
    local best_distance = math.abs(col - best.byte_col)
    for _, target in ipairs(targets) do
      local distance = math.abs(col - target.byte_col)
      if distance < best_distance then
        best = target
        best_distance = distance
      end
    end
    return { filename = best.filename, line = best.line, col = best.byte_col }
  end
  local source = state.row_sources[row] or state.file_rows[row]
  if source then
    return { filename = source.filename, line = source.line, col = col }
  end
end

local function close()
  local view_buf = state.buf
  local origin_buf = state.origin_buf
  local origin_cursor = state.origin_cursor
  restore_window_options()
  restore_buffer_tabs()
  if origin_buf and vim.api.nvim_buf_is_valid(origin_buf) then
    vim.api.nvim_set_current_buf(origin_buf)
    if origin_cursor then
      pcall(vim.api.nvim_win_set_cursor, 0, origin_cursor)
    end
  end
  if view_buf and vim.api.nvim_buf_is_valid(view_buf) then
    pcall(vim.api.nvim_buf_delete, view_buf, { force = true })
  end
  clear_state()
end

local function target_byte_col(target)
  if target.col ~= nil then
    return math.max(tonumber(target.col) or 0, 0)
  end
  if target.byte_col ~= nil then
    return math.max(tonumber(target.byte_col) or 0, 0)
  end

  local lines = read_file_lines(target.filename)
  return byte_col(lines[target.line] or "", target.character, target.encoding)
end

local function open_location_target(target, view_buf, jump_origin)
  -- Match Neovim's built-in LSP location behavior: record the source in the
  -- jumplist before replacing its buffer, so <C-o> returns to the exact spot.
  if jump_origin and jump_origin.win and vim.api.nvim_win_is_valid(jump_origin.win) then
    vim.api.nvim_set_current_win(jump_origin.win)
    if jump_origin.buf and vim.api.nvim_buf_is_valid(jump_origin.buf) then
      vim.api.nvim_win_set_buf(jump_origin.win, jump_origin.buf)
    end
    if jump_origin.cursor then
      pcall(vim.api.nvim_win_set_cursor, jump_origin.win, jump_origin.cursor)
    end
    vim.cmd("normal! m'")
  end
  local loaded_buf = loaded_buffer_for_file(target.filename)
  if loaded_buf then
    vim.api.nvim_set_current_buf(loaded_buf)
  else
    vim.cmd("edit " .. vim.fn.fnameescape(target.filename))
  end
  restore_window_options()
  restore_buffer_tabs()
  pcall(vim.api.nvim_win_set_cursor, 0, { target.line, target_byte_col(target) })
  vim.cmd("normal! zz")
  if view_buf and vim.api.nvim_buf_is_valid(view_buf) then
    pcall(vim.api.nvim_buf_delete, view_buf, { force = true })
  end
  clear_state()
end

local function open_target()
  local target = target_for_cursor()
  if not target then
    vim.notify(state.label .. ": move onto a location or file section", vim.log.levels.WARN)
    return
  end

  open_location_target(target, state.buf, {
    win = state.origin_win,
    buf = state.origin_buf,
    cursor = state.origin_cursor,
  })
end

local function open_all_target_files()
  local opened = 0
  local seen = {}
  for _, target in ipairs(state.targets) do
    local filename = target.filename and vim.fs.normalize(target.filename) or nil
    if filename and not seen[filename] and vim.fn.filereadable(filename) == 1 then
      seen[filename] = true
      local buf = vim.fn.bufadd(filename)
      if buf and buf > 0 then
        vim.fn.bufload(buf)
        vim.api.nvim_set_option_value("buflisted", true, { buf = buf })
        opened = opened + 1
      end
    end
  end

  if opened == 0 then
    vim.notify(state.label .. ": no files to open", vim.log.levels.WARN)
    return
  end
  pcall(vim.cmd.redrawtabline)
  vim.notify(string.format("%s: opened %d file%s as buffer%s", state.label, opened, opened == 1 and "" or "s", opened == 1 and "" or "s"), vim.log.levels.INFO)
  close()
end

function M.configure_keymaps(buf)
  local opts = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set("n", "q", close, vim.tbl_extend("force", opts, { desc = "Close location view" }))
  vim.keymap.set("n", "<esc>", close, vim.tbl_extend("force", opts, { desc = "Close location view" }))
  vim.keymap.set("n", "]e", function() jump_target(false) end, vim.tbl_extend("force", opts, { desc = "Next error" }))
  vim.keymap.set("n", "[e", function() jump_target(true) end, vim.tbl_extend("force", opts, { desc = "Previous error" }))
  vim.keymap.set("n", "<C-e>", function() jump_target(false) end, vim.tbl_extend("force", opts, { desc = "Next error" }))
  vim.keymap.set("n", "<C-n>", function() jump_target(false) end, vim.tbl_extend("force", opts, { desc = "Next location" }))
  vim.keymap.set("n", "<C-p>", function() jump_target(true) end, vim.tbl_extend("force", opts, { desc = "Previous location" }))
  vim.keymap.set("n", "*", function() jump_target(false) end, vim.tbl_extend("force", opts, { desc = "Next location" }))
  vim.keymap.set("n", "#", function() jump_target(true) end, vim.tbl_extend("force", opts, { desc = "Previous location" }))
  vim.keymap.set("n", "e", open_target, vim.tbl_extend("force", opts, { desc = "Open location file" }))
  vim.keymap.set("n", "<cr>", open_target, vim.tbl_extend("force", opts, { desc = "Open location file" }))
  vim.keymap.set("n", "o", open_all_target_files, vim.tbl_extend("force", opts, { desc = "Open all location files as buffers" }))
end

local function current_word_title()
  local word = vim.fn.expand("<cword>")
  return word ~= "" and word or "symbol"
end

local function path_in_root(filename, root)
  if not root or root == "" then
    return true
  end
  local normalized_file = vim.fs.normalize(filename)
  local normalized_root = vim.fs.normalize(root)
  if normalized_root == "/" then
    return true
  end
  return normalized_file == normalized_root or normalized_file:sub(1, #normalized_root + 1) == normalized_root .. "/"
end

local function diagnostic_message(diagnostic)
  local message = vim.trim(tostring(diagnostic.message or ""))
  message = message:gsub("%s*\r%s*", " "):gsub("%s*\n%s*", " ")
  local source = vim.trim(tostring(diagnostic.source or ""))
  local code = diagnostic.code and tostring(diagnostic.code) or ""
  if source ~= "" and code ~= "" then
    return string.format("%s[%s]: %s", source, code, message)
  end
  if source ~= "" then
    return source .. ": " .. message
  end
  if code ~= "" then
    return code .. ": " .. message
  end
  return message
end

local function diagnostic_related_messages(diagnostic)
  local lsp_diagnostic = diagnostic.user_data and diagnostic.user_data.lsp or {}
  local related = diagnostic.relatedInformation or lsp_diagnostic.relatedInformation
  local messages = {}

  if type(related) ~= "table" then
    return messages
  end

  for _, item in ipairs(related) do
    local message = vim.trim(tostring(item.message or ""))
    message = message:gsub("%s*\r%s*", " "):gsub("%s*\n%s*", " ")
    if message ~= "" then
      local suffix = ""
      local location = item.location or {}
      local uri = location.uri or location.targetUri
      local range = location.range or location.targetSelectionRange or location.targetRange
      if uri then
        local filename = vim.uri_to_fname(uri)
        suffix = relpath(filename)
        if range and range.start and range.start.line then
          suffix = suffix .. ":" .. tostring((range.start.line or 0) + 1)
        end
      end
      if suffix ~= "" then
        message = message .. " (" .. suffix .. ")"
      end
      table.insert(messages, message)
    end
  end

  return messages
end

local function collect_error_targets(root, opts)
  opts = opts or {}
  local targets = {}
  local seen = {}
  local diagnostics = vim.diagnostic.get(opts.bufnr, { severity = vim.diagnostic.severity.ERROR })

  for _, diagnostic in ipairs(diagnostics) do
    local bufnr = diagnostic.bufnr or opts.bufnr
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      local filename = vim.api.nvim_buf_get_name(bufnr)
      if filename ~= "" then
        filename = vim.fs.normalize(vim.fn.fnamemodify(filename, ":p"))
        if path_in_root(filename, root) then
          local line = (diagnostic.lnum or 0) + 1
          local end_line = (diagnostic.end_lnum or diagnostic.lnum or 0) + 1
          local byte_col = math.max(0, diagnostic.col or 0)
          local end_byte_col = diagnostic.end_col or byte_col + 1
          if end_line ~= line then
            end_byte_col = byte_col + 1
          end
          local message = diagnostic_message(diagnostic)
          local key = table.concat({
            filename,
            tostring(line),
            tostring(byte_col),
            tostring(end_line),
            tostring(end_byte_col),
            message,
          }, "\0")
          if not seen[key] then
            seen[key] = true
            table.insert(targets, {
              filename = filename,
              line = line,
              character = byte_col,
              end_line = end_line,
              end_character = end_byte_col,
              byte_col = byte_col,
              end_byte_col = end_byte_col,
              message = message,
              related_messages = diagnostic_related_messages(diagnostic),
              hl_group = "ReferenceViewErrorHit",
              line_hl_group = "ReferenceViewErrorLine",
            })
          end
        end
      end
    end
  end

  table.sort(targets, function(a, b)
    if a.filename ~= b.filename then
      return a.filename < b.filename
    end
    if a.line ~= b.line then
      return a.line < b.line
    end
    return a.byte_col < b.byte_col
  end)
  return targets
end

local function find_upward(names, start)
  local path = start
  if not path or path == "" then
    path = vim.api.nvim_buf_get_name(0)
  end
  local dir = vim.fs.dirname(vim.fs.normalize(path)) or vim.uv.cwd()
  local found = vim.fs.find(names, { upward = true, path = dir, type = "file" })
  return found[1]
end

local function project_root_from_marker(marker)
  if marker then
    return vim.fs.dirname(marker)
  end
  local git = vim.fs.find(".git", { upward = true, path = vim.uv.cwd(), type = "directory" })[1]
  return git and vim.fs.dirname(git) or vim.uv.cwd()
end

local function detect_project_check()
  local ts_marker = find_upward({ "tsconfig.json", "package.json" })
  local go_marker = find_upward({ "go.mod" })
  if ts_marker and (not go_marker or #ts_marker >= #go_marker) then
    local root = project_root_from_marker(ts_marker)
    local package_json = root .. "/package.json"
    local package = vim.fn.filereadable(package_json) == 1 and table.concat(vim.fn.readfile(package_json), "\n") or ""
    local runner = "npm"
    if vim.fn.filereadable(root .. "/pnpm-lock.yaml") == 1 then
      runner = "pnpm"
    elseif vim.fn.filereadable(root .. "/yarn.lock") == 1 then
      runner = "yarn"
    elseif vim.fn.filereadable(root .. "/bun.lockb") == 1 or vim.fn.filereadable(root .. "/bun.lock") == 1 then
      runner = "bun"
    end

    if package:find('"typecheck"%s*:') or package:find('"type%-check"%s*:') then
      local script = package:find('"typecheck"%s*:') and "typecheck" or "type-check"
      if runner == "yarn" or runner == "pnpm" or runner == "bun" then
        return root, "typescript", { runner, script }
      end
      return root, "typescript", { "npm", "run", script, "--", "--pretty", "false" }
    end

    if runner == "pnpm" then
      return root, "typescript", { "pnpm", "exec", "tsc", "--noEmit", "--pretty", "false" }
    elseif runner == "yarn" then
      return root, "typescript", { "yarn", "tsc", "--noEmit", "--pretty", "false" }
    elseif runner == "bun" then
      return root, "typescript", { "bunx", "tsc", "--noEmit", "--pretty", "false" }
    end
    return root, "typescript", { "npx", "tsc", "--noEmit", "--pretty", "false" }
  end

  if go_marker then
    local root = project_root_from_marker(go_marker)
    return root, "go", { "go", "test", "./..." }
  end
end

local function project_check_path(root, path)
  if not path or path == "" or path:match("^%s*%[") then
    return nil
  end
  path = vim.trim(path):gsub("\\", "/")
  if path:find("node_modules/", 1, true) == 1 then
    return nil
  end
  if path:match("^%a:[/]") or path:sub(1, 1) == "/" then
    return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  end
  return vim.fs.normalize(vim.fn.fnamemodify(root .. "/" .. path, ":p"))
end

local function add_project_check_target(targets, seen, root, path, line, col, message)
  local filename = project_check_path(root, path)
  line = tonumber(line) or 1
  col = tonumber(col) or 1
  message = vim.trim(tostring(message or ""))
  if not filename or message == "" or vim.fn.filereadable(filename) ~= 1 then
    return
  end

  local byte_col = math.max(col - 1, 0)
  local key = table.concat({ filename, tostring(line), tostring(byte_col), message }, "\0")
  if seen[key] then
    return
  end
  seen[key] = true
  table.insert(targets, {
    filename = filename,
    line = line,
    character = byte_col,
    end_line = line,
    end_character = byte_col + 1,
    byte_col = byte_col,
    end_byte_col = byte_col + 1,
    message = message,
    related_messages = {},
    hl_group = "ReferenceViewErrorHit",
    line_hl_group = "ReferenceViewErrorLine",
  })
end

local function parse_project_check_output(output, root)
  local targets = {}
  local seen = {}
  local last

  for _, raw in ipairs(vim.split(output or "", "\n", { plain = true })) do
    local line = raw:gsub("\27%[[0-9;]*m", "")
    if line ~= "" then
      local path, row, col, message = line:match("^(.+)%((%d+),(%d+)%)%s*:%s*(.-)$")
      if not path then
        path, row, col, message = line:match("^([^:]+%.[%w_]+):(%d+):(%d+)%s*%-?%s*(.+)$")
      end
      if not path then
        path, row, message = line:match("^([^:]+%.go):(%d+):%s*(.+)$")
        col = path and 1 or nil
      end

      if path and message and (path:match("%.go$") or message:match("error") or message:match("Error")) then
        add_project_check_target(targets, seen, root, path, row, col, message)
        last = targets[#targets]
      elseif last and line:match("^%s+") then
        last.message = vim.trim(last.message .. " " .. vim.trim(line))
      else
        last = nil
      end
    end
  end

  table.sort(targets, function(a, b)
    if a.filename ~= b.filename then
      return a.filename < b.filename
    end
    if a.line ~= b.line then
      return a.line < b.line
    end
    return a.byte_col < b.byte_col
  end)
  return targets
end

local function merge_error_targets(...)
  local merged = {}
  local seen = {}
  for _, targets in ipairs({ ... }) do
    for _, target in ipairs(targets or {}) do
      local key = table.concat({
        target.filename or "",
        tostring(target.line or ""),
        tostring(target.byte_col or target.character or ""),
        tostring(target.end_line or ""),
        tostring(target.end_byte_col or target.end_character or ""),
        target.message or "",
      }, "\0")
      if not seen[key] then
        seen[key] = true
        table.insert(merged, target)
      end
    end
  end

  table.sort(merged, function(a, b)
    if a.filename ~= b.filename then
      return a.filename < b.filename
    end
    if a.line ~= b.line then
      return a.line < b.line
    end
    return (a.byte_col or a.character or 0) < (b.byte_col or b.character or 0)
  end)
  return merged
end

local function open_locations(opts)
  opts = opts or {}
  local method = opts.method or "textDocument/references"
  local label = opts.label or "Locations"
  local empty = opts.empty or "no locations found"
  local origin_buf = vim.api.nvim_get_current_buf()
  local origin_win = vim.api.nvim_get_current_win()
  local origin_cursor = vim.api.nvim_win_get_cursor(origin_win)
  local clients = vim.lsp.get_clients({ bufnr = origin_buf, method = method })
  if #clients == 0 then
    vim.notify(label .. ": no attached LSP client supports this request", vim.log.levels.WARN)
    return
  end

  state.label = label
  state.origin_buf = origin_buf
  state.origin_win = origin_win
  state.origin_cursor = origin_cursor
  state.context_lines = opts.context_lines or 2
  state.root = vim.fs.root(origin_buf, { ".git", "go.mod", "package.json", "tsconfig.json", "Cargo.toml" }) or vim.fn.getcwd()

  local encoding = clients[1].offset_encoding or "utf-16"
  local params = vim.lsp.util.make_position_params(origin_win, encoding)
  if opts.context then
    params.context = opts.context
  end
  local title = current_word_title()

  vim.lsp.buf_request_all(origin_buf, method, params, function(responses)
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(origin_buf) then
        clear_state()
        return
      end
      local targets = collect_targets(responses)
      if #targets == 0 then
        vim.notify(label .. ": " .. empty, vim.log.levels.INFO)
        clear_state()
        return
      end
      if opts.open_single and #targets == 1 then
        open_location_target(targets[1], nil, {
          win = origin_win,
          buf = origin_buf,
          cursor = origin_cursor,
        })
        return
      end
      render(group_targets(targets), title, opts.scheme)
    end)
  end)
end

function M.open()
  open_locations({
    method = "textDocument/references",
    label = "References",
    empty = "no references found",
    scheme = "references",
    context = { includeDeclaration = true },
    context_lines = 3,
  })
end

function M.definitions()
  open_locations({
    method = "textDocument/definition",
    label = "Definitions",
    empty = "no definitions found",
    scheme = "definitions",
    context_lines = 8,
    open_single = true,
  })
end

-- Open ripgrep-style results in the same grouped, contextual view used for
-- LSP references. Item columns are 1-based byte columns, matching
-- `rg --vimgrep` and quickfix location items.
function M.search(items, query)
  query = tostring(query or "")
  local origin_buf = vim.api.nvim_get_current_buf()
  local origin_win = vim.api.nvim_get_current_win()
  local targets = {}

  for _, item in ipairs(items or {}) do
    local filename = item.filename and vim.fs.normalize(item.filename) or nil
    local line = tonumber(item.lnum or item.line)
    local col = tonumber(item.col) or 1
    if filename and filename ~= "" and line and line > 0 then
      local byte_col = math.max(col - 1, 0)
      table.insert(targets, {
        filename = filename,
        line = line,
        character = byte_col,
        end_line = line,
        end_character = byte_col + math.max(#query, 1),
        byte_col = byte_col,
        end_byte_col = byte_col + math.max(#query, 1),
        encoding = "utf-8",
      })
    end
  end

  if #targets == 0 then
    vim.notify("Search: no results", vim.log.levels.INFO)
    return
  end

  state.label = "Search"
  state.origin_buf = origin_buf
  state.origin_win = origin_win
  state.origin_cursor = vim.api.nvim_win_get_cursor(origin_win)
  state.context_lines = 3
  state.root = vim.fs.root(origin_buf, { ".git", "go.mod", "package.json", "tsconfig.json", "Cargo.toml" }) or vim.fn.getcwd()

  table.sort(targets, function(a, b)
    if a.filename ~= b.filename then
      return a.filename < b.filename
    end
    if a.line ~= b.line then
      return a.line < b.line
    end
    return a.byte_col < b.byte_col
  end)

  render(group_targets(targets), query ~= "" and query or "search", "search")
end

function M.errors()
  local origin_buf = vim.api.nvim_get_current_buf()
  local origin_win = vim.api.nvim_get_current_win()
  state.label = "Errors"
  state.origin_buf = origin_buf
  state.origin_win = origin_win
  state.origin_cursor = vim.api.nvim_win_get_cursor(origin_win)
  state.context_lines = ERROR_CONTEXT_LINES
  state.root = vim.fs.root(origin_buf, { ".git", "go.mod", "package.json", "tsconfig.json", "Cargo.toml" }) or vim.fn.getcwd()

  local targets = collect_error_targets(state.root, { bufnr = origin_buf })
  if #targets == 0 then
    vim.notify("Errors: no errors in current file", vim.log.levels.INFO)
    clear_state()
    return
  end

  render(group_targets(targets), "errors", "errors")
end

function M.project_errors()
  local origin_buf = vim.api.nvim_get_current_buf()
  local origin_win = vim.api.nvim_get_current_win()
  local root, project, command = detect_project_check()
  if not root then
    vim.notify("Project Errors: no TypeScript or Go project found", vim.log.levels.WARN)
    clear_state()
    return
  end

  state.label = "Project Errors"
  state.origin_buf = origin_buf
  state.origin_win = origin_win
  state.origin_cursor = vim.api.nvim_win_get_cursor(origin_win)
  state.context_lines = ERROR_CONTEXT_LINES
  state.root = root
  state.project_check_run_id = state.project_check_run_id + 1
  local run_id = state.project_check_run_id

  vim.notify("Project Errors: running " .. table.concat(command, " "), vim.log.levels.INFO)
  local ok, job = pcall(vim.system, command, { cwd = root, text = true }, function(result)
    vim.schedule(function()
      if run_id ~= state.project_check_run_id then
        return
      end
      if not vim.api.nvim_buf_is_valid(origin_buf) then
        clear_state()
        return
      end

      local output = table.concat({ result and result.stdout or "", result and result.stderr or "" }, "\n")
      local targets = merge_error_targets(parse_project_check_output(output, root), collect_error_targets(root))
      if #targets == 0 then
        clear_state()
        if result and result.code == 0 then
          vim.notify("Project Errors: " .. project .. " check passed", vim.log.levels.INFO)
        else
          vim.notify("Project Errors: check failed, but no file errors were parsed", vim.log.levels.ERROR)
        end
        return
      end

      render(group_targets(targets), "project-errors", "errors")
    end)
  end)
  if not ok or not job then
    vim.notify("Project Errors: failed to start " .. table.concat(command, " "), vim.log.levels.ERROR)
    clear_state()
    return
  end
end

vim.api.nvim_create_user_command("ReferencesView", M.open, { desc = "Open grouped LSP references view", force = true })
vim.api.nvim_create_user_command("DefinitionsView", M.definitions, { desc = "Open grouped LSP definitions view", force = true })
vim.api.nvim_create_user_command("ErrorsView", M.errors, { desc = "Open grouped diagnostic errors view", force = true })
vim.api.nvim_create_user_command("ProjectErrorsView", M.project_errors, { desc = "Open grouped project diagnostic errors view", force = true })

return M
