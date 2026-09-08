---
id: preserve-editor-on-buffer-close
status: review
features: [window]
created: 2026-09-06
updated: 2026-09-06
---

# Preserve an editor window when a buffer is closed

| Created | Updated |
| --- | --- |
| 2026-09-06 | 2026-09-06 |

## What

### Why

Closing a buffer while SuperTree is open as a split often leaves SuperTree as the only window. It then fills the tab. From that state, toggling SuperTree closed raises `E444: Cannot close last window`, and opening a file can take the full screen (or a 50/50 split) instead of restoring the sidebar layout.

`:bdelete` closes every window displaying that buffer. SuperTree still counts as a window, so Neovim does not create a replacement editor. The tree expands to fill the space.

### Requirements

- While SuperTree is open as a split (sidebar or pinned) and the user is not quitting Neovim, the tab SHALL keep at least one editor window beside the tree.
- When the active listed buffer is closed, that editor window SHALL show the most recently used remaining listed buffer if one exists; otherwise it SHALL show a new unnamed listed buffer.
- SuperTree SHALL NOT expand to fill the tab as a result of closing a buffer.
- Opening a file when no editor window exists SHALL create a full-height editor beside the tree and restore the configured sidebar width.
- Closing SuperTree SHALL NOT raise `E444` even if it is the only window; an unnamed editor remains.
- Quitting the last editor window with `:q` / `:quit` SHALL still close SuperTree so Neovim can exit (existing sidebar behavior).

### Scope

- In: sidebar and pinned modes; SuperTree buffers-pane `d`; `:bdelete` / `:bwipeout` / bufferline-style closes while SuperTree is open; toggle/close; opening files or redirecting a foreign buffer when no editor window exists.
- Out: floating mode layout (not a split); changing `:q` last-editor behavior; a global `:bdelete` replacement when SuperTree is closed; bufferline/plugin-specific APIs.

### Open questions

- None. MRU means listed normal buffers (`buftype` empty or `acwrite`), excluding SuperTree buffers, ordered by `lastused`. Replacement empty buffer is unnamed and listed (`nvim_create_buf(true, false)`), matching `[No Name]`.

## How

### Approach

Keep the tree from becoming the only window, and choose the replacement buffer explicitly.

Builtin `:bdelete` cannot be hooked before it closes windows. Combine three known-working pieces (same idea as mini.bufremove / vim-bbye):

1. **Unshow then delete** for SuperTree’s own buffer delete: switch every editor window off the target buffer, then `:bdelete`.
2. **Layout invariant** after any window close: if SuperTree is still open as a split and no editor window remains (and Neovim is not exiting), create one.
3. **Safe close / safe open**: never `nvim_win_close` the last window; when creating an editor beside a full-width tree, use a full-height split and reset sidebar width.

Details and event ordering: [design/preserve-editor-on-buffer-close.md](../design/preserve-editor-on-buffer-close.md).

### Impacted specifications

- `window` (new)

### Plan

#### 1. Window helpers

- [x] 1.1 Add `find_replacement_buf(exclude)` — MRU listed normal buffer, else nil
- [x] 1.2 Add `unshow_buffer(bufnr)` — set every non-SuperTree window showing `bufnr` to the replacement (MRU or new unnamed listed buffer)
- [x] 1.3 Add `ensure_editor_win(width)` — return an existing editor window, or `botright vsplit` a full-height editor, set MRU/unnamed buffer, restore sidebar width
- [x] 1.4 `close_window`: if the sidebar would be the last window, create an unnamed editor first; `pcall` the close
- [x] 1.5 `guard_window`: use `ensure_editor_win` instead of a raw `rightbelow vertical split`

#### 2. Buffer close and open paths

- [x] 2.1 Buffers-pane `d` calls `unshow_buffer` before `bdelete`
- [x] 2.2 `open_current` / `open_listed`: use `ensure_editor_win` when no editor window exists
- [x] 2.3 `WinClosed`: if a non-SuperTree window closed, `vim.schedule` `ensure_editor_win` when no editor remains (skip floating mode and `vim.v.exiting`)
- [x] 2.4 `BufEnter` on the SuperTree buffer as a nested safety net for the same invariant

#### 3. Docs

- [x] 3.1 README: closing a buffer keeps the sidebar and shows MRU or `[No Name]`; toggle never errors as last window

## Change history

| Date | Change |
| --- | --- |
| 2026-09-06 | Initial proposal |
| 2026-09-06 | Implemented; ready for review |
