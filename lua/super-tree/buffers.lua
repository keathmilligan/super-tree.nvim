-- Open-buffers pane: a separate window above the file tree.

local icons       = require("super-tree.icons")
local diagnostics = require("super-tree.diagnostics")
local window      = require("super-tree.window")
local filter      = require("super-tree.filter")
local fade        = require("super-tree.fade")

local M = {}

M.entries = {}  -- visible rows: { bufnr, name, path, icon, icon_hl, modified }
M.all = {}
M.search_pattern = nil
M.use_fzy = false

local ns = vim.api.nvim_create_namespace("SuperTreeBuffers")

local function is_plugin_buf(bufnr)
  local ft = vim.bo[bufnr].filetype
  return ft == "SuperTree" or ft == "SuperTreeFilter"
end

local function editor_bufnr()
  local win = window.find_editor_win()
  if win then return vim.api.nvim_win_get_buf(win) end
  local buf = vim.api.nvim_get_current_buf()
  if not is_plugin_buf(buf) then return buf end
  return nil
end

function M.collect()
  local list = {}
  for _, info in ipairs(vim.fn.getbufinfo({ buflisted = 1 })) do
    local bufnr = info.bufnr
    if not is_plugin_buf(bufnr) then
      local bt = vim.bo[bufnr].buftype
      if bt == "" or bt == "acwrite" then
        local path = info.name
        if path and path ~= "" then
          local name = vim.fn.fnamemodify(path, ":t")
          if name == "" then name = path end
          local icon, icon_hl = icons.get_icon_for_file(name, icons.get_extension(name), { enable = true, provider = "auto" })
          list[#list + 1] = {
            bufnr    = bufnr,
            name     = name,
            path     = path,
            icon     = icon,
            icon_hl  = icon_hl,
            modified = info.changed == 1,
            lastused = info.lastused or 0,
          }
        end
      end
    end
  end
  table.sort(list, function(a, b)
    if a.lastused ~= b.lastused then return a.lastused > b.lastused end
    return a.name:lower() < b.name:lower()
  end)
  M.all = list
  M.entries = list
  return list
end

function M.entry_at_cursor()
  if not window.buffers_win or not vim.api.nvim_win_is_valid(window.buffers_win) then
    return nil
  end
  return M.entries[vim.api.nvim_win_get_cursor(window.buffers_win)[1]]
end

function M.render(buf, config)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  config = config or {}
  M.collect()
  local all = M.all or M.entries
  M.entries = filter.filter_entries(all, M.search_pattern, M.use_fzy)

  local total, shown, modified = #all, #M.entries, 0
  for _, entry in ipairs(M.entries) do
    if entry.modified then modified = modified + 1 end
  end

  local header = " Buffers  " .. shown
  if M.search_pattern and M.search_pattern ~= "" then
    header = " Buffers  " .. shown .. "/" .. total
  end
  if modified > 0 then
    header = header .. "  +" .. modified
  end
  if M.search_pattern and M.search_pattern ~= "" then
    header = header .. '  "' .. M.search_pattern .. '"'
  end

  local lines = {}
  local icon_hl, name_hl, virt_marks = {}, {}, {}
  local current = editor_bufnr()

  for i, entry in ipairs(M.entries) do
    local is_current = entry.bufnr == current
    local icon = entry.icon or icons.ICON_FILE
    local icon_with_space = icon:match(" $") and icon or icon .. " "
    local extra = entry.modified and " +" or ""
    local prefix = is_current and " > " or "   "
    table.insert(lines, prefix .. icon_with_space .. entry.name .. extra)

    local lnum = i - 1
    local icon_start = #prefix
    local icon_end = icon_start + #icon
    local name_start = #prefix + #icon_with_space
    local name_end = name_start + #entry.name

    if entry.icon_hl then
      table.insert(icon_hl, { line = lnum, start = icon_start, end_ = icon_end, hl = entry.icon_hl })
    end
    table.insert(name_hl, {
      line = lnum, start = name_start, end_ = name_end,
      hl = is_current and "SuperTreeBuffersCurrent" or "SuperTreeDirectory",
    })
    if extra ~= "" then
      table.insert(name_hl, { line = lnum, start = name_end, end_ = name_end + #extra, hl = "SuperTreeGitModified" })
    end

    if config.diagnostics and config.diagnostics.enable ~= false then
      local chunk = diagnostics.chunk(entry.path, false, config)
      if chunk then
        table.insert(virt_marks, { line = lnum, chunks = { { " " .. chunk[1], chunk[2] } } })
      end
    end
  end

  if #lines == 0 then lines = { "" } end

  vim.bo[buf].modifiable = true
  vim.bo[buf].readonly   = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

  for _, pos in ipairs(icon_hl) do
    vim.api.nvim_buf_set_extmark(buf, ns, pos.line, pos.start, {
      end_col  = pos.end_,
      hl_group = pos.hl,
    })
  end
  for _, pos in ipairs(name_hl) do
    vim.api.nvim_buf_set_extmark(buf, ns, pos.line, pos.start, {
      end_col  = pos.end_,
      hl_group = pos.hl,
    })
  end
  for _, mark in ipairs(virt_marks) do
    vim.api.nvim_buf_set_extmark(buf, ns, mark.line, 0, {
      virt_text     = mark.chunks,
      virt_text_pos = "right_align",
      hl_mode       = "combine",
    })
  end

  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly   = true
  vim.bo[buf].modified   = false
  fade.attach(buf, { ns })

  if window.buffers_win and vim.api.nvim_win_is_valid(window.buffers_win) then
    vim.wo[window.buffers_win].statusline = header
  end
end

return M
