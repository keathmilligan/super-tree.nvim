---
feature: agents
created: 2026-09-18
updated: 2026-09-18
---

# Agents

| Created | Updated |
| --- | --- |
| 2026-09-18 | 2026-09-18 |

## Purpose

Visibility and navigation for coding-agent instances running across projects.

## Requirements

### OpenCode V2 discovery

When enabled, SuperTree SHALL detect live full OpenCode V2 TUI instances owned
by the current user. Background services and non-TUI commands such as `api`,
`run`, `mini`, and `serve` SHALL NOT appear as TUI instances.

SuperTree SHALL reconcile TUI instances with active OpenCode V2 sessions:

- A TUI matched to a `running` active session SHALL show `working`.
- A pending permission request SHALL override an active status with `blocked`.
- A pending question or form SHALL override an active status with `question`.
- A newly detected TUI without a matched active session SHALL show `idle`.
- When a previously active TUI no longer has an active session, it SHALL show
  `done` and retain its last session metadata until new work starts or the TUI
  exits.
- An active session without a matched TUI SHALL remain visible.
- A historical session without a live TUI and without active work SHALL NOT be
  shown.

#### Idle TUI

- GIVEN a full OpenCode V2 TUI is running
- AND no active session matches its working directory
- WHEN Agents refreshes
- THEN that TUI is listed with status `idle`

#### Running TUI

- GIVEN a full OpenCode V2 TUI is running
- AND an active session matches its working directory
- WHEN Agents refreshes
- THEN one entry represents that TUI and session
- AND it uses the TUI's stable process identity
- AND it shows the active session status and metadata

#### Multiple TUIs in one project

- GIVEN multiple TUI instances have the same project working directory
- AND fewer active sessions match that directory
- WHEN Agents refreshes
- THEN matching is one-to-one
- AND unmatched TUI instances remain visible as `idle`

### Status and presentation

Each agent entry SHALL occupy three rows:

1. status icon, status text, and project name or directory;
2. session description, or a stable TUI/session fallback; and
3. agent name and model information, including model provider and variant when
   available.

The status icon and status text SHALL both use the status color. Status SHALL
also be expressed as text so color is not the sole indicator. An unknown status
value SHALL remain visible with neutral styling and its original text.

`working` SHALL use yellow, `blocked` SHALL use red, `question` SHALL use blue,
and `done` SHALL use green.

An idle TUI without agent metadata SHALL clearly state that no agent is active
and that model information is unavailable.

The pane header SHALL count agent entries rather than rendered rows.

### Pane visibility and refresh

The Agents pane SHALL appear above Projects when at least one TUI instance or
unmatched active session exists. It SHALL hide only after a successful refresh
finds neither.

Discovery SHALL run asynchronously and refresh automatically while SuperTree is
open. `R` SHALL request an immediate refresh. Opening or closing the pane during
a background refresh SHALL NOT take focus from another valid window.

If all discovery sources fail, SuperTree SHALL retain the last usable snapshot.
If process discovery succeeds but active-session discovery fails, detected TUIs
SHALL remain visible with an unknown status rather than being removed or
incorrectly marked idle.

### Navigation and filtering

The three rows SHALL behave as one selectable entry:

- `j`, `k`, and arrow navigation SHALL move between entries, not metadata rows.
- `<Enter>`, double-click, `l`, or `<Right>` on any row SHALL activate the
  entry's project.
- `/`, `#`, `f`, and `<C-x>` SHALL filter or clear Agents using status, project,
  description, agent, model, and path metadata.

### Super Project activation

Agent activation SHALL use the registered super-project.nvim provider. It SHALL
prefer the longest registered project root containing the agent or TUI working
directory, so a nested location activates its existing project workspace.

If no registered root contains the location, SuperTree SHALL offer the exact
existing directory to Super Project for opening/registration. If
super-project.nvim is unavailable, the directory is missing, or switching
fails, SuperTree SHALL report the error and SHALL NOT change the current
workspace itself.

### Modes and state

Agents SHALL work in sidebar, pinned, and floating modes. SuperTree state SHALL
capture and restore the Agents pane height, selected process/session identity,
and focus when the entry is still available. Pane visibility SHALL remain
derived from live discovery rather than persisted as a per-project preference.

### Configuration

Configuration SHALL support:

- enabling or disabling Agents;
- initial pane height;
- refresh interval;
- the OpenCode V2 executable, defaulting to `opencode2`; and
- status symbols, including `running`, `idle`, and `unknown`.

## Change history

| Date | Change |
| --- | --- |
| 2026-09-18 | Initial Agents specification from add-agents-panel |
| 2026-09-18 | Clarified exact-directory Super Project fallback |
| 2026-09-18 | Added blocked permission and question prompt statuses |
| 2026-09-18 | Distinguished idle, working, and completed TUI states and colors |
