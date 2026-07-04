#!/usr/bin/env bash
# Behavior tests for deterministic todo extraction from data/backlog.md.
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

TMP_ROOT=

cleanup() {
  if [ -n "${TMP_ROOT:-}" ]; then
    rm -rf "$TMP_ROOT"
  fi
}
trap cleanup EXIT

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-todos-tests.XXXXXX")
BACKLOG="$TMP_ROOT/backlog.md"
OUT="$TMP_ROOT/todos.out"
EXPECTED="$TMP_ROOT/expected.out"

cat > "$BACKLOG" <<'EOF'
# Backlog

## In flight

- [ ] live-task - active work (repo: alpha, since 2026-06-20)
- **bold-live** - bold active work (repo: beta, since 2026-06-21)

## Queued

- [ ] feat-x - add feature x (repo: alpha)
- [ ] feat-y - add feature y (repo: beta) blocked-by: feat-x - waits

## Done

- [x] done-task - shipped already (repo: gamma) https://example.test/pr/1 2026-06-19
EOF

cat > "$EXPECTED" <<'EOF'
in_progress	high	live-task	active work (repo: alpha, since 2026-06-20)
in_progress	high	bold-live	bold active work (repo: beta, since 2026-06-21)
pending	medium	feat-x	add feature x (repo: alpha)
pending	medium	feat-y	add feature y (repo: beta) blocked-by: feat-x - waits
EOF

"$TODOS" --file "$BACKLOG" > "$OUT" || fail "fm-todos exited non-zero"
cmp -s "$EXPECTED" "$OUT" || {
  printf 'expected:\n' >&2
  cat "$EXPECTED" >&2
  printf 'actual:\n' >&2
  cat "$OUT" >&2
  fail "todo rows did not match expected extraction"
}

if grep -F 'done-task' "$OUT" >/dev/null; then
  fail "Done items should be excluded"
fi

if ! grep -F "$(printf 'pending\tmedium\tfeat-y\tadd feature y (repo: beta) blocked-by: feat-x - waits')" "$OUT" >/dev/null; then
  fail "blocked-by detail was not preserved"
fi

pass "fm-todos emits in-flight and queued backlog items deterministically"
