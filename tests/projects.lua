-- Run: TMPDIR=/tmp/opencode nvim --headless -u NONE -i NONE
--        --cmd 'set rtp+=.' -c "lua dofile('tests/projects.lua')"
local root = vim.fn.tempname()
local original_cwd = vim.fn.getcwd()

local function check(value, message)
  assert(value, message)
end

local function run()
  vim.o.lines = 45
  vim.o.columns = 140
  local alpha, beta = root .. "/alpha", root .. "/beta space"
  vim.fn.mkdir(alpha .. "/sub", "p")
  vim.fn.mkdir(beta, "p")
  vim.fn.writefile({ "alpha" }, alpha .. "/file.txt")
  vim.fn.writefile({ "beta" }, beta .. "/file.txt")

  local supertree = require("super-tree")
  local window = require("super-tree.window")
  local projects = require("super-tree.projects")
  local filter = require("super-tree.filter")

  supertree.setup({ git = { enable = false }, diagnostics = { enable = false } })
  supertree.open()
  check(not window.projects_win, "no provider should mean no Projects pane")
  supertree.close()

  local gamma = root .. "/gamma"
  vim.fn.mkdir(gamma, "p")
  local paths = { alpha, beta, alpha .. "/", root .. "/missing", alpha .. "/file.txt" }
  local history_oldest_first = { gamma, beta }
  package.loaded["neovim-project.utils.path"] = {
    get_all_projects_with_sorting = function() return paths end,
  }
  package.loaded["neovim-project.utils.history"] = {
    get_recent_projects = function() return history_oldest_first end,
  }
  local switched
  package.loaded["neovim-project.project"] = {
    switch_project = function(dir)
      check(not supertree.is_open(), "panes must close before the provider saves a session")
      check(not window.projects_win and not window.buffers_win, "all panes must close")
      switched = dir
      -- Simulate session loading, including deletion of scratch buffers.
      vim.cmd("silent only")
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        vim.api.nvim_buf_delete(buf, { force = true })
      end
      vim.api.nvim_set_current_dir(dir)
      vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/file.txt"))
      vim.api.nvim_exec_autocmds("User", { pattern = "SessionLoadPost" })
    end,
  }

  local function key(buf, lhs)
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      if map.lhs == lhs then return map.callback() end
    end
    error("Missing keymap: " .. lhs)
  end

  local function layout(with_buffers)
    local wins = { window.projects_win }
    if with_buffers then wins[#wins + 1] = window.buffers_win end
    wins[#wins + 1] = window.sidebar_win
    local previous_bottom = -1
    for _, win in ipairs(wins) do
      check(win and vim.api.nvim_win_is_valid(win), "pane must be open")
      local pos = vim.api.nvim_win_get_position(win)
      check(pos[1] >= previous_bottom, "panes must be ordered and must not overlap")
      previous_bottom = pos[1] + vim.api.nvim_win_get_height(win)
      check(vim.api.nvim_win_get_width(win) == vim.api.nvim_win_get_width(window.sidebar_win),
        "pane widths must match")
    end
    check(window.find_editor_win(), "panes must not replace the editor")
  end

  paths = { gamma, alpha, beta }
  vim.api.nvim_set_current_dir(alpha)
  supertree.setup({ git = { enable = false }, diagnostics = { enable = false }, projects = { enable = true } })
  supertree.open()
  check(#projects.entries == 3, "sort fixture has three projects")
  check(projects.entries[1].name == "alpha", "current project is first")
  check(projects.entries[2].name == "beta space", "more recently used history is next")
  check(projects.entries[3].name == "gamma", "older history is last")
  supertree.close()
  paths = { alpha, beta, alpha .. "/", root .. "/missing", alpha .. "/file.txt" }

  for _, mode in ipairs({ "sidebar", "pinned", "floating" }) do
    vim.api.nvim_set_current_dir(alpha .. "/sub")
    supertree.setup({
      mode = mode,
      projects = { enable = true, height = 20 },
      buffers = { enable = true, height = 8 },
    })
    supertree.open()
    check(#projects.entries == 2, "duplicate, deleted and non-directory projects must be omitted")
    local lines = vim.api.nvim_buf_get_lines(window.projects_buf, 0, -1, false)
    check(lines[1]:find(" > alpha", 1, true), "cwd below a project should mark it active")
    check(not vim.bo[window.projects_buf].modifiable and not vim.bo[window.projects_buf].modified,
      "Projects must be an unmodified scratch buffer")
    layout(true)
    check(vim.api.nvim_win_get_height(window.projects_win) == 20, "configured Projects height")
    check(vim.api.nvim_win_get_height(window.buffers_win) == 8, "configured Buffers height")
    vim.api.nvim_set_current_win(window.projects_win)
    supertree.toggle_buffers()
    layout(false)
    check(vim.api.nvim_win_get_height(window.projects_win) == 20, "hiding Buffers must preserve Projects height")
    supertree.toggle_buffers()
    layout(true)
    check(vim.api.nvim_win_get_height(window.projects_win) == 20, "showing Buffers must preserve Projects height")
    check(vim.api.nvim_win_get_height(window.buffers_win) == 8, "restored Buffers height")
    if mode ~= "floating" then
      local ph = vim.api.nvim_win_get_height(window.projects_win)
      local bh = vim.api.nvim_win_get_height(window.buffers_win)
      vim.api.nvim_set_current_win(window.find_editor_win())
      vim.cmd("vsplit")
      vim.api.nvim_win_close(vim.api.nvim_get_current_win(), true)
      check(vim.api.nvim_win_get_height(window.projects_win) == ph,
        "closing a vsplit must not change Projects height")
      check(vim.api.nvim_win_get_height(window.buffers_win) == bh,
        "closing a vsplit must not change Buffers height")
    end
    if mode == "floating" then
      vim.o.lines = 12
      vim.api.nvim_exec_autocmds("VimResized", {})
      layout(true)
      local bottom = vim.api.nvim_win_get_position(window.sidebar_win)[1]
        + vim.api.nvim_win_get_height(window.sidebar_win)
      check(bottom <= vim.o.lines - vim.o.cmdheight, "floating panes must fit a short screen")
      vim.o.lines = 45
      vim.api.nvim_exec_autocmds("VimResized", {})
    end

    -- A reordered discovery list should retain the selected project.
    vim.api.nvim_win_set_cursor(window.projects_win, { 2, 0 })
    paths = { beta, alpha }
    key(window.projects_buf, "R")
    check(projects.entry_at_cursor().path == beta, "refresh must preserve selected project")
    filter.apply_term("file")
    key(window.projects_buf, "<CR>")
    check(switched == beta, "Enter must use the provider's project switch")
    check(vim.wait(1000, function() return supertree.is_open() and window.projects_win ~= nil end),
      "panes should reopen after session replacement")
    check(vim.fn.getcwd() == beta, "project switch must change cwd")
    check(not filter.is_active(), "old project filter must be cleared")
    layout(true)
    lines = vim.api.nvim_buf_get_lines(window.projects_buf, 0, -1, false)
    check(lines[1]:find(" > beta space", 1, true), "new project must be marked active")

    -- Empty discovery hides Projects, and refresh restores it when projects return.
    paths = {}
    key(window.projects_buf, "R")
    check(not window.projects_win, "empty list must hide Projects")
    paths = { alpha, beta }
    key(window.sidebar_buf, "R")
    layout(true)
    vim.api.nvim_win_close(window.buffers_win, true)
    layout(false)
    supertree.toggle_buffers()
    layout(true)
    vim.api.nvim_win_close(window.sidebar_win, true)
    check(not window.projects_win and not window.buffers_win, "external tree close must clean up panes")
    vim.wait(20, function() return false end)
    supertree.open()
    layout(true)
    supertree.close()
    check(#vim.api.nvim_list_wins() == 1, "close must leave only the editor")
  end

  supertree.setup({ mode = "sidebar", projects = { enable = false } })
  supertree.open()
  check(not window.projects_win, "Projects can be disabled")
  supertree.close()
  supertree.setup({ projects = { enable = true }, buffers = { enable = false } })
  supertree.open()
  layout(false)
  local notify = vim.notify
  local message
  vim.notify = function(msg) message = msg end
  local provider = package.loaded["neovim-project.project"]
  provider.switch_project = function() error("test switch failure") end
  vim.api.nvim_set_current_win(window.projects_win)
  vim.api.nvim_win_set_cursor(window.projects_win, { 1, 0 })
  key(window.projects_buf, "<CR>")
  check(vim.wait(1000, function() return supertree.is_open() end), "reopen after a provider error")
  check(message and message:find("test switch failure", 1, true), "report switch errors")
  check(not window.buffers_visible, "preserve hidden Buffers after a failed switch")
  vim.notify = notify
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
  print("Projects pane checks passed (sidebar, pinned, floating)")
  vim.cmd("qa!")
end
