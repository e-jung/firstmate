# Plugins & daemon config

This is the one file to read when you want to **tune the supervision daemon** or
**add an event source** the watcher should wake on (a Linear inbox, a Slack
channel, disk health, GitHub PRs, anything).
It covers the contract every event source must honor, the two CLIs that make
adding one safe (`fm-plugin.sh`), and the one config file that tunes the daemon
(`fm-config.sh` + `config/daemon.conf`).

## The contract: silent-unless-wake

`bin/fm-watch.sh` sweeps every `state/*.check.sh` every `FM_CHECK_INTERVAL`
(default 300s) and captures its stdout.
Any stdout is treated as a **`check` wake**: one line per wake-worthy event.
The contract every check script must honor is therefore:

- **Print one line per event** you want firstmate to wake on.
- **Print NOTHING** when there is nothing to escalate.
- **Finish under `FM_CHECK_TIMEOUT`** (default 30s).

A script that prints a status *report* every cycle (so it always has output)
violates this contract: the watcher dutifully reads the whole report as ~17
events every cycle and floods escalations.
This is exactly the incident `fm-plugin.sh` exists to prevent (see below).

## Add an event source: `bin/fm-plugin.sh`

```
fm-plugin.sh add <script> [--check|--once] [--filter REGEX] [--name NAME]
fm-plugin.sh list [--describe]
fm-plugin.sh check <script> [--check|--once] [--filter REGEX]
fm-plugin.sh disable <name>
fm-plugin.sh enable <name>
```

`add` generates the `state/<name>.check.sh` wrapper for you, correctly.
There are two safe paths, and the CLI refuses to ship a flooding one:

### Report-style script → use `--filter`

A script that always prints a report (e.g. `fm-disk-health.sh --check` prints
disk usage, reclaimable caches, opencode.db growth on every run) must be wrapped
with `--filter REGEX` so only the wake-worthy lines survive.

```sh
bin/fm-plugin.sh add bin/fm-disk-health.sh --check --filter '^ALERT:' --name disk-health
```

The generated wrapper runs `fm-disk-health.sh --check 2>&1 | grep -E -- '^ALERT:' || true`,
so it stays silent while disk usage is below `FM_DISK_ALERT_PCT` and prints the
`ALERT:` line only when the threshold is crossed.

### Natively silent-unless-wake → run it raw

A script that already honors the contract (e.g. `fm-github-watch.sh`, which
prints one line per new PR event and nothing otherwise) needs no filter.
`add` validates it with `check` first and **refuses to create the wrapper** if it
prints on a no-event fixture.

```sh
bin/fm-plugin.sh add bin/fm-github-watch.sh --once --name github-watch
```

### Why `--filter` exists (the cautionary incident)

Before this CLI, check scripts were hand-written.
A real incident wrapped `fm-disk-health.sh --check` (a report) directly as
`state/disk.check.sh`.
The script always prints ~17 status lines; the watcher read all of them as
events every 300s and flooded the escalation buffer.
`fm-plugin.sh check` is the regression guard: it runs the script against an
**empty (no-event) fixture** and fails if it prints.
Run it yourself any time:

```sh
bin/fm-plugin.sh check bin/fm-disk-health.sh --check          # FAILS (report)
bin/fm-plugin.sh check bin/fm-github-watch.sh                 # OK (silent-unless-wake)
```

### `--check` vs `--once`

The mode is the argument the wrapper passes through to your script:

- `--check` — your script's read mode is `--check` (report-style; pair with `--filter`).
- `--once` — your script's read mode is `--once` (one poll; natively silent).
- neither — the script is invoked raw (its own default).

### `disable` / `enable`

`disable <name>` moves the wrapper to `state/.disabled/`, out of the watcher's
`state/*.check.sh` glob, so it stops being swept without being deleted.
`enable <name>` moves it back.

## Make your plugin self-describing (the `--describe` convention)

A plugin run with `--describe` prints `key=value` lines so `fm-plugin.sh list
--describe` can show what it watches and how to wire it:

```sh
#!/usr/bin/env bash
[ "${1:-}" = "--describe" ] && {
  echo 'name=my-linear-inbox'
  echo 'watches=new Linear issues assigned to the team'
  echo 'config_keys=FM_LINEAR_TOKEN FM_LINEAR_TEAM'
  echo 'wake_contract=silent-unless-wake'
  echo 'recommended_wrapper=--once'
  exit 0
}
# ... your silent-unless-wake poll ...
```

Fields:

- `name` — short identifier.
- `watches` — one-line description of what it surfaces.
- `config_keys` — space-separated `FM_*` knobs the script reads.
- `wake_contract` — `silent-unless-wake` (run raw) or `report` (needs `--filter`).
- `recommended_wrapper` — the `add` flags that wire it correctly
  (e.g. `--check --filter ^ALERT:` or `--once`).

`bin/fm-disk-health.sh --describe` and `bin/fm-github-watch.sh --describe` are
the reference implementations.

## Tune the daemon: `bin/fm-config.sh` + `config/daemon.conf`

```
fm-config.sh list                  every knob: name · current · default · description
fm-config.sh get <KEY>             resolve one knob (env > file > default)
fm-config.sh set <KEY> <VALUE>     write KEY into config/daemon.conf (creates it)
```

`config/daemon.conf` is the one sourced config file.
The daemon sources it at startup, so it tunes every `FM_*` knob in one place.
Precedence is **env var > config file > built-in default** (the file uses the
`FM_X=${FM_X:-value}` form, so an explicit env var always wins).

`config/daemon.conf` is **local and gitignored** (like `config/crew-harness`),
so it is never committed and each machine keeps its own.
`fm-config.sh set` creates it on first use; `fm-config.sh list` shows every knob
with its current value, the built-in default (parsed live from the scripts that
define it), and a one-line description — so you never have to grep for a default.

```sh
bin/fm-config.sh list
bin/fm-config.sh set FM_STALE_ESCALATE_SECS 120
bin/fm-config.sh set FM_DISK_ALERT_PCT 80
```

Because the daemon sources the file with exports enabled, knobs read by child
processes are tuned from the same file: `FM_CHECK_INTERVAL` / `FM_CHECK_TIMEOUT`
(read by `fm-watch.sh`), `FM_DISK_ALERT_PCT` (read by a disk-health check
script), and `FM_GH_CONTRIBUTOR` (read by the GitHub watcher) all flow through.

## Reference: wiring the two shipped plugins

```sh
# Disk health: report-style, alert only above threshold.
bin/fm-plugin.sh add bin/fm-disk-health.sh --check --filter '^ALERT:' --name disk-health

# GitHub PRs: natively silent-unless-wake.
bin/fm-plugin.sh add bin/fm-github-watch.sh --once --name github-watch

# See them.
bin/fm-plugin.sh list --describe

# Tune the alert threshold + poll cadence in one file.
bin/fm-config.sh set FM_DISK_ALERT_PCT 80
bin/fm-config.sh set FM_CHECK_INTERVAL 120
```
