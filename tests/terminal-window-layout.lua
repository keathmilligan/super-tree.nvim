-- Run: nvim --headless -u NONE --cmd 'set rtp+=.' -c "lua dofile('tests/terminal-window-layout.lua')"
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.fn.writefile({ "editor" }, root .. "/editor.txt")
local original_cwd = vim.fn.getcwd()

local function check(value, message)
  if not value then error(message, 2) end
end

local super_tree = require("super-tree")
vim.api.nvim_set_current_dir(root)
super_tree.setup({
  mode = "sidebar",
  buffers = { enable = false },
  projects = { enable = false },
  git = { enable = false },
  diagnostics = { enable = false },
  fade = { enable = false },
})

vim.cmd("edit " .. vim.fn.fnameescape(root .. "/editor.txt"))
local editor_buffer = vim.api.nvim_get_current_buf()
super_tree.open()
local window = require("super-tree.window")

local split_keys = { "<C-w>s", "<C-w>S", "<C-w><C-s>", "<C-w>v", "<C-w><C-v>" }
for _, keys in ipairs(split_keys) do
  local win_count = #vim.api.nvim_tabpage_list_wins(0)
  vim.api.nvim_set_current_win(window.sidebar_win)
  local input = vim.api.nvim_replace_termcodes(keys, true, false, true)
  vim.api.nvim_feedkeys(input, "xt", false)
  check(
    #vim.api.nvim_tabpage_list_wins(0) == win_count,
    keys .. " must not duplicate the tree"
  )
end

vim.api.nvim_set_current_win(window.find_editor_win())
vim.cmd("rightbelow vsplit")
vim.cmd("enew")
local first_job = vim.fn.jobstart({ "sh", "-c", "sleep 5" }, { term = true })
vim.cmd("rightbelow split")
vim.cmd("enew")
local second_job = vim.fn.jobstart({ "sh", "-c", "sleep 5" }, { term = true })

check(#vim.api.nvim_tabpage_list_wins(0) == 4, "fixture has tree, editor, and two terminals")
vim.cmd("bdelete! " .. editor_buffer)
vim.wait(200)

local wins = vim.api.nvim_tabpage_list_wins(0)
check(#wins == 3, "deleting the editor must not create a split beside existing terminals")
check(window.find_editor_win() == nil, "terminals remain excluded as file-opening targets")
check(window.find_non_plugin_win() ~= nil, "terminals satisfy the window-layout invariant")

pcall(vim.fn.jobstop, first_job)
pcall(vim.fn.jobstop, second_job)
super_tree.close()
vim.api.nvim_set_current_dir(original_cwd)
vim.fn.delete(root, "rf")
print("Super Tree terminal-window layout checks passed")
vim.cmd("qa!")
