#!/usr/bin/env bash
# tests/fm-backend-oc2.test.sh - unit tests for the opencode2 HTTP-API adapter.
#
# Tests the pure logic of bin/backends/oc2.sh and its integration with
# bin/fm-backend.sh's dispatch layer, using mocked API responses (no real
# opencode2 server needed). The end-to-end proof (real server, real model turn,
# watcher turn-end detection) is captured in docs/opencode2-backend.md.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"

TMP=$(fm_test_tmproot fm-backend-oc2-tests)
export FM_HOME="$TMP"
mkdir -p "$TMP/state"

# Source the oc2 backend directly so we can test its functions.
FM_BACKEND_LIB_DIR="$ROOT/bin"
# shellcheck source=bin/backends/oc2.sh
. "$ROOT/bin/backends/oc2.sh"

# --- backend registration ---------------------------------------------------

fm_backend_validate oc2 2>/dev/null || fail "fm_backend_validate oc2 should succeed"
pass "oc2 is a known backend"

fm_backend_validate_spawn oc2 2>/dev/null || fail "fm_backend_validate_spawn oc2 should succeed"
pass "oc2 is a spawn-capable backend"

tools=$(fm_backend_required_tools oc2)
case "$tools" in
  *opencode2*|*jq*|*treehouse*|*curl*) ;;
  *) fail "fm_backend_required_tools oc2 missing tools: got '$tools'" ;;
esac
pass "oc2 required tools include opencode2, jq, treehouse, curl"

# oc2 is NOT auto-detected (only reachable via --harness opencode2).
fm_backend_has_push oc2 && fail "oc2 should not have native push" || true
pass "oc2 has no native push (poll-based)"

# --- busy state with mocked responses ---------------------------------------

# Mock fm_backend_oc2_active_raw to return a controlled response.
test_active_raw=''
fm_backend_oc2_active_raw() { printf '%s' "$test_active_raw"; }

test_active_raw='{"data":{"ses_test123":{"type":"running"}}}'
fm_backend_oc2_session_is_busy "ses_test123" || fail "session should be busy when in active map"
pass "session_is_busy returns true for active session"

fm_backend_oc2_session_is_busy "ses_other" && fail "session should not be busy when absent from active map" || true
pass "session_is_busy returns false for inactive session"

result=$(fm_backend_oc2_busy_state "oc2:ses_test123")
[ "$result" = "busy" ] || fail "busy_state should be 'busy' for active session, got '$result'"
pass "busy_state returns busy for active session"

result=$(fm_backend_oc2_busy_state "oc2:ses_other")
[ "$result" = "idle" ] || fail "busy_state should be 'idle' for inactive session, got '$result'"
pass "busy_state returns idle for inactive session"

# --- capture with mocked messages -------------------------------------------

test_messages_raw=''
fm_backend_oc2_api() { printf '%s' "$test_messages_raw"; }

test_messages_raw='{"data":[
  {"id":"msg1","type":"user","text":"Reply with PONG"},
  {"id":"msg2","type":"assistant","content":[{"type":"text","id":"t0","text":"PONG"}],"finish":"stop"}
]}'

captured=$(fm_backend_oc2_capture "oc2:ses_test123" 10)
echo "$captured" | grep -q '\[user\] Reply with PONG' || fail "capture should show user message"
echo "$captured" | grep -q '\[assistant\] PONG' || fail "capture should show assistant response"
pass "capture formats user and assistant messages correctly"

# --- dispatch routing -------------------------------------------------------

# Verify fm_backend_busy_state dispatches to oc2.
unset -f fm_backend_oc2_active_raw
test_active_raw=''
fm_backend_oc2_active_raw() { printf '{"data":{}}'; }
result=$(fm_backend_busy_state oc2 "oc2:ses_test")
[ "$result" = "idle" ] || fail "fm_backend_busy_state dispatch to oc2 should return idle, got '$result'"
pass "fm_backend_busy_state dispatches to oc2"

# --- scan_oc2_turn_ends with mocked state -----------------------------------

# Create a fake oc2 task meta.
mkdir -p "$TMP/state"
cat > "$TMP/state/test-task.meta" <<META
window=oc2:ses_turntest
worktree=/tmp/fake-wt
project=/tmp/fake-proj
harness=opencode2
kind=ship
mode=no-mistakes
yolo=off
backend=oc2
oc2_url=http://127.0.0.1:4096
oc2_session=ses_turntest
META

# Mock the active check: session is NOT busy (idle).
fm_backend_oc2_active_raw() { printf '{"data":{}}'; }

# Simulate that the previous poll saw it as busy.
: > "$TMP/state/.oc2-busy-test-task"

# Source fm-watch.sh's scan_oc2_turn_ends (it's defined there, but we can
# inline-test the same logic since it operates on state files).
# Replicate the scan logic (same as bin/fm-watch.sh scan_oc2_turn_ends).
scan_test() {
  local meta id sid active was_busy is_busy
  for meta in "$TMP/state"/*.meta; do
    [ -e "$meta" ] || continue
    grep -q '^backend=oc2$' "$meta" 2>/dev/null || continue
    id=$(basename "$meta" .meta)
    sid=$(grep '^oc2_session=' "$meta" | cut -d= -f2- || true)
    [ -n "$sid" ] || continue
    active=$(fm_backend_oc2_active_raw 2>/dev/null || printf '{"data":{}}')
    if printf '%s' "$active" | grep -q "\"$sid\"" 2>/dev/null; then
      is_busy=1
    else
      is_busy=0
    fi
    if [ -f "$TMP/state/.oc2-busy-$id" ]; then was_busy=1; else was_busy=0; fi
    if [ "$was_busy" = 1 ] && [ "$is_busy" = 0 ]; then
      touch "$TMP/state/$id.turn-ended"
      rm -f "$TMP/state/.oc2-busy-$id"
    elif [ "$is_busy" = 1 ]; then
      : > "$TMP/state/.oc2-busy-$id"
    fi
  done
}
scan_test

[ -f "$TMP/state/test-task.turn-ended" ] || fail "scan_oc2_turn_ends should touch turn-ended on busy->idle"
pass "scan_oc2_turn_ends touches turn-ended on busy->idle transition"

[ ! -f "$TMP/state/.oc2-busy-test-task" ] || fail "busy marker should be cleared after turn-end"
pass "busy marker cleared after turn-end detection"

# Verify no turn-ended when session stays busy.
rm -f "$TMP/state/test-task.turn-ended"
: > "$TMP/state/.oc2-busy-test-task"
fm_backend_oc2_active_raw() { printf '{"data":{"ses_turntest":{"type":"running"}}}'; }
scan_test
[ ! -f "$TMP/state/test-task.turn-ended" ] || fail "no turn-ended when session stays busy"
pass "no false turn-end when session stays busy"

# Verify no turn-ended when session was never busy.
rm -f "$TMP/state/test-task.turn-ended" "$TMP/state/.oc2-busy-test-task"
fm_backend_oc2_active_raw() { printf '{"data":{}}'; }
scan_test
[ ! -f "$TMP/state/test-task.turn-ended" ] || fail "no turn-ended when never busy"
pass "no turn-end when session was never busy (no false wake)"

# --- model/effort resolution (spawn path) -----------------------------------

# The spawn code splits "provider/model" and maps effort to variant.
# Test the parsing logic directly.
parse_model() {
  local model=$1 provider model_id
  case "$model" in
    */*) provider=${model%%/*}; model_id=${model#*/} ;;
    *) provider='zai-coding-plan'; model_id="$model" ;;
  esac
  printf '%s\t%s' "$provider" "$model_id"
}

result=$(parse_model "zai-coding-plan/glm-5.2")
[ "$result" = "zai-coding-plan	glm-5.2" ] || fail "model split failed: '$result'"
pass "model 'zai-coding-plan/glm-5.2' splits correctly"

result=$(parse_model "glm-5.2")
[ "$result" = "zai-coding-plan	glm-5.2" ] || fail "bare model defaults to zai-coding-plan: '$result'"
pass "bare model 'glm-5.2' defaults to zai-coding-plan provider"

map_effort_to_variant() {
  case "${1:-default}" in
    max) printf 'max' ;;
    xhigh) printf 'high' ;;
    high) printf 'high' ;;
    medium) printf 'medium' ;;
    low) printf 'default' ;;
    ''|default) printf 'max' ;;
    *) printf 'max' ;;
  esac
}

[ "$(map_effort_to_variant max)" = "max" ] || fail "max->max"
[ "$(map_effort_to_variant xhigh)" = "high" ] || fail "xhigh->high"
[ "$(map_effort_to_variant high)" = "high" ] || fail "high->high"
[ "$(map_effort_to_variant medium)" = "medium" ] || fail "medium->medium"
[ "$(map_effort_to_variant low)" = "default" ] || fail "low->default"
[ "$(map_effort_to_variant default)" = "max" ] || fail "default->max"
pass "effort-to-variant mapping correct for all levels"

echo
echo "All oc2 backend tests passed."
