-- Two-key viewport word jump.
-- Press `s`, then type the two-character label drawn over a visible word.

local M = {}

local namespace = vim.api.nvim_create_namespace("search_view")

-- Labels are always two characters. Nearby words receive the easiest labels,
-- beginning with ff, fj, fd, and so on.
local LABELS = "fjdklsahgurieowtybnvmcpqxz"
local LABEL_POOL = {}
for c in LABELS:gmatch(".") do
  LABEL_POOL[#LABEL_POOL + 1] = c
end
local MAX_TARGETS = #LABEL_POOL * #LABEL_POOL
-- Leave at least one untouched screen cell between two-character labels.
local MIN_LABEL_SPACING = 4

local function apply_highlights()
  if vim.o.background == "light" then
    vim.api.nvim_set_hl(0, "SearchViewLabel", { fg = "#ffffff", bg = "#005fb8", bold = true })
    vim.api.nvim_set_hl(0, "SearchViewLabelNext", { fg = "#ffffff", bg = "#a1260d", bold = true })
  else
    vim.api.nvim_set_hl(0, "SearchViewLabel", { fg = "#1f1f1f", bg = "#4ec9b0", bold = true })
    vim.api.nvim_set_hl(0, "SearchViewLabelNext", { fg = "#1f1f1f", bg = "#ffd700", bold = true })
  end
end

-- Return one ordinary character, or nil when cancelled with Esc, Ctrl-C, or a
-- special key.
local function read_char()
  local ok, ch = pcall(vim.fn.getchar)
  if not ok then
    return nil
  end
  if type(ch) ~= "number" or ch == 27 or ch == 3 then
    return nil
  end
  ch = vim.fn.nr2char(ch)
  return ch ~= "" and ch or nil
end

local function visible_range()
  return vim.fn.line("w0"), vim.fn.line("w$")
end

local function clear()
  vim.api.nvim_buf_clear_namespace(0, namespace, 0, -1)
end

-- Find the beginning of every keyword word in the visible window. `\k` uses
-- Neovim's 'iskeyword', so this follows the current buffer's idea of a word.
local function find_targets()
  local top, bot = visible_range()
  local lines = vim.api.nvim_buf_get_lines(0, top - 1, bot, false)
  local targets = {}

  for i, line in ipairs(lines) do
    local row = top + i - 1
    local start = 0
    while start < #line do
      local result = vim.fn.matchstrpos(line, [[\k\+]], start)
      local col = result[2]
      local finish = result[3]
      if col < 0 then
        break
      end
      local screen_col = vim.fn.strdisplaywidth(line:sub(1, col))
      targets[#targets + 1] = { row = row, col = col, screen_col = screen_col }
      if #targets >= MAX_TARGETS then
        break
      end
      start = math.max(finish, start + 1)
    end
    if #targets >= MAX_TARGETS then
      break
    end
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local function distance(target)
    local row_delta = target.row - cursor[1]
    local col_delta = target.col - cursor[2]
    return row_delta * row_delta * 4096 + col_delta * col_delta
  end
  table.sort(targets, function(a, b)
    local a_distance = distance(a)
    local b_distance = distance(b)
    if a_distance == b_distance then
      if a.row == b.row then
        return a.col < b.col
      end
      return a.row < b.row
    end
    return a_distance < b_distance
  end)

  -- Keep the closest target when labels on the same row would be crowded.
  -- Targets are distance-sorted, so the first accepted one is the useful one.
  local spaced_targets = {}
  for _, target in ipairs(targets) do
    local crowded = false
    for _, accepted in ipairs(spaced_targets) do
      if accepted.row == target.row
        and math.abs(accepted.screen_col - target.screen_col) < MIN_LABEL_SPACING
      then
        crowded = true
        break
      end
    end
    if not crowded then
      spaced_targets[#spaced_targets + 1] = target
    end
  end
  targets = spaced_targets

  local index = 1
  for _, first in ipairs(LABEL_POOL) do
    for _, second in ipairs(LABEL_POOL) do
      local target = targets[index]
      if not target then
        return targets
      end
      target.label = first .. second
      index = index + 1
    end
  end
  return targets
end

-- Initially draw both label characters. After the first key, retain matching
-- targets and draw only their second character.
local function draw(targets, prefix)
  clear()
  for _, target in ipairs(targets) do
    if prefix == "" or target.label:sub(1, 1) == prefix then
      local text = prefix == "" and target.label or target.label:sub(2, 2)
      local highlight = prefix == "" and "SearchViewLabel" or "SearchViewLabelNext"
      vim.api.nvim_buf_set_extmark(0, namespace, target.row - 1, target.col, {
        virt_text = { { text, highlight } },
        virt_text_pos = "overlay",
        priority = 250,
      })
    end
  end
  vim.cmd("redraw")
end

local function jump_to(target)
  clear()
  vim.cmd("normal! m'")
  vim.api.nvim_win_set_cursor(0, { target.row, target.col })
end

function M.search()
  apply_highlights()
  local targets = find_targets()
  if #targets == 0 then
    vim.api.nvim_echo({ { "search: no visible words", "WarningMsg" } }, false, {})
    return
  end

  draw(targets, "")
  local first = read_char()
  if not first then
    clear()
    vim.cmd("redraw")
    return
  end

  local has_prefix = false
  for _, target in ipairs(targets) do
    if target.label:sub(1, 1) == first then
      has_prefix = true
      break
    end
  end
  if not has_prefix then
    clear()
    vim.cmd("redraw")
    return
  end

  draw(targets, first)
  local second = read_char()
  if not second then
    clear()
    vim.cmd("redraw")
    return
  end

  local label = first .. second
  for _, target in ipairs(targets) do
    if target.label == label then
      jump_to(target)
      return
    end
  end

  clear()
  vim.cmd("redraw")
end

vim.keymap.set("n", "s", M.search, { desc = "Jump to a visible word by its two-key label" })

return M
