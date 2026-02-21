local M = {}

local config = {
  width = 30,
  mode = "floating", -- "floating" or "pinned"
  icons = {
    enable = true,        -- Enable file-type icons
    provider = "auto",    -- "auto", "nvim-web-devicons", or "builtin"
  },
}

local sidebar_buf = nil
local sidebar_win = nil
local tree_data = {}
local expanded_paths = {}
local ns = vim.api.nvim_create_namespace("tree_sidebar")

-- Icons match Neo Tree defaults exactly (requires Nerd Font)
-- Using string.char for proper UTF-8 encoding of private use area characters
local ICON_FILE          = string.char(0xEF, 0x85, 0x9B) .. " "  -- nf-fa-file (U+F15B)
local ICON_FOLDER_CLOSED = string.char(0xEE, 0x97, 0xBF) .. " " -- nf-custom-folder (U+E5FF)
local ICON_FOLDER_OPEN   = string.char(0xEE, 0x97, 0xBE) .. " " -- nf-custom-folder_open (U+E5FE)

-- Extract file extension from filename (returns lowercase extension or empty string)
local function get_extension(name)
  local ext = name:match("%.([^%.]+)$")
  return ext and ext:lower() or ""
end

-- Built-in icon set for files (used when nvim-web-devicons is not available)
local BUILTIN_ICONS = {
  filenames = {
    ["dockerfile"]        = { icon = "󰡨 ", hl = "DevIconDockerfile" },
    [".dockerignore"]     = { icon = "󰡨 ", hl = "DevIconDockerfile" },
    [".gitignore"]        = { icon = "󰊢 ", hl = "DevIconGitignore" },
    [".gitattributes"]    = { icon = "󰊢 ", hl = "DevIconGitignore" },
    [".gitmodules"]       = { icon = "󰊢 ", hl = "DevIconGitignore" },
    ["makefile"]          = { icon = "󱁣 ", hl = "DevIconMake" },
    ["package.json"]      = { icon = "󰌞 ", hl = "DevIconNpm" },
    ["package-lock.json"] = { icon = "󰌞 ", hl = "DevIconNpm" },
    ["yarn.lock"]         = { icon = "󰌞 ", hl = "DevIconNpm" },
    ["pnpm-lock.yaml"]    = { icon = "󰌞 ", hl = "DevIconNpm" },
    ["readme.md"]         = { icon = "󰍛 ", hl = "DevIconReadme" },
    ["readme"]            = { icon = "󰍛 ", hl = "DevIconReadme" },
    ["license"]           = { icon = "󰈔 ", hl = "DevIconLicense" },
    ["license.md"]        = { icon = "󰈔 ", hl = "DevIconLicense" },
    ["license.txt"]       = { icon = "󰈔 ", hl = "DevIconLicense" },
    [".env"]              = { icon = "󰌠 ", hl = "DevIconEnv" },
    [".env.local"]        = { icon = "󰌠 ", hl = "DevIconEnv" },
    [".env.example"]      = { icon = "󰌠 ", hl = "DevIconEnv" },
    ["Cargo.toml"]        = { icon = "󱘗 ", hl = "DevIconCargo" },
    ["Cargo.lock"]        = { icon = "󱘗 ", hl = "DevIconCargo" },
    ["go.mod"]            = { icon = "󰟓 ", hl = "DevIconGo" },
    ["go.sum"]            = { icon = "󰟓 ", hl = "DevIconGo" },
  },
  extensions = {
    ["lua"]    = { icon = "󰢱 ", hl = "DevIconLua" },
    ["js"]     = { icon = "󰌞 ", hl = "DevIconJavascript" },
    ["ts"]     = { icon = "󰛚 ", hl = "DevIconTypescript" },
    ["jsx"]    = { icon = "󰌗 ", hl = "DevIconReact" },
    ["tsx"]    = { icon = "󰛢 ", hl = "DevIconReactTs" },
    ["vue"]    = { icon = "󰡄 ", hl = "DevIconVue" },
    ["svelte"] = { icon = "󰛠 ", hl = "DevIconSvelte" },
    ["py"]     = { icon = "󰌠 ", hl = "DevIconPython" },
    ["rs"]     = { icon = "󱘗 ", hl = "DevIconRust" },
    ["go"]     = { icon = "󰟓 ", hl = "DevIconGo" },
    ["c"]      = { icon = "󰌞 ", hl = "DevIconC" },
    ["cpp"]    = { icon = "󰝙 ", hl = "DevIconCxx" },
    ["h"]      = { icon = "󰌞 ", hl = "DevIconC" },
    ["hpp"]    = { icon = "󰝙 ", hl = "DevIconCxx" },
    ["java"]   = { icon = "󰬇 ", hl = "DevIconJava" },
    ["rb"]     = { icon = "󰴭 ", hl = "DevIconRuby" },
    ["php"]    = { icon = "󰘞 ", hl = "DevIconPhp" },
    ["md"]     = { icon = "󰍛 ", hl = "DevIconMarkdown" },
    ["json"]   = { icon = "󰘦 ", hl = "DevIconJson" },
    ["yaml"]   = { icon = "󰠷 ", hl = "DevIconYaml" },
    ["yml"]    = { icon = "󰠷 ", hl = "DevIconYaml" },
    ["toml"]   = { icon = "󰅭 ", hl = "DevIconToml" },
    ["xml"]    = { icon = "󰗀 ", hl = "DevIconXml" },
    ["html"]   = { icon = "󰌝 ", hl = "DevIconHtml" },
    ["css"]    = { icon = "󰌜 ", hl = "DevIconCss" },
    ["scss"]   = { icon = "󰌶 ", hl = "DevIconSass" },
    ["sass"]   = { icon = "󰌶 ", hl = "DevIconSass" },
    ["less"]   = { icon = "󰌶 ", hl = "DevIconLess" },
    ["sh"]     = { icon = "󰈷 ", hl = "DevIconShell" },
    ["bash"]   = { icon = "󰈷 ", hl = "DevIconShell" },
    ["zsh"]    = { icon = "󰈷 ", hl = "DevIconShell" },
    ["fish"]   = { icon = "󰈷 ", hl = "DevIconShell" },
    ["sql"]    = { icon = "󰆼 ", hl = "DevIconSql" },
    ["txt"]    = { icon = "󰈙 ", hl = "DevIconTxt" },
    ["conf"]   = { icon = "󰌅 ", hl = "DevIconConfig" },
    ["cfg"]    = { icon = "󰌅 ", hl = "DevIconConfig" },
    ["ini"]    = { icon = "󰌅 ", hl = "DevIconConfig" },
    ["gitconfig"] = { icon = "󰊢 ", hl = "DevIconGitignore" },
    ["lock"]   = { icon = "󰌠 ", hl = "DevIconLock" },
    ["log"]    = { icon = "󰌠 ", hl = "DevIconLog" },
  },
  default = { icon = " ", hl = "TreeSidebarFile" },
}

-- Get icon for a file using built-in icons
local function get_builtin_icon(name, extension)
  local lower_name = name:lower()
  
  -- Check exact filename matches first
  if BUILTIN_ICONS.filenames[lower_name] then
    local icon_data = BUILTIN_ICONS.filenames[lower_name]
    return icon_data.icon, icon_data.hl
  end
  
  -- Check extension matches
  if extension and extension ~= "" and BUILTIN_ICONS.extensions[extension] then
    local icon_data = BUILTIN_ICONS.extensions[extension]
    return icon_data.icon, icon_data.hl
  end
  
  -- Return default
  return BUILTIN_ICONS.default.icon, BUILTIN_ICONS.default.hl
end

-- Get icon for a file (nvim-web-devicons if available, fallback to builtin)
local function get_icon_for_file(name, extension)
  -- Skip if icons disabled
  if config.icons and config.icons.enable == false then
    return ICON_FILE, "TreeSidebarFile"
  end
  
  -- Use builtin only if explicitly requested
  if config.icons and config.icons.provider == "builtin" then
    return get_builtin_icon(name, extension)
  end
  
  -- Try nvim-web-devicons if provider is "auto" or "nvim-web-devicons"
  if not config.icons or config.icons.provider ~= "builtin" then
    local ok, web_devicons = pcall(require, "nvim-web-devicons")
    if ok then
      local icon, hl = web_devicons.get_icon(name, extension, { default = true })
      if icon then
        return icon, hl
      end
    end
    
    -- If provider was explicitly "nvim-web-devicons" but it failed, show warning once
    if config.icons and config.icons.provider == "nvim-web-devicons" then
      vim.notify_once("nvim-web-devicons not found, using builtin icons", vim.log.levels.WARN)
    end
  end
  
  -- Fallback to built-in
  return get_builtin_icon(name, extension)
end

local hl_defined = false

local cwd_name = ""  -- basename of cwd, shown as the root line

local function create_or_get_buffer()
  if sidebar_buf and vim.api.nvim_buf_is_valid(sidebar_buf) then
    return sidebar_buf
  end

  sidebar_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(sidebar_buf, "tree-sidebar://sidebar")
  vim.bo[sidebar_buf].buftype = "nofile"
  vim.bo[sidebar_buf].bufhidden = "wipe"
  vim.bo[sidebar_buf].buflisted = false
  vim.bo[sidebar_buf].swapfile = false
  vim.bo[sidebar_buf].filetype = "tree-sidebar"

  vim.api.nvim_create_autocmd("BufWinEnter", {
    buffer = sidebar_buf,
    callback = function()
      vim.bo[sidebar_buf].filetype = "tree-sidebar"
      vim.schedule(function()
        vim.cmd("redrawtabline")
        vim.api.nvim_exec_autocmds("User", { pattern = "TreeSidebarOpen" })
      end)
    end,
  })

  vim.api.nvim_create_autocmd("BufWinLeave", {
    buffer = sidebar_buf,
    callback = function()
      vim.schedule(function()
        vim.cmd("redrawtabline")
        vim.api.nvim_exec_autocmds("User", { pattern = "TreeSidebarClose" })
      end)
    end,
  })

  return sidebar_buf
end

local function get_tabline_height()
  if vim.o.showtabline == 0 then return 0 end
  if vim.o.showtabline == 2 then return 1 end
  return #vim.api.nvim_list_tabpages() > 1 and 1 or 0
end

local function create_floating_window(buf)
  local tabline_height = get_tabline_height()
  local win_config = {
    relative = "editor",
    width = config.width,
    height = vim.o.lines - vim.o.cmdheight - tabline_height - 1,
    col = 0,
    row = tabline_height,
    anchor = "NW",
    style = "minimal",
    border = "none",
    zindex = 40,
  }

  local win = vim.api.nvim_open_win(buf, true, win_config)

  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].spell = false
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false
  vim.wo[win].scrolloff = 0
  vim.wo[win].sidescrolloff = 0
  vim.wo[win].statusline = ""

  return win
end

local function create_pinned_window(buf)
  vim.cmd("topleft vertical split")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_width(win, config.width)

  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].spell = false
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false
  vim.wo[win].scrolloff = 0
  vim.wo[win].sidescrolloff = 0
  vim.wo[win].winfixwidth = true
  vim.wo[win].winfixheight = true
  vim.wo[win].statusline = " Tree Sidebar"

  return win
end

local function scan_directory(path, depth)
  local entries = {}
  local handle = vim.loop.fs_scandir(path)
  if not handle then return entries end

  while true do
    local name, type = vim.loop.fs_scandir_next(handle)
    if not name then break end

    local full_path = path .. "/" .. name
    local is_dir = type == "directory"
    local extension = get_extension(name)
    local icon, icon_hl
    
    if not is_dir then
      icon, icon_hl = get_icon_for_file(name, extension)
    end

    table.insert(entries, {
      name = name,
      path = full_path,
      is_dir = is_dir,
      depth = depth,
      expanded = expanded_paths[full_path] or false,
      icon = icon,
      icon_hl = icon_hl,
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

local function build_tree()
  tree_data = {}
  local cwd = vim.fn.getcwd()
  cwd_name = vim.fn.fnamemodify(cwd, ":t")  -- basename only
  local entries = scan_directory(cwd, 0)

  local function add_entries(entries)
    for _, entry in ipairs(entries) do
      table.insert(tree_data, entry)
      if entry.is_dir and entry.expanded then
        local child_entries = scan_directory(entry.path, entry.depth + 1)
        add_entries(child_entries)
      end
    end
  end

  add_entries(entries)
end

-- Build the indent prefix for an entry.
-- Returns the prefix string and its byte length (for highlight placement).
--   Ancestor columns: "│ " if that depth still has siblings below, "  " otherwise.
--   Current level:    "├ " for non-last child, "└ " for last child.
-- Root items (depth 0) are direct children of cwd — they get "  " padding only,
-- no connector (the cwd root line above them acts as their parent).
-- skip_marker_at_level[i] == true means depth i was the last child at that level,
-- so its ancestor column draws a space instead of │.
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

local function render()
  -- First pass: mark is_last_child on each entry.
  -- An entry is the last child when the next entry is at a shallower depth (or nil).
  for i, entry in ipairs(tree_data) do
    local next_entry = tree_data[i + 1]
    entry.is_last_child = (next_entry == nil or next_entry.depth < entry.depth)
  end

  vim.api.nvim_buf_clear_namespace(sidebar_buf, ns, 0, -1)

  -- Line 0: cwd root shown with open-folder icon and directory highlight.
  local root_icon = ICON_FOLDER_OPEN
  local root_line = root_icon .. cwd_name
  local lines = { root_line }

  -- Positions for extmark highlights accumulated during render.
  local dir_hl    = {}  -- { line, start, end_ }  for TreeSidebarDirectory
  local indent_hl = {}  -- { line, start, end_ }  for TreeSidebarIndent
  local icon_hl   = {}  -- { line, start, end_, hl } for file icon highlights

  -- Root line: highlight the cwd name as a directory.
  table.insert(dir_hl, { line = 0, start = #root_icon, end_ = #root_line })

  local skip_marker_at_level = {}

  for _, entry in ipairs(tree_data) do
    local level = entry.depth
    skip_marker_at_level[level] = entry.is_last_child

    local prefix = build_prefix(entry, skip_marker_at_level)
    local icon, icon_highlight, icon_with_space
    
    if entry.is_dir then
      icon = entry.expanded and ICON_FOLDER_OPEN or ICON_FOLDER_CLOSED
      icon_with_space = icon  -- folder icons already have trailing space
    else
      icon = entry.icon or ICON_FILE
      icon_highlight = entry.icon_hl
      -- Ensure space between file icon and name
      icon_with_space = icon:match(" $") and icon or icon .. " "
    end

    local line = prefix .. icon_with_space .. entry.name
    table.insert(lines, line)

    local lnum = #lines - 1  -- 0-indexed buffer line number
    local icon_byte_start = #prefix
    local icon_byte_end = icon_byte_start + #icon  -- highlight only the icon, not the space
    local name_byte_start = #prefix + #icon_with_space
    local name_byte_end   = name_byte_start + #entry.name

    -- Highlight the prefix (indent/connector chars) in dark gray.
    if #prefix > 0 then
      table.insert(indent_hl, { line = lnum, start = 0, end_ = #prefix })
    end

    -- Highlight file icons with their specific highlight group
    if not entry.is_dir and icon_highlight then
      table.insert(icon_hl, { line = lnum, start = icon_byte_start, end_ = icon_byte_end, hl = icon_highlight })
    end

    if entry.is_dir then
      table.insert(dir_hl, { line = lnum, start = name_byte_start, end_ = name_byte_end })
    end
  end

  vim.bo[sidebar_buf].modifiable = true
  vim.bo[sidebar_buf].readonly = false
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

  vim.bo[sidebar_buf].modifiable = false
  vim.bo[sidebar_buf].readonly = true
end

local function move_up()
  local cursor = vim.api.nvim_win_get_cursor(sidebar_win)
  local row = cursor[1]
  if row > 1 then
    vim.api.nvim_win_set_cursor(sidebar_win, { row - 1, 0 })
  end
end

local function move_down()
  local cursor = vim.api.nvim_win_get_cursor(sidebar_win)
  local row = cursor[1]
  local line_count = vim.api.nvim_buf_line_count(sidebar_buf)
  if row < line_count then
    vim.api.nvim_win_set_cursor(sidebar_win, { row + 1, 0 })
  end
end

local function get_current_entry()
  local cursor = vim.api.nvim_win_get_cursor(sidebar_win)
  local row = cursor[1]
  -- Row 1 is the cwd root line; tree entries start at row 2 → tree_data[1].
  return tree_data[row - 1]
end

local function toggle_expand()
  local entry = get_current_entry()
  if not entry or not entry.is_dir then return end

  if expanded_paths[entry.path] then
    expanded_paths[entry.path] = nil
  else
    expanded_paths[entry.path] = true
  end

  build_tree()
  render()
end

local function setup_keymaps()
  local opts = { buffer = sidebar_buf, nowait = true, silent = true }

  vim.keymap.set("n", "<Up>", move_up, opts)
  vim.keymap.set("n", "<Down>", move_down, opts)
  vim.keymap.set("n", "<CR>", toggle_expand, opts)
  vim.keymap.set("n", "q", M.close, opts)
  vim.keymap.set("n", "<Esc>", M.close, opts)

  local visual_keys = { "v", "V", "<C-v>", "gv" }
  for _, key in ipairs(visual_keys) do
    vim.keymap.set("n", key, "<Nop>", opts)
  end

  local insert_keys = { "i", "I", "a", "A", "o", "O", "s", "S", "c", "C", "R" }
  for _, key in ipairs(insert_keys) do
    vim.keymap.set("n", key, "<Nop>", opts)
  end

  local edit_keys = { "d", "D", "dd", "x", "X", "s", "S", "r", "J", "<<", ">>", "gu", "gU", "g~", "~" }
  for _, key in ipairs(edit_keys) do
    vim.keymap.set("n", key, "<Nop>", opts)
  end

  local motion_keys = { "w", "W", "b", "B", "e", "E", "ge", "gE", "f", "F", "t", "T", "%", "{", "}", "(", ")", "[[", "]]", "gg", "G", "H", "M", "L", "h", "l", "<Left>", "<Right>", "<Space>", "<Backspace>" }
  for _, key in ipairs(motion_keys) do
    vim.keymap.set("n", key, "<Nop>", opts)
  end

  local yank_keys = { "y", "Y", "yy" }
  for _, key in ipairs(yank_keys) do
    vim.keymap.set("n", key, "<Nop>", opts)
  end

  local put_keys = { "p", "P" }
  for _, key in ipairs(put_keys) do
    vim.keymap.set("n", key, "<Nop>", opts)
  end

  vim.keymap.set("n", "u", "<Nop>", opts)
  vim.keymap.set("n", "<C-r>", "<Nop>", opts)
  vim.keymap.set("n", ".", "<Nop>", opts)
  vim.keymap.set("n", "@", "<Nop>", opts)
  vim.keymap.set("n", "/", "<Nop>", opts)
  vim.keymap.set("n", "?", "<Nop>", opts)
  vim.keymap.set("n", "*", "<Nop>", opts)
  vim.keymap.set("n", "#", "<Nop>", opts)
  vim.keymap.set("n", "n", "<Nop>", opts)
  vim.keymap.set("n", "N", "<Nop>", opts)
  vim.keymap.set("n", "<C-w>", "<Nop>", opts)
end

function M.open()
  if sidebar_win and vim.api.nvim_win_is_valid(sidebar_win) then
    vim.api.nvim_set_current_win(sidebar_win)
    return
  end

  local buf = create_or_get_buffer()

  if config.mode == "pinned" then
    sidebar_win = create_pinned_window(buf)
    build_tree()
    render()
    setup_keymaps()
    -- Force filetype refresh after window is created
    vim.bo[buf].filetype = "tree-sidebar"
    vim.cmd("redrawtabline")
    vim.api.nvim_exec_autocmds("User", { pattern = "TreeSidebarOpen" })
  else
    sidebar_win = create_floating_window(buf)
    build_tree()
    render()
    setup_keymaps()
  end
end

function M.close()
  if sidebar_win and vim.api.nvim_win_is_valid(sidebar_win) then
    vim.api.nvim_win_close(sidebar_win, true)
    sidebar_win = nil
  end
end

function M.is_open()
  return sidebar_win ~= nil and vim.api.nvim_win_is_valid(sidebar_win)
end

function M.get_width()
  if not M.is_open() then return 0 end
  return config.width + 1
end

function M.toggle()
  if sidebar_win and vim.api.nvim_win_is_valid(sidebar_win) then
    M.close()
  else
    M.open()
  end
end

-- Setup built-in icon highlight groups
local function setup_builtin_icon_highlights()
  local links = {
    DevIconLua        = "Statement",
    DevIconJavascript = "Statement",
    DevIconTypescript = "Type",
    DevIconReact      = "Constant",
    DevIconReactTs    = "Type",
    DevIconVue        = "Constant",
    DevIconSvelte     = "Constant",
    DevIconPython     = "Statement",
    DevIconRust       = "Statement",
    DevIconGo         = "Statement",
    DevIconC          = "Statement",
    DevIconCxx        = "Statement",
    DevIconJava       = "Statement",
    DevIconRuby       = "Constant",
    DevIconPhp        = "Statement",
    DevIconMarkdown   = "Title",
    DevIconJson       = "String",
    DevIconYaml       = "String",
    DevIconToml       = "String",
    DevIconXml        = "String",
    DevIconHtml       = "Tag",
    DevIconCss        = "Tag",
    DevIconSass       = "Tag",
    DevIconLess       = "Tag",
    DevIconShell      = "Identifier",
    DevIconSql        = "Statement",
    DevIconTxt        = "Normal",
    DevIconConfig     = "Comment",
    DevIconDockerfile = "Constant",
    DevIconGitignore  = "Comment",
    DevIconMake       = "Statement",
    DevIconNpm        = "Constant",
    DevIconReadme     = "Title",
    DevIconLicense    = "Title",
    DevIconEnv        = "Constant",
    DevIconCargo      = "Constant",
    DevIconLock       = "Comment",
    DevIconLog        = "Comment",
    TreeSidebarFile   = "Normal",
  }
  
  for name, link in pairs(links) do
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end
end

function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})

  if not hl_defined then
    vim.api.nvim_set_hl(0, "TreeSidebarDirectory", { link = "Directory", default = true })
    vim.api.nvim_set_hl(0, "TreeSidebarIndent", { fg = "#4b5263", default = true })
    setup_builtin_icon_highlights()
    hl_defined = true
  end

  vim.api.nvim_create_user_command("TreeSidebar", M.toggle, {})
  vim.api.nvim_create_user_command("TreeSidebarOpen", M.open, {})
  vim.api.nvim_create_user_command("TreeSidebarClose", M.close, {})

  vim.api.nvim_create_autocmd("User", {
    pattern = "TreeSidebarOpen",
    callback = function()
      vim.cmd("redrawtabline")
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    pattern = "TreeSidebarClose",
    callback = function()
      vim.cmd("redrawtabline")
    end,
  })
end

return M