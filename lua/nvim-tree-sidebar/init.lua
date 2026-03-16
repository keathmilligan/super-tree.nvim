local icons  = require("nvim-tree-sidebar.icons")
local git    = require("nvim-tree-sidebar.git")
local tree   = require("nvim-tree-sidebar.tree")
local window = require("nvim-tree-sidebar.window")

local M = {}

local config = {
  width = 30,
  mode  = "floating",  -- "floating" or "pinned"
  icons = {
    enable   = true,
    provider = "auto",  -- "auto", "nvim-web-devicons", or "builtin"
  },
  git = {
    enable = true,
  },
}

-- Wire git module to re-render on async change events.
git.set_on_change(function()
  if window.is_open() then
    tree.render(window.sidebar_buf, config)
  end
end)

-- ---------------------------------------------------------------------------
-- Navigation actions (used by keymaps)
-- ---------------------------------------------------------------------------

local function move_up()
  local cursor = vim.api.nvim_win_get_cursor(window.sidebar_win)
  local row = cursor[1]
  if row > 1 then
    vim.api.nvim_win_set_cursor(window.sidebar_win, { row - 1, 0 })
  end
end

local function move_down()
  local cursor = vim.api.nvim_win_get_cursor(window.sidebar_win)
  local row = cursor[1]
  local line_count = vim.api.nvim_buf_line_count(window.sidebar_buf)
  if row < line_count then
    vim.api.nvim_win_set_cursor(window.sidebar_win, { row + 1, 0 })
  end
end

local function get_current_entry()
  local cursor = vim.api.nvim_win_get_cursor(window.sidebar_win)
  local row = cursor[1]
  -- Row 1 is the cwd root line; tree entries start at row 2 → tree_data[1].
  return tree.tree_data[row - 1]
end

local function toggle_expand()
  local entry = get_current_entry()
  if not entry or not entry.is_dir then return end

  if tree.expanded_paths[entry.path] then
    tree.expanded_paths[entry.path] = nil
  else
    tree.expanded_paths[entry.path] = true
  end

  tree.build_tree(config)
  tree.render(window.sidebar_buf, config)
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function M.open()
  if window.is_open() then
    vim.api.nvim_set_current_win(window.sidebar_win)
    return
  end

  local buf = window.create_or_get_buffer()

  if config.mode == "pinned" then
    window.sidebar_win = window.create_pinned_window(buf, config.width)
    tree.build_tree(config)
    tree.render(buf, config)
    window.setup_keymaps(buf, {
      move_up       = move_up,
      move_down     = move_down,
      toggle_expand = toggle_expand,
      close         = M.close,
    })
    vim.bo[buf].filetype = "tree-sidebar"
    vim.cmd("redrawtabline")
    vim.api.nvim_exec_autocmds("User", { pattern = "TreeSidebarOpen" })
  else
    window.sidebar_win = window.create_floating_window(buf, config.width)
    tree.build_tree(config)
    tree.render(buf, config)
    window.setup_keymaps(buf, {
      move_up       = move_up,
      move_down     = move_down,
      toggle_expand = toggle_expand,
      close         = M.close,
    })
  end
end

function M.close()
  window.close_window()
  git.reset()
end

function M.is_open()
  return window.is_open()
end

function M.get_width()
  if not M.is_open() then return 0 end
  return config.width + 1
end

function M.toggle()
  if window.is_open() then
    M.close()
  else
    M.open()
  end
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

local hl_defined = false

function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})

  if not hl_defined then
    vim.api.nvim_set_hl(0, "TreeSidebarDirectory", { link = "Directory", default = true })
    vim.api.nvim_set_hl(0, "TreeSidebarIndent",    { fg = "#4b5263",    default = true })
    vim.api.nvim_set_hl(0, "TreeSidebarGitRepo",   { fg = "#73c936",    default = true })
    vim.api.nvim_set_hl(0, "TreeSidebarGitHub",    { fg = "#73c936",    default = true })
    icons.setup_highlights()
    hl_defined = true
  end

  vim.api.nvim_create_user_command("TreeSidebar",      M.toggle, {})
  vim.api.nvim_create_user_command("TreeSidebarOpen",  M.open,   {})
  vim.api.nvim_create_user_command("TreeSidebarClose", M.close,  {})

  vim.api.nvim_create_autocmd("User", {
    pattern  = "TreeSidebarOpen",
    callback = function() vim.cmd("redrawtabline") end,
  })

  vim.api.nvim_create_autocmd("User", {
    pattern  = "TreeSidebarClose",
    callback = function() vim.cmd("redrawtabline") end,
  })
end

return M
