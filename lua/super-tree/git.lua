-- Git repository detection, git status tracking, and filesystem watcher
-- management.
--
-- Repo detection: consumers call M.detect_and_cache(path) to populate
-- M.git_roots, and call M.start_watchers / M.stop_watchers to manage
-- fs_event handles for visible directories. Negative (non-git) results are
-- cached so a tree of many folders is not re-probed on every rebuild.
--
-- Git status: every detected repo root gets an async, debounced
-- `git status --porcelain=v2 -z --branch` run whose parsed result is cached
-- in M.repo_status[root]. Statuses are bubbled up to parent directories
-- (highest-priority child status wins) so collapsed directories reflect the
-- state of their contents, mirroring neo-tree's behaviour. A watcher on each
-- repo's git dir refreshes status in the background after commits, staging,
-- branch switches, etc.
--
-- Concurrency: all `git` OS processes share a global job pool (M.max_jobs)
-- so a directory of many repositories cannot spawn unbounded processes.
-- Per-repo debounce still coalesces bursts; a follow-up run is queued if a
-- refresh arrives while that repo is in flight. Long-running git commands
-- are killed after GIT_TIMEOUT_MS so a huge worktree cannot stall the pool.
--
-- Watchers: worktree fs_event handles track currently visible directories
-- (capped) and are updated incrementally — collapsing a folder drops its
-- watch instead of tearing everything down. Git-dir watches are similarly
-- capped and dropped when the repo leaves the visible set. Worktree events
-- also notify `on_fs_change` so the tree can rescan (add/delete/rename);
-- git-dir events only refresh status decorations.
--
-- A `on_change` callback is injected via M.set_on_change so that async
-- git-status completions can trigger a re-render without a circular
-- dependency. Rapid completions coalesce into a single callback via a
-- pending flag. `on_fs_change` is a separate debounced callback for
-- worktree membership changes.

local M = {}

-- path -> { is_git = bool, is_github = bool }
M.git_roots = {}

-- repo root -> {
--   branch, oid, upstream, ahead, behind,
--   diff_added, diff_removed,  -- total lines added/removed vs HEAD
--   stash,                     -- number of stash entries
--   files  = { [abs_path] = "XY" | "?" | "!" },
--   dirs   = { [abs_path] = single bubbled status char },
--   counts = { staged, unstaged, untracked, conflict },
--   detail = { staged   = { added, modified, deleted, renamed },
--              unstaged = { added, modified, deleted, renamed } },
-- }
M.repo_status = {}

-- Toggled from init.setup based on config.git.status.enable.
M.status_enabled = true

-- Max concurrent `git` OS processes. Status, numstat, and stash share this
-- pool. Set from config.git.max_jobs.
M.max_jobs = 4

-- Visible worktree directories watched for edits / new .git dirs.
local MAX_FS_WATCHERS = 100
-- Per-repo .git directory watches (commits, staging, branch switches).
local MAX_GIT_DIR_WATCHERS = 50
-- Kill a git process that runs longer than this so a huge repo cannot
-- occupy a job-pool slot indefinitely.
local GIT_TIMEOUT_MS = 15000
-- Coalesce bursty worktree events (git checkout, rm -r, editor atomic
-- saves) into one tree rescan.
local FS_DEBOUNCE_MS = 200

-- path -> uv_fs_event handle (visible directory watchers)
local fs_watchers = {}

-- repo root -> uv_fs_event handle | true while async setup is in flight
local git_dir_watchers = {}

-- repo root -> raw porcelain output of the last successful run
local raw_status_cache = {}

-- Debounce / concurrency state for status runs
local status_timers  = {}  -- root -> uv_timer (scheduled run)
local status_running = {}  -- root -> true while a git process is running
local status_rerun   = {}  -- root -> true if a refresh arrived mid-run

-- Global git process pool
local job_queue     = {}  -- { { args, callback }, ... }
local jobs_running  = 0

-- In-flight detect_and_cache so a rebuild cannot stack probes on one path.
local detect_inflight = {}

-- Coalesce bursty status completions into one on_change.
local notify_pending = false

-- Debounce timer for worktree membership changes (add/delete/rename).
local fs_notify_timer = nil

-- False after M.reset() until watchers are started again. Async callbacks
-- scheduled before a reset must not re-create handles afterwards, otherwise
-- watchers and timers leak past sidebar close.
local active = false

-- Called when a git state change is detected; injected by the caller.
local on_change = nil

-- Called when a watched worktree directory changes; injected by the caller
-- so the tree can rescan without a circular dependency.
local on_fs_change = nil

function M.set_on_change(fn)
  on_change = fn
end

function M.set_on_fs_change(fn)
  on_fs_change = fn
end

local is_windows = vim.fn.has("win32") == 1

local function notify_change()
  if notify_pending then return end
  notify_pending = true
  vim.schedule(function()
    notify_pending = false
    if active and on_change then on_change() end
  end)
end

local function close_timer(timer)
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

local function notify_fs_change()
  if not active then return end
  -- Trailing debounce: fire once after the burst (checkout, rm -r) settles.
  close_timer(fs_notify_timer)
  fs_notify_timer = nil
  local timer = vim.loop.new_timer()
  if not timer then
    vim.schedule(function()
      if active and on_fs_change then on_fs_change() end
    end)
    return
  end
  fs_notify_timer = timer
  timer:start(FS_DEBOUNCE_MS, 0, function()
    close_timer(timer)
    fs_notify_timer = nil
    vim.schedule(function()
      if active and on_fs_change then on_fs_change() end
    end)
  end)
end

-- ---------------------------------------------------------------------------
-- Status codes
-- ---------------------------------------------------------------------------

-- Priority of a one-character status when bubbling to parent directories;
-- lower number wins. Mirrors neo-tree's "U?MADTRC." ordering.
local STATUS_PRIORITY = {
  U = 1, ["?"] = 2, M = 3, A = 4, D = 5, T = 6, R = 7, C = 8,
  ["."] = 9, ["!"] = 10,
}

-- Change-type classification of a porcelain change character.
local CHANGE_CLASS = {
  A = "added", C = "added",
  M = "modified", T = "modified",
  D = "deleted",
  R = "renamed",
}

-- True when a two-character porcelain XY code represents a merge conflict.
function M.is_conflict(code)
  if #code < 2 then return code == "U" end
  local x, y = code:sub(1, 1), code:sub(2, 2)
  return (x == y and (x == "A" or x == "D")) or x == "U" or y == "U"
end

-- ---------------------------------------------------------------------------
-- Async git detection
-- ---------------------------------------------------------------------------

-- Async: probe for <path>/.git via fs_stat; calls callback(true/false).
local function detect_git_root(path, callback)
  vim.loop.fs_stat(path .. "/.git", function(err, stat)
    callback(err == nil and stat ~= nil)
  end)
end

-- Async: resolve the actual git dir for a repo/worktree root.
-- Calls callback(git_dir | nil). Handles worktrees where .git is a file
-- containing "gitdir: <path>".
local function resolve_git_dir(path, callback)
  local git_path = path .. "/.git"
  vim.loop.fs_stat(git_path, function(err, stat)
    if err or not stat then
      callback(nil)
      return
    end
    if stat.type ~= "file" then
      callback(git_path)
      return
    end
    local fd = vim.loop.fs_open(git_path, "r", 292)  -- 0444
    if not fd then callback(nil) return end
    local data = vim.loop.fs_read(fd, stat.size or 256, 0)
    vim.loop.fs_close(fd)
    local gitdir = data and data:match("^gitdir:%s*(.-)%s*$") or nil
    if not gitdir then callback(nil) return end
    -- Resolve relative gitdir against the repo path
    if not gitdir:match("^/") and not gitdir:match("^%a:[/\\]") then
      gitdir = path .. "/" .. gitdir
    end
    callback(gitdir)
  end)
end

-- Async: read the repo's git config and check for github.com in a remote.
-- Calls callback(true/false).
local function detect_github(path, callback)
  resolve_git_dir(path, function(git_dir)
    if not git_dir then callback(false) return end
    local config_path = git_dir .. "/config"
    vim.loop.fs_stat(config_path, function(cerr, cstat)
      if cerr or not cstat then callback(false) return end
      local cfd = vim.loop.fs_open(config_path, "r", 292)
      if not cfd then callback(false) return end
      local content = vim.loop.fs_read(cfd, cstat.size, 0)
      vim.loop.fs_close(cfd)
      if not content then callback(false) return end
      callback(content:find("github%.com", 1, false) ~= nil)
    end)
  end)
end

-- Drop cached "not a repo" results so the next build re-probes. Used by
-- a manual refresh to pick up newly initialized repositories.
function M.clear_negative_cache()
  for path, info in pairs(M.git_roots) do
    if not info.is_git then
      M.git_roots[path] = nil
    end
  end
end

-- Detect git root and GitHub status for path; update git_roots and call
-- on_change() if the result differs from the cached value. When a repo is
-- found, a background status run and git-dir watcher are kicked off.
-- Non-git paths are cached as negatives so they are not re-probed until
-- a watcher sees a `.git` change or the negative cache is cleared.
function M.detect_and_cache(path)
  if not active then return end
  if detect_inflight[path] then return end
  detect_inflight[path] = true
  detect_git_root(path, function(is_git)
    detect_inflight[path] = nil
    if not active then return end
    if not is_git then
      local prev = M.git_roots[path]
      if not prev then
        M.git_roots[path] = { is_git = false, is_github = false }
      elseif prev.is_git then
        M.git_roots[path] = { is_git = false, is_github = false }
        M.repo_status[path] = nil
        raw_status_cache[path] = nil
        notify_change()
      end
      return
    end

    detect_github(path, function(is_github)
      if not active then return end
      local prev = M.git_roots[path]
      local changed = not prev or prev.is_git ~= true or prev.is_github ~= is_github
      M.git_roots[path] = { is_git = true, is_github = is_github }
      M.request_status(path)
      if changed then
        notify_change()
      end
    end)
  end)
end

-- ---------------------------------------------------------------------------
-- Repo root lookup
-- ---------------------------------------------------------------------------

-- Find the deepest known repo root that contains `path` (or is `path`).
-- Nested repos win over enclosing repos.
function M.find_repo_root(path)
  local best = nil
  for root, info in pairs(M.git_roots) do
    if info.is_git and (path == root or path:sub(1, #root + 1) == root .. "/") then
      if not best or #root > #best then
        best = root
      end
    end
  end
  return best
end

-- Request a status refresh for whichever repo owns `path` (if any).
function M.refresh_path(path)
  local root = M.find_repo_root(path)
  if root then
    M.request_status(root)
  end
end

-- Request a status refresh for every known repo.
function M.refresh_all()
  for root, info in pairs(M.git_roots) do
    if info.is_git then
      M.request_status(root)
    end
  end
end

-- ---------------------------------------------------------------------------
-- Porcelain v2 parsing
-- ---------------------------------------------------------------------------

-- Parse NUL-delimited `git status --porcelain=v2 -z --branch` output into a
-- repo_status table. Paths are made absolute against `root`.
local function parse_status_output(root, out)
  local st = {
    branch       = nil,
    oid          = nil,
    upstream     = nil,
    ahead        = 0,
    behind       = 0,
    diff_added   = 0,
    diff_removed = 0,
    stash        = 0,
    files        = {},
    dirs         = {},
    counts       = { staged = 0, unstaged = 0, untracked = 0, conflict = 0 },
    detail       = {
      staged   = { added = 0, modified = 0, deleted = 0, renamed = 0 },
      unstaged = { added = 0, modified = 0, deleted = 0, renamed = 0 },
    },
  }

  -- Propagate a status char to all ancestor directories up to the repo
  -- root. A parent keeps its existing char if it has equal or higher
  -- priority; in that case every further ancestor already does too.
  local function bubble(path, char)
    local p = STATUS_PRIORITY[char] or 9
    if p >= 9 then return end
    local dir = path:match("^(.*)/[^/]+$")
    while dir and #dir >= #root do
      local cur = st.dirs[dir]
      if cur and (STATUS_PRIORITY[cur] or 9) <= p then break end
      st.dirs[dir] = char
      if dir == root then break end
      dir = dir:match("^(.*)/[^/]+$")
    end
  end

  local function effective_char(x, y)
    local px = STATUS_PRIORITY[x] or 9
    local py = STATUS_PRIORITY[y] or 9
    return px <= py and x or y
  end

  local records = vim.split(out or "", "\0", { plain = true })
  local i = 1
  while i <= #records do
    local rec = records[i]
    local t = rec:sub(1, 1)

    if t == "#" then
      -- Branch headers: "# branch.oid <sha>", "# branch.head <name>",
      -- "# branch.upstream <ref>", "# branch.ab +<ahead> -<behind>"
      local head = rec:match("^# branch%.head (.+)$")
      local oid  = rec:match("^# branch%.oid (.+)$")
      local up   = rec:match("^# branch%.upstream (.+)$")
      local a, b = rec:match("^# branch%.ab %+(%d+) %-(%d+)$")
      if head then st.branch = head end
      if oid then st.oid = oid end
      if up then st.upstream = up end
      if a then
        st.ahead  = tonumber(a) or 0
        st.behind = tonumber(b) or 0
      end
    elseif t == "1" or t == "2" then
      -- Ordinary changed entry / rename-copy entry.
      local xy, path
      if t == "1" then
        xy, path = rec:match("^1 (..) %S+ %S+ %S+ %S+ %S+ %S+ (.*)$")
      else
        xy, path = rec:match("^2 (..) %S+ %S+ %S+ %S+ %S+ %S+ %S+ (.*)$")
        i = i + 1  -- with -z the original path follows as its own record
      end
      if xy and path and #path > 0 then
        local abs = root .. "/" .. path
        st.files[abs] = xy
        local x, y = xy:sub(1, 1), xy:sub(2, 2)
        if M.is_conflict(xy) then
          st.counts.conflict = st.counts.conflict + 1
          bubble(abs, "U")
        else
          local xc, yc = CHANGE_CLASS[x], CHANGE_CLASS[y]
          if x ~= "." then
            st.counts.staged = st.counts.staged + 1
            if xc then st.detail.staged[xc] = st.detail.staged[xc] + 1 end
          end
          if y ~= "." then
            st.counts.unstaged = st.counts.unstaged + 1
            if yc then st.detail.unstaged[yc] = st.detail.unstaged[yc] + 1 end
          end
          bubble(abs, effective_char(x, y))
        end
      end
    elseif t == "u" then
      -- Unmerged (conflict) entry.
      local xy, path = rec:match("^u (..) %S+ %S+ %S+ %S+ %S+ %S+ %S+ %S+ (.*)$")
      if xy and path and #path > 0 then
        local abs = root .. "/" .. path
        st.files[abs] = xy
        st.counts.conflict = st.counts.conflict + 1
        bubble(abs, "U")
      end
    elseif t == "?" then
      local path = rec:sub(3)
      if #path > 0 then
        local abs = (root .. "/" .. path):gsub("/+$", "")
        st.files[abs] = "?"
        st.counts.untracked = st.counts.untracked + 1
        bubble(abs, "?")
      end
    elseif t == "!" then
      local path = rec:sub(3)
      if #path > 0 then
        local abs = (root .. "/" .. path):gsub("/+$", "")
        st.files[abs] = "!"
      end
    end

    i = i + 1
  end

  return st
end

-- Expose for testing.
M._parse_status_output = parse_status_output

-- ---------------------------------------------------------------------------
-- Async status runs
-- ---------------------------------------------------------------------------

-- Spawn a single git process. Returns true if the process started; on
-- failure the callback is NOT invoked (the job pool handles that).
local function spawn_git(args, callback)
  local stdout = vim.loop.new_pipe(false)
  local stderr = vim.loop.new_pipe(false)
  if not stdout or not stderr then
    if stdout then stdout:close() end
    if stderr then stderr:close() end
    return false
  end

  local chunks = {}
  local handle
  local done = false
  local timeout_timer

  local function finish(code)
    if done then return end
    done = true
    if timeout_timer then
      if not timeout_timer:is_closing() then
        timeout_timer:stop()
        timeout_timer:close()
      end
      timeout_timer = nil
    end
    stdout:read_stop()
    stderr:read_stop()
    if not stdout:is_closing() then stdout:close() end
    if not stderr:is_closing() then stderr:close() end
    if handle and not handle:is_closing() then handle:close() end
    callback(code, table.concat(chunks))
  end

  handle = vim.loop.spawn("git", {
    args  = args,
    stdio = { nil, stdout, stderr },
    hide  = true,
  }, function(code)
    finish(code)
  end)

  if not handle then
    stdout:close()
    stderr:close()
    return false
  end

  stdout:read_start(function(err, data)
    if not err and data then
      chunks[#chunks + 1] = data
    end
  end)
  stderr:read_start(function() end)

  timeout_timer = vim.loop.new_timer()
  if timeout_timer then
    timeout_timer:start(GIT_TIMEOUT_MS, 0, function()
      if handle and not handle:is_closing() then
        handle:kill("sigterm")
      end
    end)
  end
  return true
end

local function pump_jobs()
  while jobs_running < M.max_jobs and #job_queue > 0 do
    local job = table.remove(job_queue, 1)
    jobs_running = jobs_running + 1
    local started = spawn_git(job.args, function(code, out)
      jobs_running = jobs_running - 1
      job.callback(code, out)
      pump_jobs()
    end)
    if not started then
      jobs_running = jobs_running - 1
      -- Defer so a synchronous spawn failure cannot re-enter pump_jobs
      -- via the callback (which may queue another run).
      vim.schedule(function()
        job.callback(-1, "")
        pump_jobs()
      end)
    end
  end
end

-- Queue git with `args`, collect stdout, call callback(exit_code, output).
-- Pure libuv so it works from luv callbacks and on Neovim 0.8+. All spawns
-- share the global job pool so many repos cannot fork unbounded processes.
local function run_git(args, callback)
  job_queue[#job_queue + 1] = { args = args, callback = callback }
  pump_jobs()
end

-- Sum the added/removed line counts of `git diff --numstat` output.
-- Binary files ("-\t-\t...") are skipped.
local function parse_numstat(out)
  local added, removed = 0, 0
  for a, r in (out or ""):gmatch("(%d+)\t(%d+)\t") do
    added   = added + tonumber(a)
    removed = removed + tonumber(r)
  end
  return added, removed
end

local function git_flags(root)
  return {
    "--no-pager", "--no-optional-locks", "--literal-pathspecs",
    "-c", "gc.auto=0",
    "-c", "core.quotepath=off",
    "-C", root,
  }
end

-- Run git status for a repo root, then numstat and stash. Status runs
-- first so many repositories share the job pool fairly (one slot each)
-- and the tree can show branch/symbols without waiting on diffstat. The
-- two extras then share remaining slots and update line counts / stash.
local function run_status(root)
  if not active then return end
  status_running[root] = true

  local function finish_run()
    status_running[root] = nil
    if not active then return end
    if status_rerun[root] then
      status_rerun[root] = nil
      M.request_status(root)
    end
  end

  local status_args = vim.list_extend(git_flags(root), {
    "status", "--porcelain=v2", "-z", "--branch",
    "--untracked-files=normal", "--ignored=traditional",
  })
  -- Total lines added/removed vs HEAD (staged + unstaged). Fails cleanly
  -- in repos without commits; diffstat then stays at zero.
  local numstat_args = vim.list_extend(git_flags(root), {
    "diff", "--numstat", "HEAD",
  })
  local stash_args = vim.list_extend(git_flags(root), {
    "rev-list", "--walk-reflogs", "--count", "refs/stash",
  })

  run_git(status_args, function(code, out)
    if not active then
      finish_run()
      return
    end
    if code ~= 0 then
      if M.repo_status[root] then
        M.repo_status[root] = nil
        raw_status_cache[root] = nil
        notify_change()
      end
      finish_run()
      return
    end

    local st = parse_status_output(root, out)
    local prev = M.repo_status[root]
    if prev then
      st.diff_added   = prev.diff_added
      st.diff_removed = prev.diff_removed
      st.stash        = prev.stash
    end
    M.repo_status[root] = st
    local cached = raw_status_cache[root]
    if not cached or cached:sub(1, #out + 1) ~= (out .. "\1") then
      notify_change()
    end

    local extra = {}
    local pending = 2
    local function collect_extra(key)
      return function(ecode, eout)
        extra[key] = { code = ecode, out = eout }
        pending = pending - 1
        if pending > 0 then return end
        if not active then
          finish_run()
          return
        end
        if extra.numstat.code == 0 then
          st.diff_added, st.diff_removed = parse_numstat(extra.numstat.out)
        end
        if extra.stash.code == 0 then
          st.stash = tonumber((extra.stash.out or ""):match("%d+")) or 0
        end
        local raw = out .. "\1"
          .. (extra.numstat.out or "") .. "\1"
          .. (extra.stash.out or "")
        if raw_status_cache[root] ~= raw then
          raw_status_cache[root] = raw
          M.repo_status[root] = st
          notify_change()
        end
        finish_run()
      end
    end

    run_git(numstat_args, collect_extra("numstat"))
    run_git(stash_args,   collect_extra("stash"))
  end)
end

local function git_dir_watcher_count()
  local n = 0
  for _ in pairs(git_dir_watchers) do
    n = n + 1
  end
  return n
end

local function close_watcher(handle)
  if type(handle) ~= "boolean" and handle and not handle:is_closing() then
    handle:stop()
    handle:close()
  end
end

-- Watch the repo's git dir so commits, staging, and branch switches refresh
-- the status in the background. Lock files are ignored. Capped so a folder
-- of many repos cannot exhaust inotify watches.
local function watch_git_dir(root)
  if not active then return end
  if git_dir_watchers[root] then return end
  if git_dir_watcher_count() >= MAX_GIT_DIR_WATCHERS then return end
  git_dir_watchers[root] = true  -- reserve while async setup runs

  resolve_git_dir(root, function(git_dir)
    if not active or not git_dir then
      git_dir_watchers[root] = nil
      return
    end
    local handle = vim.loop.new_fs_event()
    if not handle then
      git_dir_watchers[root] = nil
      return
    end
    local ok = handle:start(git_dir, {}, function(err, name)
      if err then return end
      if name and name:match("%.lock$") then return end
      M.request_status(root)
    end)
    if ok then
      git_dir_watchers[root] = handle
    else
      handle:close()
      git_dir_watchers[root] = nil
    end
  end)
end

-- Request a debounced background status refresh for a repo root.
-- Multiple requests within the debounce window collapse into one git run;
-- requests during a run trigger exactly one follow-up run.
function M.request_status(root)
  if not active or not M.status_enabled then return end

  watch_git_dir(root)

  if status_running[root] then
    status_rerun[root] = true
    return
  end
  if status_timers[root] then return end

  local timer = vim.loop.new_timer()
  if not timer then
    run_status(root)
    return
  end
  status_timers[root] = timer
  timer:start(200, 0, function()
    timer:stop()
    timer:close()
    status_timers[root] = nil
    if active then
      run_status(root)
    end
  end)
end

-- ---------------------------------------------------------------------------
-- Filesystem watchers
-- ---------------------------------------------------------------------------

function M.stop_watchers()
  for _, handle in pairs(fs_watchers) do
    close_watcher(handle)
  end
  fs_watchers = {}
end

local function stop_git_dir_watchers()
  for _, handle in pairs(git_dir_watchers) do
    close_watcher(handle)
  end
  git_dir_watchers = {}
end

local function start_fs_watcher(path)
  local handle = vim.loop.new_fs_event()
  if not handle then return false end
  local ok = handle:start(path, {}, function(err, name, _events)
    if err then return end
    -- On Windows name may be nil; treat any change as potential .git event.
    local is_git_change = (name == ".git") or (is_windows and name == nil)
    if is_git_change then
      M.detect_and_cache(path)
    end
    -- Any change in a watched directory may affect git status of
    -- the repo that owns it; request a debounced refresh.
    M.refresh_path(path)
    -- Rescan the tree so creates/deletes/renames show up. Git-status
    -- on_change only re-renders decorations on the existing listing.
    notify_fs_change()
  end)
  if ok then
    fs_watchers[path] = handle
    return true
  end
  handle:close()
  return false
end

-- Sync fs_event watchers to the currently visible directory set.
-- Existing handles are kept; paths that left the tree are dropped; new
-- paths are added until MAX_FS_WATCHERS. Git-dir watches for repos that
-- are no longer visible are dropped the same way.
function M.start_watchers(paths)
  active = true
  local desired = {}
  for _, path in ipairs(paths) do
    desired[path] = true
  end

  for path, handle in pairs(fs_watchers) do
    if not desired[path] then
      close_watcher(handle)
      fs_watchers[path] = nil
    end
  end

  for root, handle in pairs(git_dir_watchers) do
    if not desired[root] then
      close_watcher(handle)
      git_dir_watchers[root] = nil
    end
  end

  local count = 0
  for _ in pairs(fs_watchers) do
    count = count + 1
  end
  for _, path in ipairs(paths) do
    if count >= MAX_FS_WATCHERS then break end
    if not fs_watchers[path] then
      if start_fs_watcher(path) then
        count = count + 1
      end
    end
  end
end

-- Reset all cached git state (call when the sidebar is closed).
function M.reset()
  active = false
  job_queue        = {}
  detect_inflight  = {}
  notify_pending   = false
  close_timer(fs_notify_timer)
  fs_notify_timer  = nil
  M.stop_watchers()
  stop_git_dir_watchers()
  for _, timer in pairs(status_timers) do
    if not timer:is_closing() then
      timer:stop()
      timer:close()
    end
  end
  status_timers    = {}
  status_running   = {}
  status_rerun     = {}
  raw_status_cache = {}
  M.git_roots      = {}
  M.repo_status    = {}
end

return M
