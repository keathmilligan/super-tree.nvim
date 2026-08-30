-- File tree data management and buffer rendering.
-- Depends on icons.lua and git.lua; both must be required before use.

local icons       = require("super-tree.icons")
local git         = require("super-tree.git")
local diagnostics = require("super-tree.diagnostics")

local M = {}

-- Module-level state
M.tree_data      = {}  -- flat ordered list of visible entry tables
M.expanded_paths = {}  -- set of expanded directory paths
M.cwd_name       = ""  -- basename of cwd, shown as the root line
M.header_lines   = 1   -- buffer lines before tree entries (root + git status)
M.row_entry      = {}  -- 1-based buffer row -> tree entry (status lines map to the repo dir)
M.show_hidden    = false  -- when true, filtered_items filters are bypassed
M.search_pattern = nil    -- live / submitted filter term, or nil
M.search_matches = nil    -- abs paths of the current search hits
M.search_scores  = nil    -- path -> fzy-like score (sorter mode only)
M.search_kind    = nil    -- nil (files+dirs) or "directory"

-- Namespace for extmark highlights (shared with window module via sidebar_buf)
local ns = vim.api.nvim_create_namespace("SuperTree")

-- ---------------------------------------------------------------------------
-- Filtering
-- ---------------------------------------------------------------------------

-- True when git status data marks `path` (or an ancestor) as ignored.
local function is_gitignored(path)
  local root = git.find_repo_root(path)
  if not root then return false end
  local st = git.repo_status[root]
  if not st then return false end
  if st.files[path] == "!" then return true end
  local dir = path:match("^(.*)/[^/]+$")
  while dir and #dir >= #root do
    if st.files[dir] == "!" then return true end
    if dir == root then break end
    dir = dir:match("^(.*)/[^/]+$")
  end
  return false
end

-- True when the entry should be hidden by the filtered_items config.
-- M.show_hidden (toggled with H) bypasses all filters.
function M.should_hide(name, full_path, config)
  if M.show_hidden then return false end
  local f = config.filtered_items or {}
  if f.hide_dotfiles and name:sub(1, 1) == "." then return true end
  if f.hide_gitignored and is_gitignored(full_path) then return true end
  return false
end

local function is_filtered(name, full_path, config)
  return M.should_hide(name, full_path, config)
end

-- ---------------------------------------------------------------------------
-- Directory scanning
-- ---------------------------------------------------------------------------

local function scan_directory(path, depth, config)
  local entries = {}
  local handle = vim.loop.fs_scandir(path)
  if not handle then return entries end

  while true do
    local name, type = vim.loop.fs_scandir_next(handle)
    if not name then break end

    local full_path = path .. "/" .. name
    if not is_filtered(name, full_path, config) then
      local is_dir = type == "directory"
      local extension = icons.get_extension(name)
      local icon, icon_hl

      if not is_dir then
        icon, icon_hl = icons.get_icon_for_file(name, extension, config.icons)
      end

      table.insert(entries, {
        name     = name,
        path     = full_path,
        is_dir   = is_dir,
        depth    = depth,
        expanded = M.expanded_paths[full_path] or false,
        icon     = icon,
        icon_hl  = icon_hl,
      })
    end
  end

  table.sort(entries, function(a, b)
    if a.is_dir ~= b.is_dir then
      return a.is_dir
    end
    return a.name:lower() < b.name:lower()
  end)

  return entries
end

-- ---------------------------------------------------------------------------
-- Tree construction
-- ---------------------------------------------------------------------------

local function make_entry(name, full_path, depth, is_dir, config)
  local icon, icon_hl
  if not is_dir then
    icon, icon_hl = icons.get_icon_for_file(name, icons.get_extension(name), config.icons)
  end
  return {
    name     = name,
    path     = full_path,
    is_dir   = is_dir,
    depth    = depth,
    expanded = M.expanded_paths[full_path] or false,
    icon     = icon,
    icon_hl  = icon_hl,
  }
end

-- Rebuild the tree as a pruned view of `M.search_matches`: every hit plus
-- its ancestor directories, all expanded. Used while a filter is active.
local function build_from_matches(config)
  local cwd = vim.fn.getcwd()
  M.cwd_name = vim.fn.fnamemodify(cwd, ":~")
  M.tree_data = {}

  local shown = {}
  for _, path in ipairs(M.search_matches or {}) do
    local p = path
    while p and #p > #cwd do
      shown[p] = true
      p = p:match("^(.*)/[^/]+$")
    end
  end

  local children = {}
  for path in pairs(shown) do
    local parent = path:match("^(.*)/[^/]+$") or cwd
    children[parent] = children[parent] or {}
    table.insert(children[parent], path)
  end

  local scores = M.search_scores
  local function sort_paths(list)
    table.sort(list, function(a, b)
      if scores then
        local sa, sb = scores[a] or 0, scores[b] or 0
        if sa ~= sb then return sa > sb end
      end
      local ad = vim.fn.isdirectory(a) == 1
      local bd = vim.fn.isdirectory(b) == 1
      if ad ~= bd then return ad end
      return a:lower() < b:lower()
    end)
  end

  local function add(parent, depth)
    local list = children[parent]
    if not list then return end
    sort_paths(list)
    for _, path in ipairs(list) do
      local name = path:match("([^/]+)$") or path
      local is_dir = vim.fn.isdirectory(path) == 1
      if is_dir then
        M.expanded_paths[path] = true
      end
      table.insert(M.tree_data, make_entry(name, path, depth, is_dir, config))
      if is_dir then
        add(path, depth + 1)
      end
    end
  end

  add(cwd, 0)
end

-- Build (or rebuild) `M.tree_data` from the current working directory.
-- `config` is the full plugin config table.
function M.build_tree(config)
  if M.search_pattern and M.search_pattern ~= "" then
    build_from_matches(config)
    return
  end

  if config.git and config.git.enable then
    git.stop_watchers()
  end

  M.tree_data = {}
  local cwd = vim.fn.getcwd()
  -- Root label: full path with ~ substitution, as neo-tree does.
  M.cwd_name = vim.fn.fnamemodify(cwd, ":~")
  local entries = scan_directory(cwd, 0, config)

  local function add_entries(list)
    for _, entry in ipairs(list) do
      table.insert(M.tree_data, entry)
      if entry.is_dir and entry.expanded then
        local child_entries = scan_directory(entry.path, entry.depth + 1, config)
        add_entries(child_entries)
      end
    end
  end

  add_entries(entries)

  if config.git and config.git.enable then
    local dir_paths = { cwd }
    local seen = { [cwd] = true }
    for _, entry in ipairs(M.tree_data) do
      if entry.is_dir and not seen[entry.path] then
        table.insert(dir_paths, entry.path)
        seen[entry.path] = true
      end
    end

    git.start_watchers(dir_paths)

    for _, path in ipairs(dir_paths) do
      if not git.git_roots[path] then
        local p = path
        vim.schedule(function() git.detect_and_cache(p) end)
      elseif git.git_roots[path].is_git then
        -- Known repo: kick a debounced background status refresh.
        git.request_status(path)
      end
    end
  end
end

-- Buffer row (1-based) where `path` is displayed, or nil when not visible.
-- Returns the first row of the node (the name line, not a git status line).
function M.row_for_path(path)
  local best = nil
  for row, entry in pairs(M.row_entry) do
    if entry.path == path and (not best or row < best) then
      best = row
    end
  end
  return best
end

function M.entry_at_row(row)
  return M.row_entry[row]
end

-- ---------------------------------------------------------------------------
-- Indentation prefix
-- ---------------------------------------------------------------------------

-- Build the indent prefix for an entry.
-- Returns the full prefix string.
-- `skip_marker_at_level[i] == true` means depth i was the last child at that
-- level, so its ancestor column draws a space instead of │.
local function build_prefix(entry, skip_marker_at_level)
  local level = entry.depth

  if level == 0 then
    return "   "  -- 3-space padding, no connector for direct cwd children
  end

  local parts = { "   " }  -- leading padding matching depth-0 indent

  for i = 1, level do
    local char
    if i == level then
      char = entry.is_last_child and "└" or "├"
    else
      char = skip_marker_at_level[i] and " " or "│"
    end
    table.insert(parts, char .. " ")
  end

  return table.concat(parts)
end

-- Prefix for the git-status line under a repo directory: same ancestor
-- columns as the dir, but the connector is │ (or a space if last child)
-- so the branch line hangs under the name without a second ├/└.
local function build_status_prefix(entry, skip_marker_at_level)
  local level = entry.depth
  if level == 0 then
    return "   "
  end
  local parts = { "   " }
  for i = 1, level do
    local char
    if i == level then
      char = entry.is_last_child and " " or "│"
    else
      char = skip_marker_at_level[i] and " " or "│"
    end
    table.insert(parts, char .. " ")
  end
  return table.concat(parts)
end

-- ---------------------------------------------------------------------------
-- Git status presentation
-- ---------------------------------------------------------------------------

-- Fallback symbols when config.git.status.symbols is absent (mirrors the
-- defaults in init.lua).
local DEFAULT_GIT_SYMBOLS = {
  added     = "",
  deleted   = "",
  modified  = "",
  renamed   = "󰁕",
  untracked = "",
  ignored   = "",
  staged    = "",
  unstaged  = "󰄱",
  conflict  = "",
  branch    = "",
  ahead     = "",
  behind    = "",
  clean     = "",
  stash     = "≡",
  lines_added   = "+",
  lines_removed = "-",
}

-- Map a porcelain change character to a symbol key / highlight group.
local CHANGE_SYMBOL_KEY = {
  M = "modified", T = "modified",
  A = "added",    C = "added",
  D = "deleted",  R = "renamed",
}
local CHANGE_HL = {
  M = "SuperTreeGitModified", T = "SuperTreeGitModified",
  A = "SuperTreeGitAdded",    C = "SuperTreeGitAdded",
  D = "SuperTreeGitDeleted",  R = "SuperTreeGitRenamed",
}

local function git_symbols(config)
  local user = config.git and config.git.status and config.git.status.symbols
  if not user then return DEFAULT_GIT_SYMBOLS end
  return vim.tbl_extend("keep", user, DEFAULT_GIT_SYMBOLS)
end

local function git_status_enabled(config)
  if not (config.git and config.git.enable) then return false end
  local status = config.git.status
  return status == nil or status.enable ~= false
end

local function git_multiline(config)
  if not git_status_enabled(config) then return false end
  local m = config.git.multiline
  return m == nil or m ~= false
end

-- Find the status code for a path inside its owning repo.
-- Falls through to ancestor "?"/"!" entries because git lists an untracked
-- or ignored directory as a single entry without listing its children.
local function lookup_status(path, is_dir)
  local root = git.find_repo_root(path)
  if not root or path == root then return nil end
  local st = git.repo_status[root]
  if not st then return nil end

  local code = st.files[path]
  if not code and is_dir then
    code = st.dirs[path]
  end
  if not code then
    local dir = path:match("^(.*)/[^/]+$")
    while dir and #dir >= #root do
      local c = st.files[dir]
      if c == "?" or c == "!" then return c end
      if dir == root then break end
      dir = dir:match("^(.*)/[^/]+$")
    end
  end
  return code
end

-- Build { text, hl } chunks (no separators) for a status code, plus the
-- highlight to use for the entry name. Returns nil for clean entries.
local function status_chunks(code, symbols)
  if code == "?" then
    return { { symbols.untracked, "SuperTreeGitUntracked" } }, "SuperTreeGitUntracked"
  end
  if code == "!" then
    return { { symbols.ignored, "SuperTreeGitIgnored" } }, "SuperTreeGitIgnored"
  end
  if git.is_conflict(code) then
    return { { symbols.conflict, "SuperTreeGitConflict" } }, "SuperTreeGitConflict"
  end

  if #code == 1 then
    -- Bubbled directory status: a single change character.
    local key = CHANGE_SYMBOL_KEY[code]
    if not key then return nil, nil end
    local hl = CHANGE_HL[code]
    return { { symbols[key], hl } }, hl
  end

  local x, y = code:sub(1, 1), code:sub(2, 2)
  local chunks = {}
  local name_hl = nil

  if CHANGE_SYMBOL_KEY[x] then
    -- Staged side: change-type symbol in the staged colour.
    table.insert(chunks, { symbols[CHANGE_SYMBOL_KEY[x]], "SuperTreeGitStaged" })
    name_hl = "SuperTreeGitStaged"
  end
  if CHANGE_SYMBOL_KEY[y] then
    -- Working-tree side: change-type symbol in its own colour.
    local hl = CHANGE_HL[y]
    table.insert(chunks, { symbols[CHANGE_SYMBOL_KEY[y]], hl })
    name_hl = hl
  end

  if #chunks == 0 then return nil, nil end
  return chunks, name_hl
end

-- Per-change-type breakdown text, e.g. "1 2 1 󰁕1".
local function change_detail_text(d, symbols)
  local parts = {}
  if d.added    > 0 then table.insert(parts, symbols.added    .. d.added)    end
  if d.modified > 0 then table.insert(parts, symbols.modified .. d.modified) end
  if d.deleted  > 0 then table.insert(parts, symbols.deleted  .. d.deleted)  end
  if d.renamed  > 0 then table.insert(parts, symbols.renamed  .. d.renamed)  end
  return table.concat(parts, " ")
end

-- Human-readable branch identifier: branch name, or a short oid when the
-- HEAD is detached.
local function display_branch(st)
  local branch = st.branch
  if not branch or branch == "(detached)" then
    if st.oid and st.oid ~= "(initial)" then
      return st.oid:sub(1, 7)
    end
    return branch or "?"
  end
  return branch
end

-- Status-only chunks (ahead/behind and change counts) for a repo directory.
local function repo_status_chunks(st, symbols)
  local chunks = {}

  if st.ahead > 0 then
    table.insert(chunks, { symbols.ahead .. st.ahead, "SuperTreeGitAheadBehind" })
  end
  if st.behind > 0 then
    table.insert(chunks, { symbols.behind .. st.behind, "SuperTreeGitAheadBehind" })
  end

  local c = st.counts
  if c.conflict > 0 then
    table.insert(chunks, { symbols.conflict .. c.conflict, "SuperTreeGitConflict" })
  end
  if c.staged > 0 then
    table.insert(chunks, { symbols.staged .. c.staged, "SuperTreeGitStaged" })
  end
  if c.unstaged > 0 then
    table.insert(chunks, { symbols.unstaged .. c.unstaged, "SuperTreeGitUnstaged" })
  end
  if c.untracked > 0 then
    table.insert(chunks, { symbols.untracked .. c.untracked, "SuperTreeGitUntracked" })
  end

  return chunks
end

-- Compact repo summary including the branch name.
local function branch_chunks(st, symbols)
  local chunks = {
    { symbols.branch .. " " .. display_branch(st), "SuperTreeGitBranch" },
  }
  for _, ch in ipairs(repo_status_chunks(st, symbols)) do
    table.insert(chunks, ch)
  end
  return chunks
end

local function virt_text_width(chunks)
  local w = 0
  for _, ch in ipairs(chunks) do
    w = w + vim.fn.strdisplaywidth(ch[1])
  end
  return w
end

local function width_for_buf(buf)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      return vim.api.nvim_win_get_width(win)
    end
  end
  return vim.o.columns
end

-- Left-hand chunks of the cwd root status line: branch identity.
-- Rendered as literal text aligned with the root path label.
local function root_left_chunks(st, symbols, show_remote)
  local chunks = {}
  table.insert(chunks, { symbols.branch .. " " .. display_branch(st), "SuperTreeGitBranch" })
  if show_remote and st.upstream then
    table.insert(chunks, { "…" .. st.upstream, "SuperTreeGitIgnored" })
  end
  if st.ahead > 0 then
    table.insert(chunks, { symbols.ahead .. st.ahead, "SuperTreeGitAheadBehind" })
  end
  if st.behind > 0 then
    table.insert(chunks, { symbols.behind .. st.behind, "SuperTreeGitAheadBehind" })
  end
  if (st.stash or 0) > 0 then
    table.insert(chunks, { symbols.stash .. st.stash, "SuperTreeGitIgnored" })
  end
  return chunks
end

-- Right-hand chunks of the cwd root status line: line diffstat and
-- per-change-type breakdowns. Rendered as right-aligned virtual text.
local function root_right_chunks(st, symbols)
  local chunks = {}

  if (st.diff_added or 0) > 0 then
    table.insert(chunks, { symbols.lines_added .. st.diff_added, "SuperTreeGitAdded" })
  end
  if (st.diff_removed or 0) > 0 then
    table.insert(chunks, { symbols.lines_removed .. st.diff_removed, "SuperTreeGitDeleted" })
  end

  local c = st.counts
  if c.conflict > 0 then
    table.insert(chunks, { symbols.conflict .. c.conflict, "SuperTreeGitConflict" })
  end
  if c.staged > 0 and st.detail then
    table.insert(chunks, {
      symbols.staged .. " " .. change_detail_text(st.detail.staged, symbols),
      "SuperTreeGitStaged",
    })
  end
  if c.unstaged > 0 and st.detail then
    table.insert(chunks, {
      symbols.unstaged .. " " .. change_detail_text(st.detail.unstaged, symbols),
      "SuperTreeGitUnstaged",
    })
  end
  if c.untracked > 0 then
    table.insert(chunks, { symbols.untracked .. c.untracked, "SuperTreeGitUntracked" })
  end

  return chunks
end

local function repo_is_clean(st)
  if not st or not st.counts then return false end
  local c = st.counts
  return c.conflict + c.staged + c.unstaged + c.untracked == 0
end

-- Turn separator-less chunks into virt_text chunks with a leading space
-- before each segment.
local function to_virt_text(chunks)
  local vt = {}
  for _, ch in ipairs(chunks) do
    table.insert(vt, { " " .. ch[1], ch[2] })
  end
  return vt
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

-- Write tree contents into `sidebar_buf` with extmark highlights.
-- `config` is the full plugin config table.
function M.render(sidebar_buf, config)
  -- Mark is_last_child on each entry (next entry is shallower or nil).
  for i, entry in ipairs(M.tree_data) do
    local next_entry = M.tree_data[i + 1]
    entry.is_last_child = (next_entry == nil or next_entry.depth < entry.depth)
  end

  vim.api.nvim_buf_clear_namespace(sidebar_buf, ns, 0, -1)
  M.row_entry = {}

  local status_enabled = git_status_enabled(config)
  local multiline = git_multiline(config)
  local symbols = git_symbols(config)

  -- Line 0: cwd root with open-folder icon and optional git badge,
  -- shifted right by one column of padding.
  local root_icon = " " .. icons.ICON_FOLDER_OPEN
  local cwd = vim.fn.getcwd()
  local root_git = git.git_roots[cwd]
  local root_git_badge = ""
  local root_git_hl_group = nil
  if root_git and root_git.is_git then
    if root_git.is_github then
      root_git_badge    = " " .. icons.ICON_GITHUB
      root_git_hl_group = "SuperTreeGitHub"
    else
      root_git_badge    = " " .. icons.ICON_GIT_REPO
      root_git_hl_group = "SuperTreeGitRepo"
    end
  end
  local root_clean = ""
  if status_enabled and repo_is_clean(git.repo_status[cwd]) then
    root_clean = " " .. symbols.clean
  end
  local filter_label = ""
  if M.search_pattern and M.search_pattern ~= "" then
    filter_label = '  Find "' .. M.search_pattern .. '"'
  end
  local root_line = root_icon .. M.cwd_name .. root_git_badge .. root_clean .. filter_label
  local lines = { root_line }

  -- Accumulate highlight positions during the loop.
  local dir_hl     = {}  -- { line, start, end_ }
  local indent_hl  = {}  -- { line, start, end_ }
  local icon_hl    = {}  -- { line, start, end_, hl }
  local git_hl     = {}  -- { line, start, end_, hl }
  local virt_marks = {}  -- { line, chunks }

  -- Root line: highlight the cwd name as a directory.
  table.insert(dir_hl, { line = 0, start = #root_icon, end_ = #root_icon + #M.cwd_name })
  if root_git_hl_group and #root_git_badge > 0 then
    local badge_start = #root_icon + #M.cwd_name
    table.insert(git_hl, { line = 0, start = badge_start, end_ = badge_start + #root_git_badge, hl = root_git_hl_group })
  end
  if #root_clean > 0 then
    local clean_start = #root_icon + #M.cwd_name + #root_git_badge
    table.insert(git_hl, { line = 0, start = clean_start, end_ = clean_start + #root_clean, hl = "SuperTreeGitClean" })
  end
  if #filter_label > 0 then
    local filter_start = #root_icon + #M.cwd_name + #root_git_badge + #root_clean
    table.insert(git_hl, {
      line = 0, start = filter_start, end_ = filter_start + #filter_label,
      hl = "SuperTreeFilterTerm",
    })
  end

  -- When the cwd is a git workspace, show a detailed status on a dedicated
  -- line directly under the root line, using the full width: branch,
  -- upstream, ahead/behind, and stash as literal text on the left (aligned
  -- with the first character of the path label above), line diffstat and
  -- change breakdowns as right-aligned virtual text.
  M.header_lines = 1
  if status_enabled then
    local root_status = git.repo_status[cwd]
    if root_status then
      local status_line = string.rep(" ", vim.fn.strdisplaywidth(root_icon))
      local first = true
      for _, ch in ipairs(root_left_chunks(root_status, symbols, config.git.status and config.git.status.show_remote)) do
        if not first then status_line = status_line .. " " end
        first = false
        local seg_start = #status_line
        status_line = status_line .. ch[1]
        table.insert(git_hl, { line = 1, start = seg_start, end_ = #status_line, hl = ch[2] })
      end
      table.insert(lines, status_line)

      local right = root_right_chunks(root_status, symbols)
      if #right > 0 then
        table.insert(virt_marks, { line = 1, chunks = to_virt_text(right) })
      end
      M.header_lines = 2
    end
  end

  local skip_marker_at_level = {}

  for _, entry in ipairs(M.tree_data) do
    local level = entry.depth
    skip_marker_at_level[level] = entry.is_last_child

    local prefix = build_prefix(entry, skip_marker_at_level)
    local icon, icon_highlight, icon_with_space

    if entry.is_dir then
      icon = entry.expanded and icons.ICON_FOLDER_OPEN or icons.ICON_FOLDER_CLOSED
      icon_with_space = icon  -- folder icons already have trailing space
    else
      icon = entry.icon or icons.ICON_FILE
      icon_highlight = entry.icon_hl
      icon_with_space = icon:match(" $") and icon or icon .. " "
    end

    -- Git badge for directory nodes.
    local git_badge = ""
    local git_badge_hl = nil
    if entry.is_dir then
      local gr = git.git_roots[entry.path]
      if gr and gr.is_git then
        if gr.is_github then
          git_badge    = " " .. icons.ICON_GITHUB
          git_badge_hl = "SuperTreeGitHub"
        else
          git_badge    = " " .. icons.ICON_GIT_REPO
          git_badge_hl = "SuperTreeGitRepo"
        end
      end
    end

    local clean_badge = ""
    if status_enabled and entry.is_dir and repo_is_clean(git.repo_status[entry.path]) then
      clean_badge = " " .. symbols.clean
    end

    local line = prefix .. icon_with_space .. entry.name .. git_badge .. clean_badge
    table.insert(lines, line)
    M.row_entry[#lines] = entry

    local lnum            = #lines - 1  -- 0-indexed buffer line number
    local icon_byte_start = #prefix
    local icon_byte_end   = icon_byte_start + #icon
    local name_byte_start = #prefix + #icon_with_space
    local name_byte_end   = name_byte_start + #entry.name

    if #prefix > 0 then
      table.insert(indent_hl, { line = lnum, start = 0, end_ = #prefix })
    end

    if not entry.is_dir and icon_highlight then
      table.insert(icon_hl, { line = lnum, start = icon_byte_start, end_ = icon_byte_end, hl = icon_highlight })
    end

    if entry.is_dir then
      table.insert(dir_hl, { line = lnum, start = name_byte_start, end_ = name_byte_end })
      if git_badge_hl and #git_badge > 0 then
        local badge_start = name_byte_start + #entry.name
        table.insert(git_hl, { line = lnum, start = badge_start, end_ = badge_start + #git_badge, hl = git_badge_hl })
      end
      if #clean_badge > 0 then
        local clean_start = name_byte_start + #entry.name + #git_badge
        table.insert(git_hl, { line = lnum, start = clean_start, end_ = clean_start + #clean_badge, hl = "SuperTreeGitClean" })
      end
    end

    -- Git status and diagnostics. Repo directories use a second line
    -- (same layout as the cwd root) when git.multiline is on; otherwise
    -- a compact right-aligned summary, dropping the branch name if it
    -- would overlap the path.
    local repo_st = status_enabled and entry.is_dir and git.repo_status[entry.path] or nil
    local use_multiline = multiline and repo_st

    local vt_chunks = {}
    if status_enabled and not use_multiline then
      if repo_st then
        local with_branch = to_virt_text(branch_chunks(repo_st, symbols))
        local status_only = to_virt_text(repo_status_chunks(repo_st, symbols))
        local line_w = vim.fn.strdisplaywidth(line)
        local diag_w = 0
        if config.diagnostics and config.diagnostics.enable ~= false then
          local dchunk = diagnostics.chunk(entry.path, entry.is_dir, config)
          if dchunk then
            diag_w = vim.fn.strdisplaywidth(" " .. dchunk[1])
          end
        end
        local win_w = width_for_buf(sidebar_buf)
        if line_w + 1 + virt_text_width(with_branch) + diag_w <= win_w then
          for _, ch in ipairs(with_branch) do
            table.insert(vt_chunks, ch)
          end
        else
          for _, ch in ipairs(status_only) do
            table.insert(vt_chunks, ch)
          end
        end
      else
        local code = lookup_status(entry.path, entry.is_dir)
        if code then
          local chunks, name_status_hl = status_chunks(code, symbols)
          if chunks then
            for _, ch in ipairs(to_virt_text(chunks)) do
              table.insert(vt_chunks, ch)
            end
            if not entry.is_dir and name_status_hl then
              table.insert(git_hl, { line = lnum, start = name_byte_start, end_ = name_byte_end, hl = name_status_hl })
            end
          end
        end
      end
    end
    if not use_multiline and config.diagnostics and config.diagnostics.enable ~= false then
      local dchunk = diagnostics.chunk(entry.path, entry.is_dir, config)
      if dchunk then
        table.insert(vt_chunks, { " " .. dchunk[1], dchunk[2] })
      end
    end
    if #vt_chunks > 0 then
      table.insert(virt_marks, { line = lnum, chunks = vt_chunks })
    end

    if use_multiline then
      local st_prefix = build_status_prefix(entry, skip_marker_at_level)
      local pad = string.rep(" ", vim.fn.strdisplaywidth(icon_with_space))
      local status_line = st_prefix .. pad
      local st_lnum = #lines  -- 0-indexed after the upcoming insert
      local first = true
      for _, ch in ipairs(root_left_chunks(repo_st, symbols, config.git.status and config.git.status.show_remote)) do
        if not first then status_line = status_line .. " " end
        first = false
        local seg_start = #status_line
        status_line = status_line .. ch[1]
        table.insert(git_hl, { line = st_lnum, start = seg_start, end_ = #status_line, hl = ch[2] })
      end
      table.insert(lines, status_line)
      M.row_entry[#lines] = entry
      if #st_prefix > 0 then
        table.insert(indent_hl, { line = st_lnum, start = 0, end_ = #st_prefix })
      end
      local right = root_right_chunks(repo_st, symbols)
      if config.diagnostics and config.diagnostics.enable ~= false then
        local dchunk = diagnostics.chunk(entry.path, true, config)
        if dchunk then
          table.insert(right, dchunk)
        end
      end
      if #right > 0 then
        table.insert(virt_marks, { line = st_lnum, chunks = to_virt_text(right) })
      end
    end
  end

  vim.bo[sidebar_buf].modifiable = true
  vim.bo[sidebar_buf].readonly   = false
  vim.api.nvim_buf_set_lines(sidebar_buf, 0, -1, false, lines)

  for _, pos in ipairs(indent_hl) do
    vim.api.nvim_buf_set_extmark(sidebar_buf, ns, pos.line, pos.start, {
      end_col  = pos.end_,
      hl_group = "SuperTreeIndent",
    })
  end

  for _, pos in ipairs(icon_hl) do
    vim.api.nvim_buf_set_extmark(sidebar_buf, ns, pos.line, pos.start, {
      end_col  = pos.end_,
      hl_group = pos.hl,
    })
  end

  for _, pos in ipairs(dir_hl) do
    vim.api.nvim_buf_set_extmark(sidebar_buf, ns, pos.line, pos.start, {
      end_col  = pos.end_,
      hl_group = "SuperTreeDirectory",
    })
  end

  for _, pos in ipairs(git_hl) do
    vim.api.nvim_buf_set_extmark(sidebar_buf, ns, pos.line, pos.start, {
      end_col  = pos.end_,
      hl_group = pos.hl,
    })
  end

  for _, mark in ipairs(virt_marks) do
    vim.api.nvim_buf_set_extmark(sidebar_buf, ns, mark.line, 0, {
      virt_text     = mark.chunks,
      virt_text_pos = "right_align",
      hl_mode       = "combine",
    })
  end

  vim.bo[sidebar_buf].modifiable = false
  vim.bo[sidebar_buf].readonly   = true
  vim.bo[sidebar_buf].modified   = false
end

return M
