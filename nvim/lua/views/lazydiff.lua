-- Standalone launcher for the git diff viewer TUI.
-- Driven by the `lazydiff` shell wrapper, which runs:
--   nvim -u NORC -i NONE -c "lua require('views.lazydiff').launch{...}"
-- `-u NORC` skips the full user config (so we stay lightweight) but keeps the
-- default runtimepath, which means nvim.my/lua (via the `nvim` -> nvim.my
-- symlink and its `lua/` -> nvim.lazy/lua symlink) is still on rtp, so the
-- views.* modules resolve via require(). We set up a bare UI, match the main
-- config's colorscheme, open views.git_diff, and quit when its tab closes.

local M = {}

local function setup_ui()
  vim.o.termguicolors = true
  vim.o.showtabline = 0
  vim.o.laststatus = 0
  vim.o.ruler = false
  vim.o.showmode = false
  vim.o.swapfile = false
  vim.o.shada = ""
  vim.g.mapleader = " "

  -- Match the colorscheme + background the full config uses, so the diff
  -- view's highlights (DiffAdd/Change/Delete, Directory, and its own
  -- light/dark branch) look identical to opening it via <leader>gd inside
  -- Neovim.
  local config_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
  local bundled_path = config_root .. "/vscode-theme"
  local lazy_path = vim.fn.stdpath("data") .. "/lazy/vscode-theme"
  if vim.uv.fs_stat(bundled_path) then
    vim.opt.runtimepath:prepend(bundled_path)
  elseif vim.uv.fs_stat(lazy_path) then
    vim.opt.runtimepath:prepend(lazy_path)
  end

  -- Mirror preferred_editor_background(): NVIM_BACKGROUND override, else the
  -- GNOME color-scheme, else dark.
  local background = "dark"
  local override = vim.env.NVIM_BACKGROUND
  if override == "light" or override == "dark" then
    background = override
  elseif vim.fn.executable("gsettings") == 1 then
    local ok, out = pcall(vim.fn.system, { "gsettings", "get", "org.gnome.desktop.interface", "color-scheme" })
    if ok and vim.v.shell_error == 0 then
      out = tostring(out or ""):lower()
      if out:find("light") or out:find("default") then
        background = "light"
      elseif out:find("dark") then
        background = "dark"
      end
    end
  end

  vim.o.background = background
  local ok, vscode = pcall(require, "vscode")
  if ok then
    vscode.setup({ style = background })
  end
  pcall(vim.cmd.colorscheme, "vscode")
end

-- opts.focus_file: repo-relative path to open on (set via LAZYDIFF_FILE by the
-- wrapper / gitui keybinding).
function M.launch(opts)
  opts = opts or {}
  vim.g.lazydiff_standalone = true
  setup_ui()

  local gdv = require("views.git_diff")
  vim.schedule(function()
    local tabs_before = #vim.api.nvim_list_tabpages()
    -- allow_empty: open even with a clean tree, so lazydiff always launches
    -- (you can still press `g` for gitui, `R` to refresh, `q` to quit).
    local focus_file = opts.focus_file
    if focus_file == "" then
      focus_file = nil
    end
    gdv.open({ allow_empty = true, focus_file = focus_file })

    -- No tab was opened -> not a repo. Exit immediately.
    if #vim.api.nvim_list_tabpages() <= tabs_before then
      vim.cmd("qa!")
      return
    end

    -- The viewer lives in its own tab; when it closes we land back on the
    -- original empty buffer. Quit then, unless the user pressed `e` to open a
    -- file for editing (that leaves a named buffer -- keep Neovim open for it).
    vim.api.nvim_create_autocmd("TabClosed", {
      callback = function()
        vim.schedule(function()
          if #vim.api.nvim_list_tabpages() > 1 then
            return
          end
          if vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()) ~= "" then
            return
          end
          vim.cmd("qa!")
        end)
      end,
    })
  end)
end

return M
