-- Git repository detection, git status tracking, and filesystem watcher
-- management.
--
-- Repo detection: consumers call M.detect_and_cache(path) to populate
-- M.git_roots, and call M.start_watchers / M.stop_watchers to manage
-- fs_event handles for visible directories.
--
-- Git status: every detected repo root gets an async, debounced
-- `git status --porcelain=v2 -z --branch` run whose parsed result is cached
-- in M.repo_status[root]. Statuses are bubbled up to parent directories
-- (highest-priority child status wins) so collapsed directories reflect the
-- state of their contents, mirroring neo-tree's behaviour. A watcher on each
-- repo's git dir refreshes status in the background after commits, staging,
-- branch switches, etc.
--
-- A `on_change` callback is injected via M.set_on_change so that async
-- callbacks can trigger a re-render without a circular dependency.

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

-- False after M.reset() until watchers are started again. Async callbacks
-- scheduled before a reset must not re-create handles afterwards, otherwise
-- watchers and timers leak past sidebar close.
local active = false

-- Called when a git state change is detected; injected by the caller.
local on_change = nil

function M.set_on_change(fn)
  on_change = fn
end

local is_windows = vim.fn.has("win32") == 1

local function notify_change()
  vim.schedule(function()
    if on_change then on_change() end
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

-- Detect git root and GitHub status for path; update git_roots and call
-- on_change() if the result differs from the cached value. When a repo is
-- found, a background status run and git-dir watcher are kicked off.
function M.detect_and_cache(path)
  if not active then return end
  detect_git_root(path, function(is_git)
    if not is_git then
      local prev = M.git_roots[path]
      if prev and prev.is_git then
        M.git_roots[path] = { is_git = false, is_github = false }
        M.repo_status[path] = nil
        raw_status_cache[path] = nil
        notify_change()
      end
      return
    end

    detect_github(path, function(is_github)
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

-- Spawn git with `args`, collect stdout, call callback(exit_code, output).
-- Pure libuv so it works from luv callbacks and on Neovim 0.8+.
local function run_git(args, callback)
  local stdout = vim.loop.new_pipe(false)
  local stderr = vim.loop.new_pipe(false)
  local chunks = {}
  local handle
  handle = vim.loop.spawn("git", {
    args  = args,
    stdio = { nil, stdout, stderr },
    hide  = true,
  }, function(code)
    stdout:read_stop()
    stderr:read_stop()
    if not stdout:is_closing() then stdout:close() end
    if not stderr:is_closing() then stderr:close() end
    if handle and not handle:is_closing() then handle:close() end
    callback(code, table.concat(chunks))
  end)

  if not handle then
    stdout:close()
    stderr:close()
    callback(-1, "")
    return
  end

  stdout:read_start(function(err, data)
    if not err and data then
      chunks[#chunks + 1] = data
    end
  end)
  stderr:read_start(function() end)
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

-- Run git status (plus line diffstat and stash count) for a repo root and
-- update M.repo_status. The three git processes run concurrently.
local function run_status(root)
  status_running[root] = true

  local results = {}
  local pending = 3

  local function collect(key)
    return function(code, out)
      results[key] = { code = code, out = out }
      pending = pending - 1
      if pending > 0 then return end

      status_running[root] = nil
      if status_rerun[root] then
        status_rerun[root] = nil
        M.request_status(root)
      end

      if results.status.code ~= 0 then
        if M.repo_status[root] then
          M.repo_status[root] = nil
          raw_status_cache[root] = nil
          notify_change()
        end
        return
      end

      -- Skip reparse/redraw when all outputs are byte-identical. The
      -- numstat output participates because line counts can change while
      -- the porcelain status stays the same.
      local raw = results.status.out .. "\1"
        .. (results.numstat.out or "") .. "\1"
        .. (results.stash.out or "")
      if raw_status_cache[root] == raw and M.repo_status[root] then
        return
      end
      raw_status_cache[root] = raw

      local st = parse_status_output(root, results.status.out)
      if results.numstat.code == 0 then
        st.diff_added, st.diff_removed = parse_numstat(results.numstat.out)
      end
      if results.stash.code == 0 then
        st.stash = tonumber((results.stash.out or ""):match("%d+")) or 0
      end
      M.repo_status[root] = st
      notify_change()
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

  run_git(status_args,  collect("status"))
  run_git(numstat_args, collect("numstat"))
  run_git(stash_args,   collect("stash"))
end

-- Watch the repo's git dir so commits, staging, and branch switches refresh
-- the status in the background. Lock files are ignored.
local function watch_git_dir(root)
  if not active then return end
  if git_dir_watchers[root] then return end
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
    run_status(root)
  end)
end

-- ---------------------------------------------------------------------------
-- Filesystem watchers
-- ---------------------------------------------------------------------------

function M.stop_watchers()
  for _, handle in pairs(fs_watchers) do
    if handle and not handle:is_closing() then
      handle:stop()
      handle:close()
    end
  end
  fs_watchers = {}
end

local function stop_git_dir_watchers()
  for _, handle in pairs(git_dir_watchers) do
    if type(handle) ~= "boolean" and not handle:is_closing() then
      handle:stop()
      handle:close()
    end
  end
  git_dir_watchers = {}
end

-- Register fs_event watchers for up to 100 unique directory paths.
function M.start_watchers(paths)
  active = true
  local count = 0
  for _, path in ipairs(paths) do
    if not fs_watchers[path] then
      if count >= 100 then break end
      local handle = vim.loop.new_fs_event()
      if handle then
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
        end)
        if ok then
          fs_watchers[path] = handle
          count = count + 1
        else
          handle:close()
        end
      end
    end
  end
end

-- Reset all cached git state (call when the sidebar is closed).
function M.reset()
  active = false
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
