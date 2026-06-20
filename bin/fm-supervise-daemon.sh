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
#          Logs each wake to state/.supervise-daemon.log. Single instance via
#          flock on state/.supervise-daemon.lock. Trapped SIGTERM/SIGINT for a
#          clean shutdown; a crashing fm-watch.sh is logged and restarted, never
#          killing the daemon.
set -u

FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$FM_ROOT/state"
WATCH="$FM_ROOT/bin/fm-watch.sh"
LOG="$STATE/.supervise-daemon.log"
WATCH_ERR="$STATE/.supervise-daemon.watcher.err"
LOCK="$STATE/.supervise-daemon.lock"
PIDFILE="$STATE/.supervise-daemon.pid"
TARGET="${FM_SUPERVISOR_TARGET:-firstmate:0}"
mkdir -p "$STATE"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$LOG"; }

# --- preflight ---------------------------------------------------------------
if [ ! -x "$WATCH" ]; then
  echo "error: watcher not found or not executable: $WATCH" >&2
  exit 1
fi

# Single instance: hold fd 9 for the life of the daemon.
exec 9>"$LOCK"
if ! flock -n 9; then
  echo "error: another fm-supervise-daemon is already running (lock $LOCK held)" >&2
  exit 1
fi
# PID goes to its own file: a fresh open/write/close flushes, whereas writing to
# the long-lived lock fd 9 would sit block-buffered and never reach disk.
echo "$$" > "$PIDFILE"

# Validate the supervisor target exists and resolves to a pane (works for
# session, session:window, session:window.pane, and bare pane-id forms).
if ! tmux display-message -p -t "$TARGET" '#{pane_id}' >/dev/null 2>&1; then
  echo "error: supervisor target '$TARGET' does not resolve to a tmux pane; set FM_SUPERVISOR_TARGET" >&2
  log "startup failed: target '$TARGET' not found"
  exit 1
fi

log "daemon starting (pid $$); supervisor target=$TARGET"

# --- shutdown ----------------------------------------------------------------
WATCHER_PID=""
CUR_TMP=""
cleanup() {
  trap - TERM INT
  if [ -n "${WATCHER_PID:-}" ]; then
    kill "$WATCHER_PID" 2>/dev/null || true
  fi
  if [ -n "${CUR_TMP:-}" ]; then
    rm -f "$CUR_TMP" 2>/dev/null || true
  fi
  rm -f "$PIDFILE" 2>/dev/null || true
  log "daemon shutting down"
  exit 0
}
trap cleanup TERM INT

# --- main loop ---------------------------------------------------------------
while true; do
  CUR_TMP=$(mktemp "${TMPDIR:-/tmp}/fm-watch.XXXXXX") || {
    log "error: mktemp failed; retrying in 5s"
    sleep 5
    continue
  }
  # Run the watcher as a child so SIGTERM/SIGINT can interrupt a long block
  # (a heartbeat wake can wait up to FM_HEARTBEAT_MAX). Capture its one-line
  # wake reason from stdout; stderr goes to a separate file (watcher diagnostics,
  # e.g. a crash trace) so this daemon's wake log stays readable.
  "$WATCH" >"$CUR_TMP" 2>>"$WATCH_ERR" &
  WATCHER_PID=$!
  if wait "$WATCHER_PID"; then
    rc=0
  else
    rc=$?
  fi
  WATCHER_PID=""
  reason=$(<"$CUR_TMP")
  rm -f "$CUR_TMP"
  CUR_TMP=""

  # Robustness: a crash (non-zero or empty reason) is logged and the watcher is
  # simply restarted. The daemon never dies on a watcher failure.
  if [ "$rc" -ne 0 ] || [ -z "$reason" ]; then
    log "watcher exited rc=$rc reason='$reason'; restarting after 5s"
    sleep 5
    continue
  fi

  log "wake: $reason"

  # Storm-safe: the watcher already coalesces signals within its grace window,
  # so exactly one injection per watcher exit is correct. Inject the wake reason
  # so opencode takes a fresh supervisor turn.
  msg="Supervisor wake: $reason. Read state/*.status + handle, then ensure fm-watch.sh is running."
  if tmux send-keys -t "$TARGET" -l "$msg" 2>>"$LOG"; then
    sleep 0.3
    tmux send-keys -t "$TARGET" Enter 2>>"$LOG" || log "warn: send-keys Enter failed for target $TARGET"
  else
    log "warn: send-keys failed for target $TARGET (watcher will keep running)"
  fi
done
