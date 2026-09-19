-- Run: TMPDIR=/tmp/opencode nvim --headless -u NONE -i NONE
--        --cmd 'set rtp+=.' -c "lua dofile('tests/pane-right-fade.lua')"
--
-- Right-edge fadeout: lines too wide for a pane are truncated and dim over
-- their last three characters, in every pane (tree, projects, agents,
-- buffers).
local root = "/tmp/opencode/st-right-fade"
local original_cwd = vim.fn.getcwd()

local function check(value, message)
  assert(value, message)
end

-- True when `row` (0-based) in `buf` carries a right-edge fadeout mark that
-- ends at the last byte of the line. SuperTreeNameFade3 only ever comes from
-- the fadeout; the panes' static dim highlights use SuperTreeNameFade1.
local function fades_at_edge(buf, row)
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, { row, 0 }, { row, -1 }, { details = true })) do
    if mark[4].hl_group == "SuperTreeNameFade3" and mark[4].end_col == #line then
      return true
    end
  end
  return false
end

local function run()
  vim.o.lines = 45
  vim.o.columns = 120
  local alpha, beta = root .. "/alpha", root .. "/beta"
  vim.fn.mkdir(alpha, "p")
  vim.fn.mkdir(beta, "p")
  vim.fn.writefile({ "alpha" }, alpha .. "/x.lua")
  local long_file = alpha .. "/this-is-an-extremely-long-file-name-for-the-fade.lua"
  vim.fn.writefile({ "alpha" }, long_file)

  local fade = require("super-tree.fade")

  -- truncate_to_width: display-cell limit, never splits a multi-byte char.
  local text, truncated = fade.truncate_to_width("abc●def", 5)
  check(truncated and text == "abc●d", "truncation keeps whole multi-byte characters")
  local full, full_truncated = fade.truncate_to_width("abc", 5)
  check(not full_truncated and full == "abc", "fitting text is returned unchanged")
  check((fade.truncate_to_width("abc", 0)) == "", "zero width truncates to nothing")

  -- add_right_fade: last three bytes dim towards the edge.
  local marks = {}
  fade.add_right_fade(marks, 2, 4, "abcdef")
  check(#marks == 3, "fadeout covers the last three characters")
  check(marks[1].line == 2 and marks[1].start == 7 and marks[1].end_ == 8
    and marks[1].hl == "SuperTreeNameFade1", "third-from-last char is least faded")
  check(marks[3].start == 9 and marks[3].end_ == 10
    and marks[3].hl == "SuperTreeNameFade3", "last char is most faded")
  local custom = {}
  fade.add_right_fade(custom, 0, 0, "xy", { "A", "B", "C" })
  check(#custom == 2 and custom[2].hl == "B", "custom fade groups are honored")

  local supertree = require("super-tree")
  local window = require("super-tree.window")
  local agents = require("super-tree.agents")

  supertree.setup({
    mode = "sidebar",
    width = 48,
    icons = { provider = "builtin" },
    projects = { enable = true, height = 6 },
    buffers = { enable = true, height = 6 },
    agents = { enable = false },
    git = { enable = false },
    diagnostics = { enable = false },
    fade = { enable = false },
  })
  supertree.register_project_provider("fixture", {
    projects = function()
      return {
        { root = alpha, name = "alpha", rank = 2, active = true },
        { root = beta, name = "a-project-name-much-too-long-for-the-pane", rank = 1 },
      }
    end,
    current = function() return { root = alpha } end,
    open = function() return true end,
  })

  vim.cmd("edit " .. vim.fn.fnameescape(alpha .. "/x.lua"))
  vim.cmd("edit " .. vim.fn.fnameescape(long_file))
  vim.api.nvim_set_current_dir(alpha)
  supertree.open()

  local avail = vim.api.nvim_win_get_width(window.sidebar_win) - 1
  check(avail == 47, "fixture sidebar width")

  -- Projects: the long project line fades; the short active line fits.
  local plines = vim.api.nvim_buf_get_lines(window.projects_buf, 0, -1, false)
  check(#plines == 2, "fixture has two projects")
  check(not plines[1]:find("a%-project%-name") and not fades_at_edge(window.projects_buf, 0),
    "fitting project line is not faded")
  check(plines[2]:find("^   a%-project%-name") and not plines[2]:find("too-long-for-the-pane  "),
    "long project line is truncated")
  check(vim.fn.strdisplaywidth(plines[2]) <= avail, "project line fits the pane")
  check(fades_at_edge(window.projects_buf, 1), "long project line fades out at the right edge")

  -- Buffers: most recently used first, so the long file name is row one.
  local blines = vim.api.nvim_buf_get_lines(window.buffers_buf, 0, -1, false)
  check(#blines == 2, "fixture has two listed buffers")
  check(not blines[1]:find("for%-the%-fade%.lua"), "long buffer name is truncated")
  check(vim.fn.strdisplaywidth(blines[1]) <= avail, "buffer line fits the pane")
  check(fades_at_edge(window.buffers_buf, 0), "long buffer line fades out at the right edge")
  check(blines[2]:find("x%.lua") and not fades_at_edge(window.buffers_buf, 1),
    "fitting buffer line is not faded")

  -- Agents: drive the pane directly, one long entry and one short entry.
  agents.all = {
    {
      id = "agent-long", status = "working",
      project = "a-project-name-that-is-far-too-long-for-the-pane",
      description = "An agent session description that is far too long to fit in the pane",
      agent = "build", model = "gpt-5.6-sol-with-an-oversized-name",
      model_provider = "opencode", model_variant = "max",
    },
    { id = "agent-short", status = "idle" },
  }
  window.open_agents_window(9)
  agents.render(window.agents_buf)
  local alines = vim.api.nvim_buf_get_lines(window.agents_buf, 0, -1, false)
  check(#alines == 6, "two agents render as six rows")
  for row = 1, 3 do
    check(vim.fn.strdisplaywidth(alines[row]) <= avail, "agent row " .. row .. " fits the pane")
    check(fades_at_edge(window.agents_buf, row - 1),
      "agent row " .. row .. " fades out at the right edge")
  end
  for row = 4, 6 do
    check(not fades_at_edge(window.agents_buf, row - 1), "short agent row " .. row .. " is not faded")
  end
  check(alines[1]:find("working", 1, true), "truncated status row keeps its text")
  vim.api.nvim_win_set_cursor(window.agents_win, { 2, 0 })
  check(agents.entry_at_cursor().id == "agent-long", "row mapping survives truncation")

  -- Narrowing the sidebar re-truncates every pane at the new right edge.
  vim.api.nvim_win_set_width(window.sidebar_win, 30)
  vim.api.nvim_exec_autocmds("WinResized", {})
  local narrow_avail = vim.api.nvim_win_get_width(window.projects_win) - 1
  check(narrow_avail == 29, "panes follow the sidebar width")
  plines = vim.api.nvim_buf_get_lines(window.projects_buf, 0, -1, false)
  check(vim.fn.strdisplaywidth(plines[2]) <= narrow_avail,
    "project line is re-truncated after a resize")
  check(fades_at_edge(window.projects_buf, 1), "project fade tracks the new right edge")
  blines = vim.api.nvim_buf_get_lines(window.buffers_buf, 0, -1, false)
  check(vim.fn.strdisplaywidth(blines[1]) <= narrow_avail,
    "buffer line is re-truncated after a resize")
  alines = vim.api.nvim_buf_get_lines(window.agents_buf, 0, -1, false)
  check(vim.fn.strdisplaywidth(alines[1]) <= narrow_avail,
    "agent row is re-truncated after a resize")

  supertree.close()
end

local ok, err = xpcall(run, debug.traceback)
require("super-tree").close()
vim.api.nvim_set_current_dir(original_cwd)
vim.fn.delete(root, "rf")
if not ok then
  io.stderr:write(err .. "\n")
  vim.cmd("cquit 1")
else
  print("Pane right-edge fadeout checks passed")
  vim.cmd("qa!")
end
