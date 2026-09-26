-- OpenCode V2 agent discovery. Queries the shared background service directly
-- over HTTP using its registration file, the same discovery contract as
-- `@opencode/client`'s `Service.discover()`. SuperTree never starts the
-- service; when it is not running, TUIs are reported without a status.

local M = {}

local detail_cache = {}
local tui_history = {}
local injected_runner
local injected_http
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
        if message == "" then message = argv[1] .. " exited with code " .. tostring(code) end
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
    finish(false, "could not start " .. tostring(argv[1]))
    return function() end
  end

  local timeout = math.max(100, tonumber(opts.timeout) or 5000)
  timer = vim.loop.new_timer()
  if timer then
    timer:start(timeout, 0, function()
      vim.schedule(function()
        if finished then return end
        finish(false, tostring(argv[1]) .. " timed out")
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

local function run_text(argv, timeout, callback)
  local runner = injected_runner or default_runner
  return runner(argv, { timeout = timeout }, callback)
end

local BASE64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64(text)
  local out = {}
  for i = 1, #text, 3 do
    local a, b, c = text:byte(i, i + 2)
    local n = a * 65536 + (b or 0) * 256 + (c or 0)
    local d1 = math.floor(n / 262144) % 64
    local d2 = math.floor(n / 4096) % 64
    local d3 = math.floor(n / 64) % 64
    local d4 = n % 64
    out[#out + 1] = BASE64:sub(d1 + 1, d1 + 1) .. BASE64:sub(d2 + 1, d2 + 1)
      .. (b and BASE64:sub(d3 + 1, d3 + 1) or "=")
      .. (c and BASE64:sub(d4 + 1, d4 + 1) or "=")
  end
  return table.concat(out)
end

local function service_file(config)
  if type(config.service_file) == "string" and config.service_file ~= "" then
    return vim.fn.expand(config.service_file)
  end
  local state = vim.env.XDG_STATE_HOME
  if type(state) ~= "string" or state == "" then
    local home = vim.env.HOME
    if type(home) ~= "string" or home == "" then home = vim.fn.expand("~") end
    state = home .. "/.local/state"
  end
  return state .. "/opencode/service.json"
end

local function parse_url(url)
  if type(url) ~= "string" then return nil end
  local rest = url:match("^[hH][tT][tT][pP]://(.*)$")
  if not rest then return nil end
  local authority = rest:match("^([^/?#]*)")
  local host, port = authority:match("^%[([^%]]+)%]:?(%d*)$")
  if not host then host, port = authority:match("^([^:@]+):?(%d*)$") end
  if not host or host == "" then return nil end
  local base = rest:sub(#authority + 1):match("^([^?#]*)"):gsub("/+$", "")
  return {
    host = host,
    port = tonumber(port) or 80,
    authority = authority,
    base = base,
  }
end

local NOT_REGISTERED = "OpenCode server is not running"

-- Read the shared service registration. The service rewrites this file
-- whenever it restarts, so it is read once per collection.
local function read_endpoint(path)
  local uv = vim.loop
  local fd = uv.fs_open(path, "r", 438)
  if not fd then return nil, NOT_REGISTERED end
  local stat = uv.fs_fstat(fd)
  local data = stat and uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  local info = type(data) == "string" and decode_json(data)
  if type(info) ~= "table" then return nil, "invalid OpenCode service registration" end
  local endpoint = parse_url(info.url)
  if not endpoint then return nil, "unsupported OpenCode service URL" end
  if type(info.password) == "string" then
    endpoint.authorization = "Basic " .. base64("opencode:" .. info.password)
  end
  return endpoint
end

-- Parse a buffered HTTP/1.1 response. Returns "incomplete", "error" plus a
-- message, or "done" plus the status code and decoded body.
local function parse_response(data, eof)
  local head_end = data:find("\r\n\r\n", 1, true)
  if not head_end then
    if eof then return "error", "truncated HTTP response" end
    return "incomplete"
  end
  local head = data:sub(1, head_end - 1)
  local body = data:sub(head_end + 4)
  local status = tonumber(head:match("^HTTP/%d[%.%d]*%s+(%d%d%d)"))
  if not status then return "error", "invalid HTTP response" end
  local headers = {}
  for line in head:gmatch("\r\n([^\r\n]*)") do
    local name, value = line:match("^([^:]+):%s*(.-)%s*$")
    if name then headers[name:lower()] = value end
  end

  local encoding = headers["transfer-encoding"]
  if encoding and encoding:lower():find("chunked", 1, true) then
    local parts, pos = {}, 1
    while true do
      local line_end = body:find("\r\n", pos, true)
      if not line_end then break end
      local size = tonumber(body:sub(pos, line_end - 1):match("^%x+") or "", 16)
      if not size then return "error", "invalid chunked HTTP response" end
      if size == 0 then return "done", status, table.concat(parts) end
      local start = line_end + 2
      if #body < start + size + 1 then break end
      parts[#parts + 1] = body:sub(start, start + size - 1)
      pos = start + size + 2
    end
    if eof then return "error", "truncated HTTP response" end
    return "incomplete"
  end

  local length = tonumber(headers["content-length"])
  if length then
    if #body >= length then return "done", status, body:sub(1, length) end
    if eof then return "error", "truncated HTTP response" end
    return "incomplete"
  end
  if eof then return "done", status, body end
  return "incomplete"
end

-- Minimal HTTP/1.1 GET over libuv for the local service endpoint.
-- callback(true, { status, body }) or callback(false, message, not_running),
-- where `not_running` marks a registered service that no longer accepts
-- connections (its registration file outlives it).
local function default_http(endpoint, path, opts, callback)
  local uv = vim.loop
  opts = opts or {}
  local finished = false
  local cancelled = false
  local tcp, timer
  local buffer = ""

  local function cleanup()
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    timer = nil
    if tcp and not tcp:is_closing() then tcp:close() end
  end

  local function finish(ok, value, not_running)
    if finished then return end
    finished = true
    cleanup()
    vim.schedule(function()
      if not cancelled then callback(ok, value, not_running) end
    end)
  end

  local function handle(eof)
    local state, a, b = parse_response(buffer, eof)
    if state == "done" then
      finish(true, { status = a, body = b })
    elseif state == "error" then
      finish(false, a)
    end
  end

  local lines = {
    "GET " .. endpoint.base .. path .. " HTTP/1.1",
    "Host: " .. endpoint.authority,
    "Accept: application/json",
  }
  if endpoint.authorization then
    lines[#lines + 1] = "Authorization: " .. endpoint.authorization
  end
  lines[#lines + 1] = "Connection: close"
  local request = table.concat(lines, "\r\n") .. "\r\n\r\n"

  local function connect(address)
    if finished then return end
    tcp = uv.new_tcp()
    if not tcp then
      finish(false, "could not create OpenCode service connection", true)
      return
    end
    local ok, err = pcall(tcp.connect, tcp, address, endpoint.port, function(connect_err)
      if finished then return end
      if connect_err then
        finish(false, "could not connect to OpenCode service: " .. tostring(connect_err), true)
        return
      end
      tcp:write(request)
      tcp:read_start(function(read_err, chunk)
        if finished then return end
        if read_err then
          finish(false, "OpenCode service read failed: " .. tostring(read_err))
        elseif chunk then
          buffer = buffer .. chunk
          handle(false)
        else
          handle(true)
        end
      end)
    end)
    if not ok then
      finish(false, "could not connect to OpenCode service: " .. tostring(err), true)
    end
  end

  local host = endpoint.host
  if host:match("^%d+%.%d+%.%d+%.%d+$") or host:find(":", 1, true) then
    connect(host)
  else
    uv.getaddrinfo(host, tostring(endpoint.port), { socktype = "stream" }, function(err, results)
      if err or type(results) ~= "table" or not results[1] then
        finish(false, "could not resolve OpenCode service host: " .. tostring(err or host), true)
      else
        connect(results[1].addr)
      end
    end)
  end

  local timeout = math.max(100, tonumber(opts.timeout) or 5000)
  timer = uv.new_timer()
  if timer then
    timer:start(timeout, 0, function()
      finish(false, "OpenCode API request timed out")
    end)
  end

  return function()
    cancelled = true
    if finished then return end
    finished = true
    cleanup()
  end
end

local function http_json(endpoint, path, timeout, callback)
  local requester = injected_http or default_http
  return requester(endpoint, path, { timeout = timeout }, function(ok, response, not_running)
    if not ok then
      callback(false, response, not_running)
      return
    end
    local status = type(response) == "table" and tonumber(response.status) or nil
    if not status or status < 200 or status >= 300 then
      callback(false, "OpenCode API returned HTTP " .. tostring(status))
      return
    end
    local value, err = decode_json(response.body)
    if not value then
      callback(false, err)
      return
    end
    callback(true, value)
  end)
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

-- `comm` reports the resolved binary name. The V2 release installs the real
-- binary as `opencode` behind an `opencode2` wrapper script that execs it, so
-- TUI processes surface under both names depending on the install layout.
local TUI_EXECUTABLES = {
  opencode = true,
  ["opencode.exe"] = true,
  opencode2 = true,
  ["opencode2.exe"] = true,
}

local function is_full_tui(comm, args)
  local executable = type(comm) == "string" and comm:match("([^/]+)$") or ""
  if not TUI_EXECUTABLES[executable] then return false end
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
  if pending.form then return "question" end
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
    entry.status == "none" and "no status" or entry.status or "unknown",
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
  local unavailable = status == "unknown" and "agent status unavailable"
    or status == "none" and "OpenCode server not running"
    or "no active agent"
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
  entry.project = project_name(entry.directory)
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
  none = 8,
  unknown = 9,
}
local sort_entries

-- `sessions` is "known" when active sessions were fetched, "unknown" when the
-- query failed, and "offline" when the OpenCode server is not running.
local function reconcile(tuis, active_entries, sessions)
  local entries = {}
  local used = {}
  local live_pids = {}
  local active_known = sessions == "known"
  table.sort(tuis, function(a, b) return a.pid < b.pid end)
  -- Sessions do not survive the server, so completed-task metadata is stale.
  if sessions == "offline" then tui_history = {} end

  for _, tui in ipairs(tuis) do
    live_pids[tui.pid] = true
    local previous = tui_history[tui.pid]
    if previous and previous.tui_directory ~= tui.directory then
      tui_history[tui.pid] = nil
      previous = nil
    end
    local best_index
    if active_known then
      for index, entry in ipairs(active_entries) do
        -- An ancestor (especially $HOME) does not establish a session's
        -- project. Keep sessions with different locations as separate entries.
        if not used[index] and tui.directory == entry.directory then
          best_index = index
          break
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
      entry = update_searchable(entry)
      tui_history[tui.pid] = vim.deepcopy(entry)
      entries[#entries + 1] = entry
    else
      if active_known and previous then
        entries[#entries + 1] = done_entry(tui, previous)
      else
        local status = active_known and "idle" or (sessions == "offline" and "none" or "unknown")
        entries[#entries + 1] = idle_entry(tui, status)
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
  local sessions_offline = false

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
      finish(true, reconcile(processes, session_entries, sessions_offline and "offline" or "known"))
    elseif processes_ok and #processes > 0 then
      finish(true, reconcile(processes, {}, "unknown"))
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

  -- The server not running is a definite state rather than a failure: TUIs
  -- remain visible without a status, and no session can be active.
  local function server_offline()
    detail_cache = {}
    sessions_done = true
    sessions_ok = true
    sessions_offline = true
    session_entries = {}
    finish_if_ready()
  end

  local endpoint, endpoint_error = read_endpoint(service_file(config))

  local function request(path, handler)
    return http_json(endpoint, path, timeout, handler)
  end

  local function fetch_active()
    add_handle(request("/api/session/active", function(ok, response, not_running)
      if cancelled then return end
      if not ok and not_running then
        server_offline()
        return
      end
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
          add_handle(request("/api/session/" .. id, function(detail_ok, payload)
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
          form = "/api/session/" .. id .. "/form",
        }
        for kind, path in pairs(prompt_paths) do
          local prompt_kind = kind
          pending = pending + 1
          add_handle(request(path, function(prompt_ok, payload)
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

  if endpoint then
    fetch_active()
  elseif endpoint_error == NOT_REGISTERED then
    server_offline()
  else
    fail_sessions(endpoint_error)
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

function M._set_http(requester)
  injected_http = requester
end

function M._set_cwd_resolver(resolver)
  injected_cwd_resolver = resolver
end

function M._parse_processes(output)
  return parse_processes(output)
end

M._http_get = default_http
M._read_endpoint = read_endpoint

function M._reset()
  injected_runner = nil
  injected_http = nil
  injected_cwd_resolver = nil
  detail_cache = {}
  tui_history = {}
end

return M
