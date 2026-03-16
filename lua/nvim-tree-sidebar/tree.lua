-- File tree data management and buffer rendering.
-- Depends on icons.lua and git.lua; both must be required before use.

local icons = require("nvim-tree-sidebar.icons")
local git   = require("nvim-tree-sidebar.git")

local M = {}

-- Module-level state
M.tree_data      = {}  -- flat ordered list of visible entry tables
M.expanded_paths = {}  -- set of expanded directory paths
M.cwd_name       = ""  -- basename of cwd, shown as the root line

-- Namespace for extmark highlights (shared with window module via sidebar_buf)
local ns = vim.api.nvim_create_namespace("tree_sidebar")

-- ---------------------------------------------------------------------------
-- Directory scanning
-- ---------------------------------------------------------------------------

local function scan_directory(path, depth, icons_config)
  local entries = {}
  local handle = vim.loop.fs_scandir(path)
  if not handle then return entries end

  while true do
    local name, type = vim.loop.fs_scandir_next(handle)
    if not name then break end

    local full_path = path .. "/" .. name
    local is_dir = type == "directory"
    local extension = icons.get_extension(name)
    local icon, icon_hl

    if not is_dir then
      icon, icon_hl = icons.get_icon_for_file(name, extension, icons_config)
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

-- Build (or rebuild) `M.tree_data` from the current working directory.
-- `config` is the full plugin config table.
function M.build_tree(config)
  if config.git and config.git.enable then
    git.stop_watchers()
  end

  M.tree_data = {}
  local cwd = vim.fn.getcwd()
  M.cwd_name = vim.fn.fnamemodify(cwd, ":t")
  local entries = scan_directory(cwd, 0, config.icons)

  local function add_entries(list)
    for _, entry in ipairs(list) do
      table.insert(M.tree_data, entry)
      if entry.is_dir and entry.expanded then
        local child_entries = scan_directory(entry.path, entry.depth + 1, config.icons)
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
      end
    end
  end
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
    return "  "  -- 2-space padding, no connector for direct cwd children
  end

  local parts = { "  " }  -- leading padding matching depth-0 indent

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

  -- Line 0: cwd root with open-folder icon and optional git badge.
  local root_icon = icons.ICON_FOLDER_OPEN
  local cwd = vim.fn.getcwd()
  local root_git = git.git_roots[cwd]
  local root_git_badge = ""
  local root_git_hl_group = nil
  if root_git and root_git.is_git then
    if root_git.is_github then
      root_git_badge    = " " .. icons.ICON_GITHUB
      root_git_hl_group = "TreeSidebarGitHub"
    else
      root_git_badge    = " " .. icons.ICON_GIT_REPO
      root_git_hl_group = "TreeSidebarGitRepo"
    end
  end
  local root_line = root_icon .. M.cwd_name .. root_git_badge
  local lines = { root_line }

  -- Accumulate highlight positions during the loop.
  local dir_hl    = {}  -- { line, start, end_ }
  local indent_hl = {}  -- { line, start, end_ }
  local icon_hl   = {}  -- { line, start, end_, hl }
  local git_hl    = {}  -- { line, start, end_, hl }

  -- Root line: highlight the cwd name as a directory.
  table.insert(dir_hl, { line = 0, start = #root_icon, end_ = #root_icon + #M.cwd_name })
  if root_git_hl_group and #root_git_badge > 0 then
    local badge_start = #root_icon + #M.cwd_name
    table.insert(git_hl, { line = 0, start = badge_start, end_ = badge_start + #root_git_badge, hl = root_git_hl_group })
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
          git_badge_hl = "TreeSidebarGitHub"
        else
          git_badge    = " " .. icons.ICON_GIT_REPO
          git_badge_hl = "TreeSidebarGitRepo"
        end
      end
    end

    local line = prefix .. icon_with_space .. entry.name .. git_badge
    table.insert(lines, line)

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
    end
  end

  vim.bo[sidebar_buf].modifiable = true
  vim.bo[sidebar_buf].readonly   = false
  vim.api.nvim_buf_set_lines(sidebar_buf, 0, -1, false, lines)

  for _, pos in ipairs(indent_hl) do
    vim.api.nvim_buf_set_extmark(sidebar_buf, ns, pos.line, pos.start, {
      end_col  = pos.end_,
      hl_group = "TreeSidebarIndent",
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
      hl_group = "TreeSidebarDirectory",
    })
  end

  for _, pos in ipairs(git_hl) do
    vim.api.nvim_buf_set_extmark(sidebar_buf, ns, pos.line, pos.start, {
      end_col  = pos.end_,
      hl_group = pos.hl,
    })
  end

  vim.bo[sidebar_buf].modifiable = false
  vim.bo[sidebar_buf].readonly   = true
end

return M
