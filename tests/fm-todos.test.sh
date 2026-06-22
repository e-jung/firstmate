#!/usr/bin/env bash
# Behavior tests for bin/fm-todos.sh, the backlog -> todo parser the supervisor
# seeds its harness-native todo/task list from at every bootstrap (AGENTS.md 3).
# Exercises In flight / Queued / Done parsing, blocked-by preservation, JSON
# output, and the empty/missing-backlog edge cases. No network, no gh calls.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TODOS="$ROOT/bin/fm-todos.sh"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

cleanup() {
  [ -n "${TMP:-}" ] && rm -rf "$TMP"
}
trap cleanup EXIT
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-todos-tests.XXXXXX")

run_todos() {
  FM_BACKLOG="$BACKLOG" "$TODOS" "$@"
}

# A representative backlog covering every section and the blocked-by shape.
BACKLOG="$TMP/backlog.md"
cat > "$BACKLOG" <<'EOF'
## In flight
- [ ] fix-login-k3 - tighten session cookie scope (repo: yourapp, since 2026-06-22)

## Queued
- [ ] add-export-q9 - add CSV export to reports (repo: yourapp) blocked-by: fix-login-k3 - needs the auth fix first

## Done
- [x] init-ci-r1 - set up CI - https://example.test/pr/12 (merged 2026-06-20)
- [x] scout-aud-r2 - audit auth flow - data/scout-aud-r2/report.md (reported 2026-06-18)
EOF

test_in_flight_row() {
  local out
  out=$(run_todos)
  printf '%s\n' "$out" | grep -Fxq "$(printf 'in_progress\thigh\tfix-login-k3\ttighten session cookie scope (repo: yourapp, since 2026-06-22)')" \
    || fail "In flight item not emitted as in_progress/high with id and one-line"
  pass "In flight items map to in_progress/high"
}

test_queued_row() {
  local out
  out=$(run_todos)
  printf '%s\n' "$out" | grep -F "$(printf 'pending\tmedium\tadd-export-q9\t')" >/dev/null \
    || fail "Queued item not emitted as pending/medium"
  printf '%s\n' "$out" | grep -F 'blocked-by: fix-login-k3 - needs the auth fix first' >/dev/null \
    || fail "blocked-by info was not preserved in the Queued one-line"
  pass "Queued items map to pending/medium and keep blocked-by"
}

test_done_excluded() {
  local out
  out=$(run_todos)
  printf '%s\n' "$out" | grep -F 'init-ci-r1' >/dev/null \
    && fail "Done PR item leaked into output"
  printf '%s\n' "$out" | grep -F 'scout-aud-r2' >/dev/null \
    && fail "Done scout item leaked into output"
  [ "$(printf '%s\n' "$out" | awk 'NF{c++} END{print c+0}')" -eq 2 ] \
    || fail "expected exactly 2 active rows, got a different count"
  pass "Done items are excluded; only active items appear"
}

test_row_shape() {
  local line fields
  line=$(run_todos | head -1)
  fields=$(printf '%s' "$line" | awk -F '\t' '{print NF}')
  [ "$fields" -eq 4 ] || fail "expected 4 tab-separated fields (state/priority/id/one-line), got $fields"
  pass "each row is 4 tab-separated fields: state, priority, id, one-line"
}

test_json() {
  local out
  out=$(run_todos --json)
  # Must be valid JSON and carry the same mapping.
  python3 - "$out" <<'PY' || fail "JSON output is not valid or maps wrong"
import json, sys
doc = json.loads(sys.argv[1])
assert len(doc) == 2, "expected 2 items, got %d" % len(doc)
by_id = {d["id"]: d for d in doc}
assert by_id["fix-login-k3"]["state"] == "in_progress"
assert by_id["fix-login-k3"]["priority"] == "high"
assert by_id["add-export-q9"]["state"] == "pending"
assert by_id["add-export-q9"]["priority"] == "medium"
assert "blocked-by: fix-login-k3" in by_id["add-export-q9"]["title"]
print("ok json")
PY
  pass "--json emits valid JSON mapping In flight/Queued to the right states and priorities"
}

test_deterministic_order() {
  # For the same backlog the output must be byte-identical across runs: no LLM
  # improvisation, no sorting surprises.
  local first last
  BACKLOG="$BACKLOG" diff <(run_todos) <(run_todos) >/dev/null \
    || fail "two runs of the same backlog produced different output"
  # In flight rows precede Queued rows (document order in the backlog).
  first=$(run_todos | head -1 | cut -f1)
  last=$(run_todos | tail -1 | cut -f1)
  [ "$first" = "in_progress" ] || fail "In flight did not precede Queued"
  [ "$last" = "pending" ] || fail "Queued did not follow In flight"
  pass "output is deterministic and preserves backlog order"
}

test_id_with_dashes() {
  # ids contain dashes (e.g. fix-login-k3); only the first " - " splits id from
  # the one-line, so the id must not be truncated.
  local b out id
  b="$TMP/dashes.md"
  cat > "$b" <<'EOF'
## In flight
- [ ] fix-multi-word-id-z3 - refactor the thing (repo: r)
EOF
  out=$(FM_BACKLOG="$b" "$TODOS")
  id=$(printf '%s\n' "$out" | cut -f3)
  [ "$id" = "fix-multi-word-id-z3" ] || fail "id with dashes was truncated to '$id'"
  pass "ids containing dashes are parsed whole (first ' - ' is the split)"
}

test_blank_and_unrecognized_lines() {
  local b out count
  b="$TMP/noise.md"
  cat > "$b" <<'EOF'
## In flight

- [ ] real-z4 - a real task (repo: r)

some freeform note that is not a list item

## Queued

- [ ] next-z5 - waits (repo: r) blocked-by: real-z4 - reason

## Done
- [x] old-z6 - done
EOF
  out=$(FM_BACKLOG="$b" "$TODOS")
  count=$(printf '%s\n' "$out" | awk 'NF{c++} END{print c+0}')
  [ "$count" -eq 2 ] || fail "expected 2 rows from noisy backlog, got $count"
  printf '%s\n' "$out" | grep -F 'freeform' >/dev/null \
    && fail "unrecognized freeform line leaked into output"
  pass "blank lines, freeform notes, and Done items are all skipped"
}

test_missing_backlog() {
  local tsv json
  tsv=$(FM_BACKLOG="$TMP/no-such-file.md" "$TODOS"; printf 'x')
  [ "$tsv" = "x" ] || fail "missing backlog should emit an empty TSV stream"
  json=$(FM_BACKLOG="$TMP/no-such-file.md" "$TODOS" --json)
  [ "$json" = "[]" ] || fail "missing backlog --json should be [], got '$json'"
  pass "a missing backlog yields an empty TSV stream and an empty JSON array"
}

test_help() {
  FM_BACKLOG="$BACKLOG" "$TODOS" --help >/dev/null 2>&1 \
    || fail "--help exits non-zero"
  pass "--help exits zero"
}

test_in_flight_row
test_queued_row
test_done_excluded
test_row_shape
test_json
test_deterministic_order
test_id_with_dashes
test_blank_and_unrecognized_lines
test_missing_backlog
test_help
