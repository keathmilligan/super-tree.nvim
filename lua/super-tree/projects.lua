-- Optional neovim-project integration: use its discovery and session switching.
local window = require("super-tree.window")
local filter = require("super-tree.filter")
local fade   = require("super-tree.fade")

local M = { entries = {}, all = {} }
M.search_pattern = nil
M.use_fzy = false
local ns = vim.api.nvim_create_namespace("SuperTreeProjects")

local function normalize(path)
  local full = vim.fn.fnamemodify(path, ":p"):gsub("/+$", "")
  return full ~= "" and full or "/"
end

local function is_cwd_project(entry, cwd)
  local prefix = entry.resolved == "/" and "/" or entry.resolved .. "/"
  return cwd == entry.resolved or cwd:sub(1, #prefix) == prefix
end

-- neovim-project history is oldest-first; higher index is more recent.
local function history_ranks()
  local ranks = {}
  local ok, history = pcall(require, "neovim-project.utils.history")
  if not ok or type(history.get_recent_projects) ~= "function" then
    return ranks
  end
  local success, recent = pcall(history.get_recent_projects)
  if not success or type(recent) ~= "table" then return ranks end
  for i, dir in ipairs(recent) do
    if type(dir) == "string" and dir ~= "" then
      ranks[vim.fn.resolve(normalize(dir))] = i
    end
  end
  return ranks
end

local function sort_by_last_used(entries)
  local cwd = vim.fn.resolve(normalize(vim.fn.getcwd()))
  local ranks = history_ranks()
  local active
  for _, entry in ipairs(entries) do
    if is_cwd_project(entry, cwd) then
      if not active or #entry.resolved > #active.resolved then active = entry end
    end
  end
  table.sort(entries, function(a, b)
    if (a == active) ~= (b == active) then return a == active end
    local ra, rb = ranks[a.resolved] or 0, ranks[b.resolved] or 0
    if ra ~= rb then return ra > rb end
    local na, nb = a.name:lower(), b.name:lower()
    if na ~= nb then return na < nb end
    return a.path < b.path
  end)
end

function M.collect()
  M.all = {}
  local ok, provider = pcall(require, "neovim-project.utils.path")
  if not ok or type(provider.get_all_projects_with_sorting) ~= "function" then
    M.entries = M.all
    return M.all
  end
  local success, paths = pcall(provider.get_all_projects_with_sorting)
  if not success or type(paths) ~= "table" then
    M.entries = M.all
    return M.all
  end
  local seen = {}
  for _, dir in ipairs(paths) do
    if type(dir) == "string" and dir ~= "" then
      local path = normalize(dir)
      local resolved = vim.fn.resolve(path)
      if not seen[resolved] and vim.fn.isdirectory(path) == 1 then
        seen[resolved] = true
        M.all[#M.all + 1] = {
          dir = dir, path = path, resolved = resolved,
          name = vim.fn.fnamemodify(path, ":t"),
        }
      end
    end
  end
  sort_by_last_used(M.all)
  M.entries = M.all
  return M.all
end

function M.entry_at_cursor()
  if not window.projects_win or not vim.api.nvim_win_is_valid(window.projects_win) then return nil end
  return M.entries[vim.api.nvim_win_get_cursor(window.projects_win)[1]]
end

function M.render(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  local cwd = vim.fn.resolve(normalize(vim.fn.getcwd()))
  local source = M.all or M.entries
  local active
  for _, entry in ipairs(source) do
    if is_cwd_project(entry, cwd) then
      if not active or #entry.resolved > #active.resolved then active = entry end
    end
  end
  M.entries = filter.filter_entries(source, M.search_pattern, M.use_fzy)
  local lines = {}
  for _, entry in ipairs(M.entries) do
    lines[#lines + 1] = (entry == active and " > " or "   ") .. entry.name
      .. "  " .. vim.fn.fnamemodify(entry.path, ":~")
  end
  if #lines == 0 then lines = { "" } end
  vim.bo[buf].modifiable = true
  vim.bo[buf].readonly = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, entry in ipairs(M.entries) do
    vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 3, {
      end_col = 3 + #entry.name,
      hl_group = entry == active and "SuperTreeProjectsCurrent" or "SuperTreeDirectory",
    })
    vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 3 + #entry.name, {
      end_col = #lines[i], hl_group = "SuperTreeNameFade1",
    })
  end
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  vim.bo[buf].modified = false
  fade.attach(buf, { ns })
  if window.projects_win and vim.api.nvim_win_is_valid(window.projects_win) then
    local total = #(M.all or M.entries)
    local header = " Projects  " .. #M.entries
    if M.search_pattern and M.search_pattern ~= "" then
      header = " Projects  " .. #M.entries .. "/" .. total .. '  "' .. M.search_pattern .. '"'
    end
    vim.wo[window.projects_win].statusline = header
  end
end

return M
