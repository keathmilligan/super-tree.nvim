-- Run: TMPDIR=/tmp/opencode nvim --headless -u NONE -i NONE
--        --cmd 'set rtp+=.' -c "lua dofile('tests/pane-filter.lua')"
local root = vim.fn.tempname()
local original_cwd = vim.fn.getcwd()

local function check(value, message)
  assert(value, message)
end

local function keymap(buf, lhs)
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if map.lhs == lhs then return map.callback end
  end
  error("Missing keymap: " .. lhs)
end

local function run()
  vim.o.lines = 45
  vim.o.columns = 140
  local alpha, beta = root .. "/alpha", root .. "/beta space"
  vim.fn.mkdir(alpha, "p")
  vim.fn.mkdir(beta, "p")
  vim.fn.writefile({ "alpha" }, alpha .. "/file.txt")
  vim.fn.writefile({ "beta" }, beta .. "/file.txt")
  vim.fn.writefile({ "other" }, alpha .. "/other.lua")

  local supertree = require("super-tree")
  local window = require("super-tree.window")
  local projects = require("super-tree.projects")
  local buffers = require("super-tree.buffers")
  local filter = require("super-tree.filter")

  package.loaded["neovim-project.utils.path"] = {
    get_all_projects_with_sorting = function() return { alpha, beta } end,
  }
  package.loaded["neovim-project.project"] = {
    switch_project = function() end,
  }

  vim.api.nvim_set_current_dir(alpha)
  vim.cmd("edit " .. vim.fn.fnameescape(alpha .. "/file.txt"))
  vim.cmd("edit " .. vim.fn.fnameescape(alpha .. "/other.lua"))
  vim.cmd("edit " .. vim.fn.fnameescape(beta .. "/file.txt"))

  supertree.setup({
    git = { enable = false },
    diagnostics = { enable = false },
    projects = { enable = true },
    buffers = { enable = true },
  })
  supertree.open()
  check(window.projects_win and window.buffers_win, "both panes must be open")
  check(keymap(window.projects_buf, "/"), "Projects must map live filter")
  check(keymap(window.buffers_buf, "/"), "Buffers must map live filter")
  check(#projects.entries == 2, "unfiltered project list")

  filter.apply_term("alpha", "projects")
  check(#projects.entries == 1 and projects.entries[1].name == "alpha",
    "project live filter matches name")
  check(projects.entry_at_cursor().name == "alpha", "cursor stays on the matching project")

  filter.apply_term("beta", "projects")
  check(#projects.entries == 1 and projects.entries[1].name == "beta space",
    "project filter matches another name")

  filter.apply_term("space", "projects")
  check(#projects.entries == 1 and projects.entries[1].name == "beta space",
    "project filter matches path text")

  filter.apply_term("", "projects")
  check(#projects.entries == 2, "clearing the project term restores the list")

  filter.apply_term("other", "buffers")
  check(#buffers.entries == 1 and buffers.entries[1].name == "other.lua",
    "buffer live filter matches name")

  filter.apply_term("file.txt", "buffers")
  check(#buffers.entries == 2, "buffer filter can match shared names")

  filter.clear("buffers")
  check(not buffers.search_pattern, "clearing the buffer filter drops the term")
  check(#buffers.entries >= 2, "clearing the buffer filter restores the list")

  filter.clear("projects")
  check(not projects.search_pattern, "clearing the project filter drops the term")
  check(#projects.entries == 2, "clearing the project filter restores the list")

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
  print("Pane filter checks passed")
  vim.cmd("qa!")
end
