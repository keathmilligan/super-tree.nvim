---
id: configurable-pane-order
created: 2026-09-19
updated: 2026-09-19
---

# Design: Configurable pane order

| Created | Updated |
| --- | --- |
| 2026-09-19 | 2026-09-19 |

## Approach

The pane order becomes a module-owned list in `lua/super-tree/window.lua`
(default `projects, agents, buffers`). `M.set_pane_order(order)` normalizes any
user input into a complete permutation of the optional panes and stores it;
`M.get_pane_order()` returns a copy. `setup()` feeds `config.pane_order` to the
setter. All existing layout routines keep iterating the same list.

## Analysis

### Layout mechanics

- The optional panes are real windows: horizontal splits above the tree in
  sidebar/pinned mode, floating windows stacked in one column in floating mode.
  Open, close, floating layout, plugin-window detection, and height capture all
  iterate the single top-to-bottom order, with the tree as the flexible
  remainder.
- `lower_pane_anchor(pane)` returns the first open pane below `pane` in the
  order, otherwise the tree; `open_pane` splits above that window. Placement is
  therefore relative and already works for any order and any opening sequence
  (buffers first on startup, projects after discovery, agents when discovered):
  a pane is inserted directly above its nearest open lower neighbor, or
  directly above the tree.
- Pane heights are stored by name (`pane_heights`) and captured workspace state
  is order-independent. Only the list itself needs to become configurable.
- Floating relayout is cheap, so a new order set while floating is open is
  reflected immediately. Split windows cannot be repositioned without being
  recreated, so in split modes a new order takes effect as panes open or close,
  matching how other setup-time options behave.

### Normalization

The option is a list of optional pane names, top to bottom. The tree is always
the last, flexible pane and is never part of the stored order.

| Input | Result | Warning |
| --- | --- | --- |
| `{ "projects", "agents", "buffers" }` (default) | unchanged | no |
| `{ "buffers", "projects", "agents" }` | unchanged | no |
| `{ "buffers" }` | `{ "buffers", "projects", "agents" }` | no |
| `{ "buffers", "buffers" }` | `{ "buffers", "projects", "agents" }` | yes (duplicate) |
| `{ "projects", "agents", "buffers", "tree" }` | default order | no (`tree` last is already true) |
| `{ "tree", "buffers" }` | `{ "buffers", "projects", "agents" }` | yes (`tree` can only be last) |
| `{ "buffers", "nope" }` | `{ "buffers", "projects", "agents" }` | yes (unknown) |
| `nil` | default order | no |
| non-table (for example a string) | default order | yes (wrong type) |

Ignored entries are reported once through `vim.notify` at WARN level so a typo
is visible but never breaks the layout.

### Default Agents height

Each agent entry renders three rows (status/project, description, model). Ten
rows show three entries and one partial row. Fifteen rows show five complete
entries; no interior header consumes a row because the entry count lives in the
window statusline.

## Decisions

- Top-level `pane_order` list rather than per-pane numeric positions: one
  ordered source of truth, no gaps or ties to resolve.
- The tree is not part of the option. Every layout routine treats it as the
  flexible remainder created first; arbitrary tree placement would require a
  different layout architecture and is not needed for the requested order.
- Missing panes are appended in default order instead of rejecting the
  configuration: naming a subset still yields a complete, predictable layout.
- `"tree"` is accepted when it is the final entry (the intended state anyway)
  and warned about elsewhere, so users learn the tree stays last without a
  spurious warning for the obvious full-order list.
- The order is read at `setup()`. Split panes already open are not rebuilt;
  floating panes relayout immediately.

## Risks

- Users may read `pane_order` as controlling visibility. The README will state
  that it only controls order; visibility remains derived from live data.
- A 15-row default can squeeze the tree on short screens. Floating mode already
  scales pane heights to fit, and split-mode heights stay independently
  resizable and are preserved across pane opens and closes.

## Change history

| Date | Change |
| --- | --- |
| 2026-09-19 | Initial design |
