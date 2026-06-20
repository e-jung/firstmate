#!/usr/bin/env bash
# fm-supervise-daemon.sh — #29-aware sub-supervisor (closes #27's P2; P3 deferred).
#
# Wraps bin/fm-watch.sh: runs it as a child, classifies each wake reason, and
# either SELF-HANDLES the routine majority in bash (no firstmate turn) or
# ESCALATES a batched, distilled digest to the supervisor pane on
# captain-relevant events only. This is the token-efficient replacement for the
# prior always-inject daemon: routine signal/stale/heartbeat wakes cost zero
# firstmate context; only done/needs-decision/blocked/failed/persistent-wedge/
# check-output events reach the LLM, and even then as one pre-read digest per
# batch window.
#
# Reliability model (see AGENTS.md §8 and the scout report
# data/fm-supervision-tokens-s9/report.md):
#   - Nothing is lost: the #29 watcher enqueues every wake to state/.wake-queue
#     BEFORE advancing its suppression markers, so a crash/restart/missed
#     injection is recovered on the next fm-wake-drain.sh. The daemon does not
#     touch the queue; it only reads the watcher's stdout reason.
#   - Fail-safe-to-escalate: any wake the classifier cannot confidently mark
#     routine is escalated.
#   - Bounded wedge latency: a stale pane is escalated only after it has been
#     idle for STALE_ESCALATE_SECS (configurable), rechecked once. A wedged
#     crewmate is therefore detected within STALE_ESCALATE_SECS + a tick, never
#     lost. Crewmates are autonomous, so a delayed stale response does not stall
#     a healthy crewmate's own progress.
#   - Cheap heartbeat catch-all: every HEARTBEAT_SCAN_SECS the daemon greps all
#     state/*.status for a captain-relevant line the per-wake classifier might
#     have missed (e.g. a status verb outside CAPTAIN_RE) and escalates it.
#
# The robustness shell from the prior always-inject version is preserved:
# single-instance flock, crash-loop backoff, pane-gone guard, and a
# signal-trapped shutdown that flushes buffered escalations before exit.
#
# Usage: fm-supervise-daemon.sh
#          Long-lived background loop. Env knobs:
#          FM_SUPERVISOR_TARGET     supervisor tmux target (default firstmate:0)
#          FM_INJECT_SKIP           |-prefixes force-self-handle bypassing
#                                   classification (default "heartbeat"); empty
#                                   disables. Use sparingly: it overrides the
#                                   captain-relevant escalation for matching
#                                   kinds.
#          FM_STALE_ESCALATE_SECS   idle seconds before a stale pane escalates
#                                   as a possible wedge (default 240)
#          FM_ESCALATE_BATCH_SECS   buffer window for batched escalation
#                                   digests; 0 = flush immediately (default 90)
#          FM_HEARTBEAT_SCAN_SECS   cadence for the catch-all status scan
#                                   (default 300)
#          FM_HOUSEKEEPING_TICK     seconds between housekeeping passes while
#                                   the watcher is mid-cycle (default 15)
#          FM_BUSY_REGEX            OR-ed busy signatures (mirrors fm-watch.sh)
#          FM_LOG_MAX_BYTES / FM_LOG_KEEP_LINES / FM_CRASH_*  log + crash guards
#          FM_STATE_OVERRIDE        alternate state dir (testing)
#          Logs each wake to state/.supervise-daemon.log (size-capped). Single
#          instance via flock on state/.supervise-daemon.lock. Trapped
#          SIGTERM/SIGINT shut down within ~1s, flush escalations, release the
#          lock. A crashing fm-watch.sh is logged and restarted, never killing
#          the daemon; a tight crash-restart spin is detected and backed off.
set -u

FM_DAEMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- tunables ---------------------------------------------------------------
FM_SUPERVISOR_TARGET_DEFAULT="firstmate:0"
INJECT_SKIP_DEFAULT="heartbeat"
STALE_ESCALATE_SECS_DEFAULT=240
ESCALATE_BATCH_SECS_DEFAULT=90
HEARTBEAT_SCAN_SECS_DEFAULT=300
HOUSEKEEPING_TICK_DEFAULT=15
# Busy signatures per harness (mirror fm-watch.sh). claude/codex: "esc to
# interrupt"; opencode: "esc interrupt"; pi: "Working...".
BUSY_REGEX_DEFAULT='esc (to )?interrupt|Working\.\.\.'
CAPTAIN_RE_DEFAULT='done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged'
INJECT_FAIL_SLEEP_DEFAULT=30
CRASH_THRESHOLD_DEFAULT=10
CRASH_WINDOW_DEFAULT=60
CRASH_BACKOFF_DEFAULT=60
CRASH_NORMAL_SLEEP_DEFAULT=5
LOG_MAX_BYTES_DEFAULT=1048576
LOG_KEEP_LINES_DEFAULT=2000

# Resolve the effective state dir. FM_STATE_OVERRIDE wins (testing); otherwise
# $FM_ROOT/state, computed in fm_super_main. Kept as a function so the pure
# classifiers can take an explicit state arg without depending on globals.
_state_root() { printf '%s' "${FM_STATE_OVERRIDE:-${FM_ROOT:-$FM_DAEMON_DIR/..}/state}"; }

# --- portable stat (same trap as fm-watch.sh: no `stat -f || stat -c`) -------
if [ "$(uname)" = Darwin ]; then
  _stat_file_mtime() { stat -f %m "$1" 2>/dev/null; }
else
  _stat_file_mtime() { stat -c %Y "$1" 2>/dev/null; }
fi
_now() { date +%s; }
_file_age() {  # seconds since mtime; very large if missing
  local f=$1 m
  m=$(_stat_file_mtime "$f") || { echo 999999; return; }
  echo $(( $(_now) - m ))
}

_hash_text() {
  if command -v md5 >/dev/null 2>&1; then printf '%s' "$1" | md5 -q
  else printf '%s' "$1" | md5sum | cut -d ' ' -f1; fi
}

# --- classification helpers (PURE: no side effects, testable) ---------------
# Return the last non-blank line of a status file (empty if missing/blank).
last_status_line() {
  local f=$1
  [ -e "$f" ] || return 0
  grep -v '^[[:space:]]*$' "$f" 2>/dev/null | tail -1
}

# 0 if the given (last) status line matches a captain-relevant verb.
status_is_captain_relevant() {
  local line=$1
  [ -n "$line" ] || return 1
  printf '%s' "$line" | grep -qiE "${FM_CAPTAIN_RE:-$CAPTAIN_RE_DEFAULT}"
}

# task id from a tmux window name "<session>:fm-<id>" -> "<id>"
window_to_task() {
  local w=$1 t
  t="${w##*:}"; t="${t#fm-}"; printf '%s' "$t"
}

# Decision protocol: every classifier prints exactly one line on stdout of the
# form "<action>|<distilled>" where action is "self" or "escalate". The distilled
# field for "self" is informational (logged); for "escalate" it is the pre-read
# summary firstmate would otherwise have to re-read.

classify_signal() {  # <reason-after-colon> <state>
  local reason=$1 state=$2 f last distilled="" rel=""
  for f in $reason; do
    [ -e "$f" ] || continue
    last=$(last_status_line "$f")
    [ -n "$last" ] || continue
    distilled="${distilled}$(basename "$f"): ${last} | "
    status_is_captain_relevant "$last" && rel=1
  done
  # strip a trailing " | " separator so the distilled line is clean
  distilled="${distilled% | }"
  if [ -n "$rel" ]; then printf 'escalate|%s' "$distilled"
  else printf 'self|routine signal: %s' "$distilled"; fi
}

# classify_stale decides the WAKE itself (one-shot per distinct hash). On a
# first sight of a non-terminal stale it returns "self" and the caller records a
# timestamp marker; persistence is escalated by housekeeping's recheck, not here.
classify_stale() {  # <window> <state>
  local win=$1 state=$2 task last
  task=$(window_to_task "$win")
  last=$(last_status_line "$state/$task.status")
  if [ -n "$last" ] && status_is_captain_relevant "$last"; then
    printf 'escalate|stale + terminal status: %s' "$last"
    return
  fi
  # Non-terminal (or no status): defer to the persistence recheck. The caller
  # records/refreshes the stale marker so housekeeping can age it.
  printf 'self|transient stale (%s): %s' "$win" "${last:-no status}"
}

classify_check() {  # <full reason>  — check scripts print only when firstmate should wake
  printf 'escalate|%s' "$1"
}

classify_heartbeat() {
  # The wake itself is routine; the catch-all scan runs separately in
  # housekeeping on the HEARTBEAT_SCAN_SECS cadence.
  printf 'self|heartbeat (catch-all scan runs in housekeeping)'
}

# Anything unrecognized is escalated (fail-safe).
classify_unknown() {  # <reason>
  printf 'escalate|unknown wake: %s' "$1"
}

# --- stale marker + escalation buffer (stateful, but via explicit state dir) -
# Marker:   state/.subsuper-stale-<key>   contains the epoch first seen idle.
# Buffer:   state/.subsuper-escalations    one distilled line per escalation.
# Seen:     state/.subsuper-seen-status-<task>  last status line the scan
#           escalated, so the catch-all does not re-fire the same terminal.

_stale_key() { printf '%s' "$1" | tr ':/.' '___'; }

stale_marker_record() {  # <window> <state>  — create if absent
  local win=$1 state=$2 key marker
  key=$(_stale_key "$(window_to_task "$win")")
  marker="$state/.subsuper-stale-$key"
  [ -e "$marker" ] || _now > "$marker"
}

stale_marker_remove() {  # <window> <state>
  local win=$1 state=$2 key
  key=$(_stale_key "$(window_to_task "$win")")
  rm -f "$state/.subsuper-stale-$key"
}

# 0 if the pane is currently showing a busy signature (crewmate resumed/working).
pane_is_busy() {  # <window>
  local win=$1 tail40
  tail40=$(tmux capture-pane -p -t "$win" -S -40 2>/dev/null) || return 1
  printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -6 \
    | grep -qiE "${FM_BUSY_REGEX:-$BUSY_REGEX_DEFAULT}"
}

escalate_add() {  # <state> <distilled-item>
  local state=$1 item=$2 buf
  buf="$state/.subsuper-escalations"
  [ -s "$buf" ] || _now > "${buf}.since"
  printf '%s\n' "$item" >> "$buf"
}

# Flush the escalation buffer as ONE batched digest to the supervisor pane.
# Returns 0 on successful inject (or empty buffer), non-zero on inject failure.
escalate_flush() {  # <state>
  local state=$1 buf item n msg
  buf="$state/.subsuper-escalations"
  [ -s "$buf" ] || return 0
  n=$(wc -l < "$buf" 2>/dev/null || echo 0)
  # Join buffered items with the literal " | " separator into one digest line.
  msg=$(awk 'NR>1{printf " | "} {printf "%s",$0} END{print ""}' "$buf" 2>/dev/null)
  msg=$(printf 'Supervisor escalate (%s event(s), batched):\n%s\nStatus pre-read by sub-supervisor. Re-arm not needed (watcher is daemon-managed).' "$n" "$msg")
  if inject_msg "$msg"; then : > "$buf"; rm -f "${buf}.since"; return 0; fi
  return 1
}

_oldest_line_age() {  # <buf> -> seconds since the oldest buffered item first arrived (sidecar epoch)
  local f=$1 since
  [ -s "$f" ] || { echo 999999; return; }
  since="${f}.since"
  if [ -r "$since" ]; then
    echo $(( $(_now) - $(cat "$since" 2>/dev/null || echo 0) ))
  else
    echo 999999
  fi
}

# --- housekeeping (runs every tick while the watcher is mid-cycle) ----------
# Three cheap jobs, each guarded so an empty/quiet fleet costs near zero:
#  1) batch flush: if the escalation buffer's oldest content is older than
#     ESCALATE_BATCH_SECS (or batching is disabled), inject one digest.
#  2) stale recheck: for each pending stale marker past STALE_ESCALATE_SECS,
#     re-peek the pane; still idle -> escalate (wedge); resumed -> clear marker.
#  3) heartbeat scan: every HEARTBEAT_SCAN_SECS, grep state/*.status for a
#     captain-relevant line the per-wake classifier missed and escalate it.
housekeeping() {  # <state>
  local state=$1 now due f key task win marker age last
  now=$(_now)

  # (1) batch flush
  if [ "${FM_ESCALATE_BATCH_SECS:-$ESCALATE_BATCH_SECS_DEFAULT}" -le 0 ]; then
    escalate_flush "$state" || true
  else
    due=$(_oldest_line_age "$state/.subsuper-escalations")
    if [ "$due" -ge "${FM_ESCALATE_BATCH_SECS:-$ESCALATE_BATCH_SECS_DEFAULT}" ]; then
      escalate_flush "$state" || true
    fi
  fi

  # (2) stale persistence recheck
  for marker in "$state"/.subsuper-stale-*; do
    [ -e "$marker" ] || continue
    key="${marker##*.subsuper-stale-}"
    age=$(( now - $(cat "$marker" 2>/dev/null || echo "$now") ))
    [ "$age" -ge "${FM_STALE_ESCALATE_SECS:-$STALE_ESCALATE_SECS_DEFAULT}" ] || continue
    # Reconstruct the window name from the key (best-effort: session is unknown,
    # so probe the live fm-* windows for one whose task matches).
    win=$(window_for_task "$key" 2>/dev/null || true)
    if [ -z "$win" ]; then
      # Window gone (task torn down): drop the marker, nothing to escalate.
      rm -f "$marker"; continue
    fi
    if pane_is_busy "$win"; then
      rm -f "$marker"   # crewmate resumed: benign
    else
      escalate_add "$state" "stale persisted ${age}s (possible wedge): $win"
      stale_marker_remove "$win" "$state"
    fi
  done

  # (3) heartbeat scan (catch-all for a captain-relevant status the per-wake
  #     classifier may have missed). Cheap: status files only, no tmux.
  if [ "$(_file_age "$state/.subsuper-last-scan")" -ge "${FM_HEARTBEAT_SCAN_SECS:-$HEARTBEAT_SCAN_SECS_DEFAULT}" ]; then
    _now > "$state/.subsuper-last-scan"
    for f in "$state"/*.status; do
      [ -e "$f" ] || continue
      last=$(last_status_line "$f")
      status_is_captain_relevant "$last" || continue
      task=$(basename "$f"); task="${task%.status}"
      local seen
      seen="$state/.subsuper-seen-status-$(_stale_key "$task")"
      [ "$(cat "$seen" 2>/dev/null || true)" = "$last" ] && continue
      escalate_add "$state" "$(basename "$f"): $last (catch-all scan)"
      printf '%s' "$last" > "$seen"
    done
  fi
}

# Find a live fm-* window whose task id matches the given marker key.
window_for_task() {  # <task-key>
  local key=$1 w t
  for w in $(tmux list-windows -a -F '#{session_name}:#{window_name}' 2>/dev/null | grep ':fm-' || true); do
    t=$(window_to_task "$w")
    [ "$(_stale_key "$t")" = "$key" ] && { printf '%s' "$w"; return 0; }
  done
  return 1
}

# --- injection --------------------------------------------------------------
inject_msg() {  # <message>  -> 0 ok, non-zero if pane gone / send-keys failed
  local msg=$1
  if ! tmux display-message -p -t "${FM_SUPERVISOR_TARGET:-$FM_SUPERVISOR_TARGET_DEFAULT}" '#{pane_id}' >/dev/null 2>&1; then
    return 1
  fi
  if tmux send-keys -t "${FM_SUPERVISOR_TARGET:-$FM_SUPERVISOR_TARGET_DEFAULT}" -l "$msg" 2>/dev/null; then
    sleep 0.3
    if tmux send-keys -t "${FM_SUPERVISOR_TARGET:-$FM_SUPERVISOR_TARGET_DEFAULT}" Enter 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}

# --- INJECT_SKIP prefix match (literal prefixes, no regex) ------------------
should_force_self() {  # <reason>
  local reason=$1 skip="${FM_INJECT_SKIP:-$INJECT_SKIP_DEFAULT}" prefix
  [ -n "$skip" ] || return 1
  local -a prefixes
  IFS='|' read -ra prefixes <<<"$skip"
  for prefix in "${prefixes[@]}"; do
    [ -n "$prefix" ] || continue
    [ "$reason" != "${reason#"$prefix"}" ] && return 0
  done
  return 1
}

# --- dispatch one wake reason to self-handle or escalate --------------------
# Side effects: logging, marker records, escalation buffer appends.
handle_wake() {  # <reason> <state>
  local reason=$1 state=$2 decision action distilled
  if should_force_self "$reason"; then
    log "wake force-self (FM_INJECT_SKIP): $reason"
    return
  fi
  case "$reason" in
    signal:*) decision=$(classify_signal "${reason#signal: }" "$state") ;;
    stale:*)  stale_marker_record "${reason#stale: }" "$state"
              decision=$(classify_stale "${reason#stale: }" "$state") ;;
    check:*)  decision=$(classify_check "$reason") ;;
    heartbeat|heartbeat:*) decision=$(classify_heartbeat) ;;
    *)        decision=$(classify_unknown "$reason") ;;
  esac
  action=${decision%%|*}
  distilled=${decision#*|}
  if [ "$action" = "escalate" ]; then
    log "escalate: $reason -> $distilled"
    escalate_add "$state" "$distilled"
    [ "${FM_ESCALATE_BATCH_SECS:-$ESCALATE_BATCH_SECS_DEFAULT}" -le 0 ] && { escalate_flush "$state" || true; }
  else
    log "self-handle: $reason -> $distilled"
  fi
}

# --- log --------------------------------------------------------------------
# Uses LOG set by fm_super_main; harmless no-op-ish if unset (tests source fns
# directly and pass state explicitly, so they do not call log).
log() { [ -n "${LOG:-}" ] && printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$LOG"; }

trim_log() {
  local sz tmp
  [ -n "${LOG:-}" ] || return 0
  sz=$(wc -c < "$LOG" 2>/dev/null) || return 0
  [ "$sz" -ge "${FM_LOG_MAX_BYTES:-$LOG_MAX_BYTES_DEFAULT}" ] || return 0
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-daemon-log.XXXXXX") || return 0
  tail -n "${FM_LOG_KEEP_LINES:-$LOG_KEEP_LINES_DEFAULT}" "$LOG" >"$tmp" 2>/dev/null && mv -f "$tmp" "$LOG"
}

# ============================================================================
# Everything below runs only when the script is EXECUTED, not sourced. The pure
# classifiers above are sourceable for unit tests (tests/fm-wake-queue.test.sh).
# ============================================================================

fm_super_main() {
  FM_ROOT="$(cd "$FM_DAEMON_DIR/.." && pwd)"
  local STATE
  STATE="$(_state_root)"
  mkdir -p "$STATE"

  local WATCH="$FM_DAEMON_DIR/fm-watch.sh"
  local LOG="$STATE/.supervise-daemon.log"
  local WATCH_ERR="$STATE/.supervise-daemon.watcher.err"
  local LOCK="$STATE/.supervise-daemon.lock"
  local PIDFILE="$STATE/.supervise-daemon.pid"
  local TARGET="${FM_SUPERVISOR_TARGET:-$FM_SUPERVISOR_TARGET_DEFAULT}"
  local INJECT_FAIL_SLEEP=${FM_INJECT_FAIL_SLEEP:-$INJECT_FAIL_SLEEP_DEFAULT}
  local CRASH_THRESHOLD=${FM_CRASH_THRESHOLD:-$CRASH_THRESHOLD_DEFAULT}
  local CRASH_WINDOW=${FM_CRASH_WINDOW:-$CRASH_WINDOW_DEFAULT}
  local CRASH_BACKOFF=${FM_CRASH_BACKOFF:-$CRASH_BACKOFF_DEFAULT}
  local CRASH_NORMAL_SLEEP=${FM_CRASH_SLEEP:-$CRASH_NORMAL_SLEEP_DEFAULT}

  [ -x "$WATCH" ] || { echo "error: watcher not found or not executable: $WATCH" >&2; exit 1; }

  # --- single instance (fd 9 flock) ----------------------------------------
  exec 9>"$LOCK"
  if ! flock -n 9; then
    echo "error: another fm-supervise-daemon is already running (lock $LOCK held)" >&2
    exit 1
  fi
  echo "$$" > "$PIDFILE"

  # --- validate supervisor target at startup (a missing target is a typo) ---
  if ! tmux display-message -p -t "$TARGET" '#{pane_id}' >/dev/null 2>&1; then
    echo "error: supervisor target '$TARGET' does not resolve to a tmux pane; set FM_SUPERVISOR_TARGET" >&2
    log "startup failed: target '$TARGET' not found"
    rm -f "$PIDFILE" 2>/dev/null || true
    exit 1
  fi

  log "daemon starting (pid $$); target=$TARGET; inject_skip='${FM_INJECT_SKIP:-$INJECT_SKIP_DEFAULT}'; stale_escalate=${FM_STALE_ESCALATE_SECS:-$STALE_ESCALATE_SECS_DEFAULT}s; batch=${FM_ESCALATE_BATCH_SECS:-$ESCALATE_BATCH_SECS_DEFAULT}s"

  # --- shutdown: flush buffered escalations, reap child, release lock -------
  local WATCHER_PID="" CUR_TMP=""
  cleanup() {
    trap - TERM INT
    escalate_flush "$STATE" 2>/dev/null || true
    if [ -n "${WATCHER_PID:-}" ]; then
      kill "$WATCHER_PID" 2>/dev/null || true
      wait "$WATCHER_PID" 2>/dev/null || true
    fi
    [ -n "${CUR_TMP:-}" ] && rm -f "$CUR_TMP" 2>/dev/null || true
    rm -f "$PIDFILE" 2>/dev/null || true
    log "daemon shutting down"
    exit 0
  }
  trap cleanup TERM INT

  # --- crash-loop guard -----------------------------------------------------
  local crash_times=() backoff_secs=$CRASH_NORMAL_SLEEP
  record_crash() {
    local now t
    now=$(_now)
    local -a keep=()
    for t in "${crash_times[@]:-}"; do
      [ -n "$t" ] && [ $((now - t)) -lt "$CRASH_WINDOW" ] && keep+=("$t")
    done
    keep+=("$now")
    crash_times=("${keep[@]}")
    if [ "${#crash_times[@]}" -gt "$CRASH_THRESHOLD" ]; then
      log "ERROR: watcher crashed ${#crash_times[@]} times within ${CRASH_WINDOW}s; backing off ${CRASH_BACKOFF}s"
      crash_times=()
      backoff_secs=$CRASH_BACKOFF
    else
      backoff_secs=$CRASH_NORMAL_SLEEP
    fi
  }

  start_watcher() {
    CUR_TMP=$(mktemp "${TMPDIR:-/tmp}/fm-watch.XXXXXX") || { log "error: mktemp failed; retrying in 5s"; sleep 5; return 1; }
    # 9>&- closes the flock fd in the child so orphaned grandchildren cannot
    # outlive the daemon and hold the lock (same property as the prior daemon).
    "$WATCH" >"$CUR_TMP" 2>>"$WATCH_ERR" 9>&- &
    WATCHER_PID=$!
  }

  local rc reason
  while true; do
    # --- pane-gone guard (preserved) ---------------------------------------
    # With the #29 watcher's enqueue-before-suppress, a wake is no longer
    # swallowed by running the watcher with no injection target. We still back
    # off while the pane is gone: self-handling needs no pane, but escalation
    # has nowhere to go, and firstmate itself is the consumer of escalations.
    # Catch-up signals persist in state/*.status and flow on the next run, so
    # this delays rather than loses work.
    if ! tmux display-message -p -t "$TARGET" '#{pane_id}' >/dev/null 2>&1; then
      log "warn: supervisor target '$TARGET' gone; backing off ${INJECT_FAIL_SLEEP}s, will retry"
      # Flush is pointless with no pane; preserve any buffered escalations.
      sleep "$INJECT_FAIL_SLEEP"
      continue
    fi

    # --- (re)start watcher if it has exited --------------------------------
    if [ -z "${WATCHER_PID:-}" ] || ! kill -0 "${WATCHER_PID:-}" 2>/dev/null; then
      if [ -n "${WATCHER_PID:-}" ]; then
        # child exited: reap + classify its wake reason
        if wait "${WATCHER_PID}"; then rc=0; else rc=$?; fi
        reason=""
        [ -n "${CUR_TMP:-}" ] && [ -e "${CUR_TMP:-}" ] && reason=$(<"${CUR_TMP}")
        [ -n "${CUR_TMP:-}" ] && rm -f "${CUR_TMP}" 2>/dev/null || true
        CUR_TMP=""
        if [ "$rc" -ne 0 ] || [ -z "$reason" ]; then
          record_crash
          log "watcher exited rc=$rc reason='$reason'; restarting after ${backoff_secs}s"
          WATCHER_PID=""
          sleep "$backoff_secs"
          continue
        fi
        log "wake: $reason"
        handle_wake "$reason" "$STATE"
        trim_log
      fi
      start_watcher || continue
    fi

    # --- one housekeeping tick (gated to HOUSEKEEPING_TICK), then poll -------
    # The watcher child runs on its own FM_POLL cadence internally; we only need
    # to detect its exit (the kill -0 above) promptly and run housekeeping often
    # enough that batch flushes, stale rechecks, and the catch-all scan fire on
    # cadence. Gating keeps a large fleet cheap between ticks.
    sleep 1
    if [ "$(_file_age "$STATE/.subsuper-last-housekeep")" -ge "${FM_HOUSEKEEPING_TICK:-$HOUSEKEEPING_TICK_DEFAULT}" ]; then
      _now > "$STATE/.subsuper-last-housekeep"
      housekeeping "$STATE"
    fi
  done
}

# Run only when executed, not when sourced (tests source the classifiers).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fm_super_main "$@"
fi
