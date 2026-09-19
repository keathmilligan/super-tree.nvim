-- OpenCode V2 agent discovery. Uses `opencode2 api` so service discovery and
-- authentication stay owned by OpenCode rather than being duplicated here.

local M = {}

local detail_cache = {}
local tui_history = {}
local injected_runner
local injected_cwd_resolver

local function decode_json(text)
  local decode = vim.json and vim.json.decode or vim.fn.json_decode
  local ok, value = pcall(decode, text)
  if not ok or type(value) ~= "table" then
    return nil, "invalid JSON response"
  end
  return value
end

local function default_runner(argv, opts, callback)
  opts = opts or {}
  local stdout, stderr = {}, {}
  local finished = false
  local timer
  local job

  local function close_timer()
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    timer = nil
  end

  local function finish(ok, value)
    if finished then return end
    finished = true
    close_timer()
    callback(ok, value)
  end

  local started, result = pcall(vim.fn.jobstart, argv, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      for _, line in ipairs(data or {}) do
        if line ~= "" then stdout[#stdout + 1] = line end
      end
    end,
    on_stderr = function(_, data)
      for _, line in ipairs(data or {}) do
        if line ~= "" then stderr[#stderr + 1] = line end
      end
    end,
    on_exit = function(_, code)
      if code == 0 then
        finish(true, table.concat(stdout, "\n"))
      else
        local message = table.concat(stderr, "\n")
        if message == "" then message = "OpenCode API exited with code " .. tostring(code) end
        finish(false, message)
      end
    end,
  })
  if not started then
    finish(false, tostring(result))
    return function() end
  end
  job = result

  if type(job) ~= "number" or job <= 0 then
    finish(false, "could not start OpenCode V2")
    return function() end
  end

  local timeout = math.max(100, tonumber(opts.timeout) or 5000)
  timer = vim.loop.new_timer()
  if timer then
    timer:start(timeout, 0, function()
      vim.schedule(function()
        if finished then return end
        finish(false, "OpenCode API request timed out")
        pcall(vim.fn.jobstop, job)
      end)
    end)
  end

  return function()
    if finished then return end
    finished = true
    close_timer()
    pcall(vim.fn.jobstop, job)
  end
end

local function command_argv(command, path)
  return { command, "api", "get", path }
end

local function run_json(command, path, timeout, callback)
  local runner = injected_runner or default_runner
  return runner(command_argv(command, path), { timeout = timeout }, function(ok, output)
    if not ok then
      callback(false, output)
      return
    end
    local value, err = decode_json(output)
    if not value then
      callback(false, err)
      return
    end
    callback(true, value)
  end)
end

local function run_text(argv, timeout, callback)
  local runner = injected_runner or default_runner
  return runner(argv, { timeout = timeout }, callback)
end

local function normalize_path(path)
  if type(path) ~= "string" or path == "" then return nil end
  local full = vim.fn.fnamemodify(path, ":p"):gsub("/+$", "")
  if full == "" then return "/" end
  local resolved = vim.fn.resolve(full)
  return type(resolved) == "string" and resolved ~= "" and resolved or full
end

local NON_TUI_COMMANDS = {
  acp = true,
  api = true,
  auth = true,
  completions = true,
  console = true,
  debug = true,
  export = true,
  import = true,
  mcp = true,
  mini = true,
  models = true,
  pair = true,
  plugin = true,
  run = true,
  serve = true,
  service = true,
  session = true,
  stats = true,
  uninstall = true,
  update = true,
  upgrade = true,
}
local FLAGS_WITH_VALUES = {
  ["--completions"] = true,
  ["--log-level"] = true,
  ["--prompt"] = true,
  ["--server"] = true,
  ["--session"] = true,
  ["-s"] = true,
}
local TERMINATING_FLAGS = {
  ["--completions"] = true,
  ["--help"] = true,
  ["--version"] = true,
  ["-h"] = true,
  ["-v"] = true,
}

local function is_full_tui(comm, args)
  local executable = type(comm) == "string" and comm:match("([^/]+)$") or ""
  if executable ~= "opencode2" and executable ~= "opencode2.exe" then return false end
  local rest = type(args) == "string" and args:match("^%s*%S+%s*(.*)$") or ""
  local tokens = {}
  for token in rest:gmatch("%S+") do
    tokens[#tokens + 1] = token:gsub("^[\"']", ""):gsub("[\"']$", "")
  end
  local index = 1
  while index <= #tokens do
    local token = tokens[index]
    local flag = token:match("^([^=]+)=") or token
    if TERMINATING_FLAGS[flag] then return false end
    if FLAGS_WITH_VALUES[flag] then
      index = index + (token:find("=", 1, true) and 1 or 2)
    elseif token:sub(1, 1) == "-" then
      index = index + 1
    else
      return not NON_TUI_COMMANDS[token]
    end
  end
  return true
end

local function parse_processes(output)
  local current_uid = vim.loop.getuid and vim.loop.getuid() or nil
  local result = {}
  for line in tostring(output or ""):gmatch("[^\r\n]+") do
    local pid, uid, comm, args = line:match("^%s*(%d+)%s+(%d+)%s+(%S+)%s*(.*)$")
    if pid and (not current_uid or tonumber(uid) == current_uid) and is_full_tui(comm, args) then
      result[#result + 1] = {
        pid = tonumber(pid),
        args = args,
      }
    end
  end
  table.sort(result, function(a, b) return a.pid < b.pid end)
  return result
end

local function proc_cwd(pid)
  if injected_cwd_resolver then return normalize_path(injected_cwd_resolver(pid)) end
  local ok, value = pcall(vim.loop.fs_readlink, "/proc/" .. tostring(pid) .. "/cwd")
  if not ok then return nil end
  return normalize_path(value)
end

local function lsof_cwd(output)
  for line in tostring(output or ""):gmatch("[^\r\n]+") do
    if line:sub(1, 1) == "n" and #line > 1 then
      return normalize_path(line:sub(2))
    end
  end
  return nil
end

local function collect_tuis(config, timeout, add_handle, callback)
  local ps = config.process_command or "ps"
  add_handle(run_text({ ps, "-ww", "-eo", "pid=,uid=,comm=,args=" }, timeout, function(ok, output)
    if not ok then
      callback(false, output)
      return
    end
    local candidates = parse_processes(output)
    if #candidates == 0 then
      callback(true, {})
      return
    end

    local entries = {}
    local unresolved = {}
    for _, candidate in ipairs(candidates) do
      local directory = proc_cwd(candidate.pid)
      if directory then
        candidate.directory = directory
        entries[#entries + 1] = candidate
      else
        unresolved[#unresolved + 1] = candidate
      end
    end
    if #unresolved == 0 or vim.fn.executable("lsof") ~= 1 then
      callback(true, entries)
      return
    end

    local pending = #unresolved
    for _, candidate in ipairs(unresolved) do
      add_handle(run_text({ "lsof", "-a", "-p", tostring(candidate.pid), "-d", "cwd", "-Fn" },
        timeout, function(lsof_ok, lsof_output)
          if lsof_ok then
            local directory = lsof_cwd(lsof_output)
            if directory then
              candidate.directory = directory
              entries[#entries + 1] = candidate
            end
          end
          pending = pending - 1
          if pending == 0 then
            table.sort(entries, function(a, b) return a.pid < b.pid end)
            callback(true, entries)
          end
        end))
    end
  end))
end

local function short_id(id)
  if #id <= 16 then return id end
  return id:sub(1, 12) .. "…"
end

local function active_status(value)
  local status = type(value) == "table" and value.type or value
  if type(status) ~= "string" or status == "" then return "unknown" end
  status = status:lower()
  return status == "running" and "working" or status
end

local function has_pending(response)
  if type(response) ~= "table" or type(response.data) ~= "table" then return false end
  return next(response.data) ~= nil
end

local function prompted_status(base, pending)
  if pending.permission then return "blocked" end
  if pending.question or pending.form then return "question" end
  return base
end

local function model_fields(info)
  local model = type(info) == "table" and info.model or nil
  if type(model) ~= "table" then
    return "model unavailable", nil, nil
  end
  local name = type(model.id) == "string" and model.id or "model unavailable"
  local provider = type(model.providerID) == "string" and model.providerID or nil
  local variant = type(model.variant) == "string" and model.variant or nil
  return name, provider, variant
end

local function project_name(directory)
  local project = directory and vim.fn.fnamemodify(directory, ":t") or "unknown project"
  if project == "" and directory == "/" then return "/" end
  return project
end

local function update_searchable(entry)
  entry.name = table.concat({
    entry.status or "unknown",
    entry.project or "unknown project",
    entry.title or "",
    entry.agent or "",
    entry.model_provider or "",
    entry.model or "",
    entry.model_variant or "",
    entry.pid and tostring(entry.pid) or "",
  }, " ")
  entry.path = entry.directory or ""
  return entry
end

local function entry_for(id, status, info)
  info = type(info) == "table" and info or {}
  local directory = normalize_path(info.location and info.location.directory)
  local title = type(info.title) == "string" and info.title ~= "" and info.title
    or ("OpenCode session " .. short_id(id))
  local agent = type(info.agent) == "string" and info.agent ~= "" and info.agent
    or "OpenCode"
  local model, model_provider, model_variant = model_fields(info)
  return update_searchable({
    id = id,
    session_id = id,
    instance = "session",
    provider = "opencode",
    status = status,
    title = title,
    description = title,
    directory = directory,
    project = project_name(directory),
    agent = agent,
    model = model,
    model_provider = model_provider,
    model_variant = model_variant,
  })
end

local function idle_entry(tui, status)
  local title = "OpenCode TUI · PID " .. tostring(tui.pid)
  local unavailable = status == "unknown" and "agent status unavailable" or "no active agent"
  return update_searchable({
    id = "opencode-tui:" .. tostring(tui.pid),
    instance = "tui",
    pid = tui.pid,
    provider = "opencode",
    status = status or "idle",
    title = title,
    description = title,
    directory = tui.directory,
    project = project_name(tui.directory),
    agent = unavailable,
    model = "model unavailable",
  })
end

local function done_entry(tui, previous)
  local entry = vim.deepcopy(previous)
  entry.id = "opencode-tui:" .. tostring(tui.pid)
  entry.instance = "tui"
  entry.pid = tui.pid
  entry.status = "done"
  entry.tui_directory = tui.directory
  entry.directory = entry.directory or tui.directory
  entry.project = project_name(tui.directory)
  return update_searchable(entry)
end

local STATUS_PRIORITY = {
  blocked = 1,
  question = 1,
  waiting = 1,
  running = 2,
  working = 2,
  idle = 3,
  done = 4,
  succeeded = 4,
  error = 5,
  failed = 5,
  unknown = 9,
}
local sort_entries

local function match_score(tui_directory, session_directory)
  if not tui_directory or not session_directory then return nil end
  if tui_directory == session_directory then return 1000000 + #tui_directory end
  local tui_prefix = tui_directory == "/" and "/" or tui_directory .. "/"
  if session_directory:sub(1, #tui_prefix) == tui_prefix then
    return 500000 + #tui_directory
  end
  local session_prefix = session_directory == "/" and "/" or session_directory .. "/"
  if tui_directory:sub(1, #session_prefix) == session_prefix then
    return 400000 + #session_directory
  end
  return nil
end

local function reconcile(tuis, active_entries, active_known)
  local entries = {}
  local used = {}
  local live_pids = {}
  table.sort(tuis, function(a, b) return a.pid < b.pid end)

  for _, tui in ipairs(tuis) do
    live_pids[tui.pid] = true
    local best_index, best_score
    if active_known then
      for index, entry in ipairs(active_entries) do
        if not used[index] then
          local score = match_score(tui.directory, entry.directory)
          if score and (not best_score or score > best_score) then
            best_index, best_score = index, score
          end
        end
      end
    end

    if best_index then
      used[best_index] = true
      local entry = active_entries[best_index]
      entry.id = "opencode-tui:" .. tostring(tui.pid)
      entry.instance = "tui"
      entry.pid = tui.pid
      entry.tui_directory = tui.directory
      entry.directory = entry.directory or tui.directory
      entry.project = project_name(tui.directory)
      entry = update_searchable(entry)
      tui_history[tui.pid] = vim.deepcopy(entry)
      entries[#entries + 1] = entry
    else
      local previous = tui_history[tui.pid]
      if active_known and previous then
        entries[#entries + 1] = done_entry(tui, previous)
      else
        entries[#entries + 1] = idle_entry(tui, active_known and "idle" or "unknown")
      end
    end
  end

  for pid in pairs(tui_history) do
    if not live_pids[pid] then tui_history[pid] = nil end
  end

  for index, entry in ipairs(active_entries) do
    if not used[index] then entries[#entries + 1] = entry end
  end
  sort_entries(entries)
  return entries
end

sort_entries = function(entries)
  table.sort(entries, function(a, b)
    local ap = STATUS_PRIORITY[a.status] or STATUS_PRIORITY.unknown
    local bp = STATUS_PRIORITY[b.status] or STATUS_PRIORITY.unknown
    if ap ~= bp then return ap < bp end
    local aproject, bproject = a.project:lower(), b.project:lower()
    if aproject ~= bproject then return aproject < bproject end
    local atitle, btitle = a.title:lower(), b.title:lower()
    if atitle ~= btitle then return atitle < btitle end
    return a.id < b.id
  end)
end

-- Collect a complete OpenCode TUI/active-agent snapshot.
-- callback(ok, entries_or_error).
-- Returned function cancels all jobs owned by this collection.
function M.collect(config, opts, callback)
  config = config or {}
  opts = opts or {}
  local command = config.command or "opencode2"
  local timeout = tonumber(config.timeout) or 5000
  local refresh_age = tonumber(config.metadata_refresh_interval) or 30000
  local cancelled = false
  local finished = false
  local handles = {}
  local processes_done = false
  local processes_ok = false
  local processes = {}
  local process_error
  local sessions_done = false
  local sessions_ok = false
  local session_entries = {}
  local session_error

  local function add_handle(handle)
    if type(handle) == "function" then handles[#handles + 1] = handle end
  end

  local function finish(ok, value)
    if cancelled or finished then return end
    finished = true
    callback(ok, value)
  end

  local function finish_if_ready()
    if cancelled or finished or not processes_done or not sessions_done then return end
    if processes_ok and sessions_ok then
      finish(true, reconcile(processes, session_entries, true))
    elseif processes_ok and #processes > 0 then
      finish(true, reconcile(processes, {}, false))
    elseif sessions_ok and #session_entries > 0 then
      sort_entries(session_entries)
      finish(true, session_entries)
    else
      finish(false, session_error or process_error or "could not discover OpenCode TUI instances")
    end
  end

  collect_tuis(config, timeout, add_handle, function(ok, value)
    if cancelled then return end
    processes_done = true
    processes_ok = ok
    if ok then processes = value else process_error = value end
    finish_if_ready()
  end)

  local function fail_sessions(message)
    sessions_done = true
    sessions_ok = false
    session_error = message
    finish_if_ready()
  end

  if not injected_runner and vim.fn.executable(command) ~= 1 then
    fail_sessions(command .. " is not executable")
  else
    add_handle(run_json(command, "/api/session/active", timeout, function(ok, response)
      if cancelled then return end
      if not ok then
        fail_sessions(response)
        return
      end
      local active = response.data
      if type(active) ~= "table" then
        fail_sessions("OpenCode active-session response has no data map")
        return
      end

      local ids = {}
      for id in pairs(active) do
        if type(id) == "string" then ids[#ids + 1] = id end
      end
      table.sort(ids)

      local active_set = {}
      for _, id in ipairs(ids) do active_set[id] = true end
      for id in pairs(detail_cache) do
        if not active_set[id] then detail_cache[id] = nil end
      end

      if #ids == 0 then
        sessions_done = true
        sessions_ok = true
        session_entries = {}
        finish_if_ready()
        return
      end

      local now = vim.loop.hrtime() / 1000000
      local details = {}
      local prompts = {}
      local pending = 0
      local completed = false
      local launching = true

      local function complete_if_ready()
        if cancelled or completed or launching or pending > 0 then return end
        completed = true
        local entries = {}
        for _, id in ipairs(ids) do
          local cached = details[id] or (detail_cache[id] and detail_cache[id].value)
          local status = prompted_status(active_status(active[id]), prompts[id] or {})
          entries[#entries + 1] = entry_for(id, status, cached)
        end
        sort_entries(entries)
        sessions_done = true
        sessions_ok = true
        session_entries = entries
        finish_if_ready()
      end

      for _, id in ipairs(ids) do
        prompts[id] = {}
        local cached = detail_cache[id]
        local fresh = cached and not opts.force and now - cached.fetched_at < refresh_age
        if fresh then
          details[id] = cached.value
        else
          pending = pending + 1
          add_handle(run_json(command, "/api/session/" .. id, timeout, function(detail_ok, payload)
            if cancelled then return end
            if detail_ok and type(payload.data) == "table" then
              details[id] = payload.data
              detail_cache[id] = { value = payload.data, fetched_at = vim.loop.hrtime() / 1000000 }
            elseif cached then
              details[id] = cached.value
            end
            pending = pending - 1
            complete_if_ready()
          end))
        end

        local prompt_paths = {
          permission = "/api/session/" .. id .. "/permission",
          question = "/api/session/" .. id .. "/question",
          form = "/api/session/" .. id .. "/form",
        }
        for kind, path in pairs(prompt_paths) do
          local prompt_kind = kind
          pending = pending + 1
          add_handle(run_json(command, path, timeout, function(prompt_ok, payload)
            if cancelled then return end
            if prompt_ok then prompts[id][prompt_kind] = has_pending(payload) end
            pending = pending - 1
            complete_if_ready()
          end))
        end
      end
      launching = false
      complete_if_ready()
    end))
  end

  return function()
    if cancelled then return end
    cancelled = true
    for _, cancel in ipairs(handles) do pcall(cancel) end
  end
end

-- Internal test seam; providers are not a public registration API yet.
function M._set_runner(runner)
  injected_runner = runner
end

function M._set_cwd_resolver(resolver)
  injected_cwd_resolver = resolver
end

function M._parse_processes(output)
  return parse_processes(output)
end

function M._reset()
  injected_runner = nil
  injected_cwd_resolver = nil
  detail_cache = {}
  tui_history = {}
end

return M
