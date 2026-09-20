-- Run: TMPDIR=/tmp/opencode nvim --headless -u NONE -i NONE
--        --cmd 'set rtp+=.' -c "lua dofile('tests/ignored-status.lua')"
-- Requires the `git` binary: builds a real repository so ignored entries
-- come from `git status --ignored=traditional`.
local root = vim.fn.tempname()

local function check(value, message)
  assert(value, message)
end

local function run()
  vim.o.lines = 45
  vim.o.columns = 120
  vim.fn.mkdir(root .. "/build", "p")
  vim.fn.mkdir(root .. "/src", "p")
  vim.fn.writefile({ "x" }, root .. "/build/out.bin")
  vim.fn.writefile({ "x" }, root .. "/src/main.lua")
  vim.fn.writefile({ "x" }, root .. "/secret.txt")
  vim.fn.writefile({ "x" }, root .. "/tracked.txt")
  vim.fn.writefile({ "build/", "secret.txt" }, root .. "/.gitignore")

  vim.fn.system({ "git", "-C", root, "init", "-q" })
  vim.fn.system({ "git", "-C", root, "add", ".gitignore", "src/main.lua", "tracked.txt" })
  vim.fn.system({ "git", "-C", root, "-c", "user.email=t@t", "-c", "user.name=t",
    "commit", "-qm", "init" })

  -- Required before set_current_dir: the runtime path holds a relative "."
  -- entry that would otherwise resolve inside the temp repository.
  local supertree = require("super-tree")
  local window = require("super-tree.window")
  local git = require("super-tree.git")

  vim.api.nvim_set_current_dir(root)

  supertree.setup({
    agents = { enable = false },
    diagnostics = { enable = false },
    projects = { enable = false },
    buffers = { enable = false },
  })
  supertree.open()

  local arrived = vim.wait(5000, function() return git.repo_status[root] ~= nil end, 50)
  check(arrived, "git status arrived")

  -- The git on_change callback re-renders the sidebar via vim.schedule, so
  -- poll for the decorations instead of assuming a fixed timeline.
  local buf = window.sidebar_buf
  check(buf and vim.api.nvim_buf_is_valid(buf), "sidebar buffer exists")
  local ns = vim.api.nvim_create_namespace("SuperTree")

  -- Highlight group covering the first character of `needle` in the sidebar,
  -- or nil when the entry has no name highlight.
  local function name_hl_of(needle)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    for row, line in ipairs(lines) do
      local s = line:find(needle, 1, true)
      if s then
        s = s - 1
        local marks = vim.api.nvim_buf_get_extmarks(buf, ns,
          { row - 1, 0 }, { row, 0 }, { details = true })
        for _, m in ipairs(marks) do
          local d = m[4]
          if d.end_col and s >= m[3] and s < d.end_col then
            return d.hl_group
          end
        end
        return nil
      end
    end
    return nil
  end

  local rendered = vim.wait(5000, function()
    return name_hl_of("secret.txt") == "SuperTreeGitIgnored"
  end, 50)
  check(rendered, "ignored file is grayed")

  local dir_hl = name_hl_of("build")
  check(dir_hl == "SuperTreeGitIgnored",
    "ignored directory is grayed like the file (got " .. tostring(dir_hl) .. ")")

  local plain_dir_hl = name_hl_of("src")
  check(plain_dir_hl == "SuperTreeDirectory",
    "normal directory keeps the directory highlight (got " .. tostring(plain_dir_hl) .. ")")

  local plain_file_hl = name_hl_of("tracked.txt")
  check(plain_file_hl ~= "SuperTreeGitIgnored",
    "tracked file is not grayed (got " .. tostring(plain_file_hl) .. ")")
end

local ok, err = xpcall(run, debug.traceback)
vim.fn.delete(root, "rf")
if not ok then
  io.stderr:write(err .. "\n")
  vim.cmd("cquit 1")
else
  print("ignored-status checks passed")
  vim.cmd("qa!")
end
