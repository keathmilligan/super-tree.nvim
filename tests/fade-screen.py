"""Check colors actually sent to a Neovim UI, not just stored extmarks.

Run from the repository root:
  TMPDIR=/tmp/opencode uv run --with pynvim python tests/fade-screen.py

Add --legacy-redraw to exercise the pre-0.10 redraw invalidation fallback.
"""

import math
import sys
import tempfile
from pathlib import Path

import pynvim


class Screen:
    def __init__(self, nvim):
        self.nvim = nvim
        self.grid = []
        self.attrs = {}
        self.default_fg = None
        nvim.ui_attach(100, 40, rgb=True, ext_linegrid=True)

    def sync(self):
        self.nvim.command("redraw")
        self.nvim.exec_lua('vim.rpcnotify(..., "screen_barrier")', self.nvim.channel_id)
        while True:
            msg = self.nvim.next_message()
            if msg.type != "notification":
                continue
            if msg.name == "screen_barrier":
                return
            if msg.name != "redraw":
                continue
            for event in msg.args:
                for args in event[1:]:
                    self.update(event[0], args)

    def update(self, name, args):
        if name == "grid_resize":
            _, width, height = args
            self.grid = [[(" ", 0)] * width for _ in range(height)]
        elif name == "grid_clear":
            for row in self.grid:
                row[:] = [(" ", 0)] * len(row)
        elif name == "default_colors_set":
            self.default_fg = args[0]
        elif name == "hl_attr_define":
            self.attrs[args[0]] = args[1]
        elif name == "grid_line":
            _, row, col, cells, *_ = args
            hl = 0
            for cell in cells:
                if len(cell) > 1:
                    hl = cell[1]
                for _ in range(cell[2] if len(cell) > 2 else 1):
                    self.grid[row][col] = (cell[0], hl)
                    col += 1
        elif name == "grid_scroll":
            _, top, bottom, left, right, rows, cols = args
            assert cols == 0
            old = [row[:] for row in self.grid]
            for row in range(top, bottom):
                for col in range(left, right):
                    self.grid[row][col] = (
                        old[row + rows][col] if top <= row + rows < bottom else (" ", 0)
                    )

    def check_text(self, cells, text, expected, context):
        for col in range(len(cells)):
            if "".join(c[0] for c in cells[col:]).startswith(text):
                actual = self.attrs.get(cells[col][1], {}).get("foreground", self.default_fg)
                assert actual == expected, (
                    f"{context}: {text!r}: expected #{expected:06x}, got #{actual:06x}"
                )
                return
        raise AssertionError(f"{context}: missing {text!r}")


NORMAL = 0xC4CDF0
DIRECTORY = 0x80C0FF
ICON = 0x00C0C0
STATUS = 0xE0A060


def shade(color, row, height, enabled=True):
    # Specification: full brightness until 70% of the pane; 25% at its bottom.
    opacity = 1 if not enabled else min(1, 1 - 0.75 * (row / height - 0.7) / 0.3)
    opacity = math.floor(opacity * 20 + 0.5) / 20
    return sum(math.floor(((color >> shift) & 255) * opacity) << shift for shift in (16, 8, 0))


def window_rows(nvim, screen, win):
    info = nvim.call("getwininfo", win)[0]
    for row in range(info["height"]):
        y = info["winrow"] - 1 + row
        x = info["wincol"] - 1
        yield row + 1, info["height"], screen.grid[y][x:x + info["width"]]


def check_tree(nvim, screen, label):
    screen.sync()
    win = nvim.exec_lua('return require("super-tree.window").sidebar_win')
    checked = 0
    for row, height, cells in window_rows(nvim, screen, win):
        text = "".join(c[0] for c in cells)
        context = f"{label}, screen row {row}/{height}"
        if "file-" in text:
            screen.check_text(cells, "file-", shade(NORMAL, row, height), context)
            screen.check_text(cells, "󰢱", shade(ICON, row, height), context)
            checked += 1
        elif "dir-" in text:
            screen.check_text(cells, "dir-", shade(DIRECTORY, row, height), context)
            screen.check_text(cells, "", shade(NORMAL, row, height), context)
            checked += 1
    assert checked, f"{label}: no fixture entries visible"


def check_virtual(nvim, screen, wins, label, enabled=True):
    screen.sync()
    for win in wins:
        for row, height, cells in window_rows(nvim, screen, win):
            context = f"{label}, window {win}, row {row}/{height}"
            for text, color in (("plain", NORMAL), ("I", DIRECTORY), ("name", ICON), ("STATUS", STATUS)):
                screen.check_text(cells, text, shade(color, row, height, enabled), context)


def run(nvim, screen, root):
    roots = [root / name for name in ("a", "b", "short")]
    for project in roots:
        project.mkdir()
        for i in range(2 if project.name == "short" else 60):
            (project / f"dir-{i:02d}").mkdir()
            (project / f"file-{i:02d}.lua").touch()

    nvim.exec_lua('''
      vim.opt.rtp:append(...)
      vim.o.termguicolors = true
      vim.o.laststatus = 2
      vim.api.nvim_set_hl(0, 'Normal', { fg = '#c4cdf0', bg = '#161a22' })
      vim.api.nvim_set_hl(0, 'Directory', { fg = '#80c0ff', bold = true })
      vim.api.nvim_set_hl(0, 'DevIconLua', { fg = '#00c0c0' })
      vim.api.nvim_set_hl(0, 'CursorLine', { bg = '#101319' })
    ''', str(Path.cwd()))

    for mode in ("sidebar", "pinned", "floating"):
        nvim.exec_lua('''
          local mode, root = ...
          vim.api.nvim_set_current_dir(root)
          local st = require('super-tree')
          st.setup({ mode = mode, agents = {enable=false},
            buffers = {enable=true, height=7}, projects = {enable=false},
            icons = {provider='builtin'}, git = {enable=false}, diagnostics = {enable=false} })
          st.open()
        ''', mode, str(roots[0]))
        check_tree(nvim, screen, mode + " open (folders)")

        # Session/layout managers may suppress these events. Rendering must
        # still use the new viewport, including its last few rows.
        nvim.command("set eventignore=WinScrolled,WinResized")
        nvim.command("normal! G")
        check_tree(nvim, screen, mode + " scroll without autocmds (files)")
        for key in ("\x19", "\x05", "\x19"):
            nvim.command("normal! 5" + key)
            check_tree(nvim, screen, mode + " incremental scroll")
        nvim.exec_lua('require("super-tree").toggle_buffers()')
        check_tree(nvim, screen, mode + " pane resize")

        for project in (roots[1], roots[0], roots[2], roots[1]):
            nvim.exec_lua('''
              local root = ...
              local st = require('super-tree')
              local state = st.capture_state()
              state.root = root
              state.selected_path = root .. '/file-59.lua'
              state.buffers_visible = true
              state.pane_heights.buffers = 5
              assert(st.restore_state(state))
            ''', str(project))
            check_tree(nvim, screen, mode + " restore " + project.name)
        nvim.exec_lua('require("super-tree").close()')
        nvim.command("set eventignore=")

    # Same buffer in two independent viewports, with right-aligned git-like
    # virtual text. Check actual text and virtual-text pixels at every row.
    wins = nvim.exec_lua('''
      local buf = vim.api.nvim_create_buf(false, true)
      local ns = vim.api.nvim_create_namespace('FadeScreenFixture')
      local lines = {}
      for i = 1, 80 do lines[i] = 'plain I name' end
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.api.nvim_set_hl(0, 'FadeScreenName', { fg = '#00c0c0' })
      vim.api.nvim_set_hl(0, 'FadeScreenStatus', { fg = '#e0a060' })
      for row = 0, 79 do
        vim.api.nvim_buf_set_extmark(buf, ns, row, 6, {end_col=7, hl_group='Directory'})
        vim.api.nvim_buf_set_extmark(buf, ns, row, 8, {end_col=12, hl_group='FadeScreenName'})
        vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
          virt_text={{'STATUS','FadeScreenStatus'}}, virt_text_pos='right_align', hl_mode='combine',
        })
      end
      require('super-tree.fade').attach(buf, {ns})
      local wins = {}
      for i, height in ipairs({8,12}) do
        wins[i] = vim.api.nvim_open_win(buf, false, {
          relative='editor', row=(i-1)*10, col=0, width=36, height=height, style='minimal',
        })
        vim.wo[wins[i]].wrap = false
        vim.wo[wins[i]].scrolloff = 0
      end
      return wins
    ''')
    check_virtual(nvim, screen, wins, "independent windows")
    for row in (35, 60, 12, 1):
        nvim.exec_lua('''
          local win, row = ...
          vim.api.nvim_win_set_cursor(win, {row, 0})
          vim.api.nvim_win_call(win, function() vim.cmd('normal! zt') end)
        ''', wins[1], row)
        check_virtual(nvim, screen, wins, "independent scrolling and original colors")

    nvim.exec_lua('''
      vim.api.nvim_exec_autocmds('ColorScheme', {pattern='fade-screen-test'})
    ''')
    check_virtual(nvim, screen, wins, "colorscheme refresh")
    nvim.exec_lua('require("super-tree.fade").configure({enable=false})')
    nvim.command("redraw!")
    check_virtual(nvim, screen, wins, "disabled fade", enabled=False)
    nvim.exec_lua('require("super-tree.fade").configure()')
    nvim.command("redraw!")
    check_virtual(nvim, screen, wins, "reenabled fade")
    print("Fade screen checks passed (all rows, scrolling, resize, project restoration, virtual text)")


if __name__ == "__main__":
    nvim = pynvim.attach("child", argv=["nvim", "--embed", "-u", "NONE", "-i", "NONE"])
    try:
        if "--legacy-redraw" in sys.argv:
            nvim.exec_lua("vim.api.nvim__redraw = nil")
        screen = Screen(nvim)
        with tempfile.TemporaryDirectory(prefix="super-tree-fade-") as temp:
            run(nvim, screen, Path(temp))
    finally:
        nvim.close()
