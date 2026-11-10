-- Shared look for vimg, vimd and vime: one palette, panel headers, a global
-- status line with key chips, a selection bar and floating dialogs.
local M = {}

-- VS Code Dark Modern / Light Modern values, matching the bundled colorscheme.
M.palettes = {
  dark = {
    bg = 0x1f1f1f, bg2 = 0x191919, hdr = 0x262626, line = 0x333333, fg = 0xcccccc, fgb = 0xececec,
    mut = 0x8d8d8d, dim = 0x5c5c5c, acc = 0x4daafc, accbg = 0x0078d4, onacc = 0xffffff,
    sel = 0x04395e, seli = 0x2c2c2c, cell = 0x0b5a96, chip = 0x363636, bar = 0x181818,
    add = 0x81b88b, mod = 0xe2c08d, unt = 0x73c991, err = 0xf14c4c, warn = 0xcca700, warnbg = 0xcca700,
    insert = 0x388a34, visual = 0x8f4fb3, tab = 0x181818, float = 0x252526, floatb = 0x4a4a4a,
    pg = 0x6aa9e0, ms = 0xe0806a, sq = 0x5fb3a9,
  },
  light = {
    bg = 0xffffff, bg2 = 0xf6f6f6, hdr = 0xededed, line = 0xdddddd, fg = 0x3b3b3b, fgb = 0x1b1b1b,
    mut = 0x6e6e6e, dim = 0xa3a3a3, acc = 0x005fb8, accbg = 0x005fb8, onacc = 0xffffff,
    sel = 0xd3e6f8, seli = 0xe8e8e8, cell = 0x9fcaf0, chip = 0xe2e2e2, bar = 0xf3f3f3,
    add = 0x587c0c, mod = 0x895503, unt = 0x007100, err = 0xd01b1b, warn = 0x8a6a00, warnbg = 0xe0b100,
    insert = 0x2e7d32, visual = 0x8e3fb0, tab = 0xf0f0f0, float = 0xfbfbfb, floatb = 0xc4c4c4,
    pg = 0x1f6fb8, ms = 0xb8432f, sq = 0x1f7f74,
  },
}

function M.palette()
  return M.palettes[vim.o.background == "light" and "light" or "dark"]
end

function M.setup_highlights()
  local c = M.palette()
  local hl = function(name, opts) vim.api.nvim_set_hl(0, name, opts) end
  hl("UiPanel", { fg = c.fg, bg = c.bg })
  hl("UiPanelInactive", { fg = c.fg, bg = c.bg2 })
  hl("UiPanelEob", { fg = c.bg, bg = c.bg })
  hl("UiPanelInactiveEob", { fg = c.bg2, bg = c.bg2 })
  hl("UiSeparator", { fg = c.line, bg = c.bg2 })
  hl("UiHeader", { fg = c.mut, bg = c.hdr })
  hl("UiHeaderTitle", { fg = c.fgb, bg = c.hdr, bold = true })
  hl("UiHeaderDot", { fg = c.acc, bg = c.hdr })
  hl("UiHeaderDim", { fg = c.dim, bg = c.hdr })
  hl("UiSelect", { bg = c.sel })
  hl("UiSelectInactive", { bg = c.seli })
  hl("UiSelectBar", { fg = c.acc, bg = c.sel })
  hl("UiSelectBarInactive", { fg = c.dim, bg = c.seli })
  hl("UiCell", { fg = c.fgb, bg = c.cell })
  hl("UiRule", { fg = c.line })
  hl("UiTableHeader", { fg = c.fgb, bg = c.hdr, bold = true })
  hl("UiTab", { fg = c.mut, bg = c.tab })
  hl("UiTabActive", { fg = c.fgb, bg = c.bg, bold = true })
  hl("UiTabDot", { fg = c.acc, bg = c.bg })
  hl("UiTabFill", { fg = c.line, bg = c.tab })
  hl("UiStatus", { fg = c.fg, bg = c.bar })
  hl("UiStatusStrong", { fg = c.fgb, bg = c.bar })
  hl("UiStatusMuted", { fg = c.mut, bg = c.bar })
  hl("UiStatusDim", { fg = c.dim, bg = c.bar })
  hl("UiStatusAccent", { fg = c.acc, bg = c.bar })
  hl("UiStatusAdded", { fg = c.add, bg = c.bar })
  hl("UiStatusChanged", { fg = c.mod, bg = c.bar })
  hl("UiStatusWarn", { fg = c.warn, bg = c.bar })
  hl("UiStatusError", { fg = c.err, bg = c.bar })
  hl("UiMode", { fg = c.onacc, bg = c.accbg, bold = true })
  hl("UiModeInsert", { fg = c.onacc, bg = c.insert, bold = true })
  hl("UiModeVisual", { fg = c.onacc, bg = c.visual, bold = true })
  hl("UiReadOnly", { fg = c.onacc, bg = c.warnbg, bold = true })
  hl("UiKey", { fg = c.fgb, bg = c.chip })
  hl("UiFloat", { fg = c.fg, bg = c.float })
  hl("UiFloatBorder", { fg = c.floatb, bg = c.float })
  hl("UiFloatTitle", { fg = c.fgb, bg = c.float, bold = true })
  hl("UiFloatError", { fg = c.err, bg = c.float, bold = true })
  hl("UiFloatWarn", { fg = c.warn, bg = c.float, bold = true })
  hl("UiFloatMuted", { fg = c.mut, bg = c.float })
  hl("UiFloatKey", { fg = c.fgb, bg = c.chip })
  hl("UiFloatPrimary", { fg = c.onacc, bg = c.accbg, bold = true })
  hl("UiAccent", { fg = c.acc })
  hl("UiStrong", { fg = c.fgb })
  hl("UiMuted", { fg = c.mut })
  hl("UiDim", { fg = c.dim })
  hl("UiNull", { fg = c.dim, italic = true })
  hl("UiAdded", { fg = c.add })
  hl("UiAddedBold", { fg = c.add, bold = true })
  hl("UiChanged", { fg = c.mod })
  hl("UiChangedBold", { fg = c.mod, bold = true })
  hl("UiUntracked", { fg = c.unt })
  hl("UiError", { fg = c.err })
  hl("UiWarn", { fg = c.warn })
  hl("UiReadOnlyText", { fg = c.warn, bold = true })
  hl("UiDriverPostgres", { fg = c.pg })
  hl("UiDriverSqlServer", { fg = c.ms })
  hl("UiDriverSqlite", { fg = c.sq })
end

local augroup = vim.api.nvim_create_augroup("ViewsUi", { clear = true })
local highlights_ready = false

-- Defines the highlights once and keeps them in step with the colorscheme.
function M.ensure_highlights()
  if highlights_ready then return end
  highlights_ready = true
  M.setup_highlights()
  vim.api.nvim_create_autocmd({ "ColorScheme", "OptionSet" }, {
    group = augroup,
    pattern = { "*", "background" },
    callback = function(args)
      if args.event == "OptionSet" and args.match ~= "background" then return end
      M.setup_highlights()
    end,
  })
end

-- Options shared by the full-screen dashboards (vimg, vimd).
function M.setup_dashboard()
  M.ensure_highlights()
  vim.o.laststatus = 3
  vim.o.showmode = false
  vim.o.ruler = false
  vim.opt.fillchars:append({
    eob = " ", horiz = " ", horizup = "│", horizdown = "│",
    vertleft = "│", vertright = "│", verthoriz = "│",
  })
end

function M.escape(text)
  return (tostring(text or ""):gsub("%%", "%%%%"))
end

local function window_highlight(active)
  if active then
    return table.concat({
      "Normal:UiPanel", "NormalNC:UiPanel", "EndOfBuffer:UiPanelEob", "CursorLine:UiSelect",
      "CursorLineSign:UiSelectBar", "SignColumn:UiPanel", "WinBar:UiHeader", "WinBarNC:UiHeader",
      "WinSeparator:UiSeparator", "StatusLine:UiStatus", "StatusLineNC:UiStatus",
    }, ",")
  end
  return table.concat({
    "Normal:UiPanelInactive", "NormalNC:UiPanelInactive", "EndOfBuffer:UiPanelInactiveEob",
    "CursorLine:UiSelectInactive", "CursorLineSign:UiSelectBarInactive", "SignColumn:UiPanelInactive",
    "UiSelectBar:UiSelectBarInactive", "WinBar:UiHeader", "WinBarNC:UiHeader",
    "WinSeparator:UiSeparator", "StatusLine:UiStatus", "StatusLineNC:UiStatus",
  }, ",")
end

-- Window options for a dashboard panel. `active` paints the brighter background.
function M.panel_window(win, active)
  if not win or not vim.api.nvim_win_is_valid(win) then return end
  vim.wo[win].winhighlight = window_highlight(active)
  vim.wo[win].cursorline = true
  vim.wo[win].signcolumn = "yes:1"
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
end

-- Panel header for 'winbar': dot and title on the left, details on the right.
function M.header(title, active, details)
  local dot = active and "%#UiHeaderDot# ● " or "%#UiHeaderDim# ○ "
  local name = active and "%#UiHeaderTitle#" or "%#UiHeader#"
  local right = details and details ~= "" and ("%#UiHeader#" .. M.escape(details) .. " ") or ""
  return dot .. name .. M.escape(title) .. "%#UiHeader#%<%=" .. right
end

-- Key chips: { { "s", "stage" }, ... } -> " s  stage  "
function M.keys(list, key_group, label_group)
  key_group, label_group = key_group or "UiKey", label_group or "UiStatusMuted"
  local parts = {}
  for _, item in ipairs(list or {}) do
    parts[#parts + 1] = "%#" .. key_group .. "# " .. M.escape(item[1]) .. " %#" .. label_group .. "# " .. M.escape(item[2]) .. "  "
  end
  return table.concat(parts)
end

-- Status line: a coloured mode label, then segments, then key chips on the right.
-- segments: list of { text, group, truncate } items; a narrow screen shortens the
-- first segment marked `truncate` (or the left part) before the key chips.
function M.status(mode, segments, keys, mode_group)
  local parts = { "%#" .. (mode_group or "UiMode") .. "# " .. M.escape(mode) .. " %#UiStatus#" }
  local truncated = false
  for _, segment in ipairs(segments or {}) do
    if segment[3] and not truncated then parts[#parts + 1] = "%<"; truncated = true end
    parts[#parts + 1] = "%#" .. (segment[2] or "UiStatus") .. "#" .. M.escape(segment[1])
  end
  parts[#parts + 1] = "%#UiStatus#" .. (truncated and "" or "%<") .. "%=" .. M.keys(keys)
  return table.concat(parts)
end

-- Floating window chunks for title and footer.
function M.float_title(text, group)
  return { { " " .. tostring(text):gsub("^%s+", ""):gsub("%s+$", "") .. " ", group or "UiFloatTitle" } }
end

function M.float_footer(list, primary)
  local chunks = { { " ", "UiFloatBorder" } }
  for index, item in ipairs(list or {}) do
    chunks[#chunks + 1] = { " " .. item[1] .. " ", index == 1 and primary and "UiFloatPrimary" or "UiFloatKey" }
    chunks[#chunks + 1] = { " " .. item[2] .. "  ", "UiFloatMuted" }
  end
  chunks[#chunks] = { chunks[#chunks][1]:gsub("%s+$", " "), "UiFloatMuted" }
  return chunks
end

M.float_highlight = "Normal:UiFloat,NormalNC:UiFloat,FloatBorder:UiFloatBorder,FloatTitle:UiFloatTitle,FloatFooter:UiFloatMuted,EndOfBuffer:UiFloat,CursorLine:UiSelect"

-- Selection bar: a "▎" sign on the cursor line of every window showing `buf`.
local bar_ns = vim.api.nvim_create_namespace("views_ui_select_bar")

function M.update_select_bar(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  vim.api.nvim_buf_clear_namespace(buf, bar_ns, 0, -1)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_config(win).relative == "" then
      local row = vim.api.nvim_win_get_cursor(win)[1] - 1
      pcall(vim.api.nvim_buf_set_extmark, buf, bar_ns, row, 0, { sign_text = "▎", sign_hl_group = "UiSelectBar", priority = 5 })
    end
  end
end

function M.attach_select_bar(buf)
  if vim.b[buf].views_ui_select_bar then return end
  vim.b[buf].views_ui_select_bar = true
  vim.api.nvim_create_autocmd({ "CursorMoved", "BufWinEnter", "WinEnter", "TextChanged" }, {
    group = augroup,
    buffer = buf,
    callback = function() M.update_select_bar(buf) end,
  })
  M.update_select_bar(buf)
end

return M
