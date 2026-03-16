-- Git repository detection and filesystem watcher management.
-- Consumers call M.detect_and_cache(path) to populate M.git_roots,
-- and call M.start_watchers / M.stop_watchers to manage fs_event handles.
-- A `on_change` callback is injected via M.set_on_change so that the
-- detection callbacks can trigger a re-render without a circular dependency.

local M = {}

-- path -> { is_git = bool, is_github = bool }
M.git_roots = {}

-- path -> uv_fs_event handle
local fs_watchers = {}

-- Called when a git state change is detected; injected by the caller.
local on_change = nil

function M.set_on_change(fn)
  on_change = fn
end

local is_windows = vim.fn.has("win32") == 1

-- ---------------------------------------------------------------------------
-- Async git detection
-- ---------------------------------------------------------------------------

-- Async: probe for <path>/.git via fs_stat; calls callback(true/false).
local function detect_git_root(path, callback)
  vim.loop.fs_stat(path .. "/.git", function(err, stat)
    callback(err == nil and stat ~= nil)
  end)
end

-- Async: read <path>/.git/config and check for github.com in origin remote.
-- Handles worktrees (.git is a file pointing to the real gitdir).
-- Calls callback(true/false).
local function detect_github(path, callback)
  local git_path = path .. "/.git"
  vim.loop.fs_stat(git_path, function(err, stat)
    if err or not stat then
      callback(false)
      return
    end

    local config_path
    if stat.type == "file" then
      -- Worktree: .git is a file containing "gitdir: <path>"
      local fd = vim.loop.fs_open(git_path, "r", 292)  -- 0444
      if not fd then callback(false) return end
      local size = stat.size or 256
      local data = vim.loop.fs_read(fd, size, 0)
      vim.loop.fs_close(fd)
      if not data then callback(false) return end
      local gitdir = data:match("^gitdir:%s*(.-)%s*$")
      if not gitdir then callback(false) return end
      -- Resolve relative gitdir against the repo path
      if not gitdir:match("^/") and not gitdir:match("^%a:[/\\]") then
        gitdir = path .. "/" .. gitdir
      end
      config_path = gitdir .. "/config"
    else
      config_path = git_path .. "/config"
    end

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
-- on_change() if the result differs from the cached value.
function M.detect_and_cache(path)
  detect_git_root(path, function(is_git)
    if not is_git then
      local prev = M.git_roots[path]
      if prev and prev.is_git then
        M.git_roots[path] = { is_git = false, is_github = false }
        vim.schedule(function()
          if on_change then on_change() end
        end)
      end
      return
    end

    detect_github(path, function(is_github)
      local prev = M.git_roots[path]
      local changed = not prev or prev.is_git ~= true or prev.is_github ~= is_github
      M.git_roots[path] = { is_git = true, is_github = is_github }
      if changed then
        vim.schedule(function()
          if on_change then on_change() end
        end)
      end
    end)
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

-- Register fs_event watchers for up to 100 unique directory paths.
function M.start_watchers(paths)
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
  M.stop_watchers()
  M.git_roots = {}
end

return M
