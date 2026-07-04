# Codex App-Server Backend Spike

Date: 2026-07-04

This is an evidence note for a future `backend=codex-app`. It deliberately does
not add `codex-app` to firstmate's spawn-capable backend list.

## Local Evidence

The installed Codex CLI exposes these relevant commands:

- `codex app-server`: experimental JSON-RPC app-server over stdio, Unix socket,
  WebSocket, or `off`.
- `codex app-server generate-json-schema --out <dir>`: writes a schema bundle
  matching the installed Codex version.
- `codex app-server generate-ts --out <dir>`: writes matching TypeScript
  bindings.
- `codex app-server daemon`: manages a local app-server daemon.
- `codex remote-control`: starts/stops app-server daemon remote control.

The current Codex manual describes app-server as the integration surface used by
rich clients. Its stable transport default is stdio (`--listen stdio://`), and
its WebSocket transport is experimental. A non-loopback WebSocket listener can
accept unauthenticated connections unless WebSocket auth is configured, so
firstmate probes must never expose `ws://0.0.0.0:...` or any other non-loopback
listener without `--ws-auth` plus token or secret material.

The generated schema from this environment includes the lifecycle methods needed
for a possible backend:

- `initialize`
- `thread/start`, `thread/list`, `thread/read`, `thread/archive`
- `thread/resume`, `thread/fork`, `thread/delete`
- `turn/start`, `turn/steer`, `turn/interrupt`

A local stdio smoke verified `initialize` and read-only `thread/list` against
this installed app-server without opening a listener. A throwaway
`thread/start` returned a `codex_thread_id` and emitted `thread/started`, but
`thread/read includeTurns=true` failed before the first user message because the
thread was not materialized yet. Retrying `thread/read includeTurns=false`
succeeded. `thread/archive` then reported no rollout for the new id, so archive
is not verified until a probe starts at least one turn. That proves basic
transport and thread-id creation, not a production backend.

## Probe Helper

Use `bin/fm-codex-appserver-probe.sh` for future manual checks:

```sh
bin/fm-codex-appserver-probe.sh
bin/fm-codex-appserver-probe.sh --schema-dir /tmp/fm-codex-schema
bin/fm-codex-appserver-probe.sh --live-handshake
bin/fm-codex-appserver-probe.sh --live-handshake --create-thread --keep-thread
```

Default mode is a dry run. It does not start app-server, create a thread, expose
a listener, or touch project worktrees.

`--live-handshake` starts `codex app-server --stdio` and performs only
`initialize` plus a read-only `thread/list`.

`--create-thread` additionally creates a thread in a temporary cwd and reads it.
Before a first turn exists, app-server may report the thread as not materialized
for `includeTurns=true` and may reject archive with "no rollout"; the helper
reports that as `archived_created_thread: unavailable-no-rollout`. Pass
`--keep-thread` only when a human wants to open the printed
`codex://threads/<id>` link and confirm whether app-server-created threads
appear as normal Codex GUI threads.

## GUI Visibility Finding

The current evidence does not prove that app-server-created threads appear in
the Codex GUI sidebar as normal user-visible threads. The schema and stdio
handshake prove a callable protocol, and `thread/start` can produce a thread id,
but a no-turn thread may not have a rollout yet. The explicit `--keep-thread`
probe exists to produce a real `codex_thread_id` and `codex://threads/<id>` link
for a manual GUI check without risking real project state.

Until that manual GUI check is repeated and documented, app-server threads should
be treated as callable Codex sessions whose GUI visibility is unverified.

## Metadata A Backend Would Need

A real `backend=codex-app` task meta record would need at least:

- `backend=codex-app`
- `codex_thread_id=<thread uuid>`
- `codex_thread_url=codex://threads/<encoded thread id>`
- `codex_active_turn_id=<turn id>` while a turn is running
- `worktree=<path>` and an owner marker such as `worktree_owner=treehouse` or
  `worktree_owner=codex`
- `codex_transport=stdio|unix|ws`
- `codex_archive_on_teardown=on|off`

`turn/steer` requires an `expectedTurnId`, and `turn/interrupt` requires both
`threadId` and `turnId`. Firstmate therefore cannot treat a Codex thread as a
send-only terminal. It must track active turn identity or read it before steer
and interrupt operations.

Read semantics should map to `thread/read` and app-server notifications, not a
terminal scrollback tail. Archive/kill semantics should map to `turn/interrupt`
for active work and `thread/archive` only after firstmate has safely captured
status/report evidence.

## Codex-Managed Worktrees In Firstmate Terms

Treehouse-owned worktrees and Codex-managed worktrees are different ownership
models.

Treehouse today:

- Firstmate asks treehouse for an isolated checkout.
- `fm-spawn.sh` records the worktree path and verifies it is not the primary
  checkout.
- `fm-teardown.sh` owns landed-work checks, report checks, and treehouse return.
- Worktree cleanup is blocked when ship work is dirty or unlanded.

Codex-managed worktrees:

- Codex app creates worktrees under `$CODEX_HOME/worktrees`.
- They are usually detached HEADs dedicated to one thread.
- Codex can hand threads between Local and Worktree and can restore snapshots
  after deleting managed worktrees.
- Codex automatically deletes some managed worktrees when threads are archived
  or app worktree retention needs cleanup.
- Codex app controls where managed worktrees live.

Firstmate implications:

- A Codex-owned worktree is not safe to remove through treehouse teardown.
- Firstmate must record whether the worktree is treehouse-owned or Codex-owned.
- Teardown must fail closed when Codex has deleted or moved a worktree before
  firstmate can prove the ship work is clean and landed.
- Branch and PR safety still belongs to firstmate. A Codex GUI thread may create
  commits, push branches, or open PRs, but firstmate must record `pr=` and
  `pr_head=` and must still require captain/firstmate merge policy.
- Handoff can change where the thread's code lives, so a backend needs a fresh
  worktree read before teardown, review, or PR checks.

Codex-managed worktrees are acceptable for firstmate only if these lifecycle
rules can be made mechanical and tested. They should not replace treehouse by
default in the first backend iteration.

## Roadmap Recommendation

Do not build a production `codex-app` backend yet.

Recommended sequence:

1. Keep Herdr and tmux unchanged. Use `bin/fm-codex-appserver-probe.sh` to
   repeat schema and stdio checks as Codex versions change.
2. Manually run `--create-thread --keep-thread`, open the printed
   `codex://threads/<id>` link in Codex GUI, and record whether the thread is
   visible, readable, steerable, interruptible, and archivable from both sides.
3. Add a non-spawn backend adapter sketch only after create/read/archive and
   active-turn tracking are verified by tests or repeatable smoke output.
4. Start ship/scout-only. Do not support secondmates until a normal task can
   create, read, steer, interrupt, archive, PR, and teardown safely.
5. Decide worktree ownership explicitly per task. Prefer treehouse-owned
   worktrees for the first implementation; add Codex-managed worktrees only
   after teardown and handoff behavior are proven.

The production gate for adding `codex-app` to `FM_BACKEND_SPAWN` should be:

- create/read/send-or-turn-start/archive verified
- active turn id tracked
- GUI visibility understood
- no unauthenticated non-loopback listener path
- worktree owner recorded
- teardown fails closed on unknown or moved worktrees
- focused backend tests cover metadata, send/steer, read, interrupt/archive, and
  cleanup behavior
