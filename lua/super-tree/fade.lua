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
local panes = {}     -- win -> { buf, namespaces }
local virt_orig = {} -- buf -> { { ns, id, row, col, chunks, pos, hl_mode }, ... }

function M.overlay_ns()
  return overlay_ns
end

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

local function restore_virt(buf)
  local saved = virt_orig[buf]
  if not saved then return end
  for _, item in ipairs(saved) do
    pcall(vim.api.nvim_buf_set_extmark, buf, item.ns, item.row, item.col, {
      id            = item.id,
      virt_text     = item.chunks,
      virt_text_pos = item.pos,
      hl_mode       = item.hl_mode,
    })
  end
  virt_orig[buf] = {}
end

local function win_for_buf(buf)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then return win end
  end
end

function M.apply_factors(buf, namespaces, factors, opts)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  opts = opts or {}
  if opts.reset then
    virt_orig[buf] = {}
  else
    restore_virt(buf)
  end
  vim.api.nvim_buf_clear_namespace(buf, overlay_ns, 0, -1)
  if not factors or not next(factors) then return end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for lnum0, factor in pairs(factors) do
    local line = lines[lnum0 + 1]
    local normal_hl = M.group("Normal", factor)
    if line and #line > 0 and normal_hl ~= "Normal" then
      vim.api.nvim_buf_set_extmark(buf, overlay_ns, lnum0, 0, {
        end_col  = #line,
        hl_group = normal_hl,
        priority = 1,
      })
    end
  end

  for _, ns in ipairs(namespaces or {}) do
    for lnum0, factor in pairs(factors) do
      local marks = vim.api.nvim_buf_get_extmarks(
        buf, ns, { lnum0, 0 }, { lnum0, -1 }, { details = true }
      )
      for _, m in ipairs(marks) do
        local id, row, col, d = m[1], m[2], m[3], m[4]
        if d.hl_group and d.end_col then
          vim.api.nvim_buf_set_extmark(buf, overlay_ns, row, col, {
            end_row  = d.end_row or row,
            end_col  = d.end_col,
            hl_group = M.group(d.hl_group, factor),
            priority = (d.priority or 4096) + 200,
          })
        end
        if d.virt_text then
          virt_orig[buf] = virt_orig[buf] or {}
          virt_orig[buf][#virt_orig[buf] + 1] = {
            ns = ns, id = id, row = row, col = col,
            chunks = d.virt_text,
            pos = d.virt_text_pos or "right_align",
            hl_mode = d.hl_mode or "combine",
          }
          pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, col, {
            id            = id,
            virt_text     = fade_chunks(d.virt_text, factor),
            virt_text_pos = d.virt_text_pos or "right_align",
            hl_mode       = d.hl_mode or "combine",
          })
        end
      end
    end
  end
end

function M.apply(win, buf, namespaces, opts)
  if not win or not vim.api.nvim_win_is_valid(win) then return end
  local info = vim.fn.getwininfo(win)[1]
  if not info then return end
  M.apply_factors(buf, namespaces, M.visible_factors(info.topline, info.botline, info.height), opts)
end

function M.attach(buf, namespaces)
  local win = win_for_buf(buf)
  if not win then return end
  panes[win] = { buf = buf, namespaces = namespaces }
  M.apply(win, buf, namespaces, { reset = true })
end

function M.refresh_win(win)
  win = tonumber(win)
  if not win then return end
  local pane = panes[win]
  if not pane then return end
  if not vim.api.nvim_win_is_valid(win) then
    panes[win] = nil
    return
  end
  M.apply(win, pane.buf, pane.namespaces)
end

function M.refresh_all()
  for win, pane in pairs(panes) do
    if vim.api.nvim_win_is_valid(win) then
      M.apply(win, pane.buf, pane.namespaces)
    else
      panes[win] = nil
    end
  end
end

function M.setup(augroup, opts)
  M.configure(opts)
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = augroup,
    callback = function()
      for key in pairs(vim.v.event or {}) do
        if key ~= "all" then M.refresh_win(key) end
      end
    end,
  })
  if vim.fn.exists("##WinResized") == 1 then
    vim.api.nvim_create_autocmd("WinResized", {
      group = augroup,
      callback = M.refresh_all,
    })
  end
end

return M
