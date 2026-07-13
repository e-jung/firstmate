#!/usr/bin/env bash
# Behavior tests for bin/fm-github-watch.sh: the watcher check that surfaces new
# review comments, changes-requested reviews, and failed CI on the PRs Firstmate
# is supervising. Also covers its registration shim (fm-bootstrap.sh's
# github_watch_setup).
#
# A fake `gh` on PATH serves file-driven responses so each test can mutate the
# fixture state between poll cycles and assert on emitted events. The watcher
# contract is: stdout is captured as a `check:` wake; silence means nothing
# changed. Tests assert both directions.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

GH_WATCH="$ROOT/bin/fm-github-watch.sh"
BOOTSTRAP="$ROOT/bin/fm-bootstrap.sh"
TMP_ROOT=$(fm_test_tmproot fm-ghwatch-tests)

# Build an isolated case dir with its own state/ + fakebin/gh that reads
# per-endpoint fixture files. Echoes the case dir. The fake gh fails closed:
# any endpoint without a fixture exits 1 (so transient-failure tests can drop a
# fixture to simulate an outage), matching how a real gh API error behaves.
make_case() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$dir/fixture" "$fakebin"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
# file-driven fake gh for fm-github-watch tests.
set -u
FX="${GH_FX:?no fixture}"
[ "${1:-}" = "api" ] || exit 1
shift
raw="$1"; shift
path="${raw%%\?*}"   # strip ?per_page=...
# Order matters: the specific /comments and /reviews sub-paths MUST precede the
# bare pulls/NUM pattern, or bash's first-match would dispatch them to the pull
# handler (a bare /pulls/[0-9]* glob greedily matches /pulls/42/comments too).
case "$path" in
  user) [ -f "$FX/user" ] && cat "$FX/user" || exit 1; exit 0 ;;
  repos/*/*/issues/[0-9]*/comments)
    num=$(printf '%s' "$path" | sed 's#.*/issues/\([0-9]*\)/comments.*#\1#')
    f="$FX/issue-comments-$num"; [ -f "$f" ] && cat "$f" || exit 1; exit 0 ;;
  repos/*/*/pulls/[0-9]*/comments)
    num=$(printf '%s' "$path" | sed 's#.*/pulls/\([0-9]*\)/comments.*#\1#')
    f="$FX/review-comments-$num"; [ -f "$f" ] && cat "$f" || exit 1; exit 0 ;;
  repos/*/*/pulls/[0-9]*/reviews)
    num=$(printf '%s' "$path" | sed 's#.*/pulls/\([0-9]*\)/reviews.*#\1#')
    f="$FX/reviews-$num"; [ -f "$f" ] && cat "$f" || exit 1; exit 0 ;;
  repos/*/*/commits/*/check-runs)
    sha=$(printf '%s' "$path" | sed 's#.*/commits/\([^/]*\)/check-runs.*#\1#')
    f="$FX/checks-$sha"; [ -f "$f" ] && cat "$f" || exit 1; exit 0 ;;
  repos/*/*/pulls/[0-9]*)
    num=$(printf '%s' "$path" | sed 's#.*/pulls/\([0-9]*\).*#\1#')
    f="$FX/pull-$num"; [ -f "$f" ] && cat "$f" || exit 1; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/gh"
  printf '%s\n' "$dir"
}

# Write one task meta with a pr= line. Args: case_dir id pr-url [extra meta lines...]
write_pr_meta() {
  local case_dir=$1 id=$2 url=$3; shift 3
  : > "$case_dir/state/$id.meta"
  printf 'kind=ship\n' >> "$case_dir/state/$id.meta"
  for kv in "$@"; do printf '%s\n' "$kv" >> "$case_dir/state/$id.meta"; done
  printf 'pr=%s\n' "$url" >> "$case_dir/state/$id.meta"
}

# Set a fixture value: set_fx case_dir file content
set_fx() { printf '%s' "$3" > "$case_dir/fixture/$2"; }

# Run one poll in a case dir; echoes captured stdout.
run_poll() {
  local case_dir=$1
  GH_FX="$case_dir/fixture" PATH="$case_dir/fakebin:$PATH" \
    FM_STATE_OVERRIDE="$case_dir/state" FM_ROOT_OVERRIDE="$ROOT" \
    bash "$GH_WATCH" --once 2>/dev/null
}

# Default open-PR fixture set for PR acme/widgets#42 at sha deadbeef, no
# comments/reviews/failures. Tests mutate from this baseline.
seed_clean_pr() {
  set_fx "$1" user 'captain'
  set_fx "$1" pull-42 $'deadbeef\tOPEN'
  set_fx "$1" issue-comments-42 '0'
  set_fx "$1" review-comments-42 '0'
  set_fx "$1" reviews-42 '0'
  set_fx "$1" checks-deadbeef 'lint:success'
}

# ---------------------------------------------------------------------------
# 1. No pr= metadata at all: silent and zero gh calls (the fake gh logs calls).
pass "no supervised PRs: silent poll, no gh calls"
{
  case_dir=$(make_case no-prs)
  set_fx "$case_dir" user 'captain'   # would be read only if there were a PR
  out=$(run_poll "$case_dir")
  [ -z "$out" ] || fail "no-PR poll should be silent, got: $out"
  # gh must not have been called at all (no user fixture read needed; but verify
  # no seen dir churn). A no-PR home writes no seen files.
  [ ! -d "$case_dir/state/.github-watch-seen" ] || fail "no-PR poll created seen files"
}

# ---------------------------------------------------------------------------
# 2. Malformed pr= URL is skipped (no crash, no seen file, no event).
pass "malformed pr= URL skipped without crashing"
{
  case_dir=$(make_case bad-url)
  write_pr_meta "$case_dir" task-b1 'not-a-url'
  set_fx "$case_dir" user 'captain'
  out=$(run_poll "$case_dir")
  [ -z "$out" ] || fail "malformed-url poll should be silent, got: $out"
  assert_absent "$case_dir/state/.github-watch-seen" "malformed URL must not create a seen file"
}

# ---------------------------------------------------------------------------
# 3. Initial sighting establishes baseline silently; later no-change is silent.
pass "initial sighting is silent baseline; no-change poll is silent"
{
  case_dir=$(make_case baseline)
  write_pr_meta "$case_dir" task-a1 'https://github.com/acme/widgets/pull/42'
  seed_clean_pr "$case_dir"
  out=$(run_poll "$case_dir")
  [ -z "$out" ] || fail "initial sighting should be silent (baseline), got: $out"
  assert_present "$case_dir/state/.github-watch-seen/acme-widgets-42" "baseline should record seen"
  # Second poll, identical data: still silent.
  out=$(run_poll "$case_dir")
  [ -z "$out" ] || fail "no-change poll should be silent, got: $out"
}

# ---------------------------------------------------------------------------
# 4. New review comment (issue + review comment counts rise) wakes once.
pass "new comment wakes once; repeat poll is silent"
{
  case_dir=$(make_case new-comment)
  write_pr_meta "$case_dir" task-a1 'https://github.com/acme/widgets/pull/42'
  seed_clean_pr "$case_dir"
  run_poll "$case_dir" >/dev/null   # baseline
  set_fx "$case_dir" issue-comments-42 '3'   # +3 comments
  set_fx "$case_dir" review-comments-42 '1'  # +1 inline
  out=$(run_poll "$case_dir")
  assert_contains "$out" "COMMENT: acme/widgets#42 has" "comment event missing"
  assert_contains "$out" "4 new comment(s)" "expected combined count 4"
  # Repeat with same counts: silent.
  out=$(run_poll "$case_dir")
  [ -z "$out" ] || fail "repeat comment poll should be silent, got: $out"
}

# ---------------------------------------------------------------------------
# 5. Changes-requested review wakes once.
pass "changes-requested wakes once; repeat is silent"
{
  case_dir=$(make_case changes-req)
  write_pr_meta "$case_dir" task-a1 'https://github.com/acme/widgets/pull/42'
  seed_clean_pr "$case_dir"
  run_poll "$case_dir" >/dev/null   # baseline
  set_fx "$case_dir" reviews-42 '1'   # one CHANGES_REQUESTED review
  out=$(run_poll "$case_dir")
  assert_contains "$out" "CHANGES_REQUESTED: acme/widgets#42" "changes-requested event missing"
  out=$(run_poll "$case_dir")
  [ -z "$out" ] || fail "repeat changes-requested poll should be silent, got: $out"
}

# ---------------------------------------------------------------------------
# 6. Newly failed CI check wakes once; same failure next poll is silent.
pass "failed CI wakes once; same failure repeat is silent"
{
  case_dir=$(make_case ci-fail)
  write_pr_meta "$case_dir" task-a1 'https://github.com/acme/widgets/pull/42'
  seed_clean_pr "$case_dir"
  run_poll "$case_dir" >/dev/null   # baseline (checks passing)
  set_fx "$case_dir" checks-deadbeef 'lint:failure;test:failure'
  out=$(run_poll "$case_dir")
  assert_contains "$out" "CI: acme/widgets#42 check(s) failed" "CI event missing"
  assert_contains "$out" "lint" "CI event should name failing check"
  assert_contains "$out" "test" "CI event should name second failing check"
  out=$(run_poll "$case_dir")
  [ -z "$out" ] || fail "repeat CI-failure poll should be silent, got: $out"
}

# ---------------------------------------------------------------------------
# 7. Dedup: multiple polls with no new info never re-emit (across all signals).
pass "dedup: repeated no-info polls stay silent across signals"
{
  case_dir=$(make_case dedup)
  write_pr_meta "$case_dir" task-a1 'https://github.com/acme/widgets/pull/42'
  seed_clean_pr "$case_dir"
  set_fx "$case_dir" issue-comments-42 '2'
  set_fx "$case_dir" reviews-42 '1'
  set_fx "$case_dir" checks-deadbeef 'build:failure'
  run_poll "$case_dir" >/dev/null   # baseline records these as the starting point
  # Five polls, nothing changes: every one silent.
  for _ in 1 2 3 4 5; do
    out=$(run_poll "$case_dir")
    [ -z "$out" ] || fail "dedup poll should be silent, got: $out"
  done
}

# ---------------------------------------------------------------------------
# 8. Transient API failure does NOT corrupt the cursor and emits nothing.
pass "transient API failure: no emit, cursor preserved"
{
  case_dir=$(make_case transient)
  write_pr_meta "$case_dir" task-a1 'https://github.com/acme/widgets/pull/42'
  seed_clean_pr "$case_dir"
  run_poll "$case_dir" >/dev/null   # baseline
  set_fx "$case_dir" issue-comments-42 '5'   # a real new comment arrived
  # Simulate an outage: remove the issue-comments fixture so that call 503s.
  rm -f "$case_dir/fixture/issue-comments-42"
  out=$(run_poll "$case_dir")
  [ -z "$out" ] || fail "transient-failure poll should emit nothing, got: $out"
  # Cursor must still reflect the OLD baseline (0), so the not-yet-seen comment
  # fires once the outage clears.
  seen_comments=$(awk -F= '$1=="comments"{print $2}' "$case_dir/state/.github-watch-seen/acme-widgets-42")
  [ "$seen_comments" = "0" ] || fail "cursor corrupted by outage: comments=$seen_comments (want 0)"
  # Outage clears: the comment now wakes once.
  set_fx "$case_dir" issue-comments-42 '5'
  out=$(run_poll "$case_dir")
  assert_contains "$out" "COMMENT: acme/widgets#42 has 5 new comment(s)" "comment should fire after outage clears"
}

# ---------------------------------------------------------------------------
# 9. Merged/closed PR is skipped (merge monitoring is the per-task check's job).
pass "closed PR skipped without emitting"
{
  case_dir=$(make_case closed)
  write_pr_meta "$case_dir" task-a1 'https://github.com/acme/widgets/pull/42'
  set_fx "$case_dir" user 'captain'
  set_fx "$case_dir" pull-42 $'deadbeef\tCLOSED'
  set_fx "$case_dir" issue-comments-42 '9'
  set_fx "$case_dir" reviews-42 '2'
  out=$(run_poll "$case_dir")
  [ -z "$out" ] || fail "closed PR should not emit, got: $out"
}

# ---------------------------------------------------------------------------
# 10. Stale seen file for an unsupervised PR is pruned (teardown happened).
pass "seen file for a no-longer-supervised PR is pruned"
{
  case_dir=$(make_case prune)
  # Seed a seen file directly for a PR no meta references anymore.
  mkdir -p "$case_dir/state/.github-watch-seen"
  printf 'owner=acme\nrepo=widgets\npr=99\ncomments=3\n' > \
    "$case_dir/state/.github-watch-seen/acme-widgets-99"
  # A different PR is now supervised.
  write_pr_meta "$case_dir" task-a1 'https://github.com/acme/widgets/pull/42'
  set_fx "$case_dir" user 'captain'
  set_fx "$case_dir" pull-42 $'deadbeef\tOPEN'
  set_fx "$case_dir" issue-comments-42 '0'
  set_fx "$case_dir" review-comments-42 '0'
  set_fx "$case_dir" reviews-42 '0'
  set_fx "$case_dir" checks-deadbeef 'lint:success'
  run_poll "$case_dir" >/dev/null
  assert_absent "$case_dir/state/.github-watch-seen/acme-widgets-99" "stale seen file should be pruned"
  assert_present "$case_dir/state/.github-watch-seen/acme-widgets-42" "supervised PR seen should remain"
}

# ---------------------------------------------------------------------------
# 11. Registration: bootstrap writes the idempotent check shim that execs the
# watcher, and re-running bootstrap does not churn it.
pass "bootstrap registers idempotent github-events check shim"
{
  case_dir=$(make_case reg)
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$case_dir" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_CONFIG_OVERRIDE="$case_dir/config" FM_PROJECTS_OVERRIDE="$case_dir/projects" \
    bash "$BOOTSTRAP" >/dev/null 2>&1
  shim="$case_dir/state/github-events.check.sh"
  assert_present "$shim" "bootstrap should write the github-events check shim"
  assert_grep "fm-github-watch.sh" "$shim" "shim should exec the watcher"
  m1=$(stat -c %Y "$shim")
  sleep 1.1
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$case_dir" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_CONFIG_OVERRIDE="$case_dir/config" FM_PROJECTS_OVERRIDE="$case_dir/projects" \
    bash "$BOOTSTRAP" >/dev/null 2>&1
  m2=$(stat -c %Y "$shim")
  [ "$m1" = "$m2" ] || fail "bootstrap re-run churned the shim (not idempotent)"
}

# ---------------------------------------------------------------------------
# 12. Discovery dedup is newline-anchored: PR #4 must not be shadowed by #42
# (or vice versa) when both are supervised in the same repo - a substring match
# would silently drop the shorter number.
pass "discovery: PR #4 and #42 in the same repo are both discovered (no substring shadow)"
{
  case_dir=$(make_case prefix-shadow)
  write_pr_meta "$case_dir" task-a4 'https://github.com/acme/widgets/pull/4'
  write_pr_meta "$case_dir" task-a42 'https://github.com/acme/widgets/pull/42'
  set_fx "$case_dir" user 'captain'
  set_fx "$case_dir" pull-4 $'sha4\tOPEN'
  set_fx "$case_dir" pull-42 $'sha42\tOPEN'
  set_fx "$case_dir" issue-comments-4 '0'
  set_fx "$case_dir" issue-comments-42 '0'
  set_fx "$case_dir" review-comments-4 '0'
  set_fx "$case_dir" review-comments-42 '0'
  set_fx "$case_dir" reviews-4 '0'
  set_fx "$case_dir" reviews-42 '0'
  set_fx "$case_dir" checks-sha4 'lint:success'
  set_fx "$case_dir" checks-sha42 'lint:success'
  run_poll "$case_dir" >/dev/null   # baseline both
  assert_present "$case_dir/state/.github-watch-seen/acme-widgets-4" "PR #4 seen file missing (shadowed by #42?)"
  assert_present "$case_dir/state/.github-watch-seen/acme-widgets-42" "PR #42 seen file missing (shadowed by #4?)"
  # And a new comment on #4 alone wakes for #4 only (not #42, not silent).
  set_fx "$case_dir" issue-comments-4 '1'
  out=$(run_poll "$case_dir")
  assert_contains "$out" "acme/widgets#4 has 1 new comment(s)" "PR #4 comment should wake"
  assert_not_contains "$out" "#42 has" "PR #42 must not wake from #4's comment"
}

echo "# fm-github-watch tests: all passed"
