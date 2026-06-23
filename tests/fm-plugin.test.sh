#!/usr/bin/env bash
# Behavior tests for bin/fm-plugin.sh, the watcher check-script manager.
# Covers the --filter safe path, the raw (natively-silent) path, the contract
# lint that catches flooding plugins (the disk-health-flood regression guard),
# and list/disable/enable.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_BIN="$ROOT/bin/fm-plugin.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

cleanup() { [ -n "${TMP:-}" ] && rm -rf "$TMP"; }
trap cleanup EXIT
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-plugin-tests.XXXXXX")
STATE="$TMP/state"
mkdir -p "$STATE"

# Sample plugins.
#  silent.sh  : natively silent-unless-wake (prints only when $state/.event exists)
#  flood.sh   : always prints a report (the disk-health-flood shape)
#  report.sh  : report-style; an ALERT line only above FM_FAKE_PCT
SILENT="$TMP/silent.sh"
FLOOD="$TMP/flood.sh"
REPORT="$TMP/report.sh"

cat > "$SILENT" <<'SH'
#!/usr/bin/env bash
state="${FM_STATE_OVERRIDE:-${FM_HOME:-$HOME}/state}"
[ -f "$state/.event" ] && echo "EVENT: something happened"
SH
cat > "$FLOOD" <<'SH'
#!/usr/bin/env bash
echo "disk usage: 50%"
echo "cache: 2G"
SH
cat > "$REPORT" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = "--describe" ] && { echo "name=report"; echo "wake_contract=report"; exit 0; }
pct="${FM_FAKE_PCT:-50}"
echo "disk usage: ${pct}%"
[ "${pct:-0}" -gt 85 ] 2>/dev/null && echo "ALERT: disk ${pct}% exceeds threshold"
exit 0
SH
chmod +x "$SILENT" "$FLOOD" "$REPORT"

# Run fm-plugin.sh against a temp state dir.
run_plugin() {
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$STATE" FM_CHECK_TIMEOUT=10 \
    "$PLUGIN_BIN" "$@"
}

# 1. check passes a natively-silent plugin and FAILS a flooding one.
test_check_lint() {
  run_plugin check "$SILENT" --once >/dev/null \
    || fail "check rejected a natively-silent plugin"
  if run_plugin check "$FLOOD" --check >/dev/null 2>&1; then
    fail "check accepted a flooding plugin (should exit non-zero)"
  fi
  pass "check passes silent-unless-wake and fails a flooding plugin"
}

# 2. The flooding failure is the disk-health-flood regression guard: a script
#    that prints on a no-event fixture is rejected with a clear message.
test_check_message_names_the_flood() {
  local err
  err=$(run_plugin check "$FLOOD" --check 2>&1 >/dev/null || true)
  printf '%s' "$err" | grep -Fq 'not silent-unless-wake' \
    || fail "check did not name the contract violation"
  printf '%s' "$err" | grep -Fqe '--filter' \
    || fail "check did not suggest --filter for the report-style fix"
  pass "check failure message explains the flood and suggests --filter"
}

# 3. add with --filter generates a wrapper that is SILENT when output does not
#    match the filter and PRINTS when it does.
test_add_filter_wrapper() {
  run_plugin add "$REPORT" --check --filter '^ALERT:' --name disk >/dev/null
  [ -f "$STATE/disk.check.sh" ] || fail "add --filter did not create the wrapper"
  # No ALERT (below threshold) -> wrapper prints nothing.
  local out
  out=$(FM_FAKE_PCT=50 bash "$STATE/disk.check.sh")
  [ -z "$out" ] || fail "filter wrapper printed when no line matched (got: $out)"
  # ALERT (above threshold) -> wrapper prints the ALERT line only.
  out=$(FM_FAKE_PCT=90 bash "$STATE/disk.check.sh")
  printf '%s' "$out" | grep -Fq 'ALERT: disk 90%' \
    || fail "filter wrapper did not print the matching ALERT line"
  # The non-matching report line must NOT survive the filter.
  printf '%s' "$out" | grep -Fq 'disk usage:' \
    && fail "filter wrapper leaked a non-matching report line"
  pass "add --filter wrapper is silent on no-match and prints only matching lines"
}

# 4. add with NO filter on a contract-correct plugin passes the script through;
#    the wrapper runs the script raw and surfaces real events.
test_add_raw_silent() {
  run_plugin add "$SILENT" --once --name silent >/dev/null
  [ -f "$STATE/silent.check.sh" ] || fail "add did not create the raw wrapper"
  # No event -> silent.
  local out
  out=$(FM_STATE_OVERRIDE="$STATE" bash "$STATE/silent.check.sh")
  [ -z "$out" ] || fail "raw wrapper printed when there was no event"
  # Event present -> prints.
  touch "$STATE/.event"
  out=$(FM_STATE_OVERRIDE="$STATE" bash "$STATE/silent.check.sh")
  printf '%s' "$out" | grep -Fq 'EVENT:' \
    || fail "raw wrapper did not pass through the event"
  rm -f "$STATE/.event"
  pass "add (no filter) on a natively-silent plugin passes events through raw"
}

# 5. add with NO filter on a FLOODING plugin is REFUSED (no wrapper created) —
#    this is the structural fix for the disk-health-flood incident.
test_add_raw_flooding_refused() {
  rm -f "$STATE/flood.check.sh"
  if run_plugin add "$FLOOD" --check --name flood >/dev/null 2>&1; then
    fail "add created a wrapper for a flooding plugin without --filter"
  fi
  [ -f "$STATE/flood.check.sh" ] \
    && fail "add left a wrapper behind after refusing a flooding plugin"
  pass "add (no filter) refuses a flooding plugin and creates no wrapper"
}

# 6. list reflects add, disable, and enable.
test_list_disable_enable() {
  rm -f "$STATE"/*.check.sh; rmdir "$STATE/.disabled" 2>/dev/null || true
  run_plugin add "$SILENT" --once --name silent >/dev/null
  run_plugin add "$REPORT" --check --filter '^ALERT:' --name disk >/dev/null
  local out
  out=$(run_plugin list)
  printf '%s\n' "$out" | grep -Fq 'silent' || fail "list missing 'silent' after add"
  printf '%s\n' "$out" | grep -Fq 'disk' || fail "list missing 'disk' after add"
  printf '%s\n' "$out" | grep -Fq '^ALERT:' || fail "list did not show the filter"
  # disable removes it from the active sweep.
  run_plugin disable silent >/dev/null
  out=$(run_plugin list)
  printf '%s\n' "$out" | grep -Fq 'silent' \
    && fail "list still showed 'silent' after disable"
  [ -f "$STATE/.disabled/silent.check.sh" ] || fail "disable did not move the wrapper"
  # enable brings it back.
  run_plugin enable silent >/dev/null
  out=$(run_plugin list)
  printf '%s\n' "$out" | grep -Fq 'silent' || fail "list missing 'silent' after enable"
  pass "list reflects add, disable (to .disabled/), and enable"
}

# 7. list --describe calls a supporting plugin's --describe.
test_list_describe() {
  rm -f "$STATE"/*.check.sh
  run_plugin add "$REPORT" --check --filter '^ALERT:' --name disk >/dev/null
  local out
  out=$(run_plugin list --describe)
  printf '%s\n' "$out" | grep -Fq 'name=report' \
    || fail "list --describe did not surface the plugin's --describe output"
  printf '%s\n' "$out" | grep -Fq 'wake_contract=report' \
    || fail "list --describe did not show the wake_contract"
  pass "list --describe surfaces a self-describing plugin's metadata"
}

test_check_lint
test_check_message_names_the_flood
test_add_filter_wrapper
test_add_raw_silent
test_add_raw_flooding_refused
test_list_disable_enable
test_list_describe
