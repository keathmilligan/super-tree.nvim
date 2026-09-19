---
feature: window
created: 2026-09-12
updated: 2026-09-19
---

# Window

| Created | Updated |
| --- | --- |
| 2026-09-12 | 2026-09-19 |

## Purpose

SuperTree window layout: how the tree sits beside editor windows, and what happens when buffers or windows close.

## Requirements

### Stacked auxiliary panes

When present, the sidebar column SHALL order windows from top to bottom as the
configured optional panes followed by the file tree. The default order SHALL be
Projects, Agents, Buffers, then the file tree. Optional panes SHALL be real,
independently scrollable and resizable windows.

Configuration SHALL set the top-to-bottom order of the optional panes
independent of which panes are visible. Invalid configuration SHALL NOT break
layout: unknown or duplicate entries SHALL be ignored with a warning, a `"tree"`
entry SHALL be honored only as the final entry, and any optional pane missing
from the list SHALL be appended in the default order, so the layout covers each
optional pane exactly once. The file tree SHALL remain the last, flexible pane
and SHALL NOT be moved by pane-order configuration.

Opening or closing an optional pane SHALL preserve the measured heights of the
other optional panes where the available screen permits. The file tree SHALL
absorb the flexible remainder.

Floating mode SHALL use the same order and SHALL keep every pane within the
available editor height without overlap. Dynamically opening or closing a pane
SHALL preserve focus when the previously focused window remains valid.

### Editor beside the tree

While SuperTree is open as a split (sidebar or pinned) and the user is not quitting Neovim, the tab SHALL keep at least one editor window beside the tree. SuperTree SHALL NOT expand to fill the tab as a result of closing a buffer.

A terminal window beside SuperTree SHALL satisfy this layout invariant and
SHALL prevent creation of a redundant editor split. A terminal window SHALL NOT
be selected as the target for opening a file.

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

### Workspace state interoperability

SuperTree SHALL provide public operations to capture and restore versioned,
serializable workspace state. That state SHALL include tree root, open state,
expanded paths, selected path, hidden-entry state, Buffers and Projects pane
visibility and selections, sidebar width, and pane heights. Runtime window and
buffer identifiers SHALL NOT be required to restore the state.

SuperTree SHALL allow a named project provider to supply project listing,
current-project identification, and project opening. An explicitly registered
provider SHALL take precedence over optional fallback providers.

### Quitting the last editor

Quitting the last editor window with `:q` / `:quit` SHALL still close SuperTree so Neovim can exit.

## Change history

| Date | Change |
| --- | --- |
| 2026-09-12 | Initial spec from preserve-editor-on-buffer-close |
| 2026-09-18 | Added ordered dynamic Agents/Projects/Buffers pane layout |
| 2026-09-18 | Added terminal-aware editor preservation and public workspace/project integration contracts |
| 2026-09-19 | Made optional pane order configurable with a Projects/Agents/Buffers default |
