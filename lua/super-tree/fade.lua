-- Viewport fade: darken the bottom of the pane (window height), not the last
-- items in the list. A short list in a tall pane is unaffected. Tuned by
-- `fade.zone` and `fade.bottom_opacity` in plugin setup.
local M = {}

local defaults = {
  enable = true,
  zone = 0.3,
  bottom_opacity = 0.25,
}

local settings = {
  enable = defaults.enable,
  zone = defaults.zone,
  bottom_opacity = defaults.bottom_opacity,
}

local overlay_ns = vim.api.nvim_create_namespace("SuperTreeFade")
local cache = {}
local panes = {} -- buf -> { lines, marks (by row) }; always unfaded source data
local provider_ready = false

function M.clear_cache()
  cache = {}
end

function M.configure(opts)
  settings = {
    enable = defaults.enable,
    zone = defaults.zone,
    bottom_opacity = defaults.bottom_opacity,
  }
  if not opts then return end
  if opts.enable ~= nil then settings.enable = opts.enable end
  if opts.zone ~= nil then settings.zone = opts.zone end
  if opts.bottom_opacity ~= nil then settings.bottom_opacity = opts.bottom_opacity end
end

-- Darken a 24-bit color (integer) by `factor`.
function M.darken(color, factor)
  local r = math.floor(math.floor(color / 65536) % 256 * factor)
  local g = math.floor(math.floor(color / 256) % 256 * factor)
  local b = math.floor(color % 256 * factor)
  return r * 65536 + g * 256 + b
end

function M.visible_factors(topline, botline, win_height, opts)
  local factors = {}
  if not topline or not botline or botline < topline then return factors end
  opts = opts or settings
  if opts.enable == false then return factors end
  win_height = win_height or (botline - topline + 1)
  if win_height < 1 then return factors end
  local zone = tonumber(opts.zone) or defaults.zone
  local bottom = tonumber(opts.bottom_opacity) or defaults.bottom_opacity
  if zone <= 0 then return factors end
  if zone > 1 then zone = 1 end
  if bottom < 0 then bottom = 0 end
  if bottom > 1 then bottom = 1 end
  local fade_start = win_height * (1 - zone)
  local fade_span = win_height - fade_start
  if fade_span <= 0 then return factors end
  for lnum1 = topline, botline do
    local screen_row = lnum1 - topline + 1
    if screen_row > fade_start then
      local t = (screen_row - fade_start) / fade_span
      if t > 1 then t = 1 end
      factors[lnum1 - 1] = 1.0 - (1.0 - bottom) * t
    end
  end
  return factors
end

local function get_hl(name)
  if vim.api.nvim_get_hl then
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
    if ok and hl then return hl end
  end
  local ok, hl = pcall(vim.api.nvim_get_hl_by_name, name, true)
  if not ok or not hl then return {} end
  return {
    fg = hl.foreground,
    italic = hl.italic,
    bold = hl.bold,
    underline = hl.underline,
    undercurl = hl.undercurl,
  }
end

-- Return `name`, or a derived group whose fg is `factor` as bright.
function M.group(name, factor)
  if type(name) ~= "string" or name == "" then return name end
  if not factor or factor >= 0.995 then return name end
  local q = math.floor(factor * 20 + 0.5) / 20
  if q >= 0.995 then return name end
  local key = name .. "@" .. q
  if cache[key] then return cache[key] end
  local hl = get_hl(name)
  if not hl.fg then
    cache[key] = name
    return name
  end
  local faded = string.format(
    "SuperTreeFade_%s_%d",
    name:gsub("[^%w]", "_"):sub(1, 120),
    math.floor(q * 100 + 0.5)
  )
  local attrs = { fg = M.darken(hl.fg, q) }
  if hl.italic then attrs.italic = true end
  if hl.bold then attrs.bold = true end
  if hl.underline then attrs.underline = true end
  if hl.undercurl then attrs.undercurl = true end
  if hl.sp then attrs.sp = M.darken(hl.sp, q) end
  vim.api.nvim_set_hl(0, faded, attrs)
  cache[key] = faded
  return faded
end

local function fade_chunks(chunks, factor)
  local out = {}
  for i, ch in ipairs(chunks) do
    if type(ch[2]) == "string" then
      out[i] = { ch[1], M.group(ch[2], factor) }
    else
      out[i] = ch
    end
  end
  return out
end

-- Prepare highlight definitions outside redraw callbacks. All factors are
-- quantized to these levels by group(), including a fully dark bottom row.
local function prepare_groups(pane)
  local groups = { Normal = true }
  for _, marks in pairs(pane.marks) do
    for _, mark in ipairs(marks) do
      local d = mark[4]
      if d.hl_group then groups[d.hl_group] = true end
      for _, chunk in ipairs(d.virt_text or {}) do
        if type(chunk[2]) == "string" then groups[chunk[2]] = true end
      end
    end
  end
  for name in pairs(groups) do
    for step = 0, 19 do M.group(name, step / 20) end
  end
end

local function draw_row(buf, pane, row, factor)
  local line = pane.lines[row + 1]
  if not line then return end
  if factor and #line > 0 then
    -- This covers plain filenames and folder glyphs as well as any other
    -- text inheriting Normal. Semantic highlights below retain their colors.
    vim.api.nvim_buf_set_extmark(buf, overlay_ns, row, 0, {
      end_col = #line, hl_group = M.group("Normal", factor),
      priority = 1, ephemeral = true,
    })
  end
  for _, mark in ipairs(pane.marks[row] or {}) do
    local col, d = mark[3], mark[4]
    if factor and d.hl_group and d.end_col then
      vim.api.nvim_buf_set_extmark(buf, overlay_ns, row, col, {
        end_row = d.end_row or row, end_col = d.end_col,
        hl_group = M.group(d.hl_group, factor),
        priority = math.min(65535, (d.priority or 4096) + 200),
        ephemeral = true,
      })
    end
    if d.virt_text then
      vim.api.nvim_buf_set_extmark(buf, overlay_ns, row, col, {
        virt_text = fade_chunks(d.virt_text, factor),
        virt_text_pos = d.virt_text_pos or "right_align",
        hl_mode = d.hl_mode or "combine",
        priority = d.priority,
        ephemeral = true,
      })
    end
  end
end

local function ensure_provider()
  if provider_ready then return end
  provider_ready = true
  local views = {}
  local previous = {}
  vim.api.nvim_set_decoration_provider(overlay_ns, {
    on_win = function(_, win, buf, top)
      local pane = panes[buf]
      if not pane then return false end
      -- Use the viewport supplied by the redraw, not getwininfo().botline
      -- captured before layout/cursor restoration. SuperTree panes don't wrap.
      local height = vim.api.nvim_win_get_height(win)
      local bottom = math.min(#pane.lines, top + height)
      local last = previous[win]
      if not last or last.buf ~= buf or last.top ~= top or last.height ~= height then
        previous[win] = { buf = buf, top = top, height = height }
        -- Neovim can scroll by copying already drawn screen rows. Their old
        -- colors are no longer correct at the new screen position, so also
        -- invalidate the reused rows, not just newly exposed bottom lines.
        if vim.api.nvim__redraw then
          vim.api.nvim__redraw({ win = win, range = { top, bottom } })
        else
          -- Neovim 0.8/0.9: an empty highlight range invalidates screen rows
          -- without changing their appearance. Only this redraw marker is
          -- persistent; all actual fade decorations remain window-local.
          vim.api.nvim_buf_set_extmark(buf, overlay_ns, top, 0, {
            id = 1, end_row = bottom, end_col = 0, hl_group = "SuperTreeFadeRedraw",
          })
        end
      end
      views[win] = M.visible_factors(top + 1, bottom, height)
      return true
    end,
    on_line = function(_, win, buf, row)
      draw_row(buf, panes[buf], row, views[win][row])
    end,
    on_end = function()
      views = {}
      for win in pairs(previous) do
        if not vim.api.nvim_win_is_valid(win) then previous[win] = nil end
      end
    end,
  })
end

-- Called after a pane has replaced its contents and rebuilt its source marks.
-- Retain original colors; the viewport fade only exists for a single redraw.
function M.attach(buf, namespaces)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  ensure_provider()
  local pane = { lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false), marks = {} }
  for _, ns in ipairs(namespaces or {}) do
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
      local row, d = mark[2], mark[4]
      pane.marks[row] = pane.marks[row] or {}
      table.insert(pane.marks[row], mark)
      -- Virtual text is drawn once, by the provider, even outside the fade
      -- zone. Never rewrite it with faded colors or restore old extmark IDs.
      if d.virt_text then vim.api.nvim_buf_del_extmark(buf, ns, mark[1]) end
    end
  end
  panes[buf] = pane
  prepare_groups(pane)
  vim.api.nvim_buf_clear_namespace(buf, overlay_ns, 0, -1)
end

function M.refresh_all()
  for buf, pane in pairs(panes) do
    if vim.api.nvim_buf_is_valid(buf) then
      prepare_groups(pane)
    else
      panes[buf] = nil
    end
  end
  vim.cmd("redraw!")
end

function M.setup(augroup, opts)
  M.configure(opts)
  ensure_provider()
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = augroup,
    callback = function(args) panes[args.buf] = nil end,
  })
end

return M
