# opencode2 (oc2) backend

**Status:** EXPERIMENTAL, additive-only. Reached exclusively via `--harness opencode2`.
v1 opencode stays the fleet default.

## Overview

The `oc2` backend drives an opencode2 (OpenCode v2) crewmate over its HTTP API
instead of a terminal pane. A crewmate is a server session, not a process to
keystroke: launch, steer, interrupt, peek, and turn-end detection are all API
calls. There is no tmux pane, no send-text/Enter, no turn-end plugin, and no
busy-footer regex.

## Verified build

- **Date:** 2026-07-14
- **Build:** `opencode-ai@0.0.0-next-202606270058` (binary `opencode2`,
  self-reports `opencode2 vlocal`)
- **Installed via:** isolated npm prefix (`npm install --prefix
  ~/.local/share/oc2-prefix opencode-ai@next`), symlinked to
  `~/.local/bin/opencode2`. The global v1 `opencode` binary was never disturbed
  (spike §0 safety rail).
- **Server:** `opencode2 service start` on `http://127.0.0.1:4096`, isolated
  XDG dirs under `$FM_HOME/state/.oc2/`.

## End-to-end proof (2026-07-14)

Drove a real turn through the full `--harness opencode2` path:

1. **Spawn:** `fm-spawn.sh oc2-e2e-test-z9 projects/firstmate --harness opencode2
   --model opencode/north-mini-code-free --effort low`
   - Leased worktree via `treehouse get --lease`
   - Server ensured (`fm_backend_oc2_server_ensure`)
   - Session created (`v2.session.create` with `{id, providerID, variant}`)
   - Brief submitted (`v2.session.prompt`)
   - Meta recorded: `backend=oc2`, `harness=opencode2`,
     `window=oc2:ses_...`, `oc2_session=ses_...`, `oc2_url=http://...`
2. **Turn execution:** the model processed the brief and responded.
3. **Busy detection:** `v2.session.active` showed the session as `running`
   during the turn.
4. **Turn-end detection:** `scan_oc2_turn_ends` (in `fm-watch.sh`) detected
   the busy-to-idle transition and touched `state/<id>.turn-ended`.
5. **Capture:** `fm_backend_oc2_capture` read the session messages, showing
   `[user]` prompt and `[assistant]` response.
6. **Teardown:** `fm-teardown.sh` interrupted the session, returned the
   treehouse lease, and cleaned up state.

**Note:** the fleet's `zai-coding-plan` (GLM-5.2) key was out of credits at
test time, so the proof used `opencode/north-mini-code-free` (a free model from
the `opencode` provider). The API lifecycle is identical; only the model
differs. The spike (2026-07-13) verified the same flow with real GLM-5.2.

## Safety rails (all verified)

- The live v1 store `~/.local/share/opencode/opencode.db` was never opened,
  migrated, or written. All v2 state lives in `$FM_HOME/state/.oc2/`.
- `opencode2 migrate` was never run.
- The v1 `opencode` binary (1.17.20) was never disturbed.
- The `no-mistakes` daemon was never touched.

## Auth transfer

v2 does not read v1's `auth.json`. The GLM API key is surfaced read-only as
`ZHIPU_API_KEY`, extracted from the v1 credential file's `zai-coding-plan.key`
field. The server is started with `ZHIPU_API_KEY` in its env (spike §1.2).

## Isolation model

One shared server per firstmate home, N sessions. The server is session-centric:
concurrent sessions are isolated by sessionID (spike §5, verified with two
concurrent sessions). The backing `opencode-next.db` is an append-only event
store keyed by sessionID.

## Known gap

`v2.session.wait` is stubbed ("not available yet") in this build. Not a blocker:
the poll-based turn-end detection is the correct shape for firstmate's
event-driven watcher. The SSE event stream (`GET /api/session/{id}/event`) is an
alternative turn-end source but is not used by the current adapter; the
`v2.session.active` poll is simpler and sufficient.
