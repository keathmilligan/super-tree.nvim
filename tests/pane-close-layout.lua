-- Run: TMPDIR=/tmp/opencode nvim --headless -u NONE -i NONE
--        --cmd 'set rtp+=.' -c "lua dofile('tests/pane-close-layout.lua')"
local window = require("super-tree.window")
local panes = { "projects", "agents", "buffers" }

local function run()
  vim.o.lines = 60
  vim.o.columns = 160
  for _, floating in ipairs({ false, true }) do
    for _, equalalways in ipairs({ true, false }) do
      for _, direction in ipairs({ "both", "ver", "hor" }) do
        for _, closing in ipairs({ "projects", "agents", "buffers", "all" }) do
          vim.cmd("only!")
          vim.o.equalalways = equalalways
          vim.o.eadirection = direction
          local editor = vim.api.nvim_get_current_win()
          vim.cmd("rightbelow split")
          local bottom = vim.api.nvim_get_current_win()
          vim.cmd("rightbelow vsplit")
          local right = vim.api.nvim_get_current_win()
          vim.cmd("rightbelow split")
          local lower_right = vim.api.nvim_get_current_win()
          local editors = { editor, bottom, right, lower_right }

          local buf = window.create_or_get_buffer()
          window.sidebar_win = floating and window.create_floating_window(buf, 35)
            or window.create_pinned_window(buf, 35)
          for _, pane in ipairs(panes) do window["open_" .. pane .. "_window"](8) end

          -- Uneven editor splits, including nested splits and a fixed utility
          -- window, reveal equalization that an evenly split fixture misses.
          vim.api.nvim_win_set_height(editor, 17)
          vim.api.nvim_win_set_height(lower_right, 7)
          vim.wo[lower_right].winfixheight = true
          local before = {}
          for _, win in ipairs(editors) do
            before[win] = {
              height = vim.api.nvim_win_get_height(win),
              row = vim.api.nvim_win_get_position(win)[1],
              fixed = vim.wo[win].winfixheight,
            }
          end
          local sibling_heights = window.get_pane_heights()
          local tree_height = vim.api.nvim_win_get_height(window.sidebar_win)
          local closed_height = closing ~= "all"
            and vim.api.nvim_win_get_height(window[closing .. "_win"]) or 0
          vim.api.nvim_set_current_win(editor)
          if closing == "all" then
            window.close_window()
          else
            window["close_" .. closing .. "_window"]()
          end

          local label = string.format("floating=%s ea=%s ead=%s close=%s: ",
            floating, equalalways, direction, closing)
          for win, saved in pairs(before) do
            assert(vim.api.nvim_win_get_height(win) == saved.height,
              label .. "editor height changed")
            assert(vim.api.nvim_win_get_position(win)[1] == saved.row,
              label .. "editor row changed")
            assert(vim.wo[win].winfixheight == saved.fixed,
              label .. "editor winfixheight changed")
          end
          assert(vim.o.equalalways == equalalways, label .. "equalalways changed")
          assert(vim.api.nvim_get_current_win() == editor, label .. "focus changed")
          if closing ~= "all" then
            for _, pane in ipairs(panes) do
              if pane ~= closing then
                assert(vim.api.nvim_win_get_height(window[pane .. "_win"]) == sibling_heights[pane],
                  label .. "sibling pane height changed")
              end
            end
            assert(vim.api.nvim_win_get_height(window.sidebar_win)
                == tree_height + closed_height + (floating and 0 or 1),
              label .. "tree must absorb the closed pane's space")
          end
          window.close_window()
          vim.wo[lower_right].winfixheight = false
        end
      end
    end
  end
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
  io.stderr:write(err .. "\n")
  vim.cmd("cquit 1")
else
  print("Pane closure preserves unrelated split heights")
  vim.cmd("qa!")
end
