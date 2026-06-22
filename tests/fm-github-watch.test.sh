#!/usr/bin/env bash
# Behavior tests for fm-github-watch.sh.
# A fake `gh` on PATH serves canned, file-driven responses so each test can
# mutate fixture state between poll cycles and assert on emitted events.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GH_WATCH="$ROOT/bin/fm-github-watch.sh"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

TMP_ROOT=
cleanup() {
  [ -n "${TMP_ROOT:-}" ] && rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-ghwatch-tests.XXXXXX")

# Build an isolated case dir with its own state/ + fakebin/gh, and echo its root.
# The fake gh reads fixtures from $GH_FIXTURE (one PR's data per set of files).
make_case() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$dir/fixture" "$fakebin"
  cat > "$fakebin/gh" <<'GH'
#!/usr/bin/env bash
# Minimal, file-driven gh stand-in for fm-github-watch tests.
set -u
FX="${GH_FIXTURE:?no fixture}"
emit_default() { :; }   # most commands print nothing by default

sub="${1:-}"
shift || true

case "$sub" in
  search)
    # gh search prs ... : print "owner/repo<TAB>num" lines.
    [ -f "$FX/prs" ] && cat "$FX/prs"
    exit 0
    ;;
  api)
    # gh api <path> --jq ... : find the repos/... path argument.
    path=""
    for a in "$@"; do
      case "$a" in repos/*) path=$a ;; esac
    done
    path="${path%%\?*}"   # strip any ?per_page=... query before matching
    # repos/OWNER/REPO/issues/NUM/comments  -> comments-OWNER-REPO-NUM
    # repos/OWNER/REPO/pulls/NUM/reviews    -> reviews-OWNER-REPO-NUM
    # repos/OWNER/REPO/commits/SHA/check-runs -> ci-SHA
    case "$path" in
      */issues/*/comments)
        rest=${path#repos/}            # OWNER/REPO/issues/NUM/comments
        owner=${rest%%/*}; rest=${rest#*/}
        repo=${rest%%/*}; rest=${rest#*/}
        num=${rest#issues/}; num=${num%/comments}
        f="$FX/comments-$owner-$repo-$num"
        [ -f "$f" ] && { cat "$f"; exit 0; }
        echo 0; exit 0
        ;;
      */pulls/*/reviews)
        rest=${path#repos/}
        owner=${rest%%/*}; rest=${rest#*/}
        repo=${rest%%/*}; rest=${rest#*/}
        num=${rest#pulls/}; num=${num%/reviews}
        f="$FX/reviews-$owner-$repo-$num"
        [ -f "$f" ] && { cat "$f"; exit 0; }
        echo 0; exit 0
        ;;
      */commits/*/check-runs)
        sha=${path##*/commits/}; sha=${sha%/check-runs}
        f="$FX/ci-$sha"
        [ -f "$f" ] && { cat "$f"; exit 0; }
        exit 0
        ;;
    esac
    exit 0
    ;;
  pr)
    # gh pr view <num> -R owner/repo --json <field> -q ...
    num=""; repo=""; field=""
    prev=""
    for a in "$@"; do
      if [ "$prev" = "-R" ]; then repo=$a; fi
      if [ "$prev" = "--json" ]; then field=$a; fi
      case "$a" in [0-9]*) num=$a ;; esac
      prev=$a
    done
    owner=${repo%%/*}; rn=${repo#*/}
    case "$field" in
      state)
        f="$FX/state-$owner-$rn-$num"
        [ -f "$f" ] && { cat "$f"; exit 0; }
        echo "OPEN"; exit 0
        ;;
      headRefOid)
        f="$FX/sha-$owner-$rn-$num"
        [ -f "$f" ] && { cat "$f"; exit 0; }
        echo "deadbeef"; exit 0
        ;;
    esac
    exit 0
    ;;
esac
exit 0
GH
  chmod +x "$fakebin/gh"
  printf '%s\n' "$dir"
}

# run_poll <case-dir> : invoke one poll cycle with the fake gh on PATH.
# A known contributor is pinned via env so discovery proceeds even though the
# fake gh does not implement `api user`.
run_poll() {
  local dir=$1
  PATH="$dir/fakebin:$PATH" GH_FIXTURE="$dir/fixture" \
    FM_GH_CONTRIBUTOR=e-jung \
    FM_STATE_OVERRIDE="$dir/state" \
    bash "$GH_WATCH" --once
}

# Seed the open-PR list a fake gh search returns.
seed_prs() {
  local dir=$1
  shift
  : > "$dir/fixture/prs"
  local ln
  for ln in "$@"; do printf '%s\n' "$ln" >> "$dir/fixture/prs"; done
}

test_filter_toggling() {
  local dir
  dir=$(make_case filter-toggle)
  local cfg="$dir/state/.github-watch-config"

  run_poll "$dir" >/dev/null 2>&1   # ensure default config materializes
  # Default: all four filters active.
  FM_STATE_OVERRIDE="$dir/state" bash "$GH_WATCH" filter list > "$dir/list.out"
  grep -Fxq comments "$dir/list.out" || fail "comments filter not on by default"
  grep -Fxq ci "$dir/list.out" || fail "ci filter not on by default"
  grep -Fxq merge "$dir/list.out" || fail "merge filter not on by default"

  # Turn comments off -> persisted in config, absent from list.
  FM_STATE_OVERRIDE="$dir/state" bash "$GH_WATCH" filter comments off > "$dir/off.out"
  grep -Eq '^filters=ci,reviews,merge$' "$dir/off.out" || fail "turning comments off gave unexpected result"
  ! awk -F= '/^filters=/{print $2}' "$cfg" | grep -qw comments \
    || fail "comments should be absent from filters= when toggled off"

  # Turn comments back on.
  FM_STATE_OVERRIDE="$dir/state" bash "$GH_WATCH" filter comments on > "$dir/on.out"
  grep -Eq '^filters=ci,reviews,merge,comments$' "$dir/on.out" || fail "turning comments on gave unexpected result"

  # Disabling then re-enabling is idempotent (no dupes).
  FM_STATE_OVERRIDE="$dir/state" bash "$GH_WATCH" filter ci off >/dev/null
  FM_STATE_OVERRIDE="$dir/state" bash "$GH_WATCH" filter ci on >/dev/null
  FM_STATE_OVERRIDE="$dir/state" bash "$GH_WATCH" filter list > "$dir/list2.out"
  [ "$(grep -Fc ci "$dir/list2.out")" -eq 1 ] || fail "filter toggling duplicated the ci filter"

  pass "filter on/off toggles persist in config without duplicates"
}

test_first_run_baselines_silently() {
  local dir out
  dir=$(make_case baseline)
  seed_prs "$dir" $'kunchenguid/firstmate\t30'
  printf '5\n' > "$dir/fixture/comments-kunchenguid-firstmate-30"
  printf '2\n' > "$dir/fixture/reviews-kunchenguid-firstmate-30"

  out=$(run_poll "$dir")
  [ -z "$out" ] || fail "first poll should baseline silently, but printed: $out"
  # Seen file exists with the baselined high-water marks.
  local sf="$dir/state/.github-watch-seen/kunchenguid-firstmate-30"
  [ -f "$sf" ] || fail "baseline seen file was not written"
  grep -Fxq "comments=5" "$sf" || fail "comments high-water not baselined"
  grep -Fxq "reviews=2" "$sf" || fail "reviews high-water not baselined"
  grep -Fxq "initialized=1" "$sf" || fail "initialized marker missing"

  pass "first run for a PR baselines silently with no event"
}

test_comment_detection_advances_seen_after_print() {
  local dir out sf
  dir=$(make_case comment)
  seed_prs "$dir" $'kunchenguid/firstmate\t30'
  printf '5\n' > "$dir/fixture/comments-kunchenguid-firstmate-30"
  sf="$dir/state/.github-watch-seen/kunchenguid-firstmate-30"

  # Cycle 1: baseline.
  run_poll "$dir" >/dev/null
  grep -Fxq "comments=5" "$sf" || fail "baseline comments not set"

  # Cycle 2: two new comments.
  printf '7\n' > "$dir/fixture/comments-kunchenguid-firstmate-30"
  out=$(run_poll "$dir")
  printf '%s\n' "$out" | grep -Fq "COMMENT: kunchenguid/firstmate#30 has 2 new comment(s)" \
    || fail "comment increase did not emit event; got: $out"
  # Seen marker advanced to the new high-water (after the print).
  grep -Fxq "comments=7" "$sf" || fail "seen marker not advanced after event"

  # Cycle 3: no change -> silence.
  out=$(run_poll "$dir")
  [ -z "$out" ] || fail "steady-state poll should be silent; got: $out"

  pass "comment increase emits event and advances seen after the print"
}

test_losslessness_redetects_when_seen_write_fails() {
  local dir out sf
  dir=$(make_case lossless)
  seed_prs "$dir" $'kunchenguid/firstmate\t30'
  printf '5\n' > "$dir/fixture/comments-kunchenguid-firstmate-30"
  sf="$dir/state/.github-watch-seen/kunchenguid-firstmate-30"

  # Cycle 1: baseline (writes the seen file while dir is writable).
  run_poll "$dir" >/dev/null
  grep -Fxq "comments=5" "$sf" || fail "baseline did not write seen"

  # New comment arrives.
  printf '7\n' > "$dir/fixture/comments-kunchenguid-firstmate-30"

  # Simulate a failing seen write: make the seen dir read-only so atomic_write
  # cannot advance the marker. The event must STILL print this cycle (print
  # happens before the seen write).
  chmod a-w "$dir/state/.github-watch-seen"
  out=$(run_poll "$dir")
  chmod u+w "$dir/state/.github-watch-seen"
  printf '%s\n' "$out" | grep -Fq "COMMENT: kunchenguid/firstmate#30 has 2 new comment(s)" \
    || fail "event did not print when seen write failed; got: $out"
  # Marker must NOT have advanced (the whole point).
  grep -Fxq "comments=5" "$sf" || fail "seen marker advanced despite failing write (permanent swallow)"

  # Next cycle (writable again) re-detects the same event: lossless.
  out=$(run_poll "$dir")
  printf '%s\n' "$out" | grep -Fq "COMMENT: kunchenguid/firstmate#30 has 2 new comment(s)" \
    || fail "event was not re-detected after failed seen write; got: $out"

  pass "failed seen write leaves the event re-detectable (lossless)"
}

test_merge_detection_on_left_open() {
  local dir out sf
  dir=$(make_case merge)
  seed_prs "$dir" $'kunchenguid/firstmate\t42'
  printf 'OPEN\n' > "$dir/fixture/state-kunchenguid-firstmate-42"
  sf="$dir/state/.github-watch-seen/kunchenguid-firstmate-42"

  # Cycle 1: baseline the open PR.
  run_poll "$dir" >/dev/null
  grep -Fxq "state=OPEN" "$sf" || fail "baseline state not recorded as OPEN"

  # PR merges: it leaves the open search, and its state becomes MERGED.
  : > "$dir/fixture/prs"   # no longer open
  printf 'MERGED\n' > "$dir/fixture/state-kunchenguid-firstmate-42"

  out=$(run_poll "$dir")
  printf '%s\n' "$out" | grep -Fq "MERGED: kunchenguid/firstmate#42" \
    || fail "open->merged transition did not emit event; got: $out"
  grep -Fxq "state=MERGED" "$sf" || fail "seen state not advanced to MERGED"

  # A later cycle does not re-report the merge (state no longer OPEN).
  out=$(run_poll "$dir")
  printf '%s\n' "$out" | grep -Fq "MERGED" && fail "merge event re-reported after settling" || true

  pass "PR leaving the open set as merged emits MERGED once"
}

test_closed_then_merged_is_not_swallowed() {
  local dir out sf
  dir=$(make_case close-merge)
  seed_prs "$dir" $'kunchenguid/firstmate\t42'
  printf 'OPEN\n' > "$dir/fixture/state-kunchenguid-firstmate-42"
  sf="$dir/state/.github-watch-seen/kunchenguid-firstmate-42"
  run_poll "$dir" >/dev/null   # baseline OPEN

  # PR is closed (leaves the open set): emit CLOSED once.
  : > "$dir/fixture/prs"
  printf 'CLOSED\n' > "$dir/fixture/state-kunchenguid-firstmate-42"
  out=$(run_poll "$dir")
  printf '%s\n' "$out" | grep -Fq "CLOSED: kunchenguid/firstmate#42" \
    || fail "open->closed did not emit; got: $out"

  # Steady closed: must NOT re-emit CLOSED every cycle.
  out=$(run_poll "$dir")
  printf '%s\n' "$out" | grep -Fq "CLOSED" && fail "CLOSED re-emitted while settled" || true

  # Closed -> reopened -> merged all between polls: MERGED must still fire
  # (CLOSED is not terminal; the watcher re-probes it).
  printf 'MERGED\n' > "$dir/fixture/state-kunchenguid-firstmate-42"
  out=$(run_poll "$dir")
  printf '%s\n' "$out" | grep -Fq "MERGED: kunchenguid/firstmate#42" \
    || fail "close->merge transition was swallowed; got: $out"

  pass "CLOSED is treated as non-terminal: close->merge still emits MERGED"
}

test_closed_pr_reprobe_window_is_bounded() {
  # A closed PR is re-probed only within CLOSE_REPROBE_SECS of closing, so
  # accumulated closed PRs cannot push the fleet past the rate limit. With a
  # zero window the PR is settled immediately: a later merge is intentionally
  # not re-detected (the cost-bound tradeoff). The default window is generous.
  local dir out sf
  dir=$(make_case close-window)
  seed_prs "$dir" $'kunchenguid/firstmate\t42'
  printf 'OPEN\n' > "$dir/fixture/state-kunchenguid-firstmate-42"
  sf="$dir/state/.github-watch-seen/kunchenguid-firstmate-42"
  run_poll "$dir" >/dev/null                       # baseline OPEN
  : > "$dir/fixture/prs"
  printf 'CLOSED\n' > "$dir/fixture/state-kunchenguid-firstmate-42"
  out=$(run_poll "$dir")                           # emits CLOSED, stamps closed_at
  printf '%s\n' "$out" | grep -Fq "CLOSED: kunchenguid/firstmate#42" || fail "close not emitted"
  grep -Fq "closed_at=" "$sf" || fail "closed_at not stamped on close"

  # Zero window: the aged-out CLOSED PR is not re-probed, so a merge is missed.
  printf 'MERGED\n' > "$dir/fixture/state-kunchenguid-firstmate-42"
  out=$(PATH="$dir/fakebin:$PATH" GH_FIXTURE="$dir/fixture" FM_GH_CONTRIBUTOR=e-jung \
        FM_GH_CLOSE_REPROBE_SECS=0 FM_STATE_OVERRIDE="$dir/state" bash "$GH_WATCH" --once)
  printf '%s\n' "$out" | grep -Fq "MERGED" \
    && fail "aged-out CLOSED PR was re-probed (cost not bounded)" || true
  pass "closed PR past the re-probe window stops consuming an API call"
}

test_config_roundtrip() {
  local dir
  dir=$(make_case config)
  FM_STATE_OVERRIDE="$dir/state" bash "$GH_WATCH" contributor captain-ej >/dev/null
  FM_STATE_OVERRIDE="$dir/state" bash "$GH_WATCH" filter reviews off >/dev/null
  FM_STATE_OVERRIDE="$dir/state" bash "$GH_WATCH" filter ci off >/dev/null
  FM_STATE_OVERRIDE="$dir/state" bash "$GH_WATCH" contributor > "$dir/c.out"
  [ "$(cat "$dir/c.out")" = "captain-ej" ] || fail "contributor did not roundtrip"

  FM_STATE_OVERRIDE="$dir/state" bash "$GH_WATCH" filter list > "$dir/f.out"
  # comments + merge remain; ci + reviews disabled.
  grep -Fxq comments "$dir/f.out" || fail "comments should remain on"
  grep -Fxq merge "$dir/f.out" || fail "merge should remain on"
  ! grep -Fxq ci "$dir/f.out" || fail "ci should be off"
  ! grep -Fxq reviews "$dir/f.out" || fail "reviews should be off"

  # status reflects the persisted config.
  FM_STATE_OVERRIDE="$dir/state" bash "$GH_WATCH" status > "$dir/s.out"
  grep -Eq '^contributor: captain-ej$' "$dir/s.out" || fail "status did not show contributor"
  grep -Eq '^  ci: off$' "$dir/s.out" || fail "status did not show ci off"

  pass "config writes round-trip across contributor + filter subcommands"
}

test_review_detection() {
  local dir out sf
  dir=$(make_case review)
  seed_prs "$dir" $'kunchenguid/no-mistakes\t310'
  printf '1\n' > "$dir/fixture/reviews-kunchenguid-no-mistakes-310"
  sf="$dir/state/.github-watch-seen/kunchenguid-no-mistakes-310"

  run_poll "$dir" >/dev/null
  grep -Fxq "reviews=1" "$sf" || fail "baseline reviews not set"

  printf '3\n' > "$dir/fixture/reviews-kunchenguid-no-mistakes-310"
  out=$(run_poll "$dir")
  printf '%s\n' "$out" | grep -Fq "REVIEW: kunchenguid/no-mistakes#310 has 2 new review(s)" \
    || fail "review increase did not emit event; got: $out"
  grep -Fxq "reviews=3" "$sf" || fail "review high-water not advanced"

  pass "review count increase emits REVIEW event"
}

test_ci_detection() {
  local dir out sf
  dir=$(make_case ci)
  seed_prs "$dir" $'kunchenguid/no-mistakes\t310'
  printf 'abcdef1\n' > "$dir/fixture/sha-kunchenguid-no-mistakes-310"
  printf 'success,success,success\n' > "$dir/fixture/ci-abcdef1"
  sf="$dir/state/.github-watch-seen/kunchenguid-no-mistakes-310"

  run_poll "$dir" >/dev/null
  grep -Fxq "ci=success,success,success" "$sf" || fail "baseline ci signature not set"

  # A check goes red: signature changes.
  printf 'failure,success,success\n' > "$dir/fixture/ci-abcdef1"
  out=$(run_poll "$dir")
  printf '%s\n' "$out" | grep -Fq "CI: kunchenguid/no-mistakes#310 checks changed" \
    || fail "ci signature change did not emit event; got: $out"
  grep -Fxq "ci=failure,success,success" "$sf" || fail "ci signature not advanced"

  # Steady state again: silence.
  out=$(run_poll "$dir")
  [ -z "$out" ] || fail "steady-state ci poll should be silent; got: $out"

  pass "CI signature change emits CI event"
}

test_merge_filter_suppresses_merge_event() {
  local dir out
  dir=$(make_case merge-off)
  seed_prs "$dir" $'kunchenguid/firstmate\t42'
  printf 'OPEN\n' > "$dir/fixture/state-kunchenguid-firstmate-42"
  run_poll "$dir" >/dev/null   # baseline

  # Disable the merge filter; the PR then merges (leaves the open set).
  FM_STATE_OVERRIDE="$dir/state" bash "$GH_WATCH" filter merge off >/dev/null
  : > "$dir/fixture/prs"
  printf 'MERGED\n' > "$dir/fixture/state-kunchenguid-firstmate-42"
  out=$(run_poll "$dir")
  if printf '%s\n' "$out" | grep -Fq "MERGED"; then
    fail "merge event fired despite merge filter being off; got: $out"
  fi
  pass "merge filter off suppresses merge/close events"
}

test_ci_carry_forward_across_empty_window() {
  local dir out sf
  dir=$(make_case ci-carry)
  seed_prs "$dir" $'kunchenguid/no-mistakes\t310'
  printf 'sha1\n' > "$dir/fixture/sha-kunchenguid-no-mistakes-310"
  printf 'success,success\n' > "$dir/fixture/ci-sha1"
  sf="$dir/state/.github-watch-seen/kunchenguid-no-mistakes-310"

  # Baseline: CI passing for sha1.
  run_poll "$dir" >/dev/null
  grep -Fxq "ci=success,success" "$sf" || fail "baseline ci not recorded"

  # New commit: sha changes, check-runs not populated yet (empty ci_sig).
  printf 'sha2\n' > "$dir/fixture/sha-kunchenguid-no-mistakes-310"
  rm -f "$dir/fixture/ci-sha1"
  # No ci-sha2 fixture yet -> ci_signature returns empty.
  out=$(run_poll "$dir")
  [ -z "$out" ] || fail "transient empty ci window should be silent; got: $out"
  # seen_ci must be carried forward (not dropped) so a later change still fires.
  grep -Fxq "ci=success,success" "$sf" || fail "ci signature was dropped during empty window"

  # CI completes for sha2 and FAILS: signature differs from carried-forward.
  printf 'failure,success\n' > "$dir/fixture/ci-sha2"
  out=$(run_poll "$dir")
  printf '%s\n' "$out" | grep -Fq "CI: kunchenguid/no-mistakes#310 checks changed" \
    || fail "ci completion after empty window did not fire; got: $out"

  pass "CI signature carries forward across an empty window and fires on change"
}

test_all_filters_off_mutes_watcher() {
  local dir out
  dir=$(make_case all-off)
  seed_prs "$dir" $'kunchenguid/firstmate\t30'
  printf '5\n' > "$dir/fixture/comments-kunchenguid-firstmate-30"
  run_poll "$dir" >/dev/null   # baseline

  # Turn every filter off; the persisted config must keep filters empty (not
  # fall back to defaults).
  for f in comments ci reviews merge; do
    FM_STATE_OVERRIDE="$dir/state" bash "$GH_WATCH" filter "$f" off >/dev/null
  done
  grep -Fxq 'filters=' "$dir/state/.github-watch-config" || fail "all-off should write filters= (empty), not default"

  # A new comment must NOT fire (every filter is muted).
  printf '9\n' > "$dir/fixture/comments-kunchenguid-firstmate-30"
  out=$(run_poll "$dir")
  [ -z "$out" ] || fail "muted watcher emitted events; got: $out"
  pass "all filters off (empty filters=) mutes the watcher instead of resetting to defaults"
}

test_filter_toggling
test_first_run_baselines_silently
test_comment_detection_advances_seen_after_print
test_losslessness_redetects_when_seen_write_fails
test_merge_detection_on_left_open
test_closed_then_merged_is_not_swallowed
test_closed_pr_reprobe_window_is_bounded
test_config_roundtrip
test_review_detection
test_ci_detection
test_merge_filter_suppresses_merge_event
test_ci_carry_forward_across_empty_window
test_all_filters_off_mutes_watcher
