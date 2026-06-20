#!/usr/bin/env bash
# Self-triggering supervisor daemon: runs fm-watch.sh in a loop and injects each
# wake reason (signal:/stale:/check:/heartbeat) into the supervisor's tmux pane
# so the supervisor takes a fresh turn even while the captain is idle. This
# closes the chat-mode wake-routing gap (#27): without it, crewmate wakes that
# land between captain messages sit unhandled.
# Usage: fm-supervise-daemon.sh
#          Long-lived background loop. Wraps fm-watch.sh; it does NOT modify it.
#          FM_SUPERVISOR_TARGET sets the supervisor tmux target
#          (session:window or session:window.pane), default firstmate:0.
#          FM_INJECT_SKIP (default "heartbeat") is a |-separated list of
#          reason-prefixes to log-but-NOT-inject (routine heartbeats churn the
#          supervisor's context for a no-op review); actionable signal/stale/
#          check wakes still inject. Empty disables filtering.
#          Logs each wake to state/.supervise-daemon.log (size-capped).
#          Single instance via flock on state/.supervise-daemon.lock. Trapped
#          SIGTERM/SIGINT shut down within ~1s and release the lock so an
#          immediate restart succeeds. A crashing fm-watch.sh is logged and
#          restarted, never killing the daemon; a tight crash-restart spin is
#          detected and backed off.
set -u

FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$FM_ROOT/state"
WATCH="$FM_ROOT/bin/fm-watch.sh"
LOG="$STATE/.supervise-daemon.log"
WATCH_ERR="$STATE/.supervise-daemon.watcher.err"
LOCK="$STATE/.supervise-daemon.lock"
PIDFILE="$STATE/.supervise-daemon.pid"
TARGET="${FM_SUPERVISOR_TARGET:-firstmate:0}"
# Reasons to log but NOT inject. |-separated prefixes; a wake is skipped when its
# reason starts with any listed prefix. Default skips heartbeat (a routine fleet
# review that churns the supervisor's context for a no-op turn). Set empty to
# inject everything, e.g. FM_INJECT_SKIP="".
INJECT_SKIP="${FM_INJECT_SKIP:-heartbeat}"
# Pane-gone / injection-failure backoff: after this many consecutive failed
# injections, sleep INJECT_FAIL_SLEEP before retrying (avoids hot-looping into a
# dead supervisor pane).
INJECT_FAIL_LIMIT=${FM_INJECT_FAIL_LIMIT:-5}
INJECT_FAIL_SLEEP=${FM_INJECT_FAIL_SLEEP:-30}
# Crash-loop guard: more than this many watcher crashes (non-zero/empty reason)
# within CRASH_WINDOW seconds triggers a long backoff instead of a tight spin.
CRASH_THRESHOLD=${FM_CRASH_THRESHOLD:-10}
CRASH_WINDOW=${FM_CRASH_WINDOW:-60}
CRASH_BACKOFF=${FM_CRASH_BACKOFF:-60}
CRASH_NORMAL_SLEEP=${FM_CRASH_SLEEP:-5}
# Log size cap: once the log exceeds LOG_MAX_BYTES, trim it to the last
# LOG_KEEP_LINES (recent context survives) so a long-lived daemon can't grow it
# without bound.
LOG_MAX_BYTES=${FM_LOG_MAX_BYTES:-1048576}
LOG_KEEP_LINES=${FM_LOG_KEEP_LINES:-2000}
mkdir -p "$STATE"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$LOG"; }

# Cap log growth: a long-lived daemon otherwise appends forever. Called after a
# wake is logged; a single size check per wake is negligible vs. the watcher
# cycle. Uses `wc -c` (not `stat -f|-c`) because on Linux `stat -f %z` dumps the
# whole filesystem record to stdout and corrupts the integer comparison - the
# same stat-portability trap as firstmate issue #26.
trim_log() {
  local sz tmp
  sz=$(wc -c < "$LOG" 2>/dev/null) || return 0
  [ "$sz" -ge "$LOG_MAX_BYTES" ] || return 0
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-daemon-log.XXXXXX") || return 0
  tail -n "$LOG_KEEP_LINES" "$LOG" >"$tmp" 2>/dev/null && mv -f "$tmp" "$LOG"
}

# Should this wake be logged-but-not-injected? Compares literal prefixes (no
# regex/glob surprises): a hit means the reason starts with any |-separated
# entry in INJECT_SKIP.
should_skip() {
  local reason=$1 prefix
  [ -n "$INJECT_SKIP" ] || return 1
  local -a prefixes
  IFS='|' read -ra prefixes <<<"$INJECT_SKIP"
  for prefix in "${prefixes[@]}"; do
    [ -n "$prefix" ] || continue
    # ${reason#"$prefix"} strips a leading literal prefix; differs => it matched.
    [ "$reason" != "${reason#"$prefix"}" ] && return 0
  done
  return 1
}

# --- preflight ---------------------------------------------------------------
if [ ! -x "$WATCH" ]; then
  echo "error: watcher not found or not executable: $WATCH" >&2
  exit 1
fi

# Single instance: hold fd 9 for the life of the daemon. Released when the
# process exits (the shutdown trap exits within ~1s, see below), so an immediate
# restart can re-acquire it.
exec 9>"$LOCK"
if ! flock -n 9; then
  echo "error: another fm-supervise-daemon is already running (lock $LOCK held)" >&2
  exit 1
fi
# PID goes to its own file: a fresh open/write/close flushes, whereas writing to
# the long-lived lock fd 9 would sit block-buffered and never reach disk.
echo "$$" > "$PIDFILE"

# Validate the supervisor target at startup: a missing target here is almost
# always a config typo (firstmate starts this daemon only after the supervisor
# pane exists), so fail loudly rather than silently looping. A target that
# DISAPPEARS later (session closed) is handled gracefully by the main loop.
if ! tmux display-message -p -t "$TARGET" '#{pane_id}' >/dev/null 2>&1; then
  echo "error: supervisor target '$TARGET' does not resolve to a tmux pane; set FM_SUPERVISOR_TARGET" >&2
  log "startup failed: target '$TARGET' not found"
  rm -f "$PIDFILE" 2>/dev/null || true
  exit 1
fi

log "daemon starting (pid $$); supervisor target=$TARGET; inject_skip='$INJECT_SKIP'"

# --- shutdown ----------------------------------------------------------------
# Interruptible shutdown is the main robustness fix (#27 restart race). We never
# block in `wait $WATCHER_PID`: bash 3.2 (macOS) defers trapped signals until
# that specific child exits, which can be minutes while fm-watch waits on a
# heartbeat. Instead we poll the child's liveness with short sleeps, so a
# SIGTERM/SIGINT is handled within ~1 tick on every bash version; the trap then
# kills the child, reaps it, removes the pidfile, and exits - releasing the flock
# promptly so an immediate restart succeeds.
WATCHER_PID=""
CUR_TMP=""
cleanup() {
  trap - TERM INT
  if [ -n "${WATCHER_PID:-}" ]; then
    kill "$WATCHER_PID" 2>/dev/null || true
    wait "$WATCHER_PID" 2>/dev/null || true
  fi
  if [ -n "${CUR_TMP:-}" ]; then
    rm -f "$CUR_TMP" 2>/dev/null || true
  fi
  rm -f "$PIDFILE" 2>/dev/null || true
  log "daemon shutting down"
  exit 0
}
trap cleanup TERM INT

# --- crash-loop guard (#6) ---------------------------------------------------
# Record watcher crashes and decide how long to back off. More than
# CRASH_THRESHOLD crashes within CRASH_WINDOW seconds means fm-watch is failing
# fast (e.g. an environment break), so we back off hard instead of tight-looping
# restarts. The window resets once the threshold trips.
crash_times=()
backoff_secs=$CRASH_NORMAL_SLEEP
record_crash() {
  local now t
  now=$(date +%s)
  local -a keep=()
  if [ "${#crash_times[@]}" -gt 0 ]; then
    for t in "${crash_times[@]}"; do
      [ $((now - t)) -lt "$CRASH_WINDOW" ] && keep+=("$t")
    done
  fi
  keep+=("$now")
  crash_times=("${keep[@]}")
  if [ "${#crash_times[@]}" -gt "$CRASH_THRESHOLD" ]; then
    log "ERROR: watcher crashed ${#crash_times[@]} times within ${CRASH_WINDOW}s; backing off ${CRASH_BACKOFF}s to avoid a tight crash-restart spin"
    crash_times=()
    backoff_secs=$CRASH_BACKOFF
  else
    backoff_secs=$CRASH_NORMAL_SLEEP
  fi
}

# --- injection ---------------------------------------------------------------
# Inject a wake into the supervisor pane. Returns 0 on success, non-zero if the
# pane is gone or send-keys failed (caller backs off; consecutive failures trip
# INJECT_FAIL_LIMIT). Gating here means a missing pane never consumes the wake
# either: the watcher is only run when the pane is alive (see main loop).
inject_wake() {
  local reason=$1 msg
  if ! tmux display-message -p -t "$TARGET" '#{pane_id}' >/dev/null 2>&1; then
    return 1
  fi
  msg="Supervisor wake: $reason. Read state/*.status + handle, then ensure fm-watch.sh is running."
  if tmux send-keys -t "$TARGET" -l "$msg" 2>>"$LOG"; then
    sleep 0.3
    if tmux send-keys -t "$TARGET" Enter 2>>"$LOG"; then
      return 0
    fi
  fi
  return 1
}

# --- main loop ---------------------------------------------------------------
inject_fail=0
while true; do
  # (#3) If the supervisor pane is gone (session closed/restarted), don't crash
  # or hot-loop, and do NOT run the watcher: fm-watch marks a signal "seen"
  # before it exits, so running it with no pane to inject into would swallow the
  # wake forever. Back off and keep retrying until the pane reappears, at which
  # point pending wakes flow normally.
  if ! tmux display-message -p -t "$TARGET" '#{pane_id}' >/dev/null 2>&1; then
    log "warn: supervisor target '$TARGET' gone; backing off ${INJECT_FAIL_SLEEP}s, will retry"
    inject_fail=0
    sleep "$INJECT_FAIL_SLEEP"
    continue
  fi

  CUR_TMP=$(mktemp "${TMPDIR:-/tmp}/fm-watch.XXXXXX") || {
    log "error: mktemp failed; retrying in 5s"
    sleep 5
    continue
  }
  # Run the watcher as a child so SIGTERM/SIGINT can interrupt a long block (a
  # heartbeat wake can wait up to FM_HEARTBEAT_MAX). Capture its one-line wake
  # reason from stdout; stderr goes to a separate file (watcher diagnostics,
  # e.g. a crash trace) so this daemon's wake log stays readable.
  # 9>&- is load-bearing: fd 9 is the flock we hold for single-instance. Without
  # closing it here the watcher (and its own `sleep` grandchildren) would inherit
  # the lock fd, so after this daemon exits its orphaned descendants would keep
  # the lock held for as long as they live - defeating the fast-restart property
  # the shutdown trap above guarantees. Closing it in the child means the daemon
  # process is the SOLE holder of fd 9, so the lock releases the instant it exits.
  "$WATCH" >"$CUR_TMP" 2>>"$WATCH_ERR" 9>&- &
  WATCHER_PID=$!
  # Poll the child in short ticks rather than `wait $WATCHER_PID`: see the
  # shutdown trap comment. Bounded delay (<= sleep tick) on every bash version.
  while kill -0 "$WATCHER_PID" 2>/dev/null; do
    sleep 1
  done
  if wait "$WATCHER_PID"; then
    rc=0
  else
    rc=$?
  fi
  WATCHER_PID=""
  reason=$(<"$CUR_TMP")
  rm -f "$CUR_TMP"
  CUR_TMP=""

  # (#6) A crash (non-zero or empty reason) is logged; the watcher is restarted,
  # never killing the daemon. record_crash backs off hard if it's spinning.
  if [ "$rc" -ne 0 ] || [ -z "$reason" ]; then
    record_crash
    log "watcher exited rc=$rc reason='$reason'; restarting after ${backoff_secs}s"
    sleep "$backoff_secs"
    continue
  fi

  log "wake: $reason"

  # (#2) Skip injection for filtered reasons (default: heartbeat). Still logged
  # above so the wake is observable; we just don't spend a supervisor turn on it.
  if should_skip "$reason"; then
    log "wake skipped (matches FM_INJECT_SKIP): $reason"
    trim_log
    continue
  fi

  # Storm-safe: the watcher already coalesces signals within its grace window,
  # so exactly one injection per watcher exit is correct. (#4) On failure, back
  # off so we don't hot-loop send-keys into a dying pane.
  if inject_wake "$reason"; then
    inject_fail=0
  else
    inject_fail=$((inject_fail + 1))
    if [ "$inject_fail" -ge "$INJECT_FAIL_LIMIT" ]; then
      log "warn: injection failed $inject_fail times in a row; backing off ${INJECT_FAIL_SLEEP}s"
      inject_fail=0
      sleep "$INJECT_FAIL_SLEEP"
    else
      log "warn: injection failed for target '$TARGET' (attempt $inject_fail/$INJECT_FAIL_LIMIT)"
      sleep 1
    fi
  fi
  trim_log
done
