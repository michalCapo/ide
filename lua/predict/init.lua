-- Next-edit prediction (Cursor/Zed style).
--
-- After a pause in editing, sends the recent edit history plus the current
-- file (cursor and editable region marked) to a local ollama model and asks
-- it to rewrite the editable region. The predicted change is rendered as
-- ghost text / a ghost diff block; <Tab> accepts it.

local M = {}

M.config = {
  endpoint = "http://localhost:11434/api/chat",
  model = "glm-5.2:cloud",
  debounce_ms = 500,
  request_timeout_s = 20,
  -- Lines above/below the cursor that the model may rewrite.
  region_radius = 12,
  -- Whole file is sent when it fits; otherwise a window around the cursor.
  max_file_lines = 400,
  context_window = 150,
  history_max_entries = 6,
  history_max_diff_lines = 40,
  temperature = 0.1,
  num_predict = 700,
}

local ns = vim.api.nvim_create_namespace("predict")
-- Opt in with :PredictToggle (or <leader>ap); keep predictions off at startup.
local enabled = false
local generation = 0
local inflight = nil

-- Per-buffer text snapshots used to derive the edit history diffs.
local snapshots = {}
-- Recent edits as unified diffs, oldest first: { file = ..., diff = ... }.
local history = {}

-- The currently displayed prediction, or nil.
local current = nil

local CURSOR_MARK = "<|user_cursor_is_here|>"
local REGION_START = "<|editable_region_start|>"
local REGION_END = "<|editable_region_end|>"

local SYSTEM_PROMPT = table.concat({
  "You are an edit prediction assistant inside a code editor.",
  "You are given the user's recent edits and the current file.",
  CURSOR_MARK .. " marks the cursor.",
  "An editable region is delimited by " .. REGION_START .. " and " .. REGION_END .. ".",
  "Rewrite ONLY the editable region, applying the single most likely edit the user will make next,",
  "continuing the intent visible in their recent edits.",
  "If no further edit is likely, output the editable region unchanged.",
  "Output the rewritten editable region verbatim: no markers, no code fences, no commentary.",
}, " ")

local function buf_eligible(buf)
  return vim.api.nvim_buf_is_valid(buf)
      and vim.bo[buf].buftype == ""
      and vim.bo[buf].modifiable
      and not vim.b[buf].predict_disable
      and vim.api.nvim_buf_line_count(buf) < 20000
end

local function buf_text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") .. "\n"
end

-- Diff the buffer against its last snapshot and record the result in the
-- edit history. Called right before each prediction request, so history
-- entries are grouped by typing pauses.
local function record_edits(buf)
  local text = buf_text(buf)
  local old = snapshots[buf]
  snapshots[buf] = text
  if not old or old == text then
    return
  end
  local diff = vim.diff(old, text, { result_type = "unified", ctxlen = 1 })
  if not diff or diff == "" then
    return
  end
  local lines = vim.split(diff, "\n", { trimempty = true })
  if #lines > M.config.history_max_diff_lines then
    lines = vim.list_slice(lines, 1, M.config.history_max_diff_lines)
    table.insert(lines, "... (edit truncated)")
  end
  local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":.")
  table.insert(history, { file = name, diff = table.concat(lines, "\n") })
  while #history > M.config.history_max_entries do
    table.remove(history, 1)
  end
end

local function build_prompt(buf, win)
  local cursor = vim.api.nvim_win_get_cursor(win)
  local crow, ccol = cursor[1], cursor[2]
  local line_count = vim.api.nvim_buf_line_count(buf)

  local rstart = math.max(1, crow - M.config.region_radius)
  local rend = math.min(line_count, crow + M.config.region_radius)

  local fstart, fend = 1, line_count
  if line_count > M.config.max_file_lines then
    fstart = math.max(1, crow - M.config.context_window)
    fend = math.min(line_count, crow + M.config.context_window)
  end

  local parts = {}
  for lnum = fstart, fend do
    local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
    if lnum == crow then
      line = line:sub(1, ccol) .. CURSOR_MARK .. line:sub(ccol + 1)
    end
    if lnum == rstart then
      table.insert(parts, REGION_START)
    end
    table.insert(parts, line)
    if lnum == rend then
      table.insert(parts, REGION_END)
    end
  end

  local edits = {}
  for _, entry in ipairs(history) do
    table.insert(edits, "Edit in " .. entry.file .. ":\n" .. entry.diff)
  end

  local window_note = ""
  if fstart > 1 or fend < line_count then
    window_note = string.format(" — showing lines %d-%d of %d", fstart, fend, line_count)
  end
  local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":.")
  local user = string.format(
    "Recent edits, oldest first:\n%s\n\nCurrent file: %s (filetype: %s)%s\n```\n%s\n```",
    #edits > 0 and table.concat(edits, "\n\n") or "(none)",
    name,
    vim.bo[buf].filetype,
    window_note,
    table.concat(parts, "\n")
  )

  return user, rstart, rend
end

local function clean_response(content, region_line_count)
  content = content:gsub(vim.pesc(CURSOR_MARK), "")
  content = content:gsub(vim.pesc(REGION_START), "")
  content = content:gsub(vim.pesc(REGION_END), "")
  content = content:gsub("^%s*```[%w_-]*\n", ""):gsub("\n```%s*$", "")
  content = content:gsub("\n$", "")
  local lines = vim.split(content, "\n")
  -- Guard against runaway output: a sane rewrite of the region stays in the
  -- same order of magnitude as the original.
  if #lines > region_line_count * 2 + 20 then
    return nil
  end
  return lines
end

function M.clear()
  if inflight then
    pcall(inflight.kill, inflight, 15)
    inflight = nil
  end
  generation = generation + 1
  if current then
    if vim.api.nvim_buf_is_valid(current.buf) then
      vim.api.nvim_buf_clear_namespace(current.buf, ns, 0, -1)
    end
    current = nil
  end
end

-- Render one diff hunk. Pure single-line insertions become inline ghost
-- text; everything else becomes deletion highlights plus ghost virt_lines.
local function render_hunk(buf, rstart, old_lines, new_lines, hunk)
  local start_a, count_a, start_b, count_b = hunk[1], hunk[2], hunk[3], hunk[4]

  if count_a == 1 and count_b == 1 then
    local old = old_lines[start_a]
    local new = new_lines[start_b]
    local pre = 0
    while pre < #old and pre < #new and old:byte(pre + 1) == new:byte(pre + 1) do
      pre = pre + 1
    end
    local suf = 0
    while suf < #old - pre and suf < #new - pre
        and old:byte(#old - suf) == new:byte(#new - suf) do
      suf = suf + 1
    end
    if pre + suf == #old then
      -- Pure insertion inside one line: inline ghost text.
      vim.api.nvim_buf_set_extmark(buf, ns, rstart + start_a - 2, pre, {
        virt_text = { { new:sub(pre + 1, #new - suf), "PredictGhost" } },
        virt_text_pos = "inline",
      })
      return
    end
  end

  if count_a > 0 then
    for i = 0, count_a - 1 do
      vim.api.nvim_buf_set_extmark(buf, ns, rstart + start_a - 2 + i, 0, {
        line_hl_group = "PredictReplace",
      })
    end
  end
  if count_b > 0 then
    local virt = {}
    for i = start_b, start_b + count_b - 1 do
      table.insert(virt, { { new_lines[i] == "" and " " or new_lines[i], "PredictGhost" } })
    end
    -- Anchor below the replaced lines; for pure additions (count_a == 0)
    -- vim.diff's start_a is the line the insertion follows.
    local anchor = count_a > 0 and (rstart + start_a - 3 + count_a) or (rstart + start_a - 2)
    anchor = math.max(0, math.min(anchor, vim.api.nvim_buf_line_count(buf) - 1))
    vim.api.nvim_buf_set_extmark(buf, ns, anchor, 0, {
      virt_lines = virt,
    })
  end
end

local function show(buf, win, rstart, rend, old_lines, new_lines)
  local old_text = table.concat(old_lines, "\n") .. "\n"
  local new_text = table.concat(new_lines, "\n") .. "\n"
  if old_text == new_text then
    return
  end
  local hunks = vim.diff(old_text, new_text, { result_type = "indices" })
  if not hunks or #hunks == 0 then
    return
  end

  current = {
    buf = buf,
    win = win,
    rstart = rstart,
    rend = rend,
    new_lines = new_lines,
    hunks = hunks,
    tick = vim.api.nvim_buf_get_changedtick(buf),
  }
  for _, hunk in ipairs(hunks) do
    render_hunk(buf, rstart, old_lines, new_lines, hunk)
  end
end

function M.request()
  if not enabled then
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  if not buf_eligible(buf) or vim.fn.pumvisible() == 1 or vim.fn.reg_executing() ~= "" then
    return
  end

  M.clear()
  record_edits(buf)
  if #history == 0 then
    return
  end

  local user_prompt, rstart, rend = build_prompt(buf, win)
  local old_lines = vim.api.nvim_buf_get_lines(buf, rstart - 1, rend, false)
  local tick = vim.api.nvim_buf_get_changedtick(buf)

  local body = vim.json.encode({
    model = M.config.model,
    stream = false,
    options = { temperature = M.config.temperature, num_predict = M.config.num_predict },
    messages = {
      { role = "system", content = SYSTEM_PROMPT },
      { role = "user", content = user_prompt },
    },
  })

  generation = generation + 1
  local gen = generation

  inflight = vim.system({
    "curl", "-s", "--max-time", tostring(M.config.request_timeout_s),
    M.config.endpoint, "-d", body,
  }, { text = true }, function(result)
    vim.schedule(function()
      if gen ~= generation then
        return
      end
      inflight = nil
      if result.code ~= 0 or not result.stdout or result.stdout == "" then
        return
      end
      local ok, decoded = pcall(vim.json.decode, result.stdout)
      if not ok or type(decoded) ~= "table" or not decoded.message then
        return
      end
      if not vim.api.nvim_buf_is_valid(buf)
          or vim.api.nvim_buf_get_changedtick(buf) ~= tick
          or vim.api.nvim_get_current_buf() ~= buf then
        return
      end
      local new_lines = clean_response(decoded.message.content or "", rend - rstart + 1)
      if new_lines then
        show(buf, win, rstart, rend, old_lines, new_lines)
      end
    end)
  end)
end

-- Cancel the displayed prediction and any in-flight request. Returns true
-- if there was something to cancel, so callers can fall through otherwise.
function M.dismiss()
  if current == nil and inflight == nil then
    return false
  end
  M.clear()
  return true
end

function M.has_prediction()
  return current ~= nil
      and vim.api.nvim_get_current_buf() == current.buf
      and vim.api.nvim_buf_get_changedtick(current.buf) == current.tick
end

function M.accept()
  if not M.has_prediction() then
    return false
  end
  local p = current
  current = nil
  vim.api.nvim_buf_clear_namespace(p.buf, ns, 0, -1)
  generation = generation + 1

  vim.api.nvim_buf_set_lines(p.buf, p.rstart - 1, p.rend, false, p.new_lines)
  -- Snapshot immediately so the accepted prediction itself becomes part of
  -- the edit history for the next request.
  record_edits(p.buf)

  -- Land the cursor at the end of the last predicted change.
  local last = p.hunks[#p.hunks]
  local row = p.rstart - 1 + math.max(last[3] + math.max(last[4], 1) - 1, 1)
  row = math.min(row, vim.api.nvim_buf_line_count(p.buf))
  local line = vim.api.nvim_buf_get_lines(p.buf, row - 1, row, false)[1] or ""
  pcall(vim.api.nvim_win_set_cursor, 0, { row, #line })
  return true
end

function M.is_enabled()
  return enabled
end

function M.toggle()
  enabled = not enabled
  if not enabled then
    M.clear()
  end
  vim.notify("Prediction " .. (enabled and "enabled" or "disabled"), vim.log.levels.INFO)
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  vim.api.nvim_set_hl(0, "PredictGhost", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "PredictReplace", { link = "DiffChange", default = true })

  local group = vim.api.nvim_create_augroup("Predict", { clear = true })
  local timer = vim.uv.new_timer()

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    callback = function(event)
      if not buf_eligible(event.buf) then
        return
      end
      M.clear()
      timer:stop()
      timer:start(M.config.debounce_ms, 0, vim.schedule_wrap(M.request))
    end,
  })

  -- Seed the snapshot so the first edit in a buffer diffs against the text
  -- as it was opened, not against nothing.
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
    group = group,
    callback = function(event)
      if buf_eligible(event.buf) then
        snapshots[event.buf] = buf_text(event.buf)
      end
    end,
  })

  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    callback = function()
      if current then
        local row = vim.api.nvim_win_get_cursor(0)[1]
        if row < current.rstart or row > current.rend then
          M.clear()
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "BufLeave", "BufDelete" }, {
    group = group,
    callback = function(event)
      if current and current.buf == event.buf then
        M.clear()
      end
      if event.event == "BufDelete" then
        snapshots[event.buf] = nil
      end
    end,
  })

  vim.api.nvim_create_user_command("PredictToggle", M.toggle, { desc = "Toggle next-edit prediction" })
  vim.api.nvim_create_user_command("PredictStatus", function()
    vim.notify("Prediction is " .. (enabled and "ON" or "OFF") .. " (model: " .. M.config.model .. ")", vim.log.levels.INFO)
  end, { desc = "Show next-edit prediction status" })
  vim.api.nvim_create_user_command("PredictNow", M.request, { desc = "Request a prediction now" })
end

return M
