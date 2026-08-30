-- Neo-tree-style live filter / fuzzy finder.
-- No extra dependencies: walks the tree with libuv, scores with a small
-- fzy-like matcher, and uses a one-line input popup docked under the sidebar.

local tree   = require("super-tree.tree")
local window = require("super-tree.window")

local M = {}

-- Callbacks injected by init.lua so this module never requires it.
local callbacks = {}

function M.set_callbacks(cbs)
  callbacks = cbs or {}
end

-- Saved expansion state so clearing a filter restores the pre-search tree.
local saved_expanded = nil

local input_win = nil
local input_buf = nil
local debounce_timer = nil
local current_opts = nil  -- { live, fuzzy_finder, kind, use_fzy, keep_on_submit }

local DEFAULT_LIMIT = 50
local SCAN_CAP      = 2000

-- ---------------------------------------------------------------------------
-- Matching
-- ---------------------------------------------------------------------------

-- Sequential fuzzy score (higher is better). Returns nil when `pat` is not
-- a subsequence of `str`. Consecutive and word-boundary hits are boosted.
local function fuzzy_score(pat, str)
  pat = pat:lower()
  str = str:lower()
  local pi, score, consec = 1, 0, 0
  for i = 1, #str do
    if str:sub(i, i) == pat:sub(pi, pi) then
      local bonus = 1 + consec * 2
      if i == 1 or str:sub(i - 1, i - 1):match("[/._%-]") then
        bonus = bonus + 4
      end
      score = score + bonus
      consec = consec + 1
      pi = pi + 1
      if pi > #pat then return score end
    else
      consec = 0
    end
  end
  return nil
end

local function glob_match(term, name, rel, full_path_words)
  if full_path_words then
    local hay, start = rel:lower(), 1
    for word in term:lower():gmatch("%S+") do
      local i = hay:find(word, start, true)
      if not i then return false end
      start = i + #word
    end
    return true
  end
  return name:lower():find(term:lower(), 1, true) ~= nil
end

-- Walk `cwd` and collect matching paths. Skips hidden/gitignored entries
-- (and always skips `.git`). Caps the walk at SCAN_CAP entries.
local function collect_matches(term, opts, config)
  local cwd = vim.fn.getcwd()
  local limit = (config.filter and config.filter.search_limit) or DEFAULT_LIMIT
  local full_path_words = config.filter and config.filter.find_by_full_path_words
  local kind = opts.kind
  local use_fzy = opts.use_fzy
  local matches, scores = {}, {}
  local scanned = 0

  local function walk(dir)
    if scanned >= SCAN_CAP then return end
    if not use_fzy and #matches >= limit then return end
    local handle = vim.loop.fs_scandir(dir)
    if not handle then return end
    while true do
      local name, typ = vim.loop.fs_scandir_next(handle)
      if not name then break end
      scanned = scanned + 1
      if scanned >= SCAN_CAP then return end
      if not use_fzy and #matches >= limit then return end
      if name ~= ".git" then
        local path = dir .. "/" .. name
        local is_dir = typ == "directory"
        if not tree.should_hide(name, path, config) then
          local rel = path:sub(#cwd + 2)
          local hit = false
          if kind ~= "directory" or is_dir then
            if use_fzy then
              local s = fuzzy_score(term, full_path_words and rel or name)
              if s then
                scores[path] = s
                hit = true
              end
            else
              hit = glob_match(term, name, rel, full_path_words)
            end
          end
          if hit then
            matches[#matches + 1] = path
          end
          if is_dir then
            walk(path)
          end
        end
      end
    end
  end

  walk(cwd)

  if use_fzy then
    -- Parents inherit the max child score so they sort with their hits.
    for path, s in pairs(scores) do
      local dir = path:match("^(.*)/[^/]+$")
      while dir and #dir >= #cwd do
        if not scores[dir] or scores[dir] < s then
          scores[dir] = s
        end
        if dir == cwd then break end
        dir = dir:match("^(.*)/[^/]+$")
      end
    end
    table.sort(matches, function(a, b)
      local sa, sb = scores[a] or 0, scores[b] or 0
      if sa ~= sb then return sa > sb end
      return a < b
    end)
    if #matches > limit then
      local trimmed = {}
      for i = 1, limit do trimmed[i] = matches[i] end
      matches = trimmed
    end
  end

  return matches, scores
end

-- ---------------------------------------------------------------------------
-- Apply / clear
-- ---------------------------------------------------------------------------

local function restore_expanded()
  if saved_expanded then
    tree.expanded_paths = saved_expanded
    saved_expanded = nil
  end
end

local function apply_search(term)
  local config = callbacks.get_config and callbacks.get_config() or {}
  if not term or term == "" then
    tree.search_pattern = nil
    tree.search_matches = nil
    tree.search_scores  = nil
    tree.search_kind    = nil
    -- Restore the pre-search view but keep the snapshot; the popup is still
    -- open and the next keystroke may filter again.
    if saved_expanded then
      tree.expanded_paths = vim.deepcopy(saved_expanded)
    end
    if callbacks.rebuild then callbacks.rebuild() end
    return
  end

  if not saved_expanded then
    saved_expanded = vim.deepcopy(tree.expanded_paths)
  end

  local opts = current_opts or {}
  local matches, scores = collect_matches(term, opts, config)
  tree.search_pattern = term
  tree.search_matches = matches
  tree.search_scores  = opts.use_fzy and scores or nil
  tree.search_kind    = opts.kind
  if callbacks.rebuild then callbacks.rebuild() end

  -- Fuzzy finder: land on the first file (or first entry).
  if opts.fuzzy_finder and window.is_open() then
    local row = nil
    for _, entry in ipairs(tree.tree_data) do
      if not entry.is_dir then
        row = tree.row_for_path(entry.path)
        break
      end
    end
    if not row and tree.tree_data[1] then
      row = tree.row_for_path(tree.tree_data[1].path)
    end
    if row then
      pcall(vim.api.nvim_win_set_cursor, window.sidebar_win, { row, 0 })
    end
  end
end

function M.clear()
  M.close_input(true)
  tree.search_pattern = nil
  tree.search_matches = nil
  tree.search_scores  = nil
  tree.search_kind    = nil
  restore_expanded()
  if callbacks.rebuild then callbacks.rebuild() end
end

function M.is_active()
  return tree.search_pattern ~= nil and tree.search_pattern ~= ""
end

-- Apply `term` immediately (used by the input popup and by tests).
function M.apply_term(term)
  apply_search(term or "")
end

-- ---------------------------------------------------------------------------
-- Input popup
-- ---------------------------------------------------------------------------

local function stop_timer()
  if debounce_timer then
    if not debounce_timer:is_closing() then
      debounce_timer:stop()
      debounce_timer:close()
    end
    debounce_timer = nil
  end
end

local function prefix_for(opts)
  if opts.kind == "directory" then return "Filter Directories: " end
  if not opts.live then return "Search: " end
  return "Filter: "
end

local function debounce_ms(term)
  local n = #term
  if n <= 1 then return 500 end
  if n == 2 then return 400 end
  if n == 3 then return 200 end
  return 100
end

local function current_term()
  if not input_buf or not vim.api.nvim_buf_is_valid(input_buf) then return "" end
  local line = vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)[1] or ""
  local prefix = prefix_for(current_opts or {})
  if line:sub(1, #prefix) == prefix then
    return line:sub(#prefix + 1)
  end
  return line
end

function M.close_input(keep_filter)
  stop_timer()
  if input_win and vim.api.nvim_win_is_valid(input_win) then
    pcall(vim.api.nvim_win_close, input_win, true)
  end
  input_win = nil
  input_buf = nil
  current_opts = nil
  if not keep_filter then
    tree.search_pattern = nil
    tree.search_matches = nil
    tree.search_scores  = nil
    tree.search_kind    = nil
    restore_expanded()
    if callbacks.rebuild then callbacks.rebuild() end
  end
  if window.is_open() then
    pcall(vim.api.nvim_set_current_win, window.sidebar_win)
  end
end

local function on_live_change()
  if not (current_opts and current_opts.live) then return end
  local term = current_term()
  stop_timer()
  local timer = vim.loop.new_timer()
  if not timer then
    apply_search(term)
    return
  end
  debounce_timer = timer
  timer:start(debounce_ms(term), 0, function()
    timer:stop()
    timer:close()
    debounce_timer = nil
    vim.schedule(function()
      if current_opts then apply_search(current_term()) end
    end)
  end)
end

function M.start(opts)
  opts = opts or {}
  if not window.is_open() then return end

  -- Replacing an open popup: drop it but keep any in-progress filter until
  -- the new one applies.
  if input_win and vim.api.nvim_win_is_valid(input_win) then
    M.close_input(true)
  end

  current_opts = {
    live           = opts.live ~= false,
    fuzzy_finder   = opts.fuzzy_finder == true,
    kind           = opts.kind,
    use_fzy        = opts.use_fzy == true,
    keep_on_submit = opts.keep_on_submit == true,
  }

  local prefix = prefix_for(current_opts)
  input_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[input_buf].buftype   = "nofile"
  vim.bo[input_buf].bufhidden = "wipe"
  vim.bo[input_buf].filetype  = "SuperTreeFilter"
  vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { prefix })

  local sw = window.sidebar_win
  local width  = vim.api.nvim_win_get_width(sw)
  local height = vim.api.nvim_win_get_height(sw)
  input_win = vim.api.nvim_open_win(input_buf, true, {
    relative = "win",
    win      = sw,
    width    = math.max(width, 1),
    height   = 1,
    row      = math.max(height - 1, 0),
    col      = 0,
    style    = "minimal",
    border   = "none",
    zindex   = 50,
  })
  vim.wo[input_win].cursorline = false
  vim.wo[input_win].winhighlight = "Normal:SuperTreeNormal,NormalNC:SuperTreeNormal"

  -- Put the cursor after the prompt.
  vim.api.nvim_win_set_cursor(input_win, { 1, #prefix })
  vim.cmd("startinsert!")

  local map_opts = { buffer = input_buf, nowait = true, silent = true, noremap = true }

  local function submit()
    vim.cmd("stopinsert")
    local term = current_term()
    local fuzzy = current_opts and current_opts.fuzzy_finder
    local keep  = current_opts and current_opts.keep_on_submit
    if fuzzy and not keep then
      -- Open the focused node, then drop the filter.
      M.close_input(false)
      if callbacks.open_current then callbacks.open_current() end
    else
      apply_search(term)
      M.close_input(true)
    end
  end

  vim.keymap.set("i", "<CR>", submit, map_opts)
  vim.keymap.set("n", "<CR>", submit, map_opts)

  vim.keymap.set({ "i", "n" }, "<Esc>", function()
    vim.cmd("stopinsert")
    local keep = current_opts and current_opts.keep_on_submit and not current_opts.fuzzy_finder
    M.close_input(keep)
  end, map_opts)

  -- Keep filter / clear filter (neo-tree <S-CR> / <C-CR>).
  vim.keymap.set({ "i", "n" }, "<S-CR>", function()
    vim.cmd("stopinsert")
    apply_search(current_term())
    M.close_input(true)
  end, map_opts)
  vim.keymap.set({ "i", "n" }, "<C-CR>", function()
    vim.cmd("stopinsert")
    M.close_input(false)
  end, map_opts)

  if current_opts.fuzzy_finder then
    local function tree_move(fn)
      return function()
        if fn then fn() end
      end
    end
    vim.keymap.set("i", "<Down>", tree_move(callbacks.move_down), map_opts)
    vim.keymap.set("i", "<C-n>",  tree_move(callbacks.move_down), map_opts)
    vim.keymap.set("i", "<Up>",   tree_move(callbacks.move_up),   map_opts)
    vim.keymap.set("i", "<C-p>",  tree_move(callbacks.move_up),   map_opts)
  end

  vim.api.nvim_create_autocmd("TextChangedI", {
    buffer = input_buf,
    callback = on_live_change,
  })
  vim.api.nvim_create_autocmd("TextChanged", {
    buffer = input_buf,
    callback = on_live_change,
  })

  -- Don't let the user delete the prompt prefix.
  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
    buffer = input_buf,
    callback = function()
      if not input_buf or not vim.api.nvim_buf_is_valid(input_buf) then return end
      local line = vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)[1] or ""
      if line:sub(1, #prefix) ~= prefix then
        local rest = line
        if rest:sub(1, #prefix) ~= prefix then
          -- Prefix was edited; restore it, keep whatever remains.
          if rest:find(prefix, 1, true) == 1 then
            rest = rest:sub(#prefix + 1)
          elseif #rest < #prefix then
            rest = ""
          end
        end
        vim.api.nvim_buf_set_lines(input_buf, 0, 1, false, { prefix .. rest })
        vim.api.nvim_win_set_cursor(input_win, { 1, #prefix + #rest })
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = input_buf,
    callback = function()
      vim.schedule(function()
        if not input_win or not vim.api.nvim_win_is_valid(input_win) then return end
        -- Still in the popup (e.g. startinsert shuffling focus); don't close.
        if vim.api.nvim_get_current_win() == input_win then return end
        local keep = current_opts and current_opts.keep_on_submit and not current_opts.fuzzy_finder
        M.close_input(keep)
      end)
    end,
  })
end

return M
