-- LSP diagnostic indicators, bubbled to parent directories like git status.

local M = {}

-- path -> vim.diagnostic.severity (lowest number = highest severity)
M.files = {}
M.dirs  = {}

M.enabled = true

local SEV = vim.diagnostic.severity

-- Match the gutter: vim.diagnostic.config().signs.text, then sign_define,
-- then Neovim's default E/W/I/H (single-cell, takes highlight fg).
local FALLBACK_SYMBOLS = {
  [SEV.ERROR] = "E",
  [SEV.WARN]  = "W",
  [SEV.INFO]  = "I",
  [SEV.HINT]  = "H",
}

local SIGN_NAME = {
  [SEV.ERROR] = "DiagnosticSignError",
  [SEV.WARN]  = "DiagnosticSignWarn",
  [SEV.INFO]  = "DiagnosticSignInfo",
  [SEV.HINT]  = "DiagnosticSignHint",
}

local KEY = {
  [SEV.ERROR] = "error",
  [SEV.WARN]  = "warn",
  [SEV.INFO]  = "info",
  [SEV.HINT]  = "hint",
}

local function gutter_symbol(sev)
  local cfg = vim.diagnostic.config()
  local signs = cfg and cfg.signs
  if type(signs) == "table" and type(signs.text) == "table" then
    local t = signs.text[sev]
    if type(t) == "string" and t ~= "" then
      return t
    end
  end
  local name = SIGN_NAME[sev]
  if name then
    local def = vim.fn.sign_getdefined(name)[1]
    if def and type(def.text) == "string" and def.text:match("%S") then
      return (def.text:gsub("%s+$", ""))
    end
  end
  return FALLBACK_SYMBOLS[sev]
end

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
  local key = KEY[sev]
  local user = config.diagnostics and config.diagnostics.symbols
  local text = (user and user[key]) or gutter_symbol(sev)
  if not text or text == "" then return nil end
  return { text, DEFAULT_HL[sev] }
end

return M
