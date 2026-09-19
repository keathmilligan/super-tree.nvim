-- Run: TMPDIR=/tmp/opencode nvim --headless -u NONE -i NONE
--        --cmd 'set rtp+=.' -c "lua dofile('tests/pane-order.lua')"
-- Pane order: default order, custom orders in every window mode,
-- normalization of invalid input, and the default Agents height.
local root = vim.fn.tempname()
local alpha = root .. "/alpha"
local original_cwd = vim.fn.getcwd()

vim.fn.mkdir(alpha, "p")
vim.fn.writefile({ "alpha" }, alpha .. "/file.txt")

local function check(value, message)
  assert(value, message)
end

local supertree = require("super-tree")
local window = require("super-tree.window")
local agents = require("super-tree.agents")
local provider = require("super-tree.agent_providers.opencode")

local function wait_for(predicate, message)
  check(vim.wait(1500, predicate, 10), message)
end

local function check_order(order, label)
  local wins = {}
  for _, pane in ipairs(order) do wins[#wins + 1] = window[pane .. "_win"] end
  wins[#wins + 1] = window.sidebar_win
  local previous_bottom = -1
  for _, win in ipairs(wins) do
    check(win and vim.api.nvim_win_is_valid(win), label .. ": every pane must be open")
    local pos = vim.api.nvim_win_get_position(win)
    check(pos[1] >= previous_bottom, label .. ": panes must be ordered and non-overlapping")
    previous_bottom = pos[1] + vim.api.nvim_win_get_height(win)
    check(vim.api.nvim_win_get_width(win) == vim.api.nvim_win_get_width(window.sidebar_win),
      label .. ": pane widths must match")
  end
end

local function run()
  vim.o.lines = 55
  vim.o.columns = 150
  vim.api.nvim_set_current_dir(alpha)

  -- Agent fixture: five idle TUIs in the project. Project fixture: one project.
  local uid = vim.loop.getuid()
  local process_lines = {}
  for index = 1, 5 do
    process_lines[#process_lines + 1] =
      string.format("%d %d opencode2 opencode2", 4241 + index, uid)
  end
  local process_fixture = table.concat(process_lines, "\n")
  provider._reset()
  provider._set_runner(function(argv, _, callback)
    local cancelled = false
    vim.schedule(function()
      if cancelled then return end
      if argv[1] == "ps" then
        callback(true, process_fixture)
      elseif argv[4] == "/api/session/active" then
        callback(true, vim.json.encode({ data = {} }))
      else
        callback(true, "{}")
      end
    end)
    return function() cancelled = true end
  end)
  provider._set_cwd_resolver(function() return alpha end)

  supertree.register_project_provider("fixture-projects", {
    manages_tree_state = false,
    projects = function()
      return { { root = alpha, name = "alpha", rank = 1, active = true } }
    end,
    current = function() return { root = alpha } end,
    open = function() return true end,
  })

  local function open_with(opts)
    local base = {
      agents = { enable = true, refresh_interval = 60000, command = "fixture" },
      projects = { enable = true },
      buffers = { enable = true },
      git = { enable = false },
      diagnostics = { enable = false },
      fade = { enable = false },
    }
    supertree.setup(vim.tbl_deep_extend("force", base, opts or {}))
    supertree.open()
    wait_for(function()
      return window.agents_win ~= nil and #agents.all == 5
    end, "Agents pane must open from the fixture")
  end

  -- Default order and default Agents height in sidebar mode.
  open_with({ mode = "sidebar" })
  check(vim.deep_equal(window.get_pane_order(), { "projects", "agents", "buffers" }),
    "default pane order is Projects, Agents, Buffers")
  check_order({ "projects", "agents", "buffers" }, "default sidebar")
  check(vim.api.nvim_win_get_height(window.agents_win) == 15,
    "default Agents height fits five three-row entries")
  check(vim.api.nvim_buf_line_count(window.agents_buf) == 15,
    "five agent entries render as fifteen rows")
  check(vim.api.nvim_win_get_height(window.agents_win)
      >= vim.api.nvim_buf_line_count(window.agents_buf),
    "all five entries fit the default Agents height")
  supertree.close()

  -- Custom orders apply in all three window modes.
  for _, case in ipairs({
    { mode = "sidebar", order = { "buffers", "agents", "projects" } },
    { mode = "pinned", order = { "buffers", "projects", "agents" } },
    { mode = "floating", order = { "projects", "buffers", "agents" } },
  }) do
    open_with({ mode = case.mode, pane_order = case.order })
    check(vim.deep_equal(window.get_pane_order(), case.order),
      case.mode .. ": configured pane order is stored")
    check_order(case.order, case.mode .. " custom order")
    supertree.close()
  end

  -- Normalization: missing panes append, unknown/duplicate/misplaced tree
  -- entries are dropped, and a non-table falls back to the default.
  window.set_pane_order({ "buffers" })
  check(vim.deep_equal(window.get_pane_order(), { "buffers", "projects", "agents" }),
    "missing panes append in the default order")
  window.set_pane_order({ "buffers", "buffers", "nope" })
  check(vim.deep_equal(window.get_pane_order(), { "buffers", "projects", "agents" }),
    "duplicate and unknown entries are ignored")
  window.set_pane_order({ "projects", "agents", "buffers", "tree" })
  check(vim.deep_equal(window.get_pane_order(), { "projects", "agents", "buffers" }),
    "a final tree entry is accepted")
  window.set_pane_order({ "tree", "buffers", "projects" })
  check(vim.deep_equal(window.get_pane_order(), { "buffers", "projects", "agents" }),
    "a misplaced tree entry is ignored")
  window.set_pane_order("projects")
  check(vim.deep_equal(window.get_pane_order(), { "projects", "agents", "buffers" }),
    "a non-table order falls back to the default")
end

local ok, err = xpcall(run, debug.traceback)
supertree.close()
provider._reset()
supertree.unregister_project_provider("fixture-projects")
vim.api.nvim_set_current_dir(original_cwd)
vim.fn.delete(root, "rf")
if not ok then
  io.stderr:write(err .. "\n")
  vim.cmd("cquit 1")
else
  print("Pane order, normalization, and default Agents height checks passed")
  vim.cmd("qa!")
end
