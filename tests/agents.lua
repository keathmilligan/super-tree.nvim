-- Run: TMPDIR=/tmp/opencode nvim --headless -u NONE -i NONE
--        --cmd 'set rtp+=.' -c "lua dofile('tests/agents.lua')"
local root = vim.fn.tempname()
local alpha = root .. "/alpha"
local alpha_sub = alpha .. "/packages/app"
local beta = root .. "/beta"
local gamma = root .. "/gamma"
local original_cwd = vim.fn.getcwd()
local supertree = require("super-tree")
local provider = require("super-tree.agent_providers.opencode")

vim.fn.mkdir(alpha_sub, "p")
vim.fn.mkdir(beta, "p")
vim.fn.mkdir(gamma, "p")
vim.fn.writefile({ "alpha" }, alpha .. "/file.txt")
vim.fn.writefile({ "beta" }, beta .. "/file.txt")

local function check(value, message)
  assert(value, message)
end

local function encode(value)
  return vim.json.encode(value)
end

local function key(buf, lhs)
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if map.lhs == lhs then return map.callback() end
  end
  error("Missing keymap: " .. lhs)
end

local function wait_for(predicate, message)
  check(vim.wait(1500, predicate, 10), message)
end

local function run()
  vim.o.lines = 55
  vim.o.columns = 150
  vim.api.nvim_set_current_dir(alpha)

  local responses = {}
  local failures = {}
  local calls = {}
  local held
  local uid = vim.loop.getuid()
  local process_cwds = {
    [9001] = alpha,
    [9002] = beta,
    [9003] = alpha,
    [9004] = gamma,
  }
  local process_fixture = table.concat({
    string.format("9001 %d opencode2 opencode2", uid),
    string.format("9002 %d opencode2 opencode2 %s", uid, beta),
    string.format("9003 %d opencode2 opencode2 --continue", uid),
    string.format("9004 %d opencode opencode", uid),
    string.format("9010 %d opencode2.exe /opt/opencode2.exe serve --service", uid),
    string.format("9011 %d opencode2 opencode2 api get /api/session/active", uid),
    string.format("9012 %d opencode2 opencode2 run prompt", uid),
    string.format("9013 %d opencode2 opencode2 mini", uid),
    string.format("9014 %d other other", uid),
    string.format("9015 %d opencode2 opencode2", uid + 1),
    string.format("9016 %d opencode2 opencode2 --log-level debug api get /api/session/active", uid),
  }, "\n")

  local function runner(argv, _, callback)
    local path
    if argv[1] == "ps" then
      path = "/processes"
    elseif argv[1] == "lsof" then
      path = "/lsof/" .. tostring(argv[4])
    else
      path = argv[4]
    end
    calls[path] = (calls[path] or 0) + 1
    if path == "/api/session/active" and held == false then
      held = { callback = callback }
      return function() held.cancelled = true end
    end
    local cancelled = false
    vim.schedule(function()
      if cancelled then return end
      if failures[path] then
        callback(false, failures[path])
      else
        callback(true, responses[path] or "{}")
      end
    end)
    return function() cancelled = true end
  end

  local function inject_provider()
    provider._set_runner(runner)
    provider._set_cwd_resolver(function(pid) return process_cwds[pid] end)
  end

  local function collect(options)
    local result
    provider.collect({ command = "fixture", metadata_refresh_interval = 0 }, options or {}, function(ok, value)
      result = { ok = ok, value = value }
    end)
    wait_for(function() return result ~= nil end, "provider collection must finish")
    return result
  end

  -- Provider parsing and failure behavior.
  provider._reset()
  inject_provider()
  local flag_parsing = provider._parse_processes(table.concat({
    string.format("9020 %d opencode2 opencode2 --log-level debug --continue", uid),
    string.format("9021 %d opencode2 opencode2 api get /api/session/active", uid),
    string.format("9022 %d opencode opencode", uid),
    string.format("9023 %d opencode opencode serve --service", uid),
    string.format("9024 %d opencode opencode api get /api/session/active", uid),
    string.format("9025 %d opencode opencode run prompt", uid),
    string.format("9026 %d opencode opencode --log-level debug api get /api/session/active", uid),
  }, "\n"))
  check(#flag_parsing == 2 and flag_parsing[1].pid == 9020 and flag_parsing[2].pid == 9022,
    "process parsing skips flag values, classifies subcommands, and accepts the release binary name")
  responses["/processes"] = process_fixture
  responses["/api/session/active"] = encode({
    data = {
      ses_alpha = { type = "running" },
      ses_beta = { type = "future-state" },
    },
  })
  responses["/api/session/ses_alpha"] = encode({ data = {
    id = "ses_alpha",
    title = "Implement alpha feature",
    agent = "build",
    model = { providerID = "opencode", id = "gpt-5.6-sol", variant = "max" },
    location = { directory = alpha },
  } })
  responses["/api/session/ses_beta"] = encode({ data = {
    id = "ses_beta",
    title = "Review beta changes",
    agent = "code-review",
    model = { providerID = "xai", id = "grok-4.6", variant = "high" },
    location = { directory = beta },
  } })
  responses["/api/session/ses_alpha/permission"] = encode({ data = {
    { id = "per_alpha", sessionID = "ses_alpha", action = "bash", resources = { "*" } },
  } })
  responses["/api/session/ses_alpha/question"] = encode({ data = {} })
  responses["/api/session/ses_alpha/form"] = encode({ data = {
    { id = "frm_alpha", sessionID = "ses_alpha", title = "Choose deployment", fields = {} },
  } })
  responses["/api/session/ses_beta/permission"] = encode({ data = {} })
  responses["/api/session/ses_beta/question"] = encode({ data = {} })
  responses["/api/session/ses_beta/form"] = encode({ data = {
    { id = "frm_beta", sessionID = "ses_beta", title = "Choose review mode", fields = {} },
  } })

  local parsed = collect({ force = true })
  check(parsed.ok and #parsed.value == 4, "provider returns matched active and idle TUI instances")
  local by_pid = {}
  for _, entry in ipairs(parsed.value) do by_pid[entry.pid] = entry end
  check(by_pid[9001].session_id == "ses_alpha" and by_pid[9001].status == "blocked",
    "pending permission overrides running status as blocked")
  check(by_pid[9001].model_provider == "opencode" and by_pid[9001].model_variant == "max",
    "provider retains model metadata")
  check(by_pid[9002].status == "question", "pending form overrides active status as question")
  check(by_pid[9003].status == "idle" and by_pid[9003].session_id == nil,
    "TUI without an active session remains visible as idle")
  check(by_pid[9010] == nil and by_pid[9011] == nil and by_pid[9012] == nil,
    "service and non-TUI commands are excluded")

  responses["/api/session/ses_beta/form"] = encode({ data = {} })
  local unprompted = collect({ force = true })
  local unprompted_beta
  for _, entry in ipairs(unprompted.value) do
    if entry.session_id == "ses_beta" then unprompted_beta = entry end
  end
  check(unprompted_beta and unprompted_beta.status == "future-state",
    "unknown active status remains visible without a pending prompt")

  responses["/processes"] = ""
  responses["/api/session/active"] = "not json"
  local malformed = collect({ force = true })
  check(not malformed.ok and tostring(malformed.value):find("invalid JSON", 1, true),
    "malformed active response is rejected")

  failures["/api/session/active"] = "OpenCode API request timed out"
  local timed_out = collect({ force = true })
  check(not timed_out.ok and timed_out.value:find("timed out", 1, true),
    "timed-out active response is reported")
  failures["/api/session/active"] = nil

  provider._reset()
  local missing
  provider.collect({
    command = "__super_tree_missing_opencode2__",
    process_command = "__super_tree_missing_ps__",
  }, {}, function(ok, value)
    missing = { ok = ok, value = value }
  end)
  wait_for(function() return missing ~= nil end, "missing executables settle")
  check(not missing.ok, "missing OpenCode and process executables fail gracefully")

  provider._reset()
  inject_provider()
  responses["/processes"] = ""
  responses["/api/session/active"] = encode({ data = { ses_fallback = { type = "running" } } })
  responses["/api/session/ses_fallback"] = "not json"
  local fallback = collect({ force = true })
  check(fallback.ok and #fallback.value == 1, "bad details do not hide an active session")
  check(fallback.value[1].project == "unknown project"
      and fallback.value[1].model == "model unavailable",
    "bad details receive stable display fallbacks")

  -- A parent-directory TUI must never claim another project's session, even
  -- when its PID sorts before the TUI actually in that project.
  provider._reset()
  inject_provider()
  process_cwds[9001] = root
  responses["/processes"] = process_fixture
  responses["/api/session/active"] = encode({ data = { ses_beta = { type = "running" } } })
  local scoped = collect({ force = true })
  by_pid = {}
  for _, entry in ipairs(scoped.value) do by_pid[entry.pid] = entry end
  check(by_pid[9001].status == "idle" and by_pid[9001].session_id == nil,
    "parent-directory TUI does not claim a descendant project's session")
  check(by_pid[9002].session_id == "ses_beta" and by_pid[9002].project == "beta",
    "session metadata stays attached to the TUI in its own project")

  -- Cached task details belong to the observed directory, not just the PID.
  responses["/api/session/active"] = encode({ data = {} })
  process_cwds[9002] = gamma
  local moved = collect({ force = true })
  for _, entry in ipairs(moved.value) do
    if entry.pid == 9002 then
      check(entry.status == "idle" and entry.session_id == nil and entry.project == "gamma",
        "changing project clears completed-session metadata")
    end
  end
  process_cwds[9002] = beta
  local returned = collect({ force = true })
  for _, entry in ipairs(returned.value) do
    if entry.pid == 9002 then
      check(entry.status == "idle" and entry.session_id == nil,
        "returning to an old directory does not resurrect stale metadata")
    end
  end

  -- Nested locations remain visible under their own session directory, and a
  -- TUI inside a session's directory cannot claim the ancestor session either.
  process_cwds[9001] = alpha_sub
  responses["/processes"] = process_fixture:match("[^\n]+")
  responses["/api/session/active"] = encode({ data = { ses_alpha = { type = "running" } } })
  local ancestor = collect({ force = true })
  check(#ancestor.value == 2, "ancestor session and nested TUI remain separate")
  process_cwds[9001] = root
  local descendant = collect({ force = true })
  check(#descendant.value == 2, "descendant session remains visible without an exact TUI match")
  local session
  for _, entry in ipairs(descendant.value) do
    if entry.session_id == "ses_alpha" then session = entry end
  end
  check(session and session.instance == "session" and session.project == "alpha"
      and session.directory == alpha and session.pid == nil,
    "unmatched session keeps its authoritative project and directory")
  process_cwds[9001] = alpha

  -- UI fixture with two agents and a native Super Project provider.
  provider._reset()
  inject_provider()
  responses["/processes"] = process_fixture
  responses["/api/session/active"] = encode({
    data = {
      ses_alpha = { type = "running" },
      ses_beta = { type = "future-state" },
    },
  })
  responses["/api/session/ses_alpha"] = encode({ data = {
    id = "ses_alpha",
    title = "Implement alpha feature",
    agent = "build",
    model = { providerID = "opencode", id = "gpt-5.6-sol", variant = "max" },
    location = { directory = alpha },
  } })
  responses["/api/session/ses_beta"] = encode({ data = {
    id = "ses_beta",
    title = "Review beta changes",
    agent = "code-review",
    model = { providerID = "xai", id = "grok-4.6", variant = "high" },
    location = { directory = beta },
  } })
  responses["/api/session/ses_alpha/permission"] = encode({ data = {
    { id = "per_alpha", sessionID = "ses_alpha", action = "bash", resources = { "*" } },
  } })
  responses["/api/session/ses_alpha/question"] = encode({ data = {} })
  responses["/api/session/ses_alpha/form"] = encode({ data = {} })
  responses["/api/session/ses_beta/permission"] = encode({ data = {} })
  responses["/api/session/ses_beta/question"] = encode({ data = {
    { id = "que_beta", sessionID = "ses_beta", questions = {} },
  } })
  responses["/api/session/ses_beta/form"] = encode({ data = {} })

  local agents = require("super-tree.agents")
  local window = require("super-tree.window")
  local filter = require("super-tree.filter")
  local opened
  local open_error
  supertree.setup({
    mode = "sidebar",
    agents = {
      enable = true,
      height = 9,
      refresh_interval = 60000,
      command = "fixture",
      symbols = { working = "W", unknown = "U" },
    },
    projects = { enable = true, height = 7 },
    buffers = { enable = true, height = 6 },
    git = { enable = false },
    diagnostics = { enable = false },
    fade = { enable = false },
  })
  local current_root = alpha
  supertree.register_project_provider("super-project", {
    manages_tree_state = true,
    projects = function()
      return {
        { root = alpha, name = "alpha", rank = 2, active = current_root == alpha },
        { root = beta, name = "beta", rank = 1, active = current_root == beta },
      }
    end,
    current = function() return { root = current_root } end,
    open = function(path)
      if open_error then return false, open_error end
      opened = path
      return true
    end,
  })

  vim.cmd("edit " .. vim.fn.fnameescape(alpha .. "/file.txt"))
  supertree.open()
  local opened_agents = vim.wait(1500, function()
    return window.agents_win ~= nil and #agents.all == 4
  end, 10)
  check(opened_agents, "TUI instances automatically open Agents (entries=" .. #agents.all
    .. ", refreshing=" .. tostring(agents._is_refreshing()) .. ")")

  local function entry_pids()
    local pids = {}
    for _, entry in ipairs(agents.entries) do pids[#pids + 1] = tostring(entry.pid) end
    return table.concat(pids, ",")
  end
  check(entry_pids() == "9001,9003,9002,9004",
    "agents in the current project hoist to the top; other agents keep their order")

  local lines = vim.api.nvim_buf_get_lines(window.agents_buf, 0, -1, false)
  check(#lines == 12, "four TUI instances render as twelve content rows")
  check(lines[1]:find("◉ blocked", 1, true) and lines[1]:find("alpha", 1, true),
    "row one reflects a pending permission prompt")
  local blocked_marks = vim.api.nvim_buf_get_extmarks(
    window.agents_buf, -1, { 0, 0 }, { 0, -1 }, { details = true }
  )
  local blocked_hl
  for _, mark in ipairs(blocked_marks) do
    if mark[4].hl_group == "SuperTreeAgentBlocked" then blocked_hl = true end
  end
  check(blocked_hl, "blocked status uses its dedicated highlight")
  check(lines[2]:find("Implement alpha feature", 1, true), "row two shows description")
  check(lines[3]:find("build · opencode/gpt-5.6-sol · max", 1, true),
    "row three shows agent and model information")
  check(lines[4]:find("○ idle", 1, true), "TUI without a running agent renders as idle")
  check(lines[5]:find("OpenCode TUI · PID 9003", 1, true), "idle TUI description identifies the instance")
  check(lines[6]:find("no active agent · model unavailable", 1, true),
    "idle TUI explains missing agent and model metadata")
  check(lines[7]:find("? question", 1, true) and lines[7]:find("beta", 1, true),
    "question request is reflected in the status row")
  check(lines[10]:find("○ idle", 1, true) and lines[10]:find("gamma", 1, true),
    "the other idle TUI keeps its position below the current project's agents")
  local question_marks = vim.api.nvim_buf_get_extmarks(
    window.agents_buf, -1, { 6, 0 }, { 6, -1 }, { details = true }
  )
  local question_hl
  for _, mark in ipairs(question_marks) do
    if mark[4].hl_group == "SuperTreeAgentQuestion" then question_hl = true end
  end
  check(question_hl, "question status uses its dedicated highlight")
  check(vim.api.nvim_get_hl(0, { name = "SuperTreeAgentWorking", link = false }).fg == 0xe5c07b,
    "working status is yellow")
  check(vim.api.nvim_get_hl(0, { name = "SuperTreeAgentBlocked", link = false }).fg == 0xe06c75,
    "blocked status is red")
  check(vim.api.nvim_get_hl(0, { name = "SuperTreeAgentQuestion", link = false }).fg == 0x61afef,
    "question status is blue")
  check(vim.api.nvim_get_hl(0, { name = "SuperTreeAgentDone", link = false }).fg == 0x98c379,
    "done status is green")

  vim.api.nvim_win_set_cursor(window.agents_win, { 2, 0 })
  check(agents.entry_at_cursor().id == "opencode-tui:9001", "description row maps to its TUI")
  key(window.agents_buf, "j")
  check(vim.api.nvim_win_get_cursor(window.agents_win)[1] == 4,
    "j moves to the next agent rather than the next content row")
  key(window.agents_buf, "k")
  check(vim.api.nvim_win_get_cursor(window.agents_win)[1] == 1, "k moves to the previous agent")

  vim.api.nvim_win_set_cursor(window.agents_win, { 2, 0 })
  key(window.agents_buf, "<CR>")
  check(opened == vim.fn.resolve(alpha), "Enter activates the session's project")
  opened = nil
  require("super-tree.projects").open_path(alpha_sub)
  check(opened == vim.fn.resolve(alpha), "nested location resolves to the closest project root")
  opened = nil
  vim.api.nvim_win_set_cursor(window.agents_win, { 5, 0 })
  key(window.agents_buf, "<CR>")
  check(opened == vim.fn.resolve(alpha), "idle TUI activation uses its process working directory")
  vim.api.nvim_win_set_cursor(window.agents_win, { 9, 0 })
  key(window.agents_buf, "<2-LeftMouse>")
  check(opened == vim.fn.resolve(beta), "double-click works from the model row")

  filter.apply_term("Implement", "agents")
  check(#agents.entries == 1 and vim.api.nvim_buf_line_count(window.agents_buf) == 3,
    "Agents filter operates on entries, not individual rows")
  filter.clear("agents")
  check(#agents.entries == 4 and vim.api.nvim_buf_line_count(window.agents_buf) == 12,
    "clearing Agents filter restores all rows")

  local refresh_calls = calls["/api/session/active"] or 0
  key(window.agents_buf, "R")
  wait_for(function()
    return (calls["/api/session/active"] or 0) > refresh_calls and not agents._is_refreshing()
  end, "R requests an immediate Agents refresh")

  -- Dynamic pane ordering and configured heights in all window modes.
  local function check_layout(mode)
    local wins = { window.projects_win, window.agents_win, window.buffers_win, window.sidebar_win }
    local previous_bottom = -1
    for _, win in ipairs(wins) do
      check(win and vim.api.nvim_win_is_valid(win), mode .. " has every pane")
      local pos = vim.api.nvim_win_get_position(win)
      check(pos[1] >= previous_bottom, mode .. " panes are ordered and non-overlapping")
      previous_bottom = pos[1] + vim.api.nvim_win_get_height(win)
      check(vim.api.nvim_win_get_width(win) == vim.api.nvim_win_get_width(window.sidebar_win),
        mode .. " pane widths match")
    end
  end
  check_layout("sidebar")
  check(vim.api.nvim_win_get_height(window.agents_win) == 9, "Agents uses configured split height")

  -- State records a three-row selection, focus, and Agents height.
  vim.api.nvim_win_set_height(window.agents_win, 8)
  vim.api.nvim_win_set_cursor(window.agents_win, { 8, 0 })
  vim.api.nvim_set_current_win(window.agents_win)
  local state = supertree.capture_state()
  check(state.selected_agent == "opencode-tui:9002" and state.focused_pane == "agents",
    "state captures selected and focused agent")
  check(state.pane_heights.agents == 8, "state captures Agents height")
  supertree.close()
  check(supertree.restore_state(state), "state restores with Agents data")
  check(window.agents_win and vim.api.nvim_get_current_win() == window.agents_win,
    "state restores Agents focus")
  check(agents.entry_at_cursor().id == "opencode-tui:9002",
    "state restores selection from any content row")
  check(vim.api.nvim_win_get_height(window.agents_win) == 8, "state restores Agents height")
  supertree.close()

  -- With hoisting disabled, Agents keeps the provider's status-priority order.
  supertree.setup({ agents = { current_project_first = false } })
  supertree.open()
  wait_for(function() return window.agents_win ~= nil and #agents.entries == 4 end,
    "Agents reopens with current_project_first disabled")
  check(entry_pids() == "9001,9002,9003,9004",
    "current_project_first = false keeps the provider's order")
  supertree.close()

  -- Hoisting follows the current project; unrelated agents never reorder.
  supertree.setup({ agents = { current_project_first = true } })
  supertree.open()
  wait_for(function() return window.agents_win ~= nil and #agents.entries == 4 end,
    "Agents reopens with current_project_first enabled")
  check(entry_pids() == "9001,9003,9002,9004", "agents in the current project hoist")
  current_root = beta
  require("super-tree.projects").collect()
  agents.render(window.agents_buf)
  check(entry_pids() == "9002,9001,9003,9004",
    "hoisting follows the current project; other agents keep their order")
  current_root = alpha
  require("super-tree.projects").collect()
  agents.render(window.agents_buf)
  check(entry_pids() == "9001,9003,9002,9004", "restoring the project restores the order")
  supertree.close()

  for _, mode in ipairs({ "pinned", "floating" }) do
    supertree.setup({ mode = mode })
    supertree.open()
    wait_for(function() return window.agents_win ~= nil end, mode .. " opens Agents")
    check_layout(mode)
    if mode == "floating" then
      vim.o.lines = 12
      vim.api.nvim_exec_autocmds("VimResized", {})
      check_layout("short floating")
      local bottom = vim.api.nvim_win_get_position(window.sidebar_win)[1]
        + vim.api.nvim_win_get_height(window.sidebar_win)
      check(bottom <= vim.o.lines - vim.o.cmdheight, "three floating panes fit a short screen")
      vim.o.lines = 55
      vim.api.nvim_exec_autocmds("VimResized", {})
    end
    supertree.close()
  end

  -- Completed TUIs become done while never-active TUIs remain idle. Only a
  -- snapshot with no TUI and no agent hides.
  supertree.setup({ mode = "sidebar" })
  supertree.open()
  wait_for(function() return window.agents_win ~= nil end, "Agents reopens from cached snapshot")
  local editor = window.find_editor_win()
  vim.api.nvim_set_current_win(editor)
  responses["/api/session/active"] = encode({ data = {} })
  agents.refresh(true, true)
  wait_for(function()
    if #agents.all ~= 4 then return false end
    local counts = { done = 0, idle = 0 }
    for _, entry in ipairs(agents.all) do
      counts[entry.status] = (counts[entry.status] or 0) + 1
    end
    return counts.done == 2 and counts.idle == 2
  end, "completed TUIs become done while initially inactive TUIs stay idle")
  local completed
  for _, entry in ipairs(agents.all) do
    if entry.pid == 9001 then completed = entry end
  end
  check(completed and completed.title == "Implement alpha feature" and completed.agent == "build",
    "done TUI retains its completed session metadata")
  check(window.agents_win ~= nil, "done and idle TUI instances keep Agents visible")

  responses["/processes"] = ""
  agents.refresh(true, true)
  wait_for(function() return window.agents_win == nil and #agents.all == 0 end,
    "snapshot with no TUI and no active session hides Agents")
  check(vim.api.nvim_get_current_win() == editor, "background auto-hide does not steal focus")

  responses["/processes"] = process_fixture:match("[^\n]+")
  agents.refresh(true, true)
  wait_for(function()
    return window.agents_win ~= nil and #agents.all == 1 and agents.all[1].status == "idle"
  end, "new idle TUI automatically reopens Agents")
  check(vim.api.nvim_get_current_win() == editor, "idle TUI auto-show does not steal focus")

  responses["/api/session/active"] = encode({ data = { ses_alpha = { type = "running" } } })
  responses["/api/session/ses_alpha/permission"] = encode({ data = {} })
  agents.refresh(true, true)
  wait_for(function() return #agents.all == 1 and agents.all[1].status == "working" end,
    "idle TUI updates in place when its agent starts")
  check(agents.all[1].id == "opencode-tui:9001", "TUI identity remains stable across idle/working")
  local working_marks = vim.api.nvim_buf_get_extmarks(
    window.agents_buf, -1, { 0, 0 }, { 0, -1 }, { details = true }
  )
  local working_hl
  for _, mark in ipairs(working_marks) do
    if mark[4].hl_group == "SuperTreeAgentWorking" then working_hl = true end
  end
  check(working_hl, "working status uses its dedicated yellow highlight")

  -- Partial failure keeps the TUI visible with unknown status; total failure
  -- retains that last usable snapshot.
  failures["/api/session/active"] = "service unavailable"
  agents.refresh(true, false)
  wait_for(function() return not agents._is_refreshing() end, "failed refresh settles")
  check(#agents.all == 1 and agents.all[1].status == "unknown" and window.agents_win ~= nil,
    "API failure keeps the detected TUI visible with unknown status")
  failures["/processes"] = "process discovery unavailable"
  agents.refresh(true, false)
  wait_for(function() return not agents._is_refreshing() end, "total discovery failure settles")
  check(#agents.all == 1 and agents.all[1].status == "unknown",
    "total refresh failure retains the last usable snapshot")
  failures["/api/session/active"] = nil
  failures["/processes"] = nil

  -- Closing during a request prevents a late callback from reopening panes.
  held = false
  agents.refresh(true, false)
  wait_for(function() return type(held) == "table" end, "fixture holds an active request")
  local late = held.callback
  supertree.close()
  late(true, encode({ data = { ses_beta = { type = "running" } } }))
  vim.wait(50, function() return false end)
  check(not supertree.is_open() and not agents.is_running(), "late callback is ignored after close")

  -- Activation errors leave the current workspace intact.
  local cwd = vim.fn.getcwd()
  open_error = "fixture switch failed"
  local switch_ok, switch_err = require("super-tree.projects").open_path(beta)
  check(not switch_ok and switch_err == open_error and vim.fn.getcwd() == cwd,
    "provider switch failure leaves the workspace unchanged")
  open_error = nil
  local missing_ok, missing_err = require("super-tree.projects").open_path(root .. "/missing")
  check(not missing_ok and missing_err:find("no longer exists", 1, true),
    "missing agent directory is rejected")

  -- Activation fails safely without the native Super Project provider.
  supertree.unregister_project_provider("super-project")
  local ok, err = require("super-tree.projects").open_path(alpha)
  check(not ok and err:find("not available", 1, true), "activation requires Super Project")
end

local ok, err = xpcall(run, debug.traceback)
supertree.close()
provider._reset()
vim.api.nvim_set_current_dir(original_cwd)
vim.fn.delete(root, "rf")
if not ok then
  io.stderr:write(err .. "\n")
  vim.cmd("cquit 1")
else
  print("Agents provider, pane, layout, state, and activation checks passed")
  vim.cmd("qa!")
end
