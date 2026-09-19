---
id: configurable-pane-order
status: review
features: [window, agents]
created: 2026-09-19
updated: 2026-09-19
---

# Configurable pane order and a larger Agents default

| Created | Updated |
| --- | --- |
| 2026-09-19 | 2026-09-19 |

## What

### Why

SuperTree stacks three optional list panes above the file tree. The current
order puts the Agents pane on top, so the stable Projects pane is pushed down
whenever agents appear, and users who want a specific reading order cannot
change it. Projects is the top-level workspace switcher and belongs at the top
by default, and the order should be configurable.

The Agents pane defaults to 10 rows while each agent entry occupies three rows,
so it shows three entries and part of a fourth. A default that fits five
complete entries makes concurrent agent activity visible without manual
resizing.

### Requirements

- The default top-to-bottom pane order SHALL be Projects, Agents, Buffers, then
  the file tree.
- Configuration SHALL set the top-to-bottom order of the optional panes
  (Projects, Agents, Buffers), independent of which panes are visible.
- The file tree SHALL remain the last, flexible pane; pane order configuration
  SHALL NOT move it.
- An invalid order SHALL NOT break layout: unknown or duplicate names SHALL be
  ignored, a `"tree"` entry SHALL be honored only as the final entry (the tree
  is always last), and any optional pane missing from the list SHALL be
  appended in the default order, so the layout always covers each optional pane
  exactly once. Ignored entries SHALL produce a warning.
- The default Agents pane height SHALL be large enough to show five complete
  three-row entries.
- Pane order SHALL apply consistently in sidebar, pinned, and floating modes,
  and SHALL NOT change height preservation, focus behavior, state
  capture/restore, or pane visibility rules.

### Scope

- In: `pane_order` configuration, the new default order, the Agents default
  height, validation/warning behavior, tests, README.
- Out: moving the file tree within the stack; per-workspace or per-provider
  persisted order; drag-and-drop or runtime interactive reordering; changes to
  pane visibility rules.

### Open questions

- None.

## How

### Approach

Make the window module's hard-coded pane order a module-owned list that
defaults to `{ "projects", "agents", "buffers" }` and can be replaced through
`window.set_pane_order()`. The setter normalizes the list into a complete
permutation of the optional panes and is called from `setup()` with the new
`pane_order` config value. Existing split and floating layout code already
iterates this list, so only its source changes; `lower_pane_anchor` keeps
working for any order because it inserts a pane above its first open lower
neighbor (or above the tree).

Length/layout analysis, normalization rules, and decisions:
[design/configurable-pane-order.md](../../design/configurable-pane-order.md).

### Impacted specifications

- `window` (existing)
- `agents` (existing)

### Plan

#### 1. Configurable pane order

- [x] 1.1 Replace the hard-coded order in `lua/super-tree/window.lua` with a
      default `projects, agents, buffers` list and add
      `set_pane_order()` / `get_pane_order()` with normalization (ignore
      unknown, duplicate, and misplaced `tree` entries; append missing panes in
      default order; warn once about ignored entries)
- [x] 1.2 Apply `config.pane_order` in `setup()` and normalize before any pane
      can open
- [x] 1.3 Update pane-order comments and prose that hard-code
      "Agents / Projects / Buffers"

#### 2. Agents default height

- [x] 2.1 Default `agents.height` to 15 rows (five three-row entries) in the
      plugin config and the window module fallback

#### 3. Tests

- [x] 3.1 Update existing pane-order assertions (`tests/agents.lua`) to the new
      default
- [x] 3.2 Add headless tests for the default order, a custom order across
      sidebar/pinned/floating modes, invalid/duplicate/`tree` entries, and the
      15-row Agents default
- [x] 3.3 Run the complete headless test suite

#### 4. Documentation

- [x] 4.1 Update README: config sample (`pane_order`,
      `agents.height = 15`), pane-order explanation, and pane descriptions that
      hard-code the old order

## Change history

| Date | Change |
| --- | --- |
| 2026-09-19 | Initial proposal |
| 2026-09-19 | Approved for implementation |
| 2026-09-19 | Implemented and verified; ready for review |
