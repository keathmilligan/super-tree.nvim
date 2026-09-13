---
feature: window
created: 2026-09-12
updated: 2026-09-12
---

# Window

| Created | Updated |
| --- | --- |
| 2026-09-12 | 2026-09-12 |

## Purpose

SuperTree window layout: how the tree sits beside editor windows, and what happens when buffers or windows close.

## Requirements

### Editor beside the tree

While SuperTree is open as a split (sidebar or pinned) and the user is not quitting Neovim, the tab SHALL keep at least one editor window beside the tree. SuperTree SHALL NOT expand to fill the tab as a result of closing a buffer.

Floating mode is an overlay, not a split; this invariant does not apply there.

### Buffer close

When a listed buffer is closed while SuperTree is open as a split:

- If other listed normal buffers remain, the editor window SHALL show the most recently used remaining listed buffer (`lastused`, excluding SuperTree buffers).
- If none remain, the editor window SHALL show a new unnamed listed buffer (`[No Name]`).

This applies to SuperTree buffers-pane `d`, `:bdelete` / `:bwipeout`, and bufferline-style closes while SuperTree is open.

### Opening a file with no editor window

GIVEN SuperTree is open as a split and no editor window exists
WHEN a file is opened (or a foreign buffer is redirected into an editor)
THEN SuperTree SHALL create a full-height editor beside the tree and restore the configured sidebar width.

### Closing SuperTree

Closing SuperTree SHALL NOT raise `E444` even if it is the only window; an unnamed editor remains so Neovim still has a window.

### Quitting the last editor

Quitting the last editor window with `:q` / `:quit` SHALL still close SuperTree so Neovim can exit.

## Change history

| Date | Change |
| --- | --- |
| 2026-09-12 | Initial spec from preserve-editor-on-buffer-close |
