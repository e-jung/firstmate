# Orca Backend

Orca is an experimental runtime backend for firstmate.
It is distinct from the crewmate harness: the harness is the agent process firstmate launches (`claude`, `codex`, `opencode`, `pi`, or `grok`), while Orca owns the task worktree and terminal endpoint underneath that process.
Firstmate agents operating this backend should load the agent-only [`firstmate-orca`](../.agents/skills/firstmate-orca/SKILL.md) checklist before switching to Orca, spawning or supervising Orca-backed work, smoke-testing, debugging task state, or reconciling Orca metadata.

## Setup

Pick Orca if you run the Orca app as your terminal environment and want firstmate tasks to live in Orca-managed worktrees and terminals instead of a treehouse/tmux pair.
Orca runs in two shapes: the Orca desktop app on macOS, or a headless `orca serve` runtime on Linux.
It is explicit-only (never auto-detected) and has no secondmate support.

Prerequisites:

- The `orca` CLI on `PATH`, backed by a **running Orca runtime** reporting `reachable=true` and `state="ready"` - either the Orca desktop app on macOS or a headless `orca serve` process on Linux (see "Runtime shapes" below).
  Note that `brew install orca` installs an unrelated package (Plotly's graphing library), not the Orca agentic CLI; install Orca from its own distribution.
- `node`, used by firstmate's adapter to parse Orca's JSON output and to gate spawns on runtime readiness.
- The universal firstmate prerequisites - a verified crew harness plus the required toolchain, owned by [`docs/configuration.md`](configuration.md) ("Harness support", "Toolchain") - with `orca` as the only backend-specific tool, since Orca replaces both the session multiplexer CLI and the `treehouse` worktree provider that the other backends require.

### Runtime shapes

Orca's runtime owns the project repos, worktrees, and terminals it creates, and firstmate's adapter assumes all of those share one filesystem view with the firstmate process: the recorded `worktree=` and `project=` paths are read as local paths, the crewmate brief is read by a local `cat`, and the harness runs off local `PATH`.
Two runtime shapes satisfy that contract.

**macOS desktop.**
The Orca app runs as a GUI at `/Applications/Orca.app`; firstmate, the repos, and the worktrees all live on the same Mac.
This is the shape the original adapter was built and smoke-verified against.

**Linux headless (collocated).**
Firstmate, the project clones, Orca worktrees, terminals, and a headless `orca serve` runtime all run on one Linux host.
The Orca desktop app on a Mac, or a mobile client, may pair to that runtime as a viewer or interaction surface over the pairing address - it does not execute tasks, and firstmate never drives a remote runtime.
Verified 2026-07-15 on `oracle-vps` (Linux aarch64, kernel `6.8.0-1054-oracle`) against Orca `1.4.141`: the runtime is installed under `/opt/Orca` (a full Linux build of the app), the `orca` CLI resolves through a wrapper at `~/.local/bin/orca` to `/opt/Orca/resources/bin/orca-ide`, and `orca serve` starts a runtime server without a desktop window.
`orca serve --help` verbatim: *"Start an Orca runtime server without opening a desktop window"* and *"Use `--pairing-address` when clients should connect through a LAN, Tailscale, SSH-forward, or public tunnel address."*
`orca status --json` reported `result.runtime.reachable=true`, `result.runtime.state="ready"`, and `result.app.running=true`.
The runtime was supervised by a systemd user unit (`Restart=on-failure`, `RestartSec=5`, with `Linger=yes` so it survives SSH disconnects), launched as `orca-ide serve --port 6768 --pairing-address <tailscale-ip> --json`.
Every lifecycle primitive firstmate's adapter calls - `status`, `repo add`, `worktree create`, `terminal create`, `terminal read`, `terminal send`, `terminal close`, `worktree rm` - returned the exact JSON shapes the adapter already parses, and the 50 fake-Orca tests in `tests/fm-backend-orca.test.sh` pass unchanged on Linux.
The Orca adapter itself contains no macOS-specific assumptions (no `uname`, no `/Applications`, no `Darwin` checks), so the code that works on macOS is the same code that works on Linux.

Select Orca by putting `orca` in a local `config/backend` file - the durable way to pick it - or by exporting `FM_BACKEND=orca` when you launch your harness for a one-off session; telling the first mate in chat to use Orca also works.
It is never auto-detected.

First run: before spawn mutates any repo or worktree state, firstmate runs `orca status --json` and requires the runtime to report `reachable=true` and `state="ready"` - start the Orca runtime (the desktop app on macOS, or `orca serve` on Linux) and wait for it to report ready before spawning.
Spawn fails closed if the runtime is not ready.
The first spawn against a given project also auto-registers that project's repo in Orca (`orca repo add --path`) if it is not already registered - no manual registration step is needed.

Watching and attaching: Orca owns both the worktree and the terminal for its tasks, so there is nothing to attach to outside Orca itself - open the Orca desktop app (when running) and find the terminal for the task (recorded as `terminal=<handle>` in the task's meta, with `window=fm-<id>` as the shared firstmate alias).
You do not need to open the app for routine supervision: from an active firstmate session, `bin/fm-peek.sh <id>` reads a task's terminal without opening Orca, and `FM_HOME=<this-firstmate-home> bin/fm-send.sh <id> "<text>"` steers it unless `FM_HOME` is already set to the active firstmate home (the stable `fm-<id>` alias also works; Enter and Ctrl-C are supported; Escape is not).

Verify it works by spawning a trivial task with `--backend orca` and confirming the task's meta records `backend=orca`, `terminal=`, `orca_worktree_id=`, and `worktree=`; Orca should show a new terminal for the task (visible in the desktop app when paired or running).

Limitations: `--secondmate` spawns refuse `backend=orca` (secondmate-home semantics need a separate design), Escape is unsupported, Orca is explicit-only, and it exposes no stable CLI version marker, so spawn gates on runtime reachability instead of a version floor - see "Limitations" below for the complete list.

## Status

PR #210 landed the primitive Orca terminal adapter: bounded capture, text send, Enter, Ctrl-C interrupt, and close for already-created Orca terminals.
This follow-up adds full ship/scout task lifecycle support for `backend=orca`: spawn, metadata, send/peek/watch/crew-state routing from metadata, and guarded teardown through Orca.

Orca remains explicit-only.
Select it by putting `orca` in a local `config/backend` file, by exporting `FM_BACKEND=orca`, or by telling the first mate in chat to use Orca.
It is not auto-detected from the current process environment.
Before spawn mutates any repo/worktree state, firstmate runs `orca status --json` and requires the Orca runtime to report reachable/ready.

## Task Shape

An Orca task is one Orca-managed git worktree plus one Orca terminal.
Unlike `tmux`, `herdr`, `zellij`, and `cmux`, Orca is not only a session provider; it also provides the task worktree, so `fm-spawn.sh` does not run `treehouse get` for Orca tasks.

The normal firstmate invariant still applies: a ship or scout task must run outside the project primary checkout, and teardown must refuse to discard unlanded ship work.

## Metadata

An Orca-spawned task records the normal task fields plus these Orca-specific fields:

```text
backend=orca
window=fm-<id>
terminal=<orca terminal handle>
orca_worktree_id=<orca worktree id>
worktree=<absolute path to the Orca-created git worktree>
```

`window=` remains the shared firstmate alias used by selector-driven supervision tools after a task selector has resolved through metadata.
`fm-teardown.sh <id>` uses the same recorded fields after loading `state/<id>.meta`.
For Orca, `window=` keeps the stable firstmate alias while `terminal=` carries the stable Orca terminal handle that backend operations use.
The recorded `backend=orca` field tells shared call sites to route capture, send, interrupt, and close through `bin/backends/orca.sh` instead of tmux assumptions.

## Lifecycle

Spawn:

1. Ensure the project repo is registered in Orca, adding it with `orca repo add --path` when needed.
2. Create an independent Orca worktree with `orca worktree create --repo id:<repo> --name fm-<id> --no-parent --setup skip`.
3. Reuse the terminal returned by Orca worktree creation only when it appears in the verified `result.terminal.handle` shape, or create a titled terminal in that worktree when Orca returns only the worktree.
4. Install firstmate's per-harness turn-end hooks in the Orca worktree.
5. Write metadata, then send `GOTMPDIR` export and the selected harness launch through the recorded Orca terminal.

Operation routing:

- `fm-peek.sh` captures with `orca terminal read`.
- `fm-send.sh` types text with `orca terminal send --text ...`, submits with Enter, and verifies the composer row cleared before returning; when Orca reports a limited page, the verifier follows `oldestCursor` and preserves the current tail so older text cannot hide still-pending composer input.
  A slash-command popup that closes by filling an argument-hint placeholder still reads as pending, so the retry loop sends the required second Enter rather than treating the first Enter as a submission.
  The bordered row is classified through the shared composer classifier; a bare shell prompt has no genuine composer row and reads `unknown`, not confirmed empty.
- `fm-send.sh --key Enter` and `--key C-c` are supported.
- `fm-watch.sh` treats Orca as a pull backend with no native busy-state primitive, so it falls back to the same terminal-tail busy regex used for tmux, zellij, and cmux.
- `fm-crew-state.sh` reads the recorded Orca terminal when no no-mistakes run-step applies.

Teardown:

- Scout teardown still requires `data/<id>/report.md` unless `--force` is explicitly used.
- Ship teardown still refuses dirty or unlanded work before any terminal/worktree cleanup.
- Ship teardown resolves `orca_worktree_id` back through Orca and verifies it matches the inspected `worktree=` path before removing anything; mismatches or uninspectable paths preserve metadata and fail closed.
- After the existing firstmate safety checks pass, teardown closes the recorded Orca terminal and releases the recorded worktree through `orca worktree rm --worktree id:<orca_worktree_id> --force`.
- Teardown does not raw-delete Orca worktrees.

## Limitations

- `--secondmate` spawns still refuse `backend=orca`; secondmate-home semantics need a separate design.
- Escape is unsupported because the current Orca terminal send primitive exposes Enter and interrupt-style input but no verified Escape operation.
- Orca is explicit-only and is not selected by runtime auto-detection.
- Orca currently exposes no stable CLI version or protocol marker. Unlike the herdr/zellij/cmux docs, this backend intentionally gates spawn support on runtime reachability from `orca status --json` rather than a version floor.
- `fm_backend_agent_alive` reports `unknown` for Orca (it has no native agent-liveness primitive), so the secondmate-liveness confident-respawn path does not apply to Orca tasks; this is pre-existing and not a regression of the Linux shape.

## Verification

macOS desktop: real-Orca smoke verification was run against `/usr/local/bin/orca` with `/Applications/Orca.app` reporting bundle version `1.4.116`; `orca status --json` reported `result.runtime.reachable=true` and `result.runtime.state="ready"`.
The verified terminal creation handle field is `result.terminal.handle` from `orca terminal create --json`; worktree creation returned `result.worktree.id` and `result.worktree.path` in the same smoke run.
Firstmate intentionally ignores speculative terminal-handle shapes such as bare `result.id` and nested `result.worktree.terminal` until a real Orca smoke run proves them.

Linux headless: the full lifecycle was exercised 2026-07-15 against `orca` `1.4.141` on `oracle-vps` (Linux aarch64, kernel `6.8.0-1054-oracle`), with the runtime headless under a systemd user unit running `orca-ide serve`.
`orca status --json` reported `result.runtime.reachable=true`, `result.runtime.state="ready"`, and `result.app.running=true`.
Real CLI calls against a throwaway repo confirmed every primitive the adapter calls: `orca repo add --path` (returned `result.repo.id`), `orca worktree create` (returned `result.worktree.id` and `result.worktree.path`), `orca terminal create` (returned `result.terminal.handle`), `orca terminal send` plus `orca terminal read` round-trip, `orca terminal close`, and `orca worktree rm` - all returning the JSON shapes the adapter parses.
The 50 fake-Orca tests in `tests/fm-backend-orca.test.sh` pass unchanged on Linux, and the adapter has no macOS-specific code paths.

Fake-Orca tests cover:

- helper parsing for repo registration, worktree creation, verified implicit-terminal reuse, terminal creation, terminal sends, and worktree removal;
- rejection of undocumented terminal-handle result shapes;
- runtime readiness gating through `orca status --json`;
- `fm-spawn.sh --backend orca` metadata creation and harness launch;
- `fm-peek.sh`, `fm-send.sh`, and `fm-crew-state.sh` routing through recorded Orca metadata;
- slash-command popup placeholder handling that requires a second Enter before `fm-send.sh` reports submission;
- scout teardown releasing an Orca worktree through `orca worktree rm`;
- ship teardown failing closed when the recorded Orca worktree id is missing, cannot resolve to a path, or resolves to a different path than `worktree=`.

Run the focused suite with:

```sh
tests/fm-backend-orca.test.sh
tests/fm-backend.test.sh
tests/fm-bootstrap.test.sh
```
