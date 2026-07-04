# Codex GUI Control Thread

Firstmate works best in the Codex app when the captain keeps one firstmate thread as the control dashboard.
Worker agents still run in the configured runtime backend - tmux by default, or experimental Herdr, zellij, or Orca when selected - but the captain should not need to hunt through child Codex sessions for routine progress.

## Recommended UX

Start Codex in the firstmate repo and keep that thread open.
Use it for requests, decisions, status checks, PR review links, and merge approvals.
Let firstmate spawn and supervise crewmates in Herdr/tmux/zellij/Orca, and open worker endpoints only when deliberate inspection or manual intervention is needed.

For a compact dashboard, run:

```sh
bin/fm-fleet-view.sh
```

The table is read-only and small enough to paste into chat.
Each row shows the task id, repo, kind, backend, current status summary, PR or report pointer, worktree/path pointer, and exact commands for watching, steering, or generating Codex links.
Current status comes from `bin/fm-crew-state.sh`, so stale `state/<id>.status` events are reconciled against no-mistakes and the recorded backend before they reach the table.
If `data/backlog.md` has a `## In flight` item with no matching metadata file, the table shows a backlog-only recovery row instead of hiding it.

To generate Codex app links for a task or report, run:

```sh
bin/fm-codex-link.sh task <task-id>
bin/fm-codex-link.sh report <task-id-or-report-path>
bin/fm-codex-link.sh project <absolute-project-dir>
```

The helper prints canonical `codex://new?path=...` links with query values encoded, plus the raw local path as a fallback.
For reports, Codex opens a new thread in the report directory with a prompt that names the report file to review.
For task worktrees, Codex opens a new thread in the task worktree with a prompt asking for status, diff, blockers, and next steps.

## Operating Pattern

Use the firstmate thread as the source of truth for:

- Progress summaries and blockers.
- Decisions the captain must make.
- PR URLs and report paths.
- Merge approvals.
- Recovery after a restart.

Use worker endpoints only for:

- Watching a live turn with `bin/fm-peek.sh fm-<task-id>`.
- Sending a targeted steer with `bin/fm-send.sh fm-<task-id> '<message>'`.
- Debugging a backend-specific terminal problem.

This keeps Codex Desktop and iOS focused on one control thread while preserving firstmate's existing backend safety model.
The new commands do not create a runtime backend, change teardown rules, change no-mistakes behavior, or weaken merge approval.

## Deep-Link Basis

The Codex app registers the `codex://` URL scheme and supports `codex://new` / `codex://threads/new` links with `path`, `prompt`, and `originUrl` query parameters.
`path` must be an absolute local directory, so firstmate report links target the report directory and put the exact report file in the prompt.
