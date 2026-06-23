#!/usr/bin/env bash
# fm-daemon-opencode.test.sh — opencode-specific afk-supervision regressions.
#
# Two bugs that together completely broke autonomous (permanent-afk) supervision
# when firstmate runs on opencode (the captain's harness):
#
#   Bug 1 — pane_input_pending() false-positives on opencode's idle composer.
#     opencode renders a bordered input widget on the cursor line, so a clean
#     idle prompt is NOT a blank line: it is "<indent>┃  Ask anything... <sugg>"
#     (┃ = U+2503 box-drawing border; "Ask anything..." is the fixed empty-input
#     placeholder). The old COMPOSER_IDLE_RE never matched it, so every injection
#     was deferred forever ("inject deferred: pending input"). Fix: the regex now
#     recognizes opencode's idle composer (border + placeholder / border-only).
#
#   Bug 2 — stale-wedge detector flagged the supervisor's own idle pane.
#     The supervisor pane (the opencode window running firstmate) is legitimately
#     idle between events while the captain is away. Stale detection must apply
#     ONLY to crewmate panes (fm-* windows), never the supervisor pane. Fix:
#     classify_stale + stale_marker_record exclude non-crewmate windows.
#
# These tests pin both fixes. The opencode idle/typed lines below are byte-level
# captures from a real opencode 1.17.x pane (see the comment on
# COMPOSER_IDLE_RE_DEFAULT in bin/fm-supervise-daemon.sh).
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAEMON="$ROOT/bin/fm-supervise-daemon.sh"

# Source the daemon's pure helpers. The BASH_SOURCE guard skips fm_super_main, so
# only the testable functions become defined.
if [ -z "${FM_TEST_DAEMON_SOURCED:-}" ]; then
  export FM_TEST_DAEMON_SOURCED=1
  # shellcheck source=bin/fm-supervise-daemon.sh
  . "$DAEMON"
fi

TMP_ROOT=
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
cleanup() { [ -n "${TMP_ROOT:-}" ] && rm -rf "$TMP_ROOT"; }
trap cleanup EXIT
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-daemon-opencode.XXXXXX")

# Minimal fake tmux for pane_input_pending (display-message cursor_y +
# capture-pane) and housekeeping's window_for_task (list-windows). Behavior is
# driven by FM_FAKE_TMUX_* env vars set per test. Modeled on the
# make_supercase helper in fm-wake-queue.test.sh.
make_fake_tmux() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    [ "${FM_FAKE_TMUX_PANE_ALIVE:-1}" = "1" ] || exit 1
    for _a in "$@"; do
      case "$_a" in *cursor_y*) printf '%s\n' "${FM_FAKE_TMUX_CURSOR_Y:-0}"; exit 0 ;; esac
    done
    printf 'fakepane\n'; exit 0 ;;
  list-windows)
    [ -n "${FM_FAKE_TMUX_WINDOW:-}" ] && printf '%s\n' "$FM_FAKE_TMUX_WINDOW"
    exit 0 ;;
  capture-pane)
    [ -n "${FM_FAKE_TMUX_CAPTURE:-}" ] && cat "$FM_FAKE_TMUX_CAPTURE" 2>/dev/null
    exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$dir"
}

# opencode idle/typed cursor-line fixtures (real captures). ┃ is U+2503.
OPENCODE_IDLE_LINE='                       ┃  Ask anything... "Fix broken tests"'
OPENCODE_IDLE_NO_SUGG='                       ┃  Ask anything...'
OPENCODE_BORDER_ONLY='                       ┃'
OPENCODE_TYPED_LINE='                       ┃  hello captain'
OPENCODE_TYPED_ASK='                       ┃  Ask anything else I need help with'

# ============================================================================
# Bug 1: opencode-aware composer-idle detection (pane_input_pending)
# ============================================================================

test_opencode_idle_placeholder_not_pending() {
  local dir fakebin capture
  dir=$(make_fake_tmux oc-idle)
  fakebin="$dir/fakebin"
  capture="$dir/pane.txt"
  printf '%s\n' "$OPENCODE_IDLE_LINE" > "$capture"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURSOR_Y=0 \
    pane_input_pending "fakepane" \
    && fail "opencode idle placeholder line falsely detected as pending input"
  pass "opencode: idle composer (border + 'Ask anything...' placeholder) is NOT pending"
}

test_opencode_idle_no_suggestion_not_pending() {
  local dir fakebin capture
  dir=$(make_fake_tmux oc-idle-nosugg)
  fakebin="$dir/fakebin"
  capture="$dir/pane.txt"
  printf '%s\n' "$OPENCODE_IDLE_NO_SUGG" > "$capture"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURSOR_Y=0 \
    pane_input_pending "fakepane" \
    && fail "opencode idle (placeholder, no suggestion) falsely detected as pending"
  pass "opencode: idle composer without a dynamic suggestion is NOT pending"
}

test_opencode_border_only_not_pending() {
  local dir fakebin capture
  dir=$(make_fake_tmux oc-border)
  fakebin="$dir/fakebin"
  capture="$dir/pane.txt"
  printf '%s\n' "$OPENCODE_BORDER_ONLY" > "$capture"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURSOR_Y=0 \
    pane_input_pending "fakepane" \
    && fail "opencode border-only cursor line falsely detected as pending"
  pass "opencode: border-only composer chrome is NOT pending"
}

test_opencode_typed_text_is_pending() {
  local dir fakebin capture
  dir=$(make_fake_tmux oc-typed)
  fakebin="$dir/fakebin"
  capture="$dir/pane.txt"
  printf '%s\n' "$OPENCODE_TYPED_LINE" > "$capture"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURSOR_Y=0 \
    pane_input_pending "fakepane" \
    || fail "opencode typed text NOT detected as pending (guard weakened?)"
  pass "opencode: typed text on the composer line IS pending (protection holds)"
}

test_opencode_typed_ask_anything_is_pending() {
  # A user who typed text beginning with "Ask anything" but WITHOUT the literal
  # "..." placeholder must STILL be treated as pending. This pins that the fix
  # did not weaken the guard into a loose substring match.
  local dir fakebin capture
  dir=$(make_fake_tmux oc-typed-ask)
  fakebin="$dir/fakebin"
  capture="$dir/pane.txt"
  printf '%s\n' "$OPENCODE_TYPED_ASK" > "$capture"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURSOR_Y=0 \
    pane_input_pending "fakepane" \
    || fail "typed 'Ask anything ...' text NOT detected as pending (loose match?)"
  pass "opencode: typed text resembling the placeholder still IS pending"
}

test_legacy_bare_prompts_still_not_pending() {
  # Regression: the existing bare-prompt idle patterns must still work.
  local dir fakebin capture
  dir=$(make_fake_tmux oc-legacy)
  fakebin="$dir/fakebin"
  capture="$dir/pane.txt"
  printf 'output\n$ \n' > "$capture"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURSOR_Y=1 \
    pane_input_pending "fakepane" \
    && fail "bare \$ prompt falsely detected as pending"
  printf 'output\n> \n' > "$capture"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURSOR_Y=1 \
    pane_input_pending "fakepane" \
    && fail "bare > prompt falsely detected as pending"
  pass "legacy bare prompts ($, >) are still NOT pending (no regression)"
}

# ============================================================================
# Bug 2: supervisor pane excluded from stale-wedge detection
# ============================================================================

test_is_crewmate_window_classifies() {
  is_crewmate_window "firstmate3:fm-fm-daemon-opencode-fix-r7" \
    || fail "fm-* crewmate window not classified as crewmate"
  is_crewmate_window "firstmate3:0" \
    && fail "supervisor pane (window index) falsely classified as crewmate"
  is_crewmate_window "firstmate3:opencode" \
    && fail "supervisor pane (window name) falsely classified as crewmate"
  is_crewmate_window "%5" \
    && fail "bare pane id falsely classified as crewmate"
  pass "is_crewmate_window: fm-* only; supervisor pane / pane-id excluded"
}

test_classify_stale_ignores_supervisor_pane() {
  local dir state out key
  dir=$(make_fake_tmux sup-stale)
  state="$dir/state"
  # A terminal status under the supervisor's task name must NOT escalate from a
  # stale wake, and must NOT record a persistence marker.
  printf 'done: PR https://x/y/pull/1\n' > "$state/0.status"
  out=$(FM_STATE_OVERRIDE="$state" classify_stale "firstmate3:0" "$state")
  case "$out" in
    self\|*) ;;
    *) fail "supervisor-pane stale wake did not self-handle: $out" ;;
  esac
  # No persistence marker for any supervisor-scoped task.
  key=$(_stale_key "0")
  [ ! -e "$state/.subsuper-stale-$key" ] \
    || fail "supervisor-pane stale wake recorded a persistence marker"
  # Also the named-supervisor-window form.
  out=$(FM_STATE_OVERRIDE="$state" classify_stale "firstmate3:opencode" "$state")
  case "$out" in
    self\|*) ;;
    *) fail "named supervisor-pane stale wake did not self-handle: $out" ;;
  esac
  pass "classify_stale ignores the supervisor pane (self-handle, no marker)"
}

test_stale_marker_record_ignores_supervisor_pane() {
  # The marker-creation choke point must never track a non-crewmate pane, even
  # when called directly (defensive against future callers).
  local dir state key
  dir=$(make_fake_tmux sup-marker)
  state="$dir/state"
  stale_marker_record "firstmate3:0" "$state"
  stale_marker_record "firstmate3:opencode" "$state"
  stale_marker_record "%5" "$state"
  for f in "$state"/.subsuper-stale-*; do
    [ -e "$f" ] || continue
    fail "stale_marker_record created a marker for a non-crewmate pane: $f"
  done
  # And a crewmate window DOES record one (regression).
  stale_marker_record "firstmate3:fm-real-task-r1" "$state"
  key=$(_stale_key "real-task-r1")
  [ -e "$state/.subsuper-stale-$key" ] \
    || fail "crewmate stale marker was not recorded"
  pass "stale_marker_record: no marker for supervisor pane; crewmate still tracked"
}

test_classify_stale_crewmate_still_works() {
  # Regression: a real crewmate (fm-*) stale wake is still classified normally
  # (terminal escalates; transient self-handles + records a marker).
  local dir state out key
  dir=$(make_fake_tmux crew-stale)
  state="$dir/state"
  printf 'done: ready in branch fm/t9\n' > "$state/crew-t9.status"
  out=$(FM_STATE_OVERRIDE="$state" classify_stale "firstmate3:fm-crew-t9" "$state")
  case "$out" in
    escalate\|*) ;;
    *) fail "crewmate terminal stale did not escalate: $out" ;;
  esac
  rm -f "$state/crew-t9.status"
  out=$(FM_STATE_OVERRIDE="$state" classify_stale "firstmate3:fm-crew-t9" "$state")
  case "$out" in
    self\|*) ;;
    *) fail "crewmate transient stale did not self-handle: $out" ;;
  esac
  # handle_wake records the marker for a transient crewmate stale; verify the
  # choke point honors it.
  stale_marker_record "firstmate3:fm-crew-t9" "$state"
  key=$(_stale_key "crew-t9")
  [ -e "$state/.subsuper-stale-$key" ] \
    || fail "crewmate transient stale did not record a marker"
  pass "classify_stale: crewmate (fm-*) stale still classified (terminal+transient)"
}

test_housekeeping_drops_supervisor_marker_without_escalating() {
  # Defensive: a pre-existing supervisor-scoped marker (e.g. left by a prior
  # daemon version before this guard existed) must be DROPPED by housekeeping's
  # recheck, not escalated as a wedge. window_for_task only resolves fm-*
  # windows, so a non-crewmate key yields no window -> marker removed.
  local dir state fakebin key
  dir=$(make_fake_tmux sup-housekeep)
  state="$dir/state"
  fakebin="$dir/fakebin"
  key=$(_stale_key "0")   # supervisor task "0" (from window firstmate3:0)
  echo $(( $(date +%s) - 999 )) > "$state/.subsuper-stale-$key"
  # list-windows returns only an fm-* crewmate window (whose task != "0").
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="firstmate3:fm-other-r2" \
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=240 housekeeping "$state"
  [ ! -e "$state/.subsuper-stale-$key" ] \
    || fail "housekeeping did not drop the orphaned supervisor marker"
  [ ! -s "$state/.subsuper-escalations" ] \
    || fail "housekeeping escalated an orphaned supervisor marker as a wedge"
  pass "housekeeping drops an orphaned supervisor marker without escalating"
}

# Bug 1
test_opencode_idle_placeholder_not_pending
test_opencode_idle_no_suggestion_not_pending
test_opencode_border_only_not_pending
test_opencode_typed_text_is_pending
test_opencode_typed_ask_anything_is_pending
test_legacy_bare_prompts_still_not_pending
# Bug 2
test_is_crewmate_window_classifies
test_classify_stale_ignores_supervisor_pane
test_stale_marker_record_ignores_supervisor_pane
test_classify_stale_crewmate_still_works
test_housekeeping_drops_supervisor_marker_without_escalating

echo "all opencode daemon tests passed"
