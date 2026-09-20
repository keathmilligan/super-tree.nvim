-- Coding-agent instance pane. Runtime-specific collection is delegated to
-- provider adapters; this module owns polling, filtering, rendering, and
-- three-row entry selection.

local window   = require("super-tree.window")
local filter   = require("super-tree.filter")
local fade     = require("super-tree.fade")
local opencode = require("super-tree.agent_providers.opencode")

local M = {
  all = {},
  entries = {},
  row_map = {},
  search_pattern = nil,
  use_fzy = false,
}

local ns = vim.api.nvim_create_namespace("SuperTreeAgents")
local config = {}
local on_change
local timer
local cancel_collect
local generation = 0
local running = false
local in_flight = false
local queued_force = false
local queued_manual = false

local DEFAULT_SYMBOLS = {
  running = "●",
  working = "●",
  waiting = "◉",
  blocked = "◉",
  question = "?",
  idle = "○",
  done = "✓",
  succeeded = "✓",
  error = "✕",
  failed = "✕",
  unknown = "?",
}

local STATUS_HIGHLIGHTS = {
  running = "SuperTreeAgentWorking",
  working = "SuperTreeAgentWorking",
  waiting = "SuperTreeAgentWaiting",
  blocked = "SuperTreeAgentBlocked",
  question = "SuperTreeAgentQuestion",
  idle = "SuperTreeAgentIdle",
  done = "SuperTreeAgentDone",
  succeeded = "SuperTreeAgentDone",
  error = "SuperTreeAgentError",
  failed = "SuperTreeAgentError",
  unknown = "SuperTreeAgentUnknown",
}

local function status_key(status)
  status = type(status) == "string" and status:lower() or "unknown"
  return STATUS_HIGHLIGHTS[status] and status or "unknown"
end

local function symbols()
  return vim.tbl_extend("force", DEFAULT_SYMBOLS, config.symbols or {})
end

local function stop_timer()
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
  timer = nil
end

function M.configure(opts, callback)
  config = opts or {}
  on_change = callback
end

function M.is_running()
  return running
end

function M.refresh(force, manual)
  if not running or config.enable == false then return end
  if in_flight then
    queued_force = queued_force or force == true
    queued_manual = queued_manual or manual == true
    return
  end

  in_flight = true
  local request_generation = generation
  cancel_collect = opencode.collect(config, { force = force == true }, function(ok, value)
    if request_generation ~= generation or not running then return end
    in_flight = false
    cancel_collect = nil
    if ok then
      M.all = value
      if on_change then on_change() end
    elseif manual then
      vim.notify("Could not refresh OpenCode agents: " .. tostring(value), vim.log.levels.WARN)
    end
    if queued_force then
      local notify_on_error = queued_manual
      queued_force = false
      queued_manual = false
      vim.schedule(function() M.refresh(true, notify_on_error) end)
    end
  end)
end

function M.start()
  M.stop()
  if config.enable == false then return end
  running = true
  generation = generation + 1
  M.refresh(true, false)

  local interval = math.max(250, tonumber(config.refresh_interval) or 2000)
  timer = vim.loop.new_timer()
  if timer then
    timer:start(interval, interval, vim.schedule_wrap(function()
      M.refresh(false, false)
    end))
  end
end

function M.stop()
  generation = generation + 1
  running = false
  in_flight = false
  queued_force = false
  queued_manual = false
  stop_timer()
  if cancel_collect then pcall(cancel_collect) end
  cancel_collect = nil
end

function M.entry_at_cursor()
  if not window.agents_win or not vim.api.nvim_win_is_valid(window.agents_win) then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(window.agents_win)[1]
  return M.row_map[row]
end

function M.row_for_id(id)
  if not id then return nil end
  for index, entry in ipairs(M.entries) do
    if entry.id == id then return (index - 1) * 3 + 1 end
  end
  return nil
end

function M.set_cursor_by_id(id)
  local row = M.row_for_id(id)
  if not row or not window.agents_win or not vim.api.nvim_win_is_valid(window.agents_win) then
    return false
  end
  pcall(vim.api.nvim_win_set_cursor, window.agents_win, { row, 0 })
  return true
end

function M.move(delta)
  if not window.agents_win or not vim.api.nvim_win_is_valid(window.agents_win) then return end
  if #M.entries == 0 then return end
  local current = M.entry_at_cursor()
  local index = 1
  if current then
    for i, entry in ipairs(M.entries) do
      if entry.id == current.id then
        index = i
        break
      end
    end
  end
  index = math.max(1, math.min(#M.entries, index + delta))
  vim.api.nvim_win_set_cursor(window.agents_win, { (index - 1) * 3 + 1, 0 })
end

local function model_line(entry)
  local parts = { entry.agent or "OpenCode" }
  local model = entry.model or "model unavailable"
  if entry.model_provider and entry.model_provider ~= "" then
    model = entry.model_provider .. "/" .. model
  end
  parts[#parts + 1] = model
  if entry.model_variant and entry.model_variant ~= "" then
    parts[#parts + 1] = entry.model_variant
  end
  return table.concat(parts, " · ")
end

function M.render(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  local selected = M.entry_at_cursor()
  M.entries = filter.filter_entries(M.all, M.search_pattern, M.use_fzy)
  M.row_map = {}

  -- Keep a cell clear at the right edge, like the tree; over-wide rows fade
  -- out over their last three characters.
  local avail = window.width_for_buf(buf) - 1
  local lines = {}
  local marks = {}
  local fade_marks = {}
  local status_symbols = symbols()
  for index, entry in ipairs(M.entries) do
    local key = status_key(entry.status)
    local icon = status_symbols[entry.status] or status_symbols[key] or status_symbols.unknown
    local status = entry.status or "unknown"
    local rows = {
      " " .. icon .. " " .. status .. "  " .. (entry.project or "unknown project"),
      "   " .. (entry.description or entry.title or "OpenCode session"),
      "   " .. model_line(entry),
    }
    local first = #lines + 1
    for r = 1, 3 do
      local row = rows[r]
      if vim.fn.strdisplaywidth(row) > avail then
        row = fade.truncate_to_width(row, avail)
        fade.add_right_fade(fade_marks, first + r - 2, 0, row)
      end
      lines[#lines + 1] = row
    end
    local row1, row3 = lines[first], lines[first + 2]
    M.row_map[first] = entry
    M.row_map[first + 1] = entry
    M.row_map[first + 2] = entry

    local icon_start = 1
    local icon_end = icon_start + #icon
    local status_start = icon_end + 1
    local status_end = math.min(status_start + #status, #row1)
    local project_start = status_start + #status + 2
    if status_end > icon_start then
      marks[#marks + 1] = {
        row = first - 1, start = icon_start, finish = status_end,
        hl = STATUS_HIGHLIGHTS[key],
      }
    end
    if #row1 > project_start then
      marks[#marks + 1] = {
        row = first - 1, start = project_start, finish = #row1,
        hl = "SuperTreeDirectory",
      }
    end
    if #row3 > 3 then
      marks[#marks + 1] = {
        row = first + 1, start = 3, finish = #row3,
        hl = "SuperTreeNameFade1",
      }
    end
  end
  if #lines == 0 then lines = { "" } end

  vim.bo[buf].modifiable = true
  vim.bo[buf].readonly = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, mark in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(buf, ns, mark.row, mark.start, {
      end_col = mark.finish,
      hl_group = mark.hl,
    })
  end
  for _, mark in ipairs(fade_marks) do
    vim.api.nvim_buf_set_extmark(buf, ns, mark.line, mark.start, {
      end_col = mark.end_,
      hl_group = mark.hl,
    })
  end
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  vim.bo[buf].modified = false
  fade.attach(buf, { ns })

  if selected then M.set_cursor_by_id(selected.id) end
end

function M._provider()
  return opencode
end

function M._is_refreshing()
  return in_flight
end

return M
