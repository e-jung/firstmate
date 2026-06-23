#!/usr/bin/env bash
# Behavior tests for bin/fm-config.sh, the config/daemon.conf editor.
# Covers list/get/set roundtrip, inline-comment preservation/creation, env > file
# > default precedence, and that a generated file round-trips when sourced.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONF_BIN="$ROOT/bin/fm-config.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

cleanup() { [ -n "${TMP:-}" ] && rm -rf "$TMP"; }
trap cleanup EXIT
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-config-tests.XXXXXX")
CONF="$TMP/daemon.conf"

# Run fm-config.sh against a temp conf + the real repo root (so defaults are
# parsed from the real scripts). Strip any FM_* overrides from the environment so
# "current" reflects only file/default unless a test sets one explicitly.
run_conf() {
  env -u FM_ESCALATE_BATCH_SECS -u FM_INJECT_SKIP -u FM_BUSY_REGEX \
      -u FM_CHECK_INTERVAL -u FM_DISK_ALERT_PCT -u FM_GH_CONTRIBUTOR \
    FM_ROOT_OVERRIDE="$ROOT" FM_DAEMON_CONF="$CONF" "$CONF_BIN" "$@"
}

# 1. list shows every documented knob with name/current/default/description.
test_list_shape() {
  local out
  out=$(run_conf list)
  printf '%s\n' "$out" | grep -Fq 'NAME · CURRENT · DEFAULT · DESCRIPTION' \
    || fail "list missing header row"
  for k in FM_BUSY_REGEX FM_CHECK_INTERVAL FM_CHECK_TIMEOUT FM_COMPOSER_IDLE_RE \
           FM_DISK_ALERT_PCT FM_ESCALATE_BATCH_SECS FM_GH_CONTRIBUTOR \
           FM_HEARTBEAT_SCAN_SECS FM_INJECT_SKIP FM_STALE_ESCALATE_SECS; do
    printf '%s\n' "$out" | grep -Fq "$k" || fail "list missing knob $k"
  done
  pass "list shows all knobs with name/current/default/description"
}

# 2. defaults are parsed from the scripts (not duplicated), so the known values
#    appear in the DEFAULT column.
test_defaults_parsed() {
  local out
  out=$(run_conf list)
  printf '%s\n' "$out" | grep -Fq 'FM_ESCALATE_BATCH_SECS · 90 · 90' \
    || fail "FM_ESCALATE_BATCH_SECS default not parsed as 90"
  printf '%s\n' "$out" | grep -Fq 'FM_CHECK_INTERVAL · 300 · 300' \
    || fail "FM_CHECK_INTERVAL default not parsed from fm-watch.sh as 300"
  printf '%s\n' "$out" | grep -Fq 'FM_DISK_ALERT_PCT · 85 · 85' \
    || fail "FM_DISK_ALERT_PCT default not parsed from fm-disk-health.sh as 85"
  pass "defaults are parsed live from the defining scripts"
}

# 3. get returns the default when nothing is set; set then get roundtrips.
test_get_set_roundtrip() {
  local v
  v=$(run_conf get FM_ESCALATE_BATCH_SECS)
  [ "$v" = "90" ] || fail "get did not return the default (got '$v')"
  run_conf set FM_ESCALATE_BATCH_SECS 45 >/dev/null
  v=$(run_conf get FM_ESCALATE_BATCH_SECS)
  [ "$v" = "45" ] || fail "get did not return the set value (got '$v')"
  pass "get/set roundtrips; default is returned when nothing is set"
}

# 4. env var beats the config file (precedence: env > file > default).
test_env_precedence() {
  run_conf set FM_INJECT_SKIP heartbeat >/dev/null   # file value
  local v
  v=$(env -u FM_INJECT_SKIP FM_ROOT_OVERRIDE="$ROOT" FM_DAEMON_CONF="$CONF" \
        "$CONF_BIN" get FM_INJECT_SKIP)
  [ "$v" = "heartbeat" ] || fail "file value not honored (got '$v')"
  v=$(FM_INJECT_SKIP="stale" FM_ROOT_OVERRIDE="$ROOT" FM_DAEMON_CONF="$CONF" \
        "$CONF_BIN" get FM_INJECT_SKIP)
  [ "$v" = "stale" ] || fail "env did not beat file (got '$v')"
  pass "env var beats config file beats default"
}

# 5. set creates the file with an inline comment; set preserves a hand-edited
#    comment on the touched line and does not touch other lines.
test_set_creates_and_preserves_comment() {
  rm -f "$CONF"
  run_conf set FM_HEARTBEAT_SCAN_SECS 120 >/dev/null
  [ -f "$CONF" ] || fail "set did not create config/daemon.conf"
  grep -Fq 'FM_HEARTBEAT_SCAN_SECS:-120' "$CONF" \
    || fail "set did not write the value"
  grep -Eq "FM_HEARTBEAT_SCAN_SECS=.*# .*catch-all" "$CONF" \
    || fail "set did not add the inline comment"
  # set a second key: the first key's line must be untouched.
  run_conf set FM_INJECT_SKIP stale >/dev/null
  grep -Fq 'FM_HEARTBEAT_SCAN_SECS:-120' "$CONF" \
    || fail "set clobbered an unrelated line"
  pass "set creates the file with a comment and preserves other lines"
}

# 6. set preserves a user-edited comment on the line it edits.
test_set_preserves_edited_comment() {
  rm -f "$CONF"
  run_conf set FM_STALE_ESCALATE_SECS 240 >/dev/null
  # Hand-edit the comment (simulate a captain's note).
  sed -i 's|# .*$|# my custom note|' "$CONF"
  run_conf set FM_STALE_ESCALATE_SECS 300 >/dev/null
  grep -Fq '# my custom note' "$CONF" \
    || fail "set did not preserve the user-edited comment"
  grep -Fq 'FM_STALE_ESCALATE_SECS:-300' "$CONF" \
    || fail "set did not update the value while preserving the comment"
  pass "set preserves a hand-edited comment on the edited line"
}

# 7. a generated file (including the regex defaults) round-trips when sourced:
#    sourcing it reproduces the parsed defaults exactly.
test_source_roundtrip() {
  rm -f "$CONF"
  run_conf set FM_ESCALATE_BATCH_SECS 90 >/dev/null   # bootstraps the full file
  local expected_busy expected_composer
  expected_busy=$(run_conf get FM_BUSY_REGEX)
  expected_composer=$(run_conf get FM_COMPOSER_IDLE_RE)
  local out
  # Unset so the conf-provided defaults are what sourcing yields (env wins
  # otherwise). Subshell keeps the test shell clean.
  unset FM_BUSY_REGEX FM_COMPOSER_IDLE_RE 2>/dev/null || true
  # shellcheck disable=SC1090  # CONF is a generated temp file
  out=$( ( set -a; . "$CONF"; set +a; printf '%s\n%s' "$FM_BUSY_REGEX" "$FM_COMPOSER_IDLE_RE" ) )
  local got_busy got_composer
  got_busy=$(printf '%s\n' "$out" | head -1)
  got_composer=$(printf '%s\n' "$out" | tail -1)
  [ "$got_busy" = "$expected_busy" ] \
    || fail "FM_BUSY_REGEX did not round-trip through sourcing (got '$got_busy')"
  [ "$got_composer" = "$expected_composer" ] \
    || fail "FM_COMPOSER_IDLE_RE did not round-trip through sourcing"
  pass "generated config (incl. regex defaults) round-trips when sourced"
}

# 8. get on an unknown key errors (non-zero) without writing.
test_unknown_key_rejected() {
  local rc
  run_conf get FM_NOT_A_KNOB >/dev/null 2>&1 && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "get accepted an unknown knob"
  run_conf set FM_ALSO_FAKE 1 >/dev/null 2>&1 && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "set accepted an unknown knob"
  pass "unknown knobs are rejected by get and set"
}

test_list_shape
test_defaults_parsed
test_get_set_roundtrip
test_env_precedence
test_set_creates_and_preserves_comment
test_set_preserves_edited_comment
test_source_roundtrip
test_unknown_key_rejected
