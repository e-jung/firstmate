# Away-mode injection wedge alarm - active alert channels

The away-mode sub-supervisor (`bin/fm-supervise-daemon.sh`) buffers escalations and injects them into firstmate's own pane.
When injection cannot confirm a submit past `FM_MAX_DEFER_SECS` (the pane is genuinely busy or wedged, or its Enter is swallowed), `inject_wedge_alarm` raises a loud, rate-limited alarm so the stall never stays invisible.

## Why an active channel beyond the status-line flash

Before this change the only ACTIVE signal `inject_wedge_alarm` sent was a tmux `display-message` status-line flash, guarded by `if [ "$backend" = tmux ]`.
That flash is a client-side OSD with no cross-backend equivalent, so on every non-tmux supervisor backend it was skipped entirely.
On 2026-07-10 a `claude`-on-`herdr` primary wedged past max-defer overnight: the tmux flash was skipped, and only the passive `state/.subsuper-inject-wedged` marker was written.
Nothing surfaces that marker until the next fleet action, so 20 escalations sat buffered for roughly 8.5 hours with no active alert.
The classifier-side half of that incident shipped separately (PR #429); this is the alarm-channel half.

`inject_wedge_alarm` now also calls `wedge_alarm_notify`, a configurable active alert that does not depend on any pane or its backend status-line.
The durable marker and the tmux flash are unchanged; the active alert is added alongside them.

## Channels

`config/wedge-alarm` (local, gitignored) lists channel directives, one per non-empty, non-comment line; every listed non-`off` channel fires, best-effort.
`FM_WEDGE_ALARM_CHANNEL` overrides the file with a single directive (used by the tests).

- `off` - position-independent kill switch that disables every active alert; the marker and tmux flash remain.
- `auto` / `default` - platform default. macOS resolves to `osascript`; other platforms have no built-in OS channel, so `auto` there fires nothing and logs that the durable marker is the only signal (configure a `command:` directive instead).
- `osascript` - a macOS Notification Center banner via `osascript`. OS-level, so it reaches the captain even when every pane and its status-line is unreadable.
- `herdr` - a herdr UI notification via `herdr notification show`. herdr's own surface, separate from the pane and its status-line.
- `command:<cmd>` - run `<cmd>` via `sh -c`, with the alarm summary passed as `$1` and on stdin. Lets the alert reach a phone or pager (ntfy, Slack, SMS) even when the captain is away from the machine entirely.

An absent `config/wedge-alarm` behaves as `auto`, i.e. default-on on macOS.
Default-on is deliberate: the alarm's entire purpose is that a wedged away-mode primary is never silent, so the reachable OS channel fires unless the captain explicitly disables it.
The alarm is rate-limited to at most once per max-defer window, and fires only after a genuine wedge past max-defer, so the default-on banner is rare and never chatty.

Each channel is best-effort: a missing binary or a non-zero exit logs a warning and the alarm falls through to the next channel, never crashing the daemon loop.
Every invocation is also process-group bounded by `FM_WEDGE_ALARM_TIMEOUT_SECS` (10 seconds by default), including `command:`, `osascript`, `herdr`, and an `FM_WEDGE_ALARM_EXEC` override.
On timeout or daemon shutdown, its watchdog terminates the notifier group, logs the timeout when applicable, and continues to the next configured channel.
The AppleScript passes the summary as an `argv` item rather than interpolating it into the script source, so summary text can never break the notification.
See `docs/examples/wedge-alarm` for a copyable starting config.

## Early-wedge triggers (never blind again)

`inject_wedge_alarm` is the SINGLE alarm path for every wake-path failure trigger.
Three distinct triggers feed it, each catching a different failure shape; whichever fires first writes the `state/.subsuper-inject-wedged` marker, and that marker (plus an in-process epoch) is the one dedup window across all three, so two triggers never double-fire within one `FM_MAX_DEFER_SECS` window.
All three are gated on `state/.afk` presence: a strict no-op when away mode is off.
The captain DEFERRED the out-of-band phone/OS alert channel, so every trigger routes only through the existing `wedge_alarm_notify` channels above plus the durable marker - no new notification channel was added.

1. **Max-defer** (the original time-bound trigger): if a buffered escalation stays undelivered past `FM_MAX_DEFER_SECS` (default 300; `0` disables), the daemon retries one normal delivery and, if it still cannot confirm a submit, raises the alarm.

2. **Defer-streak** (count-bound early signal, `FM_DEFER_STREAK_MAX`, default 8; `0` disables): a rising streak of inject deferrals on an IDLE (not-busy) pane is a classifier failure - the exact signature of the U+00A0 / ghost-text incidents, where an idle composer is misread as pending so every flush defers.
   A confirmed delivery or a BUSY-pane defer (the agent is genuinely mid-turn) resets the streak; any other defer (composer guard, unconfirmed submit, gone target) on an away-active daemon increments it.
   When the streak reaches the threshold it raises the same alarm once per deferral episode (a fired sentinel suppresses re-fires as the streak keeps climbing).
   This is the only trigger when `FM_MAX_DEFER_SECS=0`, and it complements max-defer on a count bound instead of a time bound.

3. **Wake-path canary** (`FM_CANARY_INTERVAL_SECS`, default 900; `0` disables): a periodic no-inject probe of the FULL supervisor wake path that is implementation-blind - it catches a broken path regardless of why (the next composer misclassification, a phantom target, a swallowed class the daemon has not met yet).
   On each interval the daemon exercises the same target/busy/composer primitives `inject_msg`'s guard chain uses, but it only READS (it never types or submits, so it cannot inject visible junk into the pane), and classifies:
   - **healthy** - target present AND (the pane is busy, OR the composer is affirmatively empty, meaning an inject would land).
   - **broken** - the target is gone, OR an idle (not-busy) pane has a composer that is NOT affirmatively empty (`pending` = the classifier-wedge signature; `unknown` = a dead shell or unreadable pane).
   On broken it raises the alarm and writes the marker.
   A canary probe runs once at daemon startup (the first housekeeping tick) and then every interval.

## Test safety: no test posts a real notification

Every notifier channel (`osascript`, `herdr`, and `command:`) routes through a single seam, `FM_WEDGE_ALARM_EXEC`: when it is set, the daemon hands the fixed channel category and summary to that command instead of the real notifier (`wedge_alarm_emit` in `bin/fm-supervise-daemon.sh`).
This makes it structurally impossible for a test to post a real desktop notification, and impossible for a future test author to forget to stub:

- The daemon is only ever sourced (not executed) by tests - production `bin/fm-afk-start.sh` execs it.
  Whenever the daemon is sourced, its library-mode guard defaults `FM_WEDGE_ALARM_EXEC` to `discard`, which fires nothing.
  A real daemon a test later spawns inherits that default through the environment.
- `tests/wake-helpers.sh` upgrades the default to an on-disk recorder that logs `<channel>\t<summary>` to `$FM_WEDGE_ALARM_LOG`, so the daemon and wake suites can assert channel selection without any real notifier.
- Production leaves `FM_WEDGE_ALARM_EXEC` unset, so the real channels fire.

Because of this seam, the automated tests verify channel selection and summary propagation only.
The real `osascript`/`herdr` invocation form is verified once by the single bounded manual run below, never from a suite.

## Verification (macOS, darwin)

Recorded 2026-07-10T12:41-0700 on macOS 26.5.2 (build 25F84), `osascript` at `/usr/bin/osascript`, `herdr` 0.7.3.
This is the single bounded manual verification (two invocations, one per OS channel), labelled "FIRSTMATE TEST - IGNORE" so the banners are unmistakably harmless.
These are the only verification commands that fire real notifications, and they are never run inside a test suite.

### osascript channel (the exact argv-safe form the daemon runs)

```
$ /usr/bin/osascript -e 'on run argv' \
    -e 'display notification (item 1 of argv) with title "FIRSTMATE TEST - IGNORE" sound name "Basso"' \
    -e 'end run' "FIRSTMATE TEST - IGNORE (wedge-alarm channel verification)"
$ echo $?
0
```

Exit 0; a Notification Center banner titled "FIRSTMATE TEST - IGNORE" was posted with the label as its body.
In production the title is "firstmate: away-mode escalations WEDGED" and the body is the `<age>s undelivered - see <marker>` summary.

### herdr channel

```
$ herdr notification show "FIRSTMATE TEST - IGNORE" \
    --body "FIRSTMATE TEST - IGNORE (wedge-alarm channel verification)" --sound request
{"id":"cli:notification:show","result":{"reason":"shown","shown":true,"type":"notification_show"}}
$ echo $?
0
```

Exit 0; herdr reported `"shown":true`.
The daemon redirects this stdout to `/dev/null` and treats a zero exit as success.

### command channel dispatch (summary on $1 and stdin)

The `command:` channel runs `sh -c "<cmd>" fm-wedge-alarm "<summary>"` with the summary also piped on stdin.
`test_wedge_alarm_command_channel_receives_summary` deliberately unsets the seam for a safe file-writing command to verify this dispatch contract without a notification.
