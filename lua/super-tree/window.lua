-- Buffer and window management for the tree sidebar.
-- Exposes functions to create/destroy the buffer and window, query state,
-- and set up buffer-local keymaps.

local M = {}

M.sidebar_buf = nil
M.sidebar_win = nil
M.buffers_buf = nil
M.buffers_win = nil
M.buffers_visible = false
-- Original float height of the tree window, restored when the buffers pane closes.
local float_tree_height = nil

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

function M.create_or_get_buffer()
  if M.sidebar_buf and vim.api.nvim_buf_is_valid(M.sidebar_buf) then
    return M.sidebar_buf
  end

  M.sidebar_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(M.sidebar_buf, "SuperTree://sidebar")
  vim.bo[M.sidebar_buf].buftype   = "nofile"
  -- "hide", not "wipe": when a foreign buffer briefly enters the sidebar
  -- window, the sidebar buffer must survive so the guard can restore it.
  vim.bo[M.sidebar_buf].bufhidden = "hide"
  vim.bo[M.sidebar_buf].buflisted = false
  vim.bo[M.sidebar_buf].swapfile  = false
  vim.bo[M.sidebar_buf].filetype  = "SuperTree"

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

        -- Find an existing non-sidebar window to send the buffer to.
        local target_win = M.find_editor_win()

        if target_win then
          vim.api.nvim_set_current_win(target_win)
          vim.api.nvim_win_set_buf(target_win, entered_buf)
        else
          -- No suitable window exists; open a new split to the right of the sidebar.
          vim.api.nvim_set_current_win(win)
          vim.cmd("rightbelow vertical split")
          vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), entered_buf)
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
  local tabline_height = get_tabline_height()
  local win_config = {
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

  local win = vim.api.nvim_open_win(buf, true, win_config)

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
  opts = opts or {}
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

function M.create_or_get_buffers_buffer()
  if M.buffers_buf and vim.api.nvim_buf_is_valid(M.buffers_buf) then
    return M.buffers_buf
  end
  M.buffers_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(M.buffers_buf, "SuperTree://buffers")
  vim.bo[M.buffers_buf].buftype   = "nofile"
  vim.bo[M.buffers_buf].bufhidden = "hide"
  vim.bo[M.buffers_buf].buflisted = false
  vim.bo[M.buffers_buf].swapfile  = false
  vim.bo[M.buffers_buf].filetype  = "SuperTree"
  return M.buffers_buf
end

-- Open the buffers pane above the tree window. Independently scrollable
-- and resizable (`<C-w>+/-` or mouse drag on the split).
function M.open_buffers_window(height)
  if not M.is_open() then return nil end
  if M.buffers_win and vim.api.nvim_win_is_valid(M.buffers_win) then
    return M.buffers_buf
  end

  local buf = M.create_or_get_buffers_buffer()
  height = math.max(tonumber(height) or 8, 3)
  local cfg = vim.api.nvim_win_get_config(M.sidebar_win)

  if cfg.relative ~= "" then
    local tree_h = cfg.height
    local buf_h = math.min(height, math.max(tree_h - 6, 3))
    float_tree_height = tree_h
    local row = cfg.row
    local col = cfg.col
    vim.api.nvim_win_set_config(M.sidebar_win, {
      relative = cfg.relative,
      width    = cfg.width,
      height   = tree_h - buf_h,
      col      = col,
      row      = row + buf_h,
      anchor   = cfg.anchor,
      style    = cfg.style,
      border   = cfg.border,
      zindex   = cfg.zindex,
    })
    M.buffers_win = vim.api.nvim_open_win(buf, false, {
      relative = "editor",
      width    = cfg.width,
      height   = buf_h,
      col      = col,
      row      = row,
      anchor   = "NW",
      style    = "minimal",
      border   = "none",
      zindex   = 40,
    })
    apply_win_opts(M.buffers_win, { statusline = "" })
  else
    vim.api.nvim_set_current_win(M.sidebar_win)
    vim.cmd("aboveleft split")
    M.buffers_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(M.buffers_win, buf)
    vim.api.nvim_win_set_height(M.buffers_win, height)
    apply_win_opts(M.buffers_win, { statusline = " Buffers", winfixwidth = true })
    vim.wo[M.sidebar_win].winfixheight = false
    vim.wo[M.buffers_win].winfixheight = false
    vim.api.nvim_set_current_win(M.sidebar_win)
  end

  M.guard_window(M.buffers_win, buf)
  M.buffers_visible = true
  return buf
end

function M.close_buffers_window()
  if M.buffers_win and vim.api.nvim_win_is_valid(M.buffers_win) then
    local tree_ok = M.sidebar_win and vim.api.nvim_win_is_valid(M.sidebar_win)
    local cfg = tree_ok and vim.api.nvim_win_get_config(M.sidebar_win) or { relative = "" }
    vim.api.nvim_win_close(M.buffers_win, true)
    if cfg.relative ~= "" and float_tree_height and tree_ok and vim.api.nvim_win_is_valid(M.sidebar_win) then
      local tcfg = vim.api.nvim_win_get_config(M.sidebar_win)
      vim.api.nvim_win_set_config(M.sidebar_win, {
        relative = tcfg.relative,
        width    = tcfg.width,
        height   = float_tree_height,
        col      = tcfg.col,
        row      = get_tabline_height(),
        anchor   = tcfg.anchor,
        style    = tcfg.style,
        border   = tcfg.border,
        zindex   = tcfg.zindex,
      })
    elseif vim.api.nvim_win_is_valid(M.sidebar_win) then
      vim.wo[M.sidebar_win].winfixheight = true
    end
  end
  M.buffers_win = nil
  M.buffers_visible = false
  float_tree_height = nil
end

function M.create_pinned_window(buf, width)
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
    if not w or w == 0 or w == M.sidebar_win or w == M.buffers_win then return false end
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
function M.setup_keymaps(buf, actions, keymap_opts)
  keymap_opts = keymap_opts or {}
  local opts = { buffer = buf, nowait = true, silent = true }

  -- Disable keys that would edit the buffer or trigger confusing motions.
  -- Action mappings are set afterwards and take precedence. Window commands
  -- (<C-w> ...) and plain motions like j/k/gg/G stay enabled so the sidebar
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
    ["<Up>"]    = actions.move_up,
    ["<Down>"]  = actions.move_down,
    ["<CR>"]           = actions.toggle_expand,
    ["<2-LeftMouse>"]  = actions.toggle_expand,
    ["l"]       = actions.expand_or_open,
    ["<Right>"] = actions.expand_or_open,
    ["h"]       = actions.collapse_or_parent,
    ["<Left>"]  = actions.collapse_or_parent,
    ["<Tab>"]   = actions.focus_editor,
    ["z"]       = actions.close_all,
    ["."]       = actions.set_root,
    ["<BS>"]    = actions.root_up,
    -- opening
    ["S"] = actions.open_split,
    ["s"] = actions.open_vsplit,
    ["t"] = actions.open_tab,
    -- file operations
    ["a"] = actions.add,
    ["A"] = actions.add_directory,
    ["d"] = actions.delete,
    ["r"] = actions.rename,
    ["m"] = actions.move,
    ["c"] = actions.copy,
    ["y"] = actions.copy_to_clipboard,
    ["x"] = actions.cut_to_clipboard,
    ["p"] = actions.paste,
    -- view
    ["H"] = actions.toggle_hidden,
    ["R"] = actions.refresh,
    ["?"] = actions.help,
    -- filter
    ["/"]     = actions.fuzzy_finder,
    ["D"]     = actions.fuzzy_finder_directory,
    ["#"]     = actions.fuzzy_sorter,
    ["f"]     = actions.filter_on_submit,
    ["<C-x>"] = actions.clear_filter,
    ["B"]     = actions.toggle_buffers,
    -- close
    ["q"]     = actions.close,
    ["<Esc>"] = (keymap_opts.esc_closes ~= false) and actions.close or nil,
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
  M.close_buffers_window()
  if M.sidebar_win and vim.api.nvim_win_is_valid(M.sidebar_win) then
    vim.api.nvim_win_close(M.sidebar_win, true)
    M.sidebar_win = nil
  end
end

function M.setup_buffers_keymaps(buf, actions, keymap_opts)
  keymap_opts = keymap_opts or {}
  local opts = { buffer = buf, nowait = true, silent = true }
  local map = {
    ["<CR>"]          = actions.open_buffer,
    ["<2-LeftMouse>"] = actions.open_buffer,
    ["l"]             = actions.open_buffer,
    ["d"]             = actions.delete_buffer,
    ["S"]             = actions.open_buffer_split,
    ["s"]             = actions.open_buffer_vsplit,
    ["t"]             = actions.open_buffer_tab,
    ["<Tab>"]         = actions.focus_editor,
    ["B"]             = actions.toggle_buffers,
    ["R"]             = actions.refresh,
    ["?"]             = actions.help,
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
