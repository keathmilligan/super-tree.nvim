-- Run: nvim --headless -u NONE --cmd 'set rtp+=.' -c "lua dofile('tests/state-provider.lua')"
local root = vim.fn.tempname()
local project_a = root .. "/a"
local project_b = root .. "/b"
vim.fn.mkdir(project_a .. "/src", "p")
vim.fn.mkdir(project_b, "p")
vim.fn.writefile({ "fixture" }, project_a .. "/src/file.txt")
local original_cwd = vim.fn.getcwd()

local function check(value, message)
  if not value then error(message, 2) end
end

local opened
local super_tree = require("super-tree")
super_tree.setup({
  mode = "sidebar",
  buffers = { enable = true },
  projects = { enable = true, height = 5 },
  git = { enable = false },
  diagnostics = { enable = false },
  fade = { enable = false },
})
super_tree.register_project_provider("fixture", {
  manages_tree_state = true,
  projects = function()
    return {
      { root = project_b, name = "b", rank = 1 },
      { root = project_a, name = "a", rank = 2, active = true },
    }
  end,
  current = function() return { root = project_a } end,
  open = function(path)
    opened = path
    return true
  end,
})

vim.api.nvim_set_current_dir(project_a)
super_tree.open()
local tree = require("super-tree.tree")
tree.expanded_paths[project_a .. "/src"] = true
tree.show_hidden = true
local state = super_tree.capture_state()
check(state.open and state.buffers_visible and state.projects_visible, "snapshot captures pane visibility")
check(state.expanded_paths[1] == project_a .. "/src", "snapshot captures expansion")

super_tree.close()
tree.expanded_paths = {}
tree.show_hidden = false
vim.api.nvim_set_current_dir(project_b)
check(super_tree.restore_state(state), "state restores")
check(super_tree.is_open(), "restore reopens tree")
check(vim.fn.getcwd() == project_a, "restore returns to tree root")
check(tree.expanded_paths[project_a .. "/src"] and tree.show_hidden, "restore applies tree state")

local projects = require("super-tree.projects")
check(projects.provider_name() == "fixture" and projects.provider_manages_state(), "native provider is active")
local entries = projects.collect()
check(#entries == 2 and entries[1].root == vim.fn.resolve(project_a), "provider entries are sorted and active")
check(projects.open(entries[2]), "provider opens project")
check(opened == vim.fn.resolve(project_b), "provider receives canonical project root")

super_tree.close()
vim.api.nvim_set_current_dir(original_cwd)
vim.fn.delete(root, "rf")
print("Super Tree state/provider checks passed")
vim.cmd("qa!")
