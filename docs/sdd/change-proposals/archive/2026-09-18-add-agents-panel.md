---
id: add-agents-panel
status: accepted
features: [agents, window]
created: 2026-09-18
updated: 2026-09-18
---

# Add an agents panel

| Created | Updated |
| --- | --- |
| 2026-09-18 | 2026-09-18 |

## What

### Why

Developers running OpenCode across several projects cannot currently see that
activity from SuperTree. They must visit each project or terminal to find the
active agent. A compact panel, similar in purpose to Herdr's Agents panel,
would make concurrent work visible and provide a direct route to the relevant
Super Project workspace.

### Requirements

- SuperTree SHALL provide an optional Agents pane above Projects, Buffers, and
  the file tree.
- The pane SHALL support OpenCode V2 first and SHALL keep agent discovery
  behind an internal provider boundary so other runtimes can be added later.
- The OpenCode provider SHALL detect each live full `opencode2` TUI process,
  excluding the background service and non-TUI subcommands such as `api`,
  `run`, `mini`, and `serve`.
- The provider SHALL reconcile detected TUI instances with sessions returned by
  the official V2 `GET /api/session/active` endpoint:
  - a TUI matched to an active session SHALL show that session and its reported
    status (`running` in the current V2 contract);
  - a TUI with no matched active session SHALL remain visible with status
    `idle`; and
  - active sessions that cannot be matched to a detected TUI SHALL remain
    visible as running agents.
- Inactive historical sessions without a live TUI SHALL NOT be shown.
- Each agent SHALL use a three-row display:
  1. status icon, status text, and project name or directory;
  2. description, sourced from the OpenCode session title with a stable
     fallback; and
  3. agent name and model information, including provider and variant when
     available.
- The status icon and text on the first row SHALL both be colored for that
  status. The description and agent/model rows SHALL remain visually distinct
  and readable using the existing primary/faded text language.
- The three rows SHALL behave as one selectable agent: keyboard navigation
  SHALL move between agents, and Enter or double-click on any of the three rows
  SHALL activate that agent's project.
- Unknown future OpenCode status values SHALL remain visible with neutral
  styling rather than causing the provider or pane to fail.
- Discovery and refresh SHALL be asynchronous and SHALL NOT block Neovim.
  While SuperTree is open, the list SHALL refresh automatically; `R` SHALL
  request an immediate refresh.
- The pane SHALL appear when at least one TUI instance or unmatched running
  agent is discovered and hide when there are none. Background refreshes SHALL
  NOT steal window focus.
- `<Enter>` and double-click on an agent SHALL activate the Super Project
  workspace containing that agent's OpenCode location. Resolution SHALL prefer
  the closest registered Super Project root so an agent started in a nested
  directory opens the existing project rather than creating an accidental
  nested workspace.
- If super-project.nvim is unavailable, the location no longer exists, or the
  switch fails, activation SHALL leave the current workspace intact and report
  a useful warning or error.
- The Agents pane SHALL work in sidebar, pinned, and floating modes and SHALL
  participate in pane sizing, close cleanup, filtering, selection, focus, and
  Super Project state capture/restoration consistently with the existing list
  panes.
- Configuration SHALL cover enablement, pane height, refresh interval, the
  OpenCode V2 executable (default `opencode2`), and status symbols.

### Scope

- In: OpenCode V2 TUI-process and active-session discovery; running/idle status
  reconciliation; automatic and manual refresh; standard list-pane
  filtering/navigation; Super Project activation; all three SuperTree window
  modes; documentation and tests.
- Out: OpenCode V1; Claude Code, Codex, and other future providers; starting,
  stopping, resuming, attaching to, or sending input to agents; showing idle or
  completed session history; inferring states not exposed by the OpenCode V2
  active-session contract; project-manager fallbacks other than Super Project.

### Open questions

- None. OpenCode V2 does not expose a client-to-session identity map. Matching
  therefore uses canonical working directories and stable TUI PIDs; unmatched
  instances are idle and unmatched active sessions remain visible. The UI uses
  a generic status renderer so later API values and providers can add distinct
  states without redesigning the pane.

## How

### Approach

Add a provider-neutral `agents` list module and an OpenCode V2 adapter. The
adapter will asynchronously enumerate full TUI processes, invoke `opencode2
api`, reconcile TUI locations with active session details, and emit normalized
running and idle entries. A generation guard, request timeout, and single
in-flight refresh will prevent late or overlapping callbacks from mutating a
closed or newer pane.

Generalize the window module's hard-coded Projects/Buffers stack into the
ordered pane set Agents/Projects/Buffers/Tree. Render Agents as a normal
read-only SuperTree pane with status-specific highlights and route activation
through the registered `super-project` provider after resolving the closest
known project root.

Detailed behavior and trade-offs: [design/add-agents-panel.md](../../design/add-agents-panel.md).

### Impacted specifications

- `agents` (new)
- `window` (existing)

### Plan

#### 1. Agent data and OpenCode V2 provider

- [x] 1.1 Add a normalized agent-entry contract and internal provider boundary
- [x] 1.2 Add an asynchronous command runner with JSON decoding, timeout,
      cancellation/generation guards, and injectable test fixtures
- [x] 1.3 Detect full OpenCode V2 TUI processes and their working directories
      while excluding service and non-TUI subcommands
- [x] 1.4 Reconcile TUI instances, active sessions, session details, and idle
      fallback entries using stable process identity and canonical paths
- [x] 1.5 Add polling lifecycle, refresh de-duplication, stable sorting, and
      graceful handling for missing commands, API failures, and unknown status
      values

#### 2. Agents pane and window stack

- [x] 2.1 Generalize pane creation, ordering, floating layout, closing, height
      capture, and plugin-window detection for Agents/Projects/Buffers
- [x] 2.2 Render three-row agent entries, row-to-entry mapping, count/status
      header, status highlights, configured symbols, fade behavior, and
      empty-list auto-hide
- [x] 2.3 Add entry-wise Agents navigation, Enter/double-click from any entry
      row, and list filtering, including `R`, `/`, `#`, `f`, `<C-x>`, `<Tab>`,
      help, and close behavior
- [x] 2.4 Start/stop refresh with the SuperTree window and update WinClosed,
      resize, colorscheme, and cleanup paths without stealing focus

#### 3. Super Project activation and state

- [x] 3.1 Resolve an agent directory to the longest matching registered Super
      Project root and expose a safe provider activation helper
- [x] 3.2 Switch projects from Enter/double-click and report unavailable,
      missing-directory, and provider errors without changing the workspace
- [x] 3.3 Extend SuperTree state capture/restoration for Agents selection,
      focus, and pane height while treating live pane visibility as derived
      from current agent data

#### 4. Verification and documentation

- [x] 4.1 Add deterministic provider/parser tests for TUI detection and
      exclusion, active/idle reconciliation, duplicate project instances,
      empty, malformed, failed, timed-out, and unknown-status responses
- [x] 4.2 Add pane tests for rendering, filtering, auto-show/hide, refresh
      cleanup, keymaps, and all three window modes
- [x] 4.3 Add Super Project activation and state round-trip tests, including a
      nested agent directory and provider failure
- [x] 4.4 Update existing pane/layout fixtures for the new optional pane and run
      the complete headless test suite
- [x] 4.5 Document the Agents pane, OpenCode V2 requirement and semantics,
      configuration, status appearance, keybindings, and Super Project behavior

## Change history

| Date | Change |
| --- | --- |
| 2026-09-18 | Initial proposal |
| 2026-09-18 | Specified three-row agent entries with entry-wise interaction |
| 2026-09-18 | Approved for implementation |
| 2026-09-18 | Implemented and verified; ready for review |
| 2026-09-18 | Review feedback: detect live TUI instances and show inactive instances as idle |
| 2026-09-18 | Implemented and verified TUI detection and idle reconciliation; returned to review |
| 2026-09-18 | Accepted; `agents` spec created and `window` spec updated |
