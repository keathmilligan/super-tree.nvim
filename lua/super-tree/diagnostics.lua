-- LSP diagnostic indicators, bubbled to parent directories like git status.

local M = {}

-- path -> vim.diagnostic.severity (lowest number = highest severity)
M.files = {}
M.dirs  = {}

M.enabled = true

local SEV = vim.diagnostic.severity

local DEFAULT_SYMBOLS = {
  [SEV.ERROR] = "",
  [SEV.WARN]  = "",
  [SEV.INFO]  = "",
  [SEV.HINT]  = "",
}

local DEFAULT_HL = {
  [SEV.ERROR] = "SuperTreeDiagnosticError",
  [SEV.WARN]  = "SuperTreeDiagnosticWarn",
  [SEV.INFO]  = "SuperTreeDiagnosticInfo",
  [SEV.HINT]  = "SuperTreeDiagnosticHint",
}

function M.refresh()
  M.files = {}
  M.dirs  = {}
  if not M.enabled then return end

  local ok, diags = pcall(vim.diagnostic.get, nil)
  if not ok or not diags then return end

  for _, d in ipairs(diags) do
    local bufnr = d.bufnr
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      local path = vim.api.nvim_buf_get_name(bufnr)
      if path ~= "" then
        local sev = d.severity
        if not M.files[path] or sev < M.files[path] then
          M.files[path] = sev
        end
      end
    end
  end

  for path, sev in pairs(M.files) do
    local dir = path:match("^(.*)/[^/]+$")
    while dir and dir ~= "" do
      if not M.dirs[dir] or sev < M.dirs[dir] then
        M.dirs[dir] = sev
      end
      local parent = dir:match("^(.*)/[^/]+$")
      if not parent or parent == dir then break end
      dir = parent
    end
  end
end

function M.severity(path, is_dir)
  if M.files[path] then return M.files[path] end
  if is_dir then return M.dirs[path] end
  return nil
end

function M.chunk(path, is_dir, config)
  local sev = M.severity(path, is_dir)
  if not sev then return nil end
  local symbols = (config.diagnostics and config.diagnostics.symbols) or {}
  local key = ({ [SEV.ERROR] = "error", [SEV.WARN] = "warn", [SEV.INFO] = "info", [SEV.HINT] = "hint" })[sev]
  local text = symbols[key] or DEFAULT_SYMBOLS[sev]
  if not text or text == "" then return nil end
  return { text, DEFAULT_HL[sev] }
end

return M
