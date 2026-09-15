-- Optional neovim-project integration: use its discovery and session switching.
local window = require("super-tree.window")

local M = { entries = {} }
local ns = vim.api.nvim_create_namespace("SuperTreeProjects")

local function normalize(path)
  local full = vim.fn.fnamemodify(path, ":p"):gsub("/+$", "")
  return full ~= "" and full or "/"
end

function M.collect()
  M.entries = {}
  local ok, provider = pcall(require, "neovim-project.utils.path")
  if not ok or type(provider.get_all_projects_with_sorting) ~= "function" then
    return M.entries
  end
  local success, paths = pcall(provider.get_all_projects_with_sorting)
  if not success or type(paths) ~= "table" then return M.entries end
  local seen = {}
  for _, dir in ipairs(paths) do
    if type(dir) == "string" and dir ~= "" then
      local path = normalize(dir)
      local resolved = vim.fn.resolve(path)
      if not seen[resolved] and vim.fn.isdirectory(path) == 1 then
        seen[resolved] = true
        M.entries[#M.entries + 1] = {
          dir = dir, path = path, resolved = resolved,
          name = vim.fn.fnamemodify(path, ":t"),
        }
      end
    end
  end
  return M.entries
end

function M.entry_at_cursor()
  if not window.projects_win or not vim.api.nvim_win_is_valid(window.projects_win) then return nil end
  return M.entries[vim.api.nvim_win_get_cursor(window.projects_win)[1] - 1]
end

function M.render(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  local cwd = vim.fn.resolve(normalize(vim.fn.getcwd()))
  local active
  for _, entry in ipairs(M.entries) do
    local prefix = entry.resolved == "/" and "/" or entry.resolved .. "/"
    if cwd == entry.resolved or cwd:sub(1, #prefix) == prefix then
      if not active or #entry.resolved > #active.resolved then active = entry end
    end
  end
  local header = " Projects  " .. #M.entries
  local lines = { header }
  for _, entry in ipairs(M.entries) do
    lines[#lines + 1] = (entry == active and " > " or "   ") .. entry.name
      .. "  " .. vim.fn.fnamemodify(entry.path, ":~")
  end
  vim.bo[buf].modifiable = true
  vim.bo[buf].readonly = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_set_extmark(buf, ns, 0, 1, { end_col = 9, hl_group = "SuperTreeDirectory" })
  for i, entry in ipairs(M.entries) do
    vim.api.nvim_buf_set_extmark(buf, ns, i, 3, {
      end_col = 3 + #entry.name,
      hl_group = entry == active and "SuperTreeProjectsCurrent" or "SuperTreeDirectory",
    })
    vim.api.nvim_buf_set_extmark(buf, ns, i, 3 + #entry.name, {
      end_col = #lines[i + 1], hl_group = "SuperTreeNameFade1",
    })
  end
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  vim.bo[buf].modified = false
  if window.projects_win and vim.api.nvim_win_is_valid(window.projects_win) then
    vim.wo[window.projects_win].statusline = header
  end
end

return M
