#!/usr/bin/env bash
# Behavior tests for fm-fleet-sync.sh drift handling.
#
# fm-fleet-sync fast-forwards a clone that is cleanly on its default branch. This
# suite pins the two behavioral additions on top of that:
#   - the one safe drift self-heals: a clean, detached HEAD that holds no unique
#     commits (it is an ancestor of origin/<default>) and whose <default> is free
#     to check out is re-attached and then fast-forwarded ("recovered:").
#   - every other off-default state is left untouched and reported as a loud,
#     quantified "STUCK: ... N commits behind ... - needs attention" warning
#     instead of a quiet skip.
# The pre-existing fast-forward / already-current / local-only / no-origin paths
# must be unchanged, and bootstrap must relay the new outcomes as FLEET_SYNC lines.
#
# It also pins the orphaned .git/packed-refs.lock recovery in the fetch step
# (fetch_with_packed_refs_lock_guard, backed by bin/fm-lock-lib.sh's shared
# staleness proof): a provably-stale lock is retried then removed and the clone
# syncs (with a "recovered:" summary on stdout so a session-start refresh, which
# discards stderr, still surfaces it); a live lock (fake lsof holder) is never
# removed and the sync fails loudly; a live process merely holding the clone
# worktree dir as its cwd also blocks removal (the clone-dir liveness check); a
# transient lock that self-clears is retried without a force-remove; and any
# non-packed-refs.lock fetch failure keeps today's behavior with no retry.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-fleet-sync-tests)
HOME_N=0

# --- fixtures ---------------------------------------------------------------

# new_home: fresh isolated FM_HOME with an empty projects/ dir. Each test gets its
# own so the whole-fleet form never sees another test's clones.
new_home() {
  HOME_N=$((HOME_N + 1))
  local h="$TMP_ROOT/home-$HOME_N"
  mkdir -p "$h/projects"
  printf '%s\n' "$h"
}

commit_file() {
  local dir=$1 file=$2 content=$3 msg=$4
  printf '%s\n' "$content" > "$dir/$file"
  git -C "$dir" add "$file"
  git -C "$dir" commit -qm "$msg"
}

# build_pair <home> <name>: create projects/<name>, a clone of a fresh bare origin
# with one commit on main, plus a side "work-<name>" repo wired to that origin for
# advancing it later. Portable branch naming (no init -b) for older git.
build_pair() {
  local home=$1 name=$2 work remote clone remote_abs
  work="$home/work-$name"
  remote="$home/remotes/$name.git"
  clone="$home/projects/$name"
  mkdir -p "$home/remotes"

  git init -q "$work"
  git -C "$work" symbolic-ref HEAD refs/heads/main
  commit_file "$work" file.txt v0 C0

  git clone --quiet --bare "$work" "$remote"
  remote_abs=$(cd "$remote" && pwd)
  git -C "$work" remote add origin "file://$remote_abs"
  git -C "$work" push -q -u origin main

  git clone --quiet "file://$remote_abs" "$clone"
  printf '%s\n' "$clone"
}

# advance_origin <home> <name> <msg>: push one more commit to <name>'s origin via
# its work repo, so the clone (until it fetches) is one commit behind origin/main.
advance_origin() {
  local home=$1 name=$2 msg=$3 work
  work="$home/work-$name"
  commit_file "$work" file.txt "$msg" "$msg"
  git -C "$work" push -q origin main
}

head_sha() { git -C "$1" rev-parse HEAD; }

# run_sync <home> [args...]: run fleet-sync against an isolated home, stdout only.
run_sync() {
  local home=$1
  shift
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-sync.sh" "$@" 2>/dev/null
}

# --- packed-refs.lock fixtures ----------------------------------------------

# build_packed_prunable <home> <name>: like build_pair, but the clone has PACKED
# refs plus a local `feature` branch tracking a since-deleted origin/feature, so a
# fetch --prune must rewrite packed-refs - which an orphaned .git/packed-refs.lock
# blocks with Git's "Unable to create '...packed-refs.lock': File exists". origin/main
# is advanced by one commit so a successful sync fast-forwards. Echoes the clone path.
build_packed_prunable() {
  local home=$1 name=$2 work remote clone remote_abs
  work="$home/work-$name"
  remote="$home/remotes/$name.git"
  clone="$home/projects/$name"
  mkdir -p "$home/remotes"

  git init -q "$work"
  git -C "$work" symbolic-ref HEAD refs/heads/main
  commit_file "$work" file.txt v0 C0
  git clone --quiet --bare "$work" "$remote"
  remote_abs=$(cd "$remote" && pwd)
  git -C "$work" remote add origin "file://$remote_abs"
  git -C "$work" push -q -u origin main
  git -C "$work" push -q origin main:refs/heads/feature

  git clone --quiet "file://$remote_abs" "$clone"
  git -C "$clone" branch -q feature origin/feature
  commit_file "$work" file.txt v1 C1
  git -C "$work" push -q origin main
  git -C "$work" push -q origin --delete feature
  git -C "$clone" pack-refs --all
  printf '%s\n' "$clone"
}

plant_packed_refs_lock() { : > "$1/.git/packed-refs.lock"; }

# lsof shims mirror tests/fm-teardown.test.sh: no-holder (provably free), a live
# holder, and an lsof error. Written into a per-home fakebin/ prepended to PATH.
lsof_no_holder() {
  cat > "$1/lsof" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$1/lsof"
}
lsof_live_holder() {
  cat > "$1/lsof" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$1/lsof"
}

# lsof shim: a holder ONLY for $FLEET_TEST_LIVE_DIR (a live `git -C <clone>` keeping
# its cwd there), and no holder of the lock file itself - the exact window the
# clone-dir liveness check must cover.
lsof_holds_only_live_dir() {
  cat > "$1/lsof" <<'SH'
#!/usr/bin/env bash
target=
for a in "$@"; do case "$a" in --|-*) ;; *) target=$a ;; esac; done
[ -n "${FLEET_TEST_LIVE_DIR:-}" ] && [ "$target" = "$FLEET_TEST_LIVE_DIR" ] && exit 0
exit 1
SH
  chmod +x "$1/lsof"
}

# git shim: fail the FIRST `fetch` with the packed-refs.lock signature and drop
# the lock (simulating the dying ref-rewrite finishing), then delegate every
# later call - including the retried fetch - to the real git so the sync completes.
git_transient_packed_refs_lock() {
  cat > "$1/git" <<'SH'
#!/usr/bin/env bash
real=${REAL_GIT_FOR_TEST:?}
dir=; is_fetch=0
for a in "$@"; do [ "$a" = fetch ] && is_fetch=1; done
prev=
for a in "$@"; do [ "$prev" = -C ] && dir=$a; prev=$a; done
if [ "$is_fetch" = 1 ]; then
  n=$(cat "${GIT_FETCH_COUNTER:?}" 2>/dev/null || echo 0); n=$(( n + 1 ))
  printf '%s\n' "$n" > "$GIT_FETCH_COUNTER"
  if [ "$n" -eq 1 ]; then
    lock="$dir/.git/packed-refs.lock"
    echo "error: could not delete reference refs/remotes/origin/feature: Unable to create '$lock': File exists." >&2
    rm -f "$lock"
    exit 1
  fi
fi
exec "$real" "$@"
SH
  chmod +x "$1/git"
}

# run_sync_guarded <home> <fakebin> <outfile> <errfile> [args...]: run fleet-sync
# with the fakebin on PATH and stdout/stderr captured separately. Per-test knobs
# (FM_FLEET_SYNC_PACKED_REFS_LOCK_*, GIT_FETCH_COUNTER) are read from the caller's
# exported environment.
run_sync_guarded() {
  local home=$1 fakebin=$2 outf=$3 errf=$4 realgit
  shift 4
  realgit=$(command -v git)
  PATH="$fakebin:$PATH" REAL_GIT_FOR_TEST="$realgit" \
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-fleet-sync.sh" "$@" >"$outf" 2>"$errf"
}

# --- tests ------------------------------------------------------------------

test_detached_clean_ancestor_recovers() {
  local home clone out before after
  home=$(new_home)
  clone=$(build_pair "$home" alpha)
  advance_origin "$home" alpha C1
  before=$(head_sha "$clone")
  # Detach at the clone's main (C0), an ancestor of the now-advanced origin/main.
  git -C "$clone" checkout --detach --quiet

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "alpha: recovered: re-attached main, synced" "detached-clean-ancestor reports recovered"
  assert_not_contains "$out" "STUCK" "recovered case is not flagged STUCK"
  [ "$(git -C "$clone" symbolic-ref --short HEAD 2>/dev/null)" = "main" ] \
    || fail "expected re-attach to main, HEAD still detached"
  after=$(head_sha "$clone")
  [ "$after" != "$before" ] || fail "expected fast-forward after re-attach, HEAD unchanged"
  [ "$after" = "$(git -C "$clone" rev-parse origin/main)" ] \
    || fail "expected HEAD at origin/main after recovery"
  pass "detached clean ancestor is re-attached and fast-forwarded (recovered)"
}

test_detached_unique_commit_is_stuck_untouched() {
  local home clone out before
  home=$(new_home)
  clone=$(build_pair "$home" beta)
  git -C "$clone" checkout --detach --quiet
  commit_file "$clone" extra.txt unique "local unique work"
  before=$(head_sha "$clone")
  advance_origin "$home" beta C1

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "beta: STUCK:" "detached-with-unique-commit reports STUCK"
  assert_contains "$out" "unique commits" "STUCK names the unique-commit state"
  assert_contains "$out" "commits behind origin/main - needs attention" "STUCK is quantified"
  assert_not_contains "$out" "recovered" "unique-commit case is never recovered"
  [ "$(head_sha "$clone")" = "$before" ] || fail "expected unique-commit detached HEAD left untouched"
  pass "detached HEAD with unique commits is reported STUCK and left untouched"
}

test_detached_clean_ancestor_with_diverged_local_default_is_stuck_untouched() {
  local home clone out before local_main
  home=$(new_home)
  clone=$(build_pair "$home" beta-local-default)
  commit_file "$clone" local.txt local "local divergent main commit"
  local_main=$(git -C "$clone" rev-parse main)
  git -C "$clone" checkout --detach --quiet HEAD^
  before=$(head_sha "$clone")
  advance_origin "$home" beta-local-default C1

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "beta-local-default: STUCK:" "diverged local default reports STUCK"
  assert_contains "$out" "local main diverged from origin/main" "STUCK names the unsafe local default"
  assert_not_contains "$out" "recovered" "diverged local default is never recovered"
  [ "$(head_sha "$clone")" = "$before" ] || fail "detached HEAD was moved"
  ! git -C "$clone" symbolic-ref -q HEAD >/dev/null || fail "clone re-attached to local default"
  [ "$(git -C "$clone" rev-parse main)" = "$local_main" ] || fail "local default branch was moved"
  pass "detached clean ancestor with diverged local default is reported STUCK and left untouched"
}

test_dirty_is_stuck_untouched() {
  local home clone out before
  home=$(new_home)
  clone=$(build_pair "$home" gamma)
  advance_origin "$home" gamma C1
  before=$(head_sha "$clone")
  printf 'uncommitted edit\n' >> "$clone/file.txt"

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "gamma: STUCK:" "dirty clone reports STUCK"
  assert_contains "$out" "uncommitted changes" "STUCK names the dirty state"
  assert_contains "$out" "1 commits behind origin/main" "STUCK quantifies how far behind"
  [ "$(head_sha "$clone")" = "$before" ] || fail "dirty clone HEAD was moved"
  grep -q "uncommitted edit" "$clone/file.txt" || fail "dirty working-tree change was discarded"
  pass "dirty working tree is reported STUCK and left untouched"
}

test_non_default_branch_is_stuck_untouched() {
  local home clone out
  home=$(new_home)
  clone=$(build_pair "$home" delta)
  git -C "$clone" checkout -q -b feature
  advance_origin "$home" delta C1

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "delta: STUCK: on branch feature" "non-default branch reports STUCK with branch name"
  assert_contains "$out" "commits behind origin/main - needs attention" "STUCK is quantified"
  assert_not_contains "$out" "recovered" "named branch is never auto-changed"
  [ "$(git -C "$clone" symbolic-ref --short HEAD)" = "feature" ] || fail "named branch checkout was changed"
  pass "non-default named branch is reported STUCK and left untouched"
}

test_diverged_is_stuck_untouched() {
  local home clone out before
  home=$(new_home)
  clone=$(build_pair "$home" epsilon)
  # Local main gains its own commit; origin advances down a different line.
  commit_file "$clone" local.txt local "local divergent commit"
  before=$(head_sha "$clone")
  advance_origin "$home" epsilon C1

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "epsilon: STUCK:" "diverged clone reports STUCK"
  assert_contains "$out" "diverged main" "STUCK names the diverged state"
  assert_contains "$out" "commits behind origin/main - needs attention" "STUCK is quantified"
  [ "$(head_sha "$clone")" = "$before" ] || fail "diverged clone was moved"
  pass "diverged default branch is reported STUCK and left untouched"
}

test_on_default_clean_behind_fast_forwards() {
  local home clone out
  home=$(new_home)
  clone=$(build_pair "$home" zeta)
  advance_origin "$home" zeta C1

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "zeta: synced" "on-default clean behind fast-forwards as before"
  assert_not_contains "$out" "recovered" "ordinary fast-forward is not labelled recovered"
  assert_not_contains "$out" "STUCK" "ordinary fast-forward is not flagged STUCK"
  [ "$(head_sha "$clone")" = "$(git -C "$clone" rev-parse origin/main)" ] || fail "clone was not fast-forwarded"
  pass "on-default clean behind clone still fast-forwards"
}

test_already_current_unchanged() {
  local home clone out before
  home=$(new_home)
  clone=$(build_pair "$home" eta)
  before=$(head_sha "$clone")

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "eta: already current" "already-current clone reports unchanged"
  assert_not_contains "$out" "STUCK" "already-current is not flagged STUCK"
  assert_not_contains "$out" "recovered" "already-current is not labelled recovered"
  [ "$(head_sha "$clone")" = "$before" ] || fail "already-current clone was moved"
  pass "already-current clone is reported unchanged"
}

test_no_origin_skipped() {
  local home clone out
  home=$(new_home)
  clone="$home/projects/theta"
  git init -q "$clone"
  git -C "$clone" symbolic-ref HEAD refs/heads/main
  commit_file "$clone" file.txt v0 C0

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "theta: skipped: no origin remote" "no-origin clone is skipped as before"
  assert_not_contains "$out" "STUCK" "no-origin skip is not escalated to STUCK"
  pass "no-origin clone is skipped (benign), not flagged STUCK"
}

test_local_only_skipped() {
  local home clone out
  home=$(new_home)
  clone=$(build_pair "$home" iota)
  advance_origin "$home" iota C1
  mkdir -p "$home/data"
  printf -- '- iota [local-only] - test project (added 2026-06-27)\n' > "$home/data/projects.md"

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "iota: skipped: local-only project" "local-only clone is skipped as before"
  assert_not_contains "$out" "STUCK" "local-only skip is not escalated to STUCK"
  pass "local-only clone is skipped (benign), not flagged STUCK"
}

test_single_project_by_bare_name_resolves() {
  local home out
  home=$(new_home)
  build_pair "$home" kappa >/dev/null
  advance_origin "$home" kappa C1

  out=$(run_sync "$home" "kappa")

  assert_contains "$out" "kappa: synced" "bare project name resolves against the home's projects dir"
  pass "single-project form accepts a bare project name"
}

test_single_project_by_bare_name_ignores_cwd_shadow() {
  local home cwd out
  home=$(new_home)
  build_pair "$home" mu >/dev/null
  advance_origin "$home" mu C1
  cwd="$home/shadow"
  mkdir -p "$cwd/mu"

  out=$(cd "$cwd" && run_sync "$home" "mu")

  assert_contains "$out" "mu: synced" "bare project name prefers the home's projects dir"
  assert_not_contains "$out" "skipped: not a git repo" "bare project name ignores a cwd shadow directory"
  pass "single-project bare name resolution is not cwd-sensitive"
}

test_single_project_by_projects_relative_name_resolves() {
  local home out
  home=$(new_home)
  build_pair "$home" lambda >/dev/null
  advance_origin "$home" lambda C1

  out=$(run_sync "$home" "projects/lambda")

  assert_contains "$out" "lambda: synced" "projects/<name> form resolves against the home's projects dir"
  pass "single-project form accepts a projects/<name> relative name"
}

test_single_project_by_projects_relative_name_ignores_cwd_shadow() {
  local home cwd out
  home=$(new_home)
  build_pair "$home" nu >/dev/null
  advance_origin "$home" nu C1
  cwd="$home/shadow"
  mkdir -p "$cwd/projects/nu"

  out=$(cd "$cwd" && run_sync "$home" "projects/nu")

  assert_contains "$out" "nu: synced" "projects/<name> form prefers the home's projects dir"
  assert_not_contains "$out" "skipped: not a git repo" "projects/<name> form ignores a cwd shadow directory"
  pass "single-project projects/<name> resolution is not cwd-sensitive"
}

test_single_project_unresolvable_name_still_skips() {
  local home out
  home=$(new_home)

  out=$(run_sync "$home" "does-not-exist")

  assert_contains "$out" "skipped: not a directory" "an unresolvable name still hits the existing not-a-directory skip"
  pass "single-project form leaves a genuinely bad name unresolved"
}

test_whole_fleet_form() {
  local home behind current out
  home=$(new_home)
  behind=$(build_pair "$home" fleet-behind)
  advance_origin "$home" fleet-behind C1
  current=$(build_pair "$home" fleet-current)

  # Whole-fleet form: no project-dir argument.
  out=$(run_sync "$home")

  assert_contains "$out" "fleet-behind: synced" "whole-fleet form syncs a behind clone"
  assert_contains "$out" "fleet-current: already current" "whole-fleet form reports a current clone"
  : "$behind $current"
  pass "whole-fleet form processes every clone under projects/"
}

test_bootstrap_relays_recovered_and_stuck() {
  local home stuck rec out
  home=$(new_home)
  # A clone we will leave STUCK (dirty), and one that self-heals (detached-clean-ancestor).
  stuck=$(build_pair "$home" stuck-clone)
  advance_origin "$home" stuck-clone C1
  printf 'dirty\n' >> "$stuck/file.txt"
  rec=$(build_pair "$home" rec-clone)
  advance_origin "$home" rec-clone C1
  git -C "$rec" checkout --detach --quiet

  # Full bootstrap: no state/ dir -> secondmate sync no-ops; no .env -> X mode off.
  # We only assert the fleet-sync relay lines; other detect lines are irrelevant.
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)

  assert_contains "$out" "FLEET_SYNC: stuck-clone: STUCK:" "bootstrap relays the STUCK outcome"
  assert_contains "$out" "FLEET_SYNC: rec-clone: recovered:" "bootstrap relays the recovered outcome"
  pass "bootstrap relays recovered: and STUCK: fleet-sync outcomes"
}

# --- packed-refs.lock guard tests -------------------------------------------

test_orphaned_stale_packed_refs_lock_recovers() {
  local home fakebin clone out err
  home=$(new_home)
  fakebin="$home/fb-lockstale"; rm -rf "$fakebin"; mkdir -p "$fakebin"
  clone=$(build_packed_prunable "$home" lockstale)
  plant_packed_refs_lock "$clone"
  lsof_no_holder "$fakebin"           # provably no live holder
  out="$home/out-lockstale"; err="$home/err-lockstale"

  set +e
  FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=2 \
  FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=0 \
  FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS=0 \
    run_sync_guarded "$home" "$fakebin" "$out" "$err" lockstale
  set -e

  assert_grep "removed provably-stale packed-refs lock" "$err" \
    "stale lock: guard did not force-remove the provably-stale lock"
  assert_grep "fetch succeeded after stale packed-refs lock cleanup" "$err" \
    "stale lock: fetch did not succeed after cleanup"
  assert_contains "$(cat "$out")" "lockstale: synced" "stale lock: clone did not sync after recovery"
  assert_grep "recovered: removed a stale packed-refs lock" "$out" \
    "stale lock: recovery summary not emitted on stdout (bootstrap relays stdout, discards stderr)"
  assert_absent "$clone/.git/packed-refs.lock" "stale lock: lock should be gone after removal"
  [ "$(git -C "$clone" rev-parse HEAD)" = "$(git -C "$clone" rev-parse origin/main)" ] \
    || fail "stale lock: clone HEAD not at origin/main after recovery"
  pass "orphaned provably-stale packed-refs.lock is cleared and the clone syncs"
}

test_live_packed_refs_lock_is_never_removed() {
  local home fakebin clone out err before
  home=$(new_home)
  fakebin="$home/fb-locklive"; rm -rf "$fakebin"; mkdir -p "$fakebin"
  clone=$(build_packed_prunable "$home" locklive)
  plant_packed_refs_lock "$clone"
  lsof_live_holder "$fakebin"         # a live process holds the lock/.git open
  before=$(head_sha "$clone")
  out="$home/out-locklive"; err="$home/err-locklive"

  set +e
  FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=2 \
  FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=0 \
  FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS=0 \
    run_sync_guarded "$home" "$fakebin" "$out" "$err" locklive
  set -e

  assert_grep "is not provably stale" "$err" "live lock: guard did not explain the refusal"
  assert_no_grep "removed provably-stale packed-refs lock" "$err" \
    "live lock: guard force-removed a live lock"
  assert_contains "$(cat "$out")" "locklive: skipped: fetch failed" "live lock: fleet-sync did not skip"
  assert_present "$clone/.git/packed-refs.lock" "live lock: lock must never be removed"
  [ "$(head_sha "$clone")" = "$before" ] || fail "live lock: clone was advanced despite the refusal"
  pass "a live packed-refs.lock is never removed and the sync fails loudly"
}

test_live_git_cwd_in_clone_dir_blocks_removal() {
  local home fakebin clone out err before
  home=$(new_home)
  fakebin="$home/fb-lockcwd"; rm -rf "$fakebin"; mkdir -p "$fakebin"
  clone=$(build_packed_prunable "$home" lockcwd)
  plant_packed_refs_lock "$clone"
  # Nobody holds the lock file, but a live process holds the clone worktree as its
  # cwd - the narrow race where git closed packed-refs.lock but has not yet exited.
  lsof_holds_only_live_dir "$fakebin"
  before=$(head_sha "$clone")
  out="$home/out-lockcwd"; err="$home/err-lockcwd"

  set +e
  FLEET_TEST_LIVE_DIR="$clone" \
  FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=2 \
  FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=0 \
  FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS=0 \
    run_sync_guarded "$home" "$fakebin" "$out" "$err" lockcwd
  set -e

  assert_grep "is not provably stale" "$err" "clone-cwd holder: guard did not refuse"
  assert_no_grep "removed provably-stale packed-refs lock" "$err" \
    "clone-cwd holder: guard removed a lock while a live process held the clone dir"
  assert_present "$clone/.git/packed-refs.lock" "clone-cwd holder: lock must not be removed"
  [ "$(head_sha "$clone")" = "$before" ] || fail "clone-cwd holder: clone was advanced despite the refusal"
  pass "a live process holding the clone worktree dir blocks lock removal (clone-dir liveness)"
}

test_transient_packed_refs_lock_self_clears() {
  local home fakebin clone out err counter
  home=$(new_home)
  fakebin="$home/fb-locktrans"; rm -rf "$fakebin"; mkdir -p "$fakebin"
  clone=$(build_packed_prunable "$home" locktrans)
  plant_packed_refs_lock "$clone"
  git_transient_packed_refs_lock "$fakebin"   # fail once + drop lock, then real git
  counter="$home/git-fetch-count"; : > "$counter"
  out="$home/out-locktrans"; err="$home/err-locktrans"

  set +e
  GIT_FETCH_COUNTER="$counter" \
  FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=3 \
  FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=0 \
    run_sync_guarded "$home" "$fakebin" "$out" "$err" locktrans
  set -e

  assert_grep "cleared on its own" "$err" "transient lock: guard did not report the self-clear"
  assert_no_grep "removed provably-stale packed-refs lock" "$err" \
    "transient lock: guard force-removed a lock that only needed patience"
  assert_contains "$(cat "$out")" "locktrans: synced" "transient lock: clone did not sync after self-clear"
  assert_grep "recovered: packed-refs lock cleared on its own" "$out" \
    "transient lock: recovery summary not emitted on stdout"
  assert_absent "$clone/.git/packed-refs.lock" "transient lock: lock should be gone after self-clear"
  pass "a transient packed-refs.lock that self-clears is retried without a force-remove"
}

test_non_signature_fetch_failure_is_not_retried() {
  local home fakebin clone out err
  home=$(new_home)
  fakebin="$home/fb-locknonsig"; rm -rf "$fakebin"; mkdir -p "$fakebin"
  clone=$(build_pair "$home" locknonsig)
  advance_origin "$home" locknonsig C1
  git -C "$clone" remote set-url origin "file://$home/remotes/does-not-exist.git"
  out="$home/out-locknonsig"; err="$home/err-locknonsig"

  set +e
  FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=3 \
  FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=0 \
    run_sync_guarded "$home" "$fakebin" "$out" "$err" locknonsig
  set -e

  assert_contains "$(cat "$out")" "locknonsig: skipped: fetch failed" "non-signature: fleet-sync did not report the fetch failure"
  assert_no_grep "waiting" "$err" "non-signature: a non-lock failure was wrongly retried"
  assert_no_grep "packed-refs lock" "$err" "non-signature: a non-lock failure entered the lock guard"
  pass "a non-packed-refs.lock fetch failure keeps today's behavior (no retry)"
}

# --- fork-sync tests --------------------------------------------------------
#
# sync_fork_default fast-forwards a no-mistakes gate fork's default branch from
# its upstream parent (via the merge-upstream API) and refreshes the gate
# bare-repo's origin/<default> ref. These tests pin the fork-detection +
# fast-forward-only decision logic using a mock gh, without hitting GitHub.

# build_forked_project <home> <name>: creates a project clone wired like a real
# no-mistakes gate setup:
#   - clone origin      = upstream bare repo (at C0)
#   - clone no-mistakes  = gate bare repo
#   - gate origin        = https://github.com/testowner/testrepo.git (fake fork URL)
#   - gate url.insteadOf  redirects that fake URL to a local fork bare repo
#   - fork                = bare clone of upstream at C0
# The fork's work repo lives at $home/work-fork-<name> (push there to advance it).
# Echoes the clone path.
build_forked_project() {
  local home=$1 name=$2
  local up_work up_git fork_git fork_work gate_git clone up_abs fork_abs
  up_work="$home/work-up-$name"
  up_git="$home/up-$name.git"
  fork_git="$home/fork-$name.git"
  fork_work="$home/work-fork-$name"
  gate_git="$home/gate-$name.git"
  clone="$home/projects/$name"
  mkdir -p "$home/projects"

  git init -q "$up_work"
  git -C "$up_work" symbolic-ref HEAD refs/heads/main
  commit_file "$up_work" file.txt v0 C0
  git clone --quiet --bare "$up_work" "$up_git"
  up_abs=$(cd "$up_git" && pwd)
  git -C "$up_work" remote add origin "file://$up_abs"
  git -C "$up_work" push -q -u origin main

  git clone --quiet --bare "file://$up_abs" "$fork_git"
  fork_abs=$(cd "$fork_git" && pwd)
  git clone --quiet "file://$fork_abs" "$fork_work"

  git clone --quiet --bare "file://$fork_abs" "$gate_git"
  git -C "$gate_git" remote set-url origin "https://github.com/testowner/testrepo.git"
  git -C "$gate_git" config "url.file://$fork_abs.insteadOf" "https://github.com/testowner/testrepo.git"
  git -C "$gate_git" fetch -q origin '+refs/heads/*:refs/remotes/origin/*'

  git clone --quiet "file://$up_abs" "$clone"
  git -C "$clone" remote add no-mistakes "$gate_git"
  printf '%s\n' "$clone"
}

# write_mock_gh <fakebin>: drop a mock gh that responds to the three API calls
# sync_fork_default makes. Controlled by env vars:
#   GH_FORK       - "true"/"false" (is the repo a fork)
#   GH_PARENT     - parent full_name
#   GH_DEFAULT    - default branch
#   GH_COMPARE    - compare status (behind|identical|diverged|ahead)
#   GH_MERGE_TYPE - merge_type result (fast-forward|merge|none)
#   GH_MERGE_FAIL - if set, merge-upstream exits 1
#   GH_MERGE_LOG  - file touched when merge-upstream is called
write_mock_gh() {
  cat > "$1/gh" <<'SH'
#!/usr/bin/env bash
path=
for a in "$@"; do
  case "$a" in /*) path=$a; break ;; esac
done
case "$path" in
  */merge-upstream)
    [ -n "${GH_MERGE_LOG:-}" ] && : >> "$GH_MERGE_LOG"
    if [ -n "${GH_MERGE_FAIL:-}" ]; then
      printf '%s\n' "HTTP 409: merge conflict (mocked)" >&2
      exit 1
    fi
    printf '%s\n' "${GH_MERGE_TYPE:-fast-forward}"
    ;;
  */compare/*)
    printf '%s\n' "${GH_COMPARE:-behind}"
    ;;
  /repos/*)
    printf '%s\t%s\t%s\n' "${GH_FORK:-true}" "${GH_PARENT:-upstream-owner/testrepo}" "${GH_DEFAULT:-main}"
    ;;
  *)
    printf 'mock gh: unexpected path: %s\n' "$path" >&2
    exit 1
    ;;
esac
SH
  chmod +x "$1/gh"
}

# run_sync_fork <home> <fakebin> [args...]: run fleet-sync with the mock gh.
run_sync_fork() {
  local home=$1 fakebin=$2
  shift 2
  PATH="$fakebin:$PATH" \
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-fleet-sync.sh" "$@" 2>/dev/null
}

test_fork_behind_syncs() {
  local home fakebin clone out fork_work gate merge_log fork_main gate_main
  home=$(new_home)
  fakebin="$home/fb"; mkdir -p "$fakebin"
  write_mock_gh "$fakebin"
  clone=$(build_forked_project "$home" forksync)
  fork_work="$home/work-fork-forksync"
  gate="$home/gate-forksync.git"
  merge_log="$home/merge-forksync"

  commit_file "$fork_work" file.txt v1 C1
  git -C "$fork_work" push -q origin main
  fork_main=$(git -C "$fork_work" rev-parse main)

  out=$(GH_MERGE_LOG="$merge_log" run_sync_fork "$home" "$fakebin" forksync)

  assert_contains "$out" "forksync: fork-synced:" "behind fork should report synced"
  assert_contains "$out" "upstream-owner/testrepo" "synced line names the parent"
  [ -f "$merge_log" ] || fail "merge-upstream was not called for a behind fork"
  gate_main=$(git -C "$gate" rev-parse refs/remotes/origin/main)
  [ "$gate_main" = "$fork_main" ] || fail "gate origin/main was not refreshed to fork's main"
  pass "a behind fork is fast-forwarded and the gate ref is refreshed"
}

test_fork_diverged_skips_merge_upstream() {
  local home fakebin clone out merge_log
  home=$(new_home)
  fakebin="$home/fb"; mkdir -p "$fakebin"
  write_mock_gh "$fakebin"
  clone=$(build_forked_project "$home" forkdiv)
  merge_log="$home/merge-forkdiv"

  out=$(GH_COMPARE=diverged GH_MERGE_LOG="$merge_log" run_sync_fork "$home" "$fakebin" forkdiv)

  assert_contains "$out" "forkdiv: fork-sync: skipped: diverged" "diverged fork should report skipped"
  [ ! -f "$merge_log" ] || fail "merge-upstream was called for a diverged fork"
  pass "a diverged fork is skipped and merge-upstream is never called"
}

test_non_fork_silently_ignored() {
  local home fakebin clone out merge_log
  home=$(new_home)
  fakebin="$home/fb"; mkdir -p "$fakebin"
  write_mock_gh "$fakebin"
  clone=$(build_forked_project "$home" forknon)
  merge_log="$home/merge-forknon"

  out=$(GH_FORK=false GH_MERGE_LOG="$merge_log" run_sync_fork "$home" "$fakebin" forknon)

  assert_not_contains "$out" "fork-sync" "non-fork should produce no fork-sync line"
  [ ! -f "$merge_log" ] || fail "merge-upstream was called for a non-fork"
  pass "a non-fork repo is silently ignored (no fork-sync output)"
}

test_fork_already_current_no_merge_upstream() {
  local home fakebin clone out merge_log
  home=$(new_home)
  fakebin="$home/fb"; mkdir -p "$fakebin"
  write_mock_gh "$fakebin"
  clone=$(build_forked_project "$home" forkcur)
  merge_log="$home/merge-forkcur"

  out=$(GH_COMPARE=identical GH_MERGE_LOG="$merge_log" run_sync_fork "$home" "$fakebin" forkcur)

  assert_contains "$out" "forkcur: fork-sync: already current" "identical fork should report already current"
  [ ! -f "$merge_log" ] || fail "merge-upstream was called for an already-current fork"
  pass "an already-current fork reports 'already current' without calling merge-upstream"
}

test_fork_merge_upstream_failure_skips() {
  local home fakebin clone out merge_log
  home=$(new_home)
  fakebin="$home/fb"; mkdir -p "$fakebin"
  write_mock_gh "$fakebin"
  clone=$(build_forked_project "$home" forkfail)
  merge_log="$home/merge-forkfail"

  out=$(GH_MERGE_FAIL=1 GH_MERGE_LOG="$merge_log" run_sync_fork "$home" "$fakebin" forkfail)

  assert_contains "$out" "forkfail: fork-sync: skipped: merge-upstream failed" "failed merge-upstream should report skipped"
  [ -f "$merge_log" ] || fail "merge-upstream marker not touched despite GH_MERGE_FAIL"
  pass "a merge-upstream failure is reported and skipped"
}

test_fork_sync_disabled_by_env() {
  local home fakebin clone out merge_log
  home=$(new_home)
  fakebin="$home/fb"; mkdir -p "$fakebin"
  write_mock_gh "$fakebin"
  clone=$(build_forked_project "$home" forkoff)
  merge_log="$home/merge-forkoff"

  out=$(FM_FORK_SYNC=0 GH_MERGE_LOG="$merge_log" run_sync_fork "$home" "$fakebin" forkoff)

  assert_not_contains "$out" "fork-sync" "FM_FORK_SYNC=0 should suppress all fork-sync output"
  [ ! -f "$merge_log" ] || fail "merge-upstream was called despite FM_FORK_SYNC=0"
  pass "FM_FORK_SYNC=0 disables fork sync entirely"
}

test_bootstrap_relays_fork_sync_diverged() {
  local home fakebin clone out merge_log
  home=$(new_home)
  fakebin="$home/fb"; mkdir -p "$fakebin"
  write_mock_gh "$fakebin"
  clone=$(build_forked_project "$home" forkrelay)
  merge_log="$home/merge-forkrelay"

  out=$(GH_COMPARE=diverged GH_MERGE_LOG="$merge_log" \
    PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)

  assert_contains "$out" "FLEET_SYNC: forkrelay: fork-sync: skipped: diverged" \
    "bootstrap relays the fork-sync diverged line"
  pass "bootstrap relays fork-sync diverged as a FLEET_SYNC line"
}

test_detached_clean_ancestor_recovers
test_detached_unique_commit_is_stuck_untouched
test_detached_clean_ancestor_with_diverged_local_default_is_stuck_untouched
test_dirty_is_stuck_untouched
test_non_default_branch_is_stuck_untouched
test_diverged_is_stuck_untouched
test_on_default_clean_behind_fast_forwards
test_already_current_unchanged
test_no_origin_skipped
test_local_only_skipped
test_single_project_by_bare_name_resolves
test_single_project_by_bare_name_ignores_cwd_shadow
test_single_project_by_projects_relative_name_resolves
test_single_project_by_projects_relative_name_ignores_cwd_shadow
test_single_project_unresolvable_name_still_skips
test_whole_fleet_form
test_bootstrap_relays_recovered_and_stuck
test_orphaned_stale_packed_refs_lock_recovers
test_live_packed_refs_lock_is_never_removed
test_live_git_cwd_in_clone_dir_blocks_removal
test_transient_packed_refs_lock_self_clears
test_non_signature_fetch_failure_is_not_retried
test_fork_behind_syncs
test_fork_diverged_skips_merge_upstream
test_non_fork_silently_ignored
test_fork_already_current_no_merge_upstream
test_fork_merge_upstream_failure_skips
test_fork_sync_disabled_by_env
test_bootstrap_relays_fork_sync_diverged
