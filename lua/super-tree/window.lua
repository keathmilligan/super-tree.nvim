-- Buffer and window management for the tree sidebar.
-- Exposes functions to create/destroy the buffer and window, query state,
-- and set up buffer-local keymaps.

local M = {}

M.sidebar_buf = nil
M.sidebar_win = nil
M.sidebar_width = 40
M.buffers_buf = nil
M.buffers_win = nil
M.buffers_visible = false
M.projects_buf = nil
M.projects_win = nil
local pane_heights = { buffers = 10, projects = 10 }

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function get_tabline_height()
  if vim.o.showtabline == 0 then return 0 end
  if vim.o.showtabline == 2 then return 1 end
  return #vim.api.nvim_list_tabpages() > 1 and 1 or 0
end

-- ---------------------------------------------------------------------------
-- Buffer
-- ---------------------------------------------------------------------------

-- Scratch options so :qa never prompts to save SuperTree:// buffers.
-- nvim_buf_set_lines marks a named buffer modified; callers must also
-- set `modified = false` after rewriting contents.
local function configure_scratch(buf, name)
  vim.api.nvim_buf_set_name(buf, name)
  vim.bo[buf].buftype   = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].buflisted = false
  vim.bo[buf].swapfile  = false
  vim.bo[buf].undofile  = false
  vim.bo[buf].modified  = false
  vim.bo[buf].filetype  = "SuperTree"
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      vim.bo[buf].modified = false
    end,
  })
end

function M.create_or_get_buffer()
  if M.sidebar_buf and vim.api.nvim_buf_is_valid(M.sidebar_buf) then
    return M.sidebar_buf
  end

  M.sidebar_buf = vim.api.nvim_create_buf(false, true)
  -- "hide", not "wipe": when a foreign buffer briefly enters the sidebar
  -- window, the sidebar buffer must survive so the guard can restore it.
  configure_scratch(M.sidebar_buf, "SuperTree://sidebar")

  vim.api.nvim_create_autocmd("BufWinEnter", {
    buffer = M.sidebar_buf,
    callback = function()
      vim.bo[M.sidebar_buf].filetype = "SuperTree"
      vim.schedule(function()
        vim.cmd("redrawtabline")
        vim.api.nvim_exec_autocmds("User", { pattern = "SuperTreeOpen" })
      end)
    end,
  })

  vim.api.nvim_create_autocmd("BufWinLeave", {
    buffer = M.sidebar_buf,
    callback = function()
      vim.schedule(function()
        vim.cmd("redrawtabline")
        vim.api.nvim_exec_autocmds("User", { pattern = "SuperTreeClose" })
      end)
    end,
  })

  return M.sidebar_buf
end

-- Guard the sidebar window against buffer replacement.
-- Call this once after the sidebar window is created.
-- If any buffer other than the sidebar buffer enters the sidebar window,
-- the sidebar buffer is restored and the foreign buffer is redirected to
-- the nearest non-sidebar window (opening a new split if none exists).
function M.guard_window(win, buf)
  vim.api.nvim_create_autocmd("BufEnter", {
    callback = function()
      -- Only act when the sidebar window is still open.
      if not (win and vim.api.nvim_win_is_valid(win)) then
        return true -- remove this autocmd
      end

      local current_win = vim.api.nvim_get_current_win()
      if current_win ~= win then return end

      local entered_buf = vim.api.nvim_get_current_buf()
      if entered_buf == buf then return end

      -- A foreign buffer has entered the sidebar window.  Redirect it.
      vim.schedule(function()
        if not (win and vim.api.nvim_win_is_valid(win)) then return end
        if vim.api.nvim_get_current_win() ~= win then return end

        -- Restore the sidebar buffer in the sidebar window.
        vim.api.nvim_win_set_buf(win, buf)

        local target_win = M.ensure_editor_win(M.sidebar_width)
        if target_win then
          vim.api.nvim_set_current_win(target_win)
          vim.api.nvim_win_set_buf(target_win, entered_buf)
        end
      end)
    end,
  })
end

-- ---------------------------------------------------------------------------
-- Window creation
-- ---------------------------------------------------------------------------

-- Window-local highlight remap giving the sidebar its darker background.
local WINHIGHLIGHT = table.concat({
  "Normal:SuperTreeNormal",
  "NormalNC:SuperTreeNormalNC",
  "NormalFloat:SuperTreeNormal",
  "EndOfBuffer:SuperTreeEndOfBuffer",
  "CursorLine:SuperTreeCursorLine",
  "SignColumn:SuperTreeNormal",
  "WinSeparator:SuperTreeWinSeparator",
}, ",")

function M.create_floating_window(buf, width)
  M.sidebar_width            = width
  local tabline_height       = get_tabline_height()
  local win_config           = {
    relative = "editor",
    width    = width,
    height   = vim.o.lines - vim.o.cmdheight - tabline_height - 1,
    col      = 0,
    row      = tabline_height,
    anchor   = "NW",
    style    = "minimal",
    border   = "none",
    zindex   = 40,
  }

  local win                  = vim.api.nvim_open_win(buf, true, win_config)

  vim.wo[win].number         = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn     = "no"
  vim.wo[win].foldcolumn     = "0"
  vim.wo[win].spell          = false
  vim.wo[win].cursorline     = true
  vim.wo[win].wrap           = false
  vim.wo[win].scrolloff      = 0
  vim.wo[win].sidescrolloff  = 0
  vim.wo[win].statusline     = ""
  vim.wo[win].winhighlight   = WINHIGHLIGHT

  M.guard_window(win, buf)

  return win
end

local function apply_win_opts(win, opts)
  opts                       = opts or {}
  vim.wo[win].number         = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn     = "no"
  vim.wo[win].foldcolumn     = "0"
  vim.wo[win].spell          = false
  vim.wo[win].cursorline     = true
  vim.wo[win].wrap           = false
  vim.wo[win].scrolloff      = 0
  vim.wo[win].sidescrolloff  = 0
  vim.wo[win].winhighlight   = WINHIGHLIGHT
  if opts.statusline ~= nil then
    vim.wo[win].statusline = opts.statusline
  end
  if opts.winfixwidth then
    vim.wo[win].winfixwidth = true
  end
  if opts.winfixheight then
    vim.wo[win].winfixheight = true
  end
end

local function create_pane_buffer(pane)
  local key = pane .. "_buf"
  if M[key] and vim.api.nvim_buf_is_valid(M[key]) then
    return M[key]
  end
  M[key] = vim.api.nvim_create_buf(false, true)
  configure_scratch(M[key], "SuperTree://" .. pane)
  return M[key]
end

-- All floating panes share one column, in Projects / Buffers / Tree order.
-- Recompute together so toggling either pane cannot overlap the other.
function M.layout_floating_panes()
  if not M.is_open() then return end
  local cfg = vim.api.nvim_win_get_config(M.sidebar_win)
  if cfg.relative == "" then return end
  local panes = {}
  for _, pane in ipairs({ "projects", "buffers" }) do
    local win = M[pane .. "_win"]
    if win and vim.api.nvim_win_is_valid(win) then
      panes[#panes + 1] = pane
    end
  end
  local row = get_tabline_height()
  local total = math.max(#panes + 1, vim.o.lines - vim.o.cmdheight - row - 1)
  local available = total - math.min(6, total - #panes)
  local requested = 0
  for _, pane in ipairs(panes) do requested = requested + pane_heights[pane] end
  for i, pane in ipairs(panes) do
    local height = math.min(pane_heights[pane], math.floor(available * pane_heights[pane] / requested))
    height = math.min(height, available - (#panes - i))
    height = math.max(1, height)
    vim.api.nvim_win_set_config(M[pane .. "_win"], {
      relative = "editor", row = row, col = cfg.col, width = cfg.width, height = height,
    })
    row = row + height
    total = total - height
    available = available - height
    requested = requested - pane_heights[pane]
  end
  vim.api.nvim_win_set_config(M.sidebar_win, {
    relative = "editor", row = row, col = cfg.col, width = cfg.width, height = total,
  })
end

-- Panes are real, independently scrollable/resizable windows in split modes.
local function open_pane(pane, height, title)
  if not M.is_open() then return nil end
  local key = pane .. "_win"
  if M[key] and vim.api.nvim_win_is_valid(M[key]) then return M[pane .. "_buf"] end
  local buf = create_pane_buffer(pane)
  height = math.max(tonumber(height) or pane_heights[pane], 3)
  pane_heights[pane] = height
  local cfg = vim.api.nvim_win_get_config(M.sidebar_win)

  if cfg.relative ~= "" then
    M[key] = vim.api.nvim_open_win(buf, false, {
      relative = "editor",
      width    = cfg.width,
      height   = 1,
      col      = cfg.col,
      row      = cfg.row,
      anchor   = "NW",
      style    = "minimal",
      border   = "none",
      zindex   = 40,
    })
    apply_win_opts(M[key], { statusline = "" })
    M.layout_floating_panes()
  else
    local current = vim.api.nvim_get_current_win()
    local sibling = pane == "projects" and M.buffers_win or M.projects_win
    local sibling_height = sibling and vim.api.nvim_win_is_valid(sibling)
        and vim.api.nvim_win_get_height(sibling) or nil
    local anchor = pane == "projects" and M.buffers_win or M.sidebar_win
    if not anchor or not vim.api.nvim_win_is_valid(anchor) then anchor = M.sidebar_win end
    vim.api.nvim_set_current_win(anchor)
    vim.cmd("aboveleft split")
    M[key] = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(M[key], buf)
    vim.api.nvim_win_set_height(M[key], height)
    -- Keep stacked panes at their height when other windows split or close
    -- ('equalalways'). The tree stays flexible and absorbs leftover space.
    -- winfixheight does not block <C-w>+/- or mouse resize.
    apply_win_opts(M[key], { statusline = " " .. title, winfixwidth = true, winfixheight = true })
    vim.wo[M.sidebar_win].winfixheight = false
    if sibling_height then
      -- :split can equalize the whole column. Keep the existing pane's
      -- user-adjusted height, taking the new pane's space from the tree.
      vim.wo[sibling].winfixheight = true
      vim.api.nvim_win_set_height(sibling, sibling_height)
    end
    vim.api.nvim_set_current_win(current)
  end

  M.guard_window(M[key], buf)
  return buf
end

local function close_pane(pane)
  local key = pane .. "_win"
  local sibling = pane == "projects" and M.buffers_win or M.projects_win
  local sibling_valid = sibling and vim.api.nvim_win_is_valid(sibling)
  local fixed = sibling_valid and vim.wo[sibling].winfixheight
  if sibling_valid then vim.wo[sibling].winfixheight = true end
  if M[key] and vim.api.nvim_win_is_valid(M[key]) then
    pcall(vim.api.nvim_win_close, M[key], true)
  end
  if sibling_valid and vim.api.nvim_win_is_valid(sibling) then
    vim.wo[sibling].winfixheight = fixed
  end
  M[key] = nil
  M.layout_floating_panes()
  if M.is_open() then
    vim.wo[M.sidebar_win].winfixheight = not (M.buffers_win or M.projects_win)
  end
end

function M.open_buffers_window(height)
  local buf = open_pane("buffers", height, "Buffers")
  M.buffers_visible = buf ~= nil
  return buf
end

function M.close_buffers_window()
  close_pane("buffers")
  M.buffers_visible = false
end

function M.open_projects_window(height)
  return open_pane("projects", height, "Projects")
end

function M.close_projects_window()
  close_pane("projects")
end

function M.get_pane_heights()
  local result = vim.deepcopy(pane_heights)
  if M.buffers_win and vim.api.nvim_win_is_valid(M.buffers_win) then
    result.buffers = vim.api.nvim_win_get_height(M.buffers_win)
  end
  if M.projects_win and vim.api.nvim_win_is_valid(M.projects_win) then
    result.projects = vim.api.nvim_win_get_height(M.projects_win)
  end
  return result
end

function M.set_pane_heights(heights)
  if type(heights) ~= "table" then return end
  for _, pane in ipairs({ "buffers", "projects" }) do
    local height = tonumber(heights[pane])
    if height and height > 0 then
      pane_heights[pane] = math.max(1, math.floor(height))
      local win = M[pane .. "_win"]
      if win and vim.api.nvim_win_is_valid(win)
          and vim.api.nvim_win_get_config(win).relative == "" then
        pcall(vim.api.nvim_win_set_height, win, pane_heights[pane])
      end
    end
  end
  M.layout_floating_panes()
end

function M.is_plugin_win(win)
  return win ~= nil and (win == M.sidebar_win or win == M.buffers_win or win == M.projects_win)
end

function M.create_pinned_window(buf, width)
  M.sidebar_width = width
  vim.cmd("topleft vertical split")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_width(win, width)

  vim.wo[win].number         = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn     = "no"
  vim.wo[win].foldcolumn     = "0"
  vim.wo[win].spell          = false
  vim.wo[win].cursorline     = true
  vim.wo[win].wrap           = false
  vim.wo[win].scrolloff      = 0
  vim.wo[win].sidescrolloff  = 0
  vim.wo[win].winfixwidth    = true
  vim.wo[win].winfixheight   = true
  vim.wo[win].statusline     = " SuperTree"
  vim.wo[win].winhighlight   = WINHIGHLIGHT

  M.guard_window(win, buf)

  return win
end

-- ---------------------------------------------------------------------------
-- Editor window helpers
-- ---------------------------------------------------------------------------

-- Filetypes/buftypes whose windows are never reused for opening files
-- (matches neo-tree's open_files_do_not_replace_types default).
M.open_files_do_not_replace_types = { "terminal", "Trouble", "qf", "edgy" }

-- Find a window suitable for displaying a file buffer: prefers the
-- previously-active window, otherwise the first suitable window in the
-- tabpage. Like neo-tree, any non-floating window is reused unless its
-- filetype or buftype is in open_files_do_not_replace_types.
-- Returns nil when none exists.
function M.find_editor_win()
  local function usable(w)
    if not w or w == 0 or M.is_plugin_win(w) then return false end
    if not vim.api.nvim_win_is_valid(w) then return false end
    if vim.api.nvim_win_get_config(w).relative ~= "" then return false end
    local b = vim.api.nvim_win_get_buf(w)
    local bt = vim.bo[b].buftype
    local ft = vim.bo[b].filetype
    if bt == "prompt" or ft == "SuperTree" or ft == "SuperTreeFilter" then return false end
    for _, t in ipairs(M.open_files_do_not_replace_types) do
      if bt == t or ft == t then return false end
    end
    return true
  end

  local prev = vim.fn.win_getid(vim.fn.winnr("#"))
  if usable(prev) then return prev end
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if usable(w) then return w end
  end
  return nil
end

-- Find any ordinary window beside SuperTree, including terminals and utility
-- windows that are intentionally unsafe as file-opening targets.
function M.find_non_plugin_win()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_is_valid(win) and not M.is_plugin_win(win)
        and vim.api.nvim_win_get_config(win).relative == "" then
      return win
    end
  end
  return nil
end

local function is_plugin_ft(bufnr)
  local ft = vim.bo[bufnr].filetype
  return ft == "SuperTree" or ft == "SuperTreeFilter"
end

-- Most recently used listed normal buffer, excluding `exclude` (a bufnr).
-- SuperTree buffers and non-file buftypes are skipped. Returns nil if none.
function M.find_replacement_buf(exclude)
  local best, best_time = nil, -1
  for _, info in ipairs(vim.fn.getbufinfo({ buflisted = 1 })) do
    local b = info.bufnr
    if b ~= exclude and vim.api.nvim_buf_is_valid(b) and not is_plugin_ft(b) then
      local bt = vim.bo[b].buftype
      if bt == "" or bt == "acwrite" then
        local t = info.lastused or 0
        if t > best_time then
          best, best_time = b, t
        end
      end
    end
  end
  return best
end

local function new_unnamed_buf()
  return vim.api.nvim_create_buf(true, false)
end

-- Switch every non-SuperTree window off `bufnr` so a later :bdelete does
-- not close those windows. Replacement is the MRU listed buffer, or a new
-- unnamed listed buffer if none remain.
function M.unshow_buffer(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  local replacement = M.find_replacement_buf(bufnr) or new_unnamed_buf()
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if not M.is_plugin_win(win)
        and vim.api.nvim_win_is_valid(win)
        and vim.api.nvim_win_get_config(win).relative == "" then
      vim.api.nvim_win_set_buf(win, replacement)
    end
  end
end

local function restore_sidebar_width(width)
  width = width or M.sidebar_width
  if not width then return end
  if M.sidebar_win and vim.api.nvim_win_is_valid(M.sidebar_win) then
    vim.api.nvim_win_set_width(M.sidebar_win, width)
  end
end

-- :vsplit/:vnew copy window-local options from the current window.
-- After splitting from the sidebar, restore normal editor settings.
local function reset_editor_win_opts(win)
  if not win or not vim.api.nvim_win_is_valid(win) then return end
  vim.wo[win].winhighlight   = ""
  vim.wo[win].winfixwidth    = false
  vim.wo[win].winfixheight   = false
  vim.wo[win].statusline     = ""
  vim.wo[win].signcolumn     = vim.go.signcolumn
  vim.wo[win].foldcolumn     = vim.go.foldcolumn
  vim.wo[win].number         = vim.go.number
  vim.wo[win].relativenumber = vim.go.relativenumber
  vim.wo[win].cursorline     = vim.go.cursorline
  vim.wo[win].wrap           = vim.go.wrap
  vim.wo[win].spell          = vim.go.spell
  vim.wo[win].scrolloff      = vim.go.scrolloff
  vim.wo[win].sidescrolloff  = vim.go.sidescrolloff
end

-- Return an editor window, creating a full-height split beside the tree
-- if none exists. No-op for floating mode. The new window shows the MRU
-- listed buffer, or a new unnamed listed buffer.
function M.ensure_editor_win(width)
  local existing = M.find_editor_win()
  if existing then return existing end
  if not M.is_open() then return nil end
  if vim.api.nvim_win_get_config(M.sidebar_win).relative ~= "" then
    return nil
  end

  local buf = M.find_replacement_buf() or new_unnamed_buf()
  vim.api.nvim_set_current_win(M.sidebar_win)
  vim.cmd("botright vsplit")
  local win = vim.api.nvim_get_current_win()
  reset_editor_win_opts(win)
  vim.api.nvim_win_set_buf(win, buf)
  restore_sidebar_width(width)
  return win
end

local function is_last_non_float(win)
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if w ~= win and vim.api.nvim_win_is_valid(w)
        and vim.api.nvim_win_get_config(w).relative == "" then
      return false
    end
  end
  return true
end

-- Jump out of the sidebar into an editor window.
function M.focus_editor()
  local w = M.find_editor_win()
  if w then
    vim.api.nvim_set_current_win(w)
  end
end

-- ---------------------------------------------------------------------------
-- Keymaps
-- ---------------------------------------------------------------------------

-- Set up buffer-local keymaps.
-- `actions` is a table of named callbacks; see the `map` table below.
-- `keymap_opts` (optional): { esc_closes = boolean } - when false, <Esc> is
-- left unmapped so the sidebar behaves like a persistent window.
local function disable_pane_splits(buf, opts)
  -- Splitting a plugin buffer duplicates it outside the managed pane layout.
  -- Keep the other <C-w> commands available for navigation and resizing.
  for _, key in ipairs({
    "<C-w>s",
    "<C-w>S",
    "<C-w><C-s>",
    "<C-w>v",
    "<C-w><C-v>",
  }) do
    vim.keymap.set("n", key, "<Nop>", opts)
  end
end

function M.setup_keymaps(buf, actions, keymap_opts)
  keymap_opts = keymap_opts or {}
  local opts = { buffer = buf, nowait = true, silent = true }
  disable_pane_splits(buf, opts)

  -- Disable keys that would edit the buffer or trigger confusing motions.
  -- Action mappings are set afterwards and take precedence. Window navigation
  -- and resizing plus plain motions like j/k/gg/G stay enabled so the sidebar
  -- can be navigated into and out of like a normal window.
  local nop_keys = {
    -- visual
    "v", "V", "<C-v>", "gv",
    -- insert
    "i", "I", "o", "O", "C",
    -- edit
    "D", "dd", "X", "J", "<<", ">>", "gu", "gU", "g~", "~",
    -- motion
    "w", "W", "b", "B", "e", "E", "ge", "gE", "F", "T",
    "%", "{", "}", "(", ")", "[[", "]]", "M", "L", "<Space>",
    -- yank / put
    "Y", "yy", "P",
    -- misc
    "u", "<C-r>", "@", "*", "n", "N",
  }
  for _, key in ipairs(nop_keys) do
    vim.keymap.set("n", key, "<Nop>", opts)
  end

  local map = {
    -- navigation
    ["<Up>"]          = actions.move_up,
    ["<Down>"]        = actions.move_down,
    ["<CR>"]          = actions.toggle_expand,
    ["<2-LeftMouse>"] = actions.toggle_expand,
    ["l"]             = actions.expand_or_open,
    ["<Right>"]       = actions.expand_or_open,
    ["h"]             = actions.collapse_or_parent,
    ["<Left>"]        = actions.collapse_or_parent,
    ["<Tab>"]         = actions.focus_editor,
    ["z"]             = actions.close_all,
    ["."]             = actions.set_root,
    ["<BS>"]          = actions.root_up,
    -- opening
    ["S"]             = actions.open_split,
    ["s"]             = actions.open_vsplit,
    ["t"]             = actions.open_tab,
    -- file operations
    ["a"]             = actions.add,
    ["A"]             = actions.add_directory,
    ["d"]             = actions.delete,
    ["r"]             = actions.rename,
    ["m"]             = actions.move,
    ["c"]             = actions.copy,
    ["y"]             = actions.copy_to_clipboard,
    ["x"]             = actions.cut_to_clipboard,
    ["p"]             = actions.paste,
    -- view
    ["H"]             = actions.toggle_hidden,
    ["R"]             = actions.refresh,
    ["?"]             = actions.help,
    -- filter
    ["/"]             = actions.fuzzy_finder,
    ["D"]             = actions.fuzzy_finder_directory,
    ["#"]             = actions.fuzzy_sorter,
    ["f"]             = actions.filter_on_submit,
    ["<C-x>"]         = actions.clear_filter,
    ["B"]             = actions.toggle_buffers,
    -- close
    ["q"]             = actions.close,
    ["<Esc>"]         = (keymap_opts.esc_closes ~= false) and actions.close or nil,
  }
  for key, fn in pairs(map) do
    if fn then
      vim.keymap.set("n", key, fn, opts)
    end
  end
end

-- ---------------------------------------------------------------------------
-- State queries
-- ---------------------------------------------------------------------------

function M.is_open()
  return M.sidebar_win ~= nil and vim.api.nvim_win_is_valid(M.sidebar_win)
end

function M.close_window()
  M.close_projects_window()
  M.close_buffers_window()
  if not (M.sidebar_win and vim.api.nvim_win_is_valid(M.sidebar_win)) then
    return
  end
  if is_last_non_float(M.sidebar_win) then
    pcall(function()
      vim.api.nvim_set_current_win(M.sidebar_win)
      vim.cmd("botright vnew")
      reset_editor_win_opts(vim.api.nvim_get_current_win())
    end)
  end
  pcall(vim.api.nvim_win_close, M.sidebar_win, true)
  M.sidebar_win = nil
end

function M.setup_projects_keymaps(buf, actions, keymap_opts)
  keymap_opts = keymap_opts or {}
  local opts = { buffer = buf, nowait = true, silent = true }
  disable_pane_splits(buf, opts)
  local map = {
    ["<CR>"]          = actions.switch_project,
    ["<2-LeftMouse>"] = actions.switch_project,
    ["l"]             = actions.switch_project,
    ["<Right>"]       = actions.switch_project,
    ["h"]             = actions.buffers_collapse,
    ["<Left>"]        = actions.buffers_collapse,
    ["<Tab>"]         = actions.focus_editor,
    ["B"]             = actions.toggle_buffers,
    ["R"]             = actions.refresh,
    ["?"]             = actions.help,
    ["/"]             = actions.fuzzy_finder,
    ["#"]             = actions.fuzzy_sorter,
    ["f"]             = actions.filter_on_submit,
    ["<C-x>"]         = actions.clear_filter,
    ["q"]             = actions.close,
    ["<Esc>"]         = (keymap_opts.esc_closes ~= false) and actions.close or nil,
  }
  for key, fn in pairs(map) do
    if fn then vim.keymap.set("n", key, fn, opts) end
  end
end

function M.setup_buffers_keymaps(buf, actions, keymap_opts)
  keymap_opts = keymap_opts or {}
  local opts = { buffer = buf, nowait = true, silent = true }
  disable_pane_splits(buf, opts)
  local map = {
    ["<CR>"]          = actions.open_buffer,
    ["<2-LeftMouse>"] = actions.open_buffer,
    ["l"]             = actions.open_buffer,
    ["<Right>"]       = actions.open_buffer,
    ["h"]             = actions.buffers_collapse,
    ["<Left>"]        = actions.buffers_collapse,
    ["d"]             = actions.delete_buffer,
    ["S"]             = actions.open_buffer_split,
    ["s"]             = actions.open_buffer_vsplit,
    ["t"]             = actions.open_buffer_tab,
    ["<Tab>"]         = actions.focus_editor,
    ["B"]             = actions.toggle_buffers,
    ["R"]             = actions.refresh,
    ["?"]             = actions.help,
    ["/"]             = actions.fuzzy_finder,
    ["#"]             = actions.fuzzy_sorter,
    ["f"]             = actions.filter_on_submit,
    ["<C-x>"]         = actions.clear_filter,
    ["q"]             = actions.close,
    ["<Esc>"]         = (keymap_opts.esc_closes ~= false) and actions.close or nil,
  }
  for key, fn in pairs(map) do
    if fn then
      vim.keymap.set("n", key, fn, opts)
    end
  end
end

return M
