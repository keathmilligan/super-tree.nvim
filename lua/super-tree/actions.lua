-- File operations and helper popups for the tree sidebar.
-- These mirror neo-tree's filesystem commands: add, add_directory, delete,
-- rename, move, copy, and clipboard-style copy/cut/paste.

local git    = require("super-tree.git")
local tree   = require("super-tree.tree")
local window = require("super-tree.window")

local M = {}

local uv = vim.loop

-- { path = string, op = "copy" | "cut" } or nil
M.clipboard = nil

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function parent_dir(path)
  return path:match("^(.*)/[^/]+$")
end

local function basename(path)
  return path:match("([^/]+)/*$")
end

local function notify(msg, level)
  vim.notify("super-tree: " .. msg, level or vim.log.levels.INFO)
end

-- Rebuild and re-render the tree.
function M.refresh(config)
  tree.build_tree(config)
  if window.is_open() then
    tree.render(window.sidebar_buf, config)
  end
end

-- Directory that receives new/pasted nodes for the entry under the cursor:
-- the entry itself when it is a directory, otherwise its parent. Falls back
-- to the cwd when the cursor is on a header line.
local function target_dir(entry)
  if not entry then return vim.fn.getcwd() end
  if entry.is_dir then return entry.path end
  return parent_dir(entry.path) or vim.fn.getcwd()
end

local function ensure_parents(path)
  local dir = parent_dir(path)
  if dir and dir ~= "" then
    vim.fn.mkdir(dir, "p")
  end
end

-- Move the sidebar cursor to `path` if it is visible.
local function focus_path(path)
  local row = tree.row_for_path(path)
  if row and window.is_open() then
    pcall(vim.api.nvim_win_set_cursor, window.sidebar_win, { row, 0 })
  end
end

-- Expand every ancestor directory of `path` below the cwd so a newly
-- created node is visible.
local function expand_ancestors(path)
  local cwd = vim.fn.getcwd()
  local dir = parent_dir(path)
  while dir and #dir > #cwd do
    tree.expanded_paths[dir] = true
    dir = parent_dir(dir)
  end
end

local function copy_recursive(src, dst)
  local stat = uv.fs_stat(src)
  if not stat then
    return false, "source does not exist: " .. src
  end
  if stat.type == "directory" then
    vim.fn.mkdir(dst, "p")
    local handle = uv.fs_scandir(src)
    if handle then
      while true do
        local name = uv.fs_scandir_next(handle)
        if not name then break end
        local ok, err = copy_recursive(src .. "/" .. name, dst .. "/" .. name)
        if not ok then return false, err end
      end
    end
    return true
  end
  ensure_parents(dst)
  local ok, err = uv.fs_copyfile(src, dst)
  if not ok then return false, err end
  return true
end

-- Update expanded_paths keys after `old` was renamed/moved to `new` so the
-- moved subtree stays expanded.
local function remap_expanded(old, new)
  local updated = {}
  for p in pairs(tree.expanded_paths) do
    if p == old then
      updated[new] = true
    elseif p:sub(1, #old + 1) == old .. "/" then
      updated[new .. p:sub(#old + 1)] = true
    else
      updated[p] = true
    end
  end
  tree.expanded_paths = updated
end

local function do_move(src, dst, config)
  if uv.fs_stat(dst) then
    notify("already exists: " .. dst, vim.log.levels.WARN)
    return false
  end
  ensure_parents(dst)
  local ok = uv.fs_rename(src, dst)
  if not ok then
    -- Cross-device fallback: copy then delete.
    local cok, err = copy_recursive(src, dst)
    if not cok then
      notify("move failed: " .. tostring(err), vim.log.levels.ERROR)
      return false
    end
    vim.fn.delete(src, "rf")
  end
  remap_expanded(src, dst)
  M.refresh(config)
  focus_path(dst)
  git.refresh_path(parent_dir(src) or src)
  git.refresh_path(dst)
  return true
end

-- ---------------------------------------------------------------------------
-- Commands (neo-tree filesystem parity)
-- ---------------------------------------------------------------------------

-- a: create a file (or directory when the name ends with /). Missing parent
-- directories are created, so nested paths like "a/b/c.txt" work.
function M.add(entry, config)
  local base = target_dir(entry)
  vim.ui.input({ prompt = "Add (end with / for a directory): " .. base .. "/" }, function(name)
    if not name or name == "" then return end
    local path = base .. "/" .. name
    if name:sub(-1) == "/" then
      path = path:gsub("/+$", "")
      vim.fn.mkdir(path, "p")
    else
      if uv.fs_stat(path) then
        notify("already exists: " .. path, vim.log.levels.WARN)
        return
      end
      ensure_parents(path)
      local f = io.open(path, "w")
      if not f then
        notify("could not create " .. path, vim.log.levels.ERROR)
        return
      end
      f:close()
    end
    expand_ancestors(path)
    M.refresh(config)
    focus_path(path)
    git.refresh_path(path)
  end)
end

-- A: create a directory.
function M.add_directory(entry, config)
  local base = target_dir(entry)
  vim.ui.input({ prompt = "New directory: " .. base .. "/" }, function(name)
    if not name or name == "" then return end
    local path = (base .. "/" .. name):gsub("/+$", "")
    vim.fn.mkdir(path, "p")
    expand_ancestors(path)
    M.refresh(config)
    focus_path(path)
    git.refresh_path(path)
  end)
end

-- d: delete the node under the cursor (recursively for directories).
function M.delete(entry, config)
  if not entry then return end
  local kind = entry.is_dir and "directory" or "file"
  if vim.fn.confirm("Delete " .. kind .. " " .. entry.path .. "?", "&Yes\n&No", 2) ~= 1 then
    return
  end
  if vim.fn.delete(entry.path, "rf") ~= 0 then
    notify("delete failed: " .. entry.path, vim.log.levels.ERROR)
    return
  end
  tree.expanded_paths[entry.path] = nil
  M.refresh(config)
  git.refresh_path(parent_dir(entry.path) or entry.path)
end

-- r: rename within the same directory.
function M.rename(entry, config)
  if not entry then return end
  vim.ui.input({ prompt = "Rename to: ", default = entry.name }, function(name)
    if not name or name == "" or name == entry.name then return end
    local dir = parent_dir(entry.path)
    if not dir then return end
    do_move(entry.path, dir .. "/" .. name, config)
  end)
end

-- m: move to an arbitrary path.
function M.move(entry, config)
  if not entry then return end
  vim.ui.input({ prompt = "Move to: ", default = entry.path }, function(dst)
    if not dst or dst == "" or dst == entry.path then return end
    do_move(entry.path, dst:gsub("/+$", ""), config)
  end)
end

-- c: copy to an arbitrary path.
function M.copy(entry, config)
  if not entry then return end
  vim.ui.input({ prompt = "Copy to: ", default = entry.path }, function(dst)
    if not dst or dst == "" or dst == entry.path then return end
    dst = dst:gsub("/+$", "")
    if uv.fs_stat(dst) then
      notify("already exists: " .. dst, vim.log.levels.WARN)
      return
    end
    local ok, err = copy_recursive(entry.path, dst)
    if not ok then
      notify("copy failed: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    M.refresh(config)
    focus_path(dst)
    git.refresh_path(dst)
  end)
end

-- y: put the node on the internal clipboard for pasting.
function M.copy_to_clipboard(entry)
  if not entry then return end
  M.clipboard = { path = entry.path, op = "copy" }
  notify("copied " .. entry.name)
end

-- x: like y, but pasting moves instead of copies.
function M.cut_to_clipboard(entry)
  if not entry then return end
  M.clipboard = { path = entry.path, op = "cut" }
  notify("cut " .. entry.name)
end

-- p: paste the clipboard node into the directory under the cursor.
function M.paste(entry, config)
  if not M.clipboard then
    notify("clipboard is empty")
    return
  end
  local src = M.clipboard.path
  if not uv.fs_stat(src) then
    notify("clipboard source no longer exists: " .. src, vim.log.levels.WARN)
    M.clipboard = nil
    return
  end
  local dst = target_dir(entry) .. "/" .. basename(src)
  if dst == src then
    notify("source and destination are the same")
    return
  end
  if M.clipboard.op == "cut" then
    if do_move(src, dst, config) then
      M.clipboard = nil
    end
  else
    if uv.fs_stat(dst) then
      notify("already exists: " .. dst, vim.log.levels.WARN)
      return
    end
    local ok, err = copy_recursive(src, dst)
    if not ok then
      notify("copy failed: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    M.refresh(config)
    focus_path(dst)
    git.refresh_path(dst)
  end
end

-- ---------------------------------------------------------------------------
-- Help popup
-- ---------------------------------------------------------------------------

local HELP_ENTRIES = {
  { "j / k / arrows", "move up / down" },
  { "<CR>",               "toggle directory / open file" },
  { "<2-LeftMouse>",      "toggle directory / open file" },
  { "l / <Right>",    "expand directory / open file" },
  { "h / <Left>",     "collapse directory / go to parent" },
  { "S",              "open in horizontal split" },
  { "s",              "open in vertical split" },
  { "t",              "open in new tab" },
  { "<Tab>",          "jump to editor window" },
  { "<C-w> ...",      "standard window commands" },
  { ".",              "set directory as root (:cd)" },
  { "<BS>",           "root to parent directory" },
  { "z",              "collapse all directories" },
  { "a",              "add file (name ending in / adds dir)" },
  { "A",              "add directory" },
  { "d",              "delete" },
  { "r",              "rename" },
  { "m",              "move to path" },
  { "c",              "copy to path" },
  { "y",              "copy node to clipboard" },
  { "x",              "cut node to clipboard" },
  { "p",              "paste clipboard node here" },
  { "H",                  "toggle hidden (dotfiles, gitignored)" },
  { "/",                  "live filter (fuzzy finder)" },
  { "D",                  "filter directories" },
  { "#",                  "fuzzy sorter" },
  { "f",                  "filter on submit" },
  { "<C-x>",              "clear filter" },
  { "B",                  "toggle buffers pane" },
  { "R",                  "refresh tree and git status" },
  { "?",              "this help" },
  { "q / <Esc>",      "close (<Esc> not in sidebar mode)" },
}

function M.show_help()
  local lines = { " SuperTree", "" }
  for _, item in ipairs(HELP_ENTRIES) do
    table.insert(lines, string.format("  %-14s %s", item[1], item[2]))
  end
  table.insert(lines, "")

  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = width + 2
  local height = #lines

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden  = "wipe"

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width    = width,
    height   = height,
    row      = math.max(0, math.floor((vim.o.lines - height) / 2)),
    col      = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style    = "minimal",
    border   = "rounded",
    zindex   = 60,
  })
  vim.wo[win].cursorline = false

  local function close_help()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  local opts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set("n", "q",     close_help, opts)
  vim.keymap.set("n", "<Esc>", close_help, opts)
  vim.keymap.set("n", "?",     close_help, opts)
end

return M
