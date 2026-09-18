-- Optional project-manager integration. A registered native provider takes
-- precedence; neovim-project remains the compatibility fallback.
local window = require("super-tree.window")
local filter = require("super-tree.filter")
local fade   = require("super-tree.fade")

local M = { entries = {}, all = {} }
M.search_pattern = nil
M.use_fzy = false

local provider_name
local provider
local ns = vim.api.nvim_create_namespace("SuperTreeProjects")

local function normalize(path)
  local full = vim.fn.fnamemodify(path, ":p"):gsub("/+$", "")
  return full ~= "" and full or "/"
end

local function is_cwd_project(entry, cwd)
  local prefix = entry.resolved == "/" and "/" or entry.resolved .. "/"
  return cwd == entry.resolved or cwd:sub(1, #prefix) == prefix
end

local function provider_current()
  if not provider or type(provider.current) ~= "function" then return nil end
  local ok, current = pcall(provider.current)
  if not ok or current == nil then return nil end
  local root = type(current) == "table" and current.root or current
  return type(root) == "string" and vim.fn.resolve(normalize(root)) or nil
end

local function active_entry(entries)
  local current = provider_current() or vim.fn.resolve(normalize(vim.fn.getcwd()))
  local active
  for _, entry in ipairs(entries) do
    if entry.active or is_cwd_project(entry, current) then
      if not active or #entry.resolved > #active.resolved then active = entry end
    end
  end
  return active
end

-- neovim-project history is oldest-first; higher index is more recent.
local function legacy_history_ranks()
  local ranks = {}
  local ok, history = pcall(require, "neovim-project.utils.history")
  if not ok or type(history.get_recent_projects) ~= "function" then return ranks end
  local success, recent = pcall(history.get_recent_projects)
  if not success or type(recent) ~= "table" then return ranks end
  for i, dir in ipairs(recent) do
    if type(dir) == "string" and dir ~= "" then
      ranks[vim.fn.resolve(normalize(dir))] = i
    end
  end
  return ranks
end

local function sort_by_last_used(entries, ranks)
  local active = active_entry(entries)
  table.sort(entries, function(a, b)
    if (a == active) ~= (b == active) then return a == active end
    local ra = tonumber(a.rank) or ranks[a.resolved] or 0
    local rb = tonumber(b.rank) or ranks[b.resolved] or 0
    if ra ~= rb then return ra > rb end
    local na, nb = a.name:lower(), b.name:lower()
    if na ~= nb then return na < nb end
    return a.path < b.path
  end)
end

local function append_entry(seen, value, index)
  local dir = type(value) == "table" and (value.root or value.path or value.dir) or value
  if type(dir) ~= "string" or dir == "" then return end
  local path = normalize(dir)
  local resolved = vim.fn.resolve(path)
  if seen[resolved] or vim.fn.isdirectory(path) ~= 1 then return end
  seen[resolved] = true
  M.all[#M.all + 1] = {
    dir = dir,
    root = resolved,
    path = path,
    resolved = resolved,
    name = type(value) == "table" and value.name or vim.fn.fnamemodify(path, ":t"),
    rank = type(value) == "table" and (value.rank or value.last_used) or index,
    active = type(value) == "table" and value.active or false,
  }
end

local function collect_native()
  if not provider or type(provider.projects) ~= "function" then return false end
  local ok, values = pcall(provider.projects, { order = "recent" })
  if not ok or type(values) ~= "table" then return true end
  local seen = {}
  for index, value in ipairs(values) do append_entry(seen, value, #values - index + 1) end
  sort_by_last_used(M.all, {})
  return true
end

local function collect_legacy()
  local ok, legacy = pcall(require, "neovim-project.utils.path")
  if not ok or type(legacy.get_all_projects_with_sorting) ~= "function" then return end
  local success, paths = pcall(legacy.get_all_projects_with_sorting)
  if not success or type(paths) ~= "table" then return end
  local seen = {}
  for index, dir in ipairs(paths) do append_entry(seen, dir, index) end
  sort_by_last_used(M.all, legacy_history_ranks())
end

function M.collect()
  M.all = {}
  if not collect_native() then collect_legacy() end
  M.entries = M.all
  return M.all
end

function M.register_provider(name, value)
  assert(type(name) == "string" and name ~= "", "project provider name is required")
  assert(type(value) == "table", "project provider must be a table")
  assert(type(value.projects) == "function", "project provider must define projects(opts)")
  assert(type(value.open) == "function", "project provider must define open(root)")
  provider_name = name
  provider = value
end

function M.unregister_provider(name)
  if name == nil or name == provider_name then
    provider_name = nil
    provider = nil
  end
end

function M.provider_name()
  return provider_name
end

function M.provider_manages_state()
  return provider ~= nil and provider.manages_tree_state == true
end

function M.open(entry)
  if provider then
    local ok, result, err = pcall(provider.open, entry.root or entry.dir)
    if not ok then return false, result end
    if result == false then return false, err end
    return true
  end
  local ok, legacy = pcall(require, "neovim-project.project")
  if not ok or type(legacy.switch_project) ~= "function" then
    return false, "Unable to load a project provider"
  end
  local switched, err = pcall(legacy.switch_project, entry.dir)
  return switched, err
end

function M.entry_at_cursor()
  if not window.projects_win or not vim.api.nvim_win_is_valid(window.projects_win) then return nil end
  return M.entries[vim.api.nvim_win_get_cursor(window.projects_win)[1]]
end

function M.render(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  local source = M.all or M.entries
  local active = active_entry(source)
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
