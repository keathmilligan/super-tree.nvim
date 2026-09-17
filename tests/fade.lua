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

  vim.api.nvim_set_hl(0, "Directory", { fg = "#ffffff", bold = true })
  check(fade.group("Directory") == "Directory", "no factor keeps the original group")
  check(fade.group("Directory", 1) == "Directory", "full brightness keeps the original group")

  local quarter = fade.group("Directory", 0.25)
  check(quarter ~= "Directory", "quarter brightness uses a derived group")
  local hl = vim.api.nvim_get_hl(0, { name = quarter, link = false })
  check(hl.fg == fade.darken(0xffffff, 0.25), "bottom-of-panel factor is 25% foreground")
  check(hl.bold == true, "fade preserves bold")
  check(hl.bg == nil, "fade does not paint over the sidebar background")

  local ns = vim.api.nvim_create_namespace("SuperTreeFadeTest")
  local buf = vim.api.nvim_create_buf(false, true)
  local lines = { "one", "two", "three", "four", "five", "six", "seven", "eight" }
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  for i = 0, 7 do
    vim.api.nvim_buf_set_extmark(buf, ns, i, 0, { end_col = #lines[i + 1], hl_group = "Directory" })
  end
  local virt_id = vim.api.nvim_buf_set_extmark(buf, ns, 7, 0, {
    virt_text     = { { "X", "Directory" } },
    virt_text_pos = "right_align",
    hl_mode       = "combine",
  })

  fade.apply_factors(buf, { ns }, fade.visible_factors(1, 8, 8), { reset = true })
  local overlays = vim.api.nvim_buf_get_extmarks(
    buf, fade.overlay_ns(), { 7, 0 }, { 7, -1 }, { details = true }
  )
  local saw_quarter
  for _, m in ipairs(overlays) do
    if m[4].hl_group == quarter then saw_quarter = true end
  end
  check(saw_quarter, "last line overlay uses the 25% Directory group")

  local virt = vim.api.nvim_buf_get_extmarks(buf, ns, { 7, 0 }, { 7, -1 }, { details = true })
  local faded_virt
  for _, m in ipairs(virt) do
    if m[1] == virt_id and m[4].virt_text then
      faded_virt = m[4].virt_text[1][2]
    end
  end
  check(faded_virt == quarter, "right-aligned virt_text fades with the row")

  fade.apply_factors(buf, { ns }, {}, {})
  virt = vim.api.nvim_buf_get_extmarks(buf, ns, { 7, 0 }, { 7, -1 }, { details = true })
  local restored
  for _, m in ipairs(virt) do
    if m[1] == virt_id and m[4].virt_text then
      restored = m[4].virt_text[1][2]
    end
  end
  check(restored == "Directory", "leaving the fade zone restores virt_text")
  check(#vim.api.nvim_buf_get_extmarks(buf, fade.overlay_ns(), 0, -1, {}) == 0,
    "leaving the fade zone clears overlays")
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
  io.stderr:write(err .. "\n")
  vim.cmd("cquit 1")
else
  print("Fade checks passed")
  vim.cmd("qa!")
end
