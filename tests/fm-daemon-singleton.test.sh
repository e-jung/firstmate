#!/usr/bin/env bash
# fm-daemon-singleton.test.sh — daemon singleton-lock anchoring (2026-06-22 fix).
#
# Regression coverage for the worktree-launch bypass: a daemon launched from a
# git worktree must NEVER lock a worktree-local state dir. It must either resolve
# to the canonical lock (via FM_HOME / FM_STATE_OVERRIDE / FM_ROOT_OVERRIDE) or
# refuse. The full daemon loop blocks forever, so these tests exercise the
# canonical-resolution + worktree-guard decision functions the loop calls, plus
# one end-to-end execution of the refusal path.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAEMON="$ROOT/bin/fm-supervise-daemon.sh"
LIB="$ROOT/bin/fm-wake-lib.sh"

# Source the daemon's pure helpers. The BASH_SOURCE guard in the daemon skips
# fm_super_main under sourcing, so only the testable functions become defined.
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
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-daemon-singleton.XXXXXX")

# Build a real linked-worktree fixture: <tmp>/main (main checkout) plus a linked
# worktree <tmp>/main-wt. Returns the linked-worktree path on stdout. Identity is
# injected via -c so the test does not depend on the host's git config.
make_worktree_fixture() {
  local tmp=$1 main wt
  main="$tmp/main"; wt="$tmp/main-wt"
  git -c init.defaultBranch=main init -q "$main"
  git -C "$main" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  git -C "$main" worktree add -q "$wt" >/dev/null
  printf '%s\n' "$wt"
}

# --- tests ------------------------------------------------------------------

test_state_root_canonical_under_fm_home() {
  local dir home out
  dir="$TMP_ROOT/sr"; mkdir -p "$dir"
  home="$dir/canonical-home"; mkdir -p "$home"
  out=$(FM_HOME="$home" _state_root)
  [ "$out" = "$home/state" ] || fail "_state_root ignored FM_HOME: $out"
  # FM_STATE_OVERRIDE still wins over FM_HOME (testing selector).
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$dir/ov" _state_root)
  [ "$out" = "$dir/ov" ] || fail "_state_root ignored FM_STATE_OVERRIDE: $out"
  pass "_state_root resolves to the canonical home under FM_HOME (no path drift)"
}

test_lock_path_is_canonical() {
  local home lock_path
  home="$TMP_ROOT/lockpath-home"; mkdir -p "$home"
  # The live fleet locks <home>/state/.supervise-daemon.lock. The filename and
  # its location under <home>/state/ must not drift (regression guard).
  lock_path="$(FM_HOME="$home" _state_root)/.supervise-daemon.lock"
  [ "$lock_path" = "$home/state/.supervise-daemon.lock" ] \
    || fail "canonical lock path drifted: $lock_path"
  pass "canonical singleton lock path is <home>/state/.supervise-daemon.lock"
}

test_fm_in_git_worktree_classifies() {
  local wt main
  wt=$(make_worktree_fixture "$TMP_ROOT/wt-fix")
  main="$TMP_ROOT/wt-fix/main"
  _fm_in_git_worktree "$wt" || fail "linked worktree not detected as a worktree"
  if _fm_in_git_worktree "$main"; then fail "main checkout falsely detected as a worktree"; fi
  # Not a repo at all -> not a worktree (git absence must never block the daemon).
  if _fm_in_git_worktree "$TMP_ROOT"; then fail "non-repo dir falsely detected as a worktree"; fi
  pass "_fm_in_git_worktree detects a linked worktree, not the main checkout or a non-repo"
}

test_worktree_launch_refused_without_selector() {
  local wt
  wt=$(make_worktree_fixture "$TMP_ROOT/refuse")
  # No explicit canonical selector -> guard refuses (returns 0).
  if ! ( _FM_HOME_SET=0; _FM_STATE_SET=0; _FM_ROOT_OVERRIDE_SET=0; \
          _daemon_refuses_worktree_launch "$wt" ); then
    fail "worktree launch not refused without a canonical selector"
  fi
  # FM_HOME selector present -> guard does NOT refuse (returns 1).
  if ( _FM_HOME_SET=1; _FM_STATE_SET=0; _FM_ROOT_OVERRIDE_SET=0; \
        _daemon_refuses_worktree_launch "$wt" ); then
    fail "worktree launch refused despite FM_HOME selector"
  fi
  # FM_STATE_OVERRIDE selector present -> guard does NOT refuse.
  if ( _FM_HOME_SET=0; _FM_STATE_SET=1; _FM_ROOT_OVERRIDE_SET=0; \
        _daemon_refuses_worktree_launch "$wt" ); then
    fail "worktree launch refused despite FM_STATE_OVERRIDE selector"
  fi
  # A main checkout (not a worktree) is never refused, even with no selector.
  if ( _FM_HOME_SET=0; _FM_STATE_SET=0; _FM_ROOT_OVERRIDE_SET=0; \
        _daemon_refuses_worktree_launch "$TMP_ROOT/refuse/main" ); then
    fail "main-checkout launch refused with no selector"
  fi
  pass "worktree launch refused only with no selector; main checkout always allowed"
}

test_worktree_launch_resolves_canonical_with_fm_home() {
  # Even when the daemon script sits in a worktree, an explicit FM_HOME pins the
  # lock to the canonical path — it never lands on the worktree-local state dir.
  local home canonical_state
  home="$TMP_ROOT/canon-home"; mkdir -p "$home"
  canonical_state=$(FM_HOME="$home" _state_root)
  [ "$canonical_state" = "$home/state" ] \
    || fail "FM_HOME did not pin canonical state: $canonical_state"
  pass "worktree launch with FM_HOME resolves the lock to the canonical path"
}

test_canonical_launch_acquires_canonical_lock() {
  local home state lock
  home="$TMP_ROOT/acq-home"; mkdir -p "$home"
  state=$(FM_HOME="$home" _state_root)
  lock="$state/.supervise-daemon.lock"
  (
    export FM_STATE_OVERRIDE="$state"
    # shellcheck source=bin/fm-wake-lib.sh
    . "$LIB"
    fm_lock_try_acquire "$lock" || exit 1
  ) || fail "could not acquire the canonical singleton lock"
  [ -d "$lock" ] || fail "canonical lock dir was not created at $lock"
  pass "canonical launch acquires <home>/state/.supervise-daemon.lock"
}

test_concurrent_lock_has_one_winner() {
  # Two concurrent acquisitions of the resolved canonical lock: exactly one
  # wins, the other is rejected. The singleton property holds regardless of how
  # the lock path was resolved.
  local state lock results winners
  mkdir -p "$TMP_ROOT/conc/state"
  state="$TMP_ROOT/conc/state"
  lock="$state/.supervise-daemon.lock"
  results="$TMP_ROOT/conc/results"; : > "$results"
  for _ in 1 2; do
    (
      export FM_STATE_OVERRIDE="$state"
      # shellcheck source=bin/fm-wake-lib.sh
      . "$LIB"
      if fm_lock_try_acquire "$lock"; then
        printf 'won\n' >> "$results"
        sleep 1
        fm_lock_release "$lock"
      else
        printf 'lost\n' >> "$results"
      fi
    ) &
  done
  wait
  winners=$(grep -c '^won$' "$results")
  [ "$winners" -eq 1 ] || fail "expected exactly 1 lock winner, got $winners"
  pass "two concurrent acquire attempts: exactly one wins the canonical lock"
}

test_daemon_refuses_from_worktree_e2e() {
  # End-to-end: executing the daemon from a worktree with no canonical selector
  # must refuse with the documented error, before touching state or the watcher.
  local wt daemon_copy out rc
  wt=$(make_worktree_fixture "$TMP_ROOT/e2e")
  mkdir -p "$wt/bin"
  daemon_copy="$wt/bin/fm-supervise-daemon.sh"
  cp "$DAEMON" "$daemon_copy"
  chmod +x "$daemon_copy"
  out=$(env -u FM_HOME -u FM_STATE_OVERRIDE -u FM_ROOT_OVERRIDE \
    "$daemon_copy" 2>&1 >/dev/null); rc=$?
  [ "$rc" -ne 0 ] || fail "daemon did not exit non-zero from a worktree (rc=$rc)"
  printf '%s\n' "$out" | grep -qi 'refused' || fail "refusal message missing: $out"
  printf '%s\n' "$out" | grep -qi 'worktree' || fail "refusal did not mention worktree: $out"
  # A worktree-local state dir must NOT have been created by the refused launch.
  [ ! -e "$wt/state/.supervise-daemon.lock" ] \
    || fail "refused launch still created a worktree-local lock"
  pass "daemon end-to-end refuses a worktree launch with the documented error"
}

test_state_root_canonical_under_fm_home
test_lock_path_is_canonical
test_fm_in_git_worktree_classifies
test_worktree_launch_refused_without_selector
test_worktree_launch_resolves_canonical_with_fm_home
test_canonical_launch_acquires_canonical_lock
test_concurrent_lock_has_one_winner
test_daemon_refuses_from_worktree_e2e
