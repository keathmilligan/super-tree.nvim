local icons   = require("super-tree.icons")
local git     = require("super-tree.git")
local tree    = require("super-tree.tree")
local window  = require("super-tree.window")
local actions = require("super-tree.actions")
local filter      = require("super-tree.filter")
local buffers     = require("super-tree.buffers")
local diagnostics = require("super-tree.diagnostics")

local M = {}

local config = {
  width = 50,
  -- "floating": overlay popup, closes when a file is opened
  -- "pinned":   vertical split, <Esc>/q close it
  -- "sidebar":  persistent vertical split like neo-tree - stays open when
  --             files are opened, never covers other windows, navigable
  --             like a regular window; only q closes it
  mode  = "sidebar",
  icons = {
    enable   = true,
    provider = "auto",  -- "auto", "nvim-web-devicons", or "builtin"
  },
  -- Move the sidebar cursor to the current file on BufEnter.
  follow_current_file = true,
  -- When opening files, never replace windows with these filetypes or
  -- buftypes; any other window is reused (like neo-tree).
  open_files_do_not_replace_types = { "terminal", "Trouble", "qf", "edgy" },
  -- Entries hidden by default; toggle visibility with H.
  filtered_items = {
    hide_dotfiles   = false,
    hide_gitignored = false,
  },
  -- Live filter / fuzzy finder (`/`, `D`, `#`, `f`).
  filter = {
    search_limit = 50,
    find_by_full_path_words = false,
  },
  -- Open-buffers pane above the file tree (`B` to toggle).
  buffers = {
    enable = true,
    height = 8,
  },
  diagnostics = {
    enable = true,
    -- nil: use gutter sign text (vim.diagnostic.config().signs), else E/W/I/H
    -- symbols = { error = "E", warn = "W", info = "I", hint = "H" },
  },
  git = {
    enable = true,
    -- Two-line layout for git workspaces in the tree (name, then branch/status).
    multiline = true,
    status = {
      enable = true,  -- git status symbols, branch names, repo summaries
      show_remote = false,  -- show upstream ref next to the branch name
      symbols = {
        -- Change type
        added     = "",
        deleted   = "",
        modified  = "",
        renamed   = "󰁕",
        -- Status type
        untracked = "",
        ignored   = "",
        staged    = "",
        unstaged  = "󰄱",
        conflict  = "",
        -- Repo summary
        branch    = "",
        ahead     = "",
        behind    = "",
        clean     = "",
        stash     = "≡",
        lines_added   = "+",
        lines_removed = "-",
      },
    },
  },
}

local function render_buffers()
  if window.buffers_visible and window.buffers_buf
      and vim.api.nvim_buf_is_valid(window.buffers_buf) then
    buffers.render(window.buffers_buf, config)
  end
end

-- Rebuild the tree data and re-render the sidebar (and buffers pane).
local function rebuild()
  diagnostics.refresh()
  tree.build_tree(config)
  if window.is_open() then
    tree.render(window.sidebar_buf, config)
  end
  render_buffers()
end

-- Wire git module to rebuild on async change events (a status change can
-- affect gitignore filtering, not just decorations).
git.set_on_change(function()
  if window.is_open() then
    rebuild()
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
  return tree.entry_at_row(cursor[1])
end

local function toggle_dir(entry)
  if tree.expanded_paths[entry.path] then
    tree.expanded_paths[entry.path] = nil
  else
    tree.expanded_paths[entry.path] = true
  end
  rebuild()
end

-- Open the file under the cursor. `mode` is "edit", "split", "vsplit", or
-- "tab". In floating mode the sidebar is closed first; in pinned mode the
-- file opens in an editor window while the sidebar stays.
local function open_current(mode)
  local entry = get_current_entry()
  if not entry then return end
  if entry.is_dir then
    if mode == "edit" then toggle_dir(entry) end
    return
  end

  local cmd = ({ edit = "edit", split = "split", vsplit = "vsplit", tab = "tabedit" })[mode] or "edit"
  local path = vim.fn.fnameescape(entry.path)

  if config.mode == "floating" then
    M.close()
    vim.cmd(cmd .. " " .. path)
    return
  end

  local target = window.find_editor_win()
  if target then
    vim.api.nvim_set_current_win(target)
    vim.cmd(cmd .. " " .. path)
  else
    -- No editor window exists; make one beside the sidebar.
    vim.api.nvim_set_current_win(window.sidebar_win)
    vim.cmd("rightbelow vertical split")
    vim.cmd("edit " .. path)
  end
end

-- Open a listed buffer (from the buffers pane) in an editor window.
local function open_listed(bufnr, mode)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  local cmd = ({ edit = "buffer", split = "sbuffer", vsplit = "vert sbuffer", tab = "tab sbuffer" })[mode] or "buffer"

  if config.mode == "floating" then
    M.close()
    vim.cmd(cmd .. " " .. bufnr)
    return
  end

  local target = window.find_editor_win()
  if target then
    vim.api.nvim_set_current_win(target)
    vim.cmd(cmd .. " " .. bufnr)
  else
    vim.api.nvim_set_current_win(window.sidebar_win)
    vim.cmd("rightbelow vertical split")
    vim.cmd("buffer " .. bufnr)
  end
end

local function toggle_expand()
  local entry = get_current_entry()
  if not entry then return end
  if entry.is_dir then
    toggle_dir(entry)
  else
    open_current("edit")
  end
end

-- l / <Right>: expand a directory (never collapses) or open a file.
local function expand_or_open()
  local entry = get_current_entry()
  if not entry then return end
  if entry.is_dir then
    if not tree.expanded_paths[entry.path] then
      tree.expanded_paths[entry.path] = true
      rebuild()
    end
  else
    open_current("edit")
  end
end

-- h / <Left>: collapse an expanded directory, otherwise jump to the parent.
local function collapse_or_parent()
  local entry = get_current_entry()
  if not entry then return end
  if entry.is_dir and tree.expanded_paths[entry.path] then
    tree.expanded_paths[entry.path] = nil
    rebuild()
    return
  end
  local parent = entry.path:match("^(.*)/[^/]+$")
  local row = parent and tree.row_for_path(parent)
  vim.api.nvim_win_set_cursor(window.sidebar_win, { row or 1, 0 })
end

-- .: make the directory under the cursor the tree root (changes cwd).
local function set_root()
  local entry = get_current_entry()
  if not entry or not entry.is_dir then return end
  vim.cmd("cd " .. vim.fn.fnameescape(entry.path))
  rebuild()
end

-- <BS>: move the tree root up to the parent directory.
local function root_up()
  local cwd = vim.fn.getcwd()
  local parent = cwd:match("^(.*)/[^/]+$")
  if not parent then return end
  if parent == "" then parent = "/" end
  tree.expanded_paths[cwd] = true  -- keep the old root visible and open
  vim.cmd("cd " .. vim.fn.fnameescape(parent))
  rebuild()
end

local function sidebar_actions()
  local function with_entry(fn)
    return function() fn(get_current_entry(), config) end
  end
  return {
    -- navigation
    move_up            = move_up,
    move_down          = move_down,
    toggle_expand      = toggle_expand,
    expand_or_open     = expand_or_open,
    collapse_or_parent = collapse_or_parent,
    focus_editor       = window.focus_editor,
    close_all          = function()
      tree.expanded_paths = {}
      rebuild()
      vim.api.nvim_win_set_cursor(window.sidebar_win, { 1, 0 })
    end,
    set_root           = set_root,
    root_up            = root_up,
    -- opening
    open_split  = function() open_current("split") end,
    open_vsplit = function() open_current("vsplit") end,
    open_tab    = function() open_current("tab") end,
    -- file operations
    add               = with_entry(actions.add),
    add_directory     = with_entry(actions.add_directory),
    delete            = with_entry(actions.delete),
    rename            = with_entry(actions.rename),
    move              = with_entry(actions.move),
    copy              = with_entry(actions.copy),
    copy_to_clipboard = with_entry(actions.copy_to_clipboard),
    cut_to_clipboard  = with_entry(actions.cut_to_clipboard),
    paste             = with_entry(actions.paste),
    -- view
    toggle_hidden = function()
      tree.show_hidden = not tree.show_hidden
      rebuild()
    end,
    refresh = function()
      rebuild()
      git.refresh_all()
    end,
    help = actions.show_help,
    -- filter (neo-tree filesystem defaults)
    fuzzy_finder = function()
      filter.start({ live = true, fuzzy_finder = true })
    end,
    fuzzy_finder_directory = function()
      filter.start({ live = true, fuzzy_finder = true, kind = "directory" })
    end,
    fuzzy_sorter = function()
      filter.start({ live = true, fuzzy_finder = true, use_fzy = true })
    end,
    filter_on_submit = function()
      filter.start({ live = false, keep_on_submit = true })
    end,
    clear_filter = function()
      filter.clear()
    end,
    toggle_buffers = function()
      M.toggle_buffers()
    end,
    open_buffer = function()
      local e = buffers.entry_at_cursor()
      if e then open_listed(e.bufnr, "edit") end
    end,
    -- h / <Left>: same idea as the tree (collapse / parent). The buffers
    -- list is flat, so this jumps to the file tree below.
    buffers_collapse = function()
      if window.sidebar_win and vim.api.nvim_win_is_valid(window.sidebar_win) then
        vim.api.nvim_set_current_win(window.sidebar_win)
      end
    end,
    open_buffer_split = function()
      local e = buffers.entry_at_cursor()
      if e then open_listed(e.bufnr, "split") end
    end,
    open_buffer_vsplit = function()
      local e = buffers.entry_at_cursor()
      if e then open_listed(e.bufnr, "vsplit") end
    end,
    open_buffer_tab = function()
      local e = buffers.entry_at_cursor()
      if e then open_listed(e.bufnr, "tab") end
    end,
    delete_buffer = function()
      local e = buffers.entry_at_cursor()
      if not e then return end
      if vim.bo[e.bufnr].modified then
        if vim.fn.confirm("Buffer is modified. Delete anyway?", "&Yes\n&No", 2) ~= 1 then
          return
        end
      end
      pcall(vim.cmd, "bdelete! " .. e.bufnr)
      render_buffers()
    end,
    -- close
    close = M.close,
  }
end

filter.set_callbacks({
  get_config   = function() return config end,
  rebuild      = rebuild,
  open_current = toggle_expand,
  move_up      = move_up,
  move_down    = move_down,
})

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function M.open()
  if window.is_open() then
    vim.api.nvim_set_current_win(window.sidebar_win)
    return
  end

  local buf = window.create_or_get_buffer()
  local is_split = config.mode == "pinned" or config.mode == "sidebar"

  if is_split then
    window.sidebar_win = window.create_pinned_window(buf, config.width)
  else
    window.sidebar_win = window.create_floating_window(buf, config.width)
  end

  tree.build_tree(config)
  tree.render(buf, config)
  -- In sidebar mode <Esc> stays unmapped: the tree is a persistent window,
  -- not a popup to dismiss.
  window.setup_keymaps(buf, sidebar_actions(), { esc_closes = config.mode ~= "sidebar" })

  if config.buffers.enable then
    M.toggle_buffers()
  end

  if is_split then
    vim.bo[buf].filetype = "SuperTree"
    vim.cmd("redrawtabline")
    vim.api.nvim_exec_autocmds("User", { pattern = "SuperTreeOpen" })
  end
end

function M.toggle_buffers()
  if not window.is_open() then return end
  if window.buffers_visible then
    window.close_buffers_window()
    return
  end
  local buf = window.open_buffers_window(config.buffers.height)
  if buf then
    buffers.render(buf, config)
    window.setup_buffers_keymaps(buf, sidebar_actions(), { esc_closes = config.mode ~= "sidebar" })
  end
end

function M.close()
  filter.close_input(false)
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

-- Focus the sidebar window, opening it first if necessary.
function M.focus()
  if window.is_open() then
    vim.api.nvim_set_current_win(window.sidebar_win)
  else
    M.open()
  end
end

-- Reveal `path` (default: current buffer) in the tree: expand its ancestor
-- directories and move the sidebar cursor to it.
function M.reveal(path)
  if not window.is_open() then return end
  path = path or vim.api.nvim_buf_get_name(0)
  if path == "" then return end

  local cwd = vim.fn.getcwd()
  if path:sub(1, #cwd + 1) ~= cwd .. "/" then return end

  local changed = false
  local dir = path:match("^(.*)/[^/]+$")
  while dir and #dir > #cwd do
    if not tree.expanded_paths[dir] then
      tree.expanded_paths[dir] = true
      changed = true
    end
    dir = dir:match("^(.*)/[^/]+$")
  end
  if changed then
    rebuild()
  end

  local row = tree.row_for_path(path)
  if not row then return end  -- not visible (e.g. filtered out)
  pcall(vim.api.nvim_win_set_cursor, window.sidebar_win, { row, 0 })
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

-- Darken a 24-bit color (integer) by `factor` and return "#rrggbb".
local function darken(color, factor)
  local r = math.floor(math.floor(color / 65536) % 256 * factor)
  local g = math.floor(math.floor(color / 256) % 256 * factor)
  local b = math.floor(color % 256 * factor)
  return string.format("#%02x%02x%02x", r, g, b)
end

-- Background color of the Normal group, or nil (e.g. transparent themes).
local function normal_bg()
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = "Normal", link = false })
  if ok and hl and hl.bg then return hl.bg end
  local ok2, hl2 = pcall(vim.api.nvim_get_hl_by_name, "Normal", true)
  if ok2 and hl2 and hl2.background then return hl2.background end
  return nil
end

local function define_highlights()
  -- Sidebar background: darker than the editor background, like neo-tree
  -- themes do. Falls back to a fixed dark tone for transparent themes.
  local bg = normal_bg()
  local sidebar_bg = bg and darken(bg, 0.75) or "#101010"
  vim.api.nvim_set_hl(0, "SuperTreeNormal",       { bg = sidebar_bg, default = true })
  vim.api.nvim_set_hl(0, "SuperTreeNormalNC",     { link = "SuperTreeNormal", default = true })
  vim.api.nvim_set_hl(0, "SuperTreeEndOfBuffer",  { bg = sidebar_bg, fg = sidebar_bg, default = true })
  vim.api.nvim_set_hl(0, "SuperTreeCursorLine",   { link = "CursorLine", default = true })
  vim.api.nvim_set_hl(0, "SuperTreeWinSeparator", { link = "WinSeparator", default = true })

  vim.api.nvim_set_hl(0, "SuperTreeFilterTerm", { link = "Special", default = true })
  vim.api.nvim_set_hl(0, "SuperTreeDirectory", { link = "Directory", default = true })
  vim.api.nvim_set_hl(0, "SuperTreeIndent",    { fg = "#4b5263",    default = true })
  vim.api.nvim_set_hl(0, "SuperTreeGitRepo",   { fg = "#73c936",    default = true })
  vim.api.nvim_set_hl(0, "SuperTreeGitHub",    { fg = "#73c936",    default = true })
  -- Git status highlights (muted versions of neo-tree's palette so the
  -- indicators stay in the background visually).
  vim.api.nvim_set_hl(0, "SuperTreeGitAdded",       { fg = "#467a46", default = true })
  vim.api.nvim_set_hl(0, "SuperTreeGitDeleted",     { fg = "#a63a00", default = true })
  vim.api.nvim_set_hl(0, "SuperTreeGitModified",    { fg = "#967a42", default = true })
  vim.api.nvim_set_hl(0, "SuperTreeGitRenamed",     { link = "SuperTreeGitModified", default = true })
  vim.api.nvim_set_hl(0, "SuperTreeGitStaged",      { link = "SuperTreeGitAdded", default = true })
  vim.api.nvim_set_hl(0, "SuperTreeGitUnstaged",    { fg = "#b25e00", default = true })
  vim.api.nvim_set_hl(0, "SuperTreeGitUntracked",   { fg = "#467a46", italic = true, default = true })
  vim.api.nvim_set_hl(0, "SuperTreeGitIgnored",     { fg = "#4b5263", default = true })
  vim.api.nvim_set_hl(0, "SuperTreeGitConflict",    { fg = "#b25e00", bold = true, italic = true, default = true })
  vim.api.nvim_set_hl(0, "SuperTreeGitBranch",      { fg = "#518c26", default = true })
  vim.api.nvim_set_hl(0, "SuperTreeGitAheadBehind", { fg = "#967a42", default = true })
  vim.api.nvim_set_hl(0, "SuperTreeGitClean",       { fg = "#467a46", default = true })
  vim.api.nvim_set_hl(0, "SuperTreeDiagnosticError", { link = "DiagnosticError", default = true })
  vim.api.nvim_set_hl(0, "SuperTreeDiagnosticWarn",  { link = "DiagnosticWarn",  default = true })
  vim.api.nvim_set_hl(0, "SuperTreeDiagnosticInfo",  { link = "DiagnosticInfo",  default = true })
  vim.api.nvim_set_hl(0, "SuperTreeDiagnosticHint",  { link = "DiagnosticHint",  default = true })
  vim.api.nvim_set_hl(0, "SuperTreeBuffersCurrent",  { bold = true, default = true })
  icons.setup_highlights()
end

function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})
  window.open_files_do_not_replace_types = config.open_files_do_not_replace_types

  define_highlights()

  vim.api.nvim_create_user_command("SuperTree",       M.toggle,                  {})
  vim.api.nvim_create_user_command("SuperTreeOpen",   M.open,                    {})
  vim.api.nvim_create_user_command("SuperTreeClose",  M.close,                   {})
  vim.api.nvim_create_user_command("SuperTreeFocus",  M.focus,                   {})
  vim.api.nvim_create_user_command("SuperTreeReveal", function() M.reveal() end, {})

  vim.api.nvim_create_autocmd("User", {
    pattern  = "SuperTreeOpen",
    callback = function() vim.cmd("redrawtabline") end,
  })

  vim.api.nvim_create_autocmd("User", {
    pattern  = "SuperTreeClose",
    callback = function() vim.cmd("redrawtabline") end,
  })

  local group = vim.api.nvim_create_augroup("SuperTree", { clear = true })

  -- Re-derive highlights (including the darkened sidebar background) when
  -- the colorscheme changes, since :colorscheme clears them.
  vim.api.nvim_create_autocmd("ColorScheme", {
    group    = group,
    callback = define_highlights,
  })

  -- Sidebar mode: when the last editor window quits, close the sidebar too
  -- so Neovim can exit instead of leaving an orphaned tree window.
  vim.api.nvim_create_autocmd("QuitPre", {
    group    = group,
    callback = function()
      if config.mode ~= "sidebar" then return end
      if not window.is_open() then return end
      local quitting = vim.api.nvim_get_current_win()
      if quitting == window.sidebar_win or quitting == window.buffers_win then return end
      for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if w ~= quitting and w ~= window.sidebar_win and w ~= window.buffers_win
            and vim.api.nvim_win_get_config(w).relative == "" then
          return  -- another normal window remains; nothing to do
        end
      end
      M.close()
    end,
  })

  -- Clean up plugin state when the sidebar window is closed externally
  -- (e.g. :q inside the sidebar, or <C-w>c).
  vim.api.nvim_create_autocmd("WinClosed", {
    group    = group,
    callback = function(args)
      local win = tonumber(args.match)
      if win and win == window.sidebar_win then
        window.sidebar_win = nil
        window.close_buffers_window()
        git.reset()
      elseif win and win == window.buffers_win then
        window.buffers_win = nil
        window.buffers_visible = false
      end
    end,
  })

  -- Propagate git status control to the git module and refresh status when
  -- files are written, even if they live outside the visible tree.
  git.status_enabled = config.git.enable and config.git.status.enable
  diagnostics.enabled = config.diagnostics.enable ~= false

  vim.api.nvim_create_autocmd("BufWritePost", {
    group    = group,
    callback = function(args)
      if not window.is_open() then return end
      if not git.status_enabled then return end
      local name = vim.api.nvim_buf_get_name(args.buf)
      if name ~= "" then
        git.refresh_path(name)
      end
    end,
  })

  -- Follow the current file: reveal it in the tree whenever a normal
  -- buffer is entered outside the sidebar.
  vim.api.nvim_create_autocmd("BufEnter", {
    group    = group,
    callback = function(args)
      if not config.follow_current_file then return end
      if filter.is_active() then return end
      if not window.is_open() then return end
      local curwin = vim.api.nvim_get_current_win()
      if curwin == window.sidebar_win or curwin == window.buffers_win then return end
      if vim.bo[args.buf].buftype ~= "" then return end
      local name = vim.api.nvim_buf_get_name(args.buf)
      if name ~= "" then
        M.reveal(name)
      end
      render_buffers()
    end,
  })

  vim.api.nvim_create_autocmd({ "BufAdd", "BufDelete", "BufModifiedSet", "BufFilePost" }, {
    group    = group,
    callback = function()
      if window.is_open() then
        vim.schedule(render_buffers)
      end
    end,
  })

  -- Re-render when the sidebar width changes so repo branch names can
  -- hide/show instead of overlapping the path.
  local function rerender_on_resize()
    if window.is_open() then
      tree.render(window.sidebar_buf, config)
    end
  end
  vim.api.nvim_create_autocmd("VimResized", {
    group    = group,
    callback = rerender_on_resize,
  })
  if vim.fn.exists("##WinResized") == 1 then
    vim.api.nvim_create_autocmd("WinResized", {
      group    = group,
      callback = rerender_on_resize,
    })
  end

  vim.api.nvim_create_autocmd("DiagnosticChanged", {
    group    = group,
    callback = function()
      if not window.is_open() then return end
      if not diagnostics.enabled then return end
      vim.schedule(function()
        diagnostics.refresh()
        if window.is_open() then
          tree.render(window.sidebar_buf, config)
        end
        render_buffers()
      end)
    end,
  })
end

return M
