-- Buffer and window management for the tree sidebar.
-- Exposes functions to create/destroy the buffer and window, query state,
-- and set up buffer-local keymaps.

local M = {}

M.sidebar_buf = nil
M.sidebar_win = nil

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
  vim.api.nvim_buf_set_name(M.sidebar_buf, "tree-sidebar://sidebar")
  vim.bo[M.sidebar_buf].buftype   = "nofile"
  vim.bo[M.sidebar_buf].bufhidden = "wipe"
  vim.bo[M.sidebar_buf].buflisted = false
  vim.bo[M.sidebar_buf].swapfile  = false
  vim.bo[M.sidebar_buf].filetype  = "tree-sidebar"

  vim.api.nvim_create_autocmd("BufWinEnter", {
    buffer = M.sidebar_buf,
    callback = function()
      vim.bo[M.sidebar_buf].filetype = "tree-sidebar"
      vim.schedule(function()
        vim.cmd("redrawtabline")
        vim.api.nvim_exec_autocmds("User", { pattern = "TreeSidebarOpen" })
      end)
    end,
  })

  vim.api.nvim_create_autocmd("BufWinLeave", {
    buffer = M.sidebar_buf,
    callback = function()
      vim.schedule(function()
        vim.cmd("redrawtabline")
        vim.api.nvim_exec_autocmds("User", { pattern = "TreeSidebarClose" })
      end)
    end,
  })

  return M.sidebar_buf
end

-- ---------------------------------------------------------------------------
-- Window creation
-- ---------------------------------------------------------------------------

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

  return win
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
  vim.wo[win].statusline     = " Tree Sidebar"

  return win
end

-- ---------------------------------------------------------------------------
-- Keymaps
-- ---------------------------------------------------------------------------

-- Set up buffer-local keymaps.
-- `actions` must be a table with keys: move_up, move_down, toggle_expand, close.
function M.setup_keymaps(buf, actions)
  local opts = { buffer = buf, nowait = true, silent = true }

  vim.keymap.set("n", "<Up>",   actions.move_up,       opts)
  vim.keymap.set("n", "<Down>", actions.move_down,     opts)
  vim.keymap.set("n", "<CR>",   actions.toggle_expand, opts)
  vim.keymap.set("n", "q",      actions.close,         opts)
  vim.keymap.set("n", "<Esc>",  actions.close,         opts)

  local nop_keys = {
    -- visual
    "v", "V", "<C-v>", "gv",
    -- insert
    "i", "I", "a", "A", "o", "O", "s", "S", "c", "C", "R",
    -- edit
    "d", "D", "dd", "x", "X", "r", "J", "<<", ">>", "gu", "gU", "g~", "~",
    -- motion
    "w", "W", "b", "B", "e", "E", "ge", "gE", "f", "F", "t", "T",
    "%", "{", "}", "(", ")", "[[", "]]", "gg", "G", "H", "M", "L",
    "h", "l", "<Left>", "<Right>", "<Space>", "<Backspace>",
    -- yank / put
    "y", "Y", "yy", "p", "P",
    -- misc
    "u", "<C-r>", ".", "@", "/", "?", "*", "#", "n", "N", "<C-w>",
  }

  for _, key in ipairs(nop_keys) do
    vim.keymap.set("n", key, "<Nop>", opts)
  end
end

-- ---------------------------------------------------------------------------
-- State queries
-- ---------------------------------------------------------------------------

function M.is_open()
  return M.sidebar_win ~= nil and vim.api.nvim_win_is_valid(M.sidebar_win)
end

function M.close_window()
  if M.sidebar_win and vim.api.nvim_win_is_valid(M.sidebar_win) then
    vim.api.nvim_win_close(M.sidebar_win, true)
    M.sidebar_win = nil
  end
end

return M
