-- Run: TMPDIR=/tmp/opencode nvim --headless -u NONE -i NONE
--        --cmd 'set rtp+=.' -c "lua dofile('tests/fade.lua')"
local function check(value, message)
  assert(value, message)
end

local function run()
  vim.o.termguicolors = true
  local fade = require("super-tree.fade")
  fade.clear_cache()

  local f8 = fade.visible_factors(1, 8, 8)
  check(f8[4] == nil, "rows above the last 30% of the panel stay full brightness")
  check(math.abs(f8[7] - 0.25) < 1e-9, "item at the bottom of the panel is 25% opacity")

  check(not next(fade.visible_factors(1, 3, 20)),
    "items that do not reach the last 30% of a tall panel do not fade")

  local scrolled = fade.visible_factors(10, 17, 8)
  check(math.abs((scrolled[16] or 0) - 0.25) < 1e-9, "fade follows the viewport bottom")

  local custom = fade.visible_factors(1, 10, 10, { zone = 0.5, bottom_opacity = 0.1 })
  check(custom[4] == nil, "custom zone starts halfway down a filled pane")
  check(math.abs((custom[9] or 0) - 0.1) < 1e-9, "custom bottom opacity")
  check(not next(fade.visible_factors(1, 8, 8, { enable = false })),
    "disabled fade applies nothing")
  check(not next(fade.visible_factors(1, 8, 8, { zone = 0 })),
    "zero zone applies nothing")

  fade.configure({ zone = 1, bottom_opacity = 0 })
  check(math.abs((fade.visible_factors(1, 4, 4)[3] or -1)) < 1e-9,
    "configure updates the default fade")
  fade.configure()

  -- The highlighted item under the pane cursor never fades.
  local fbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, { "a", "b", "c", "d", "e", "f", "g", "h" })
  local fwin = vim.api.nvim_open_win(fbuf, false,
    { relative = "editor", row = 0, col = 0, width = 20, height = 8 })
  vim.api.nvim_win_set_cursor(fwin, { 7, 0 })
  local factors = fade.window_factors(fwin, 1, 8, 8)
  check(factors[6] == nil, "the highlighted item under the cursor keeps full brightness")
  check(math.abs((factors[7] or 0) - 0.25) < 1e-9, "items below the cursor row still fade")
  vim.api.nvim_win_set_cursor(fwin, { 8, 0 })
  factors = fade.window_factors(fwin, 1, 8, 8)
  check(factors[6] ~= nil, "a row that is no longer highlighted fades again")
  check(factors[7] == nil, "the newly highlighted row is exempt")
  vim.api.nvim_win_close(fwin, true)

  vim.api.nvim_set_hl(0, "Directory", { fg = "#ffffff", bold = true })
  check(fade.group("Directory") == "Directory", "no factor keeps the original group")
  check(fade.group("Directory", 1) == "Directory", "full brightness keeps the original group")

  local quarter = fade.group("Directory", 0.25)
  check(quarter ~= "Directory", "quarter brightness uses a derived group")
  local hl = vim.api.nvim_get_hl(0, { name = quarter, link = false })
  check(hl.fg == fade.darken(0xffffff, 0.25), "bottom-of-panel factor is 25% foreground")
  check(hl.bold == true, "fade preserves bold")
  check(hl.bg == nil, "fade does not paint over the sidebar background")

  -- Rendering, scrolling, virtual text, and project restoration are verified
  -- against the RGB screen cells in tests/fade-screen.py. Stored extmarks do
  -- not prove that the viewport was actually drawn with the correct colors.
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
  io.stderr:write(err .. "\n")
  vim.cmd("cquit 1")
else
  print("Fade checks passed")
  vim.cmd("qa!")
end
