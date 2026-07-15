#!/usr/bin/env bash
# Behavior tests for fm-github-watch.sh.
# A fake `gh` on PATH serves canned, file-driven responses so each test can
# mutate fixture state between poll cycles and assert on emitted events.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GH_WATCH="$ROOT/bin/fm-github-watch.sh"

TMP_ROOT=$(fm_test_tmproot fm-ghwatch)

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
    # gh search prs ... : print "owner/repo<TAB>num" lines. A search-error
    # fixture makes discovery fail (non-zero exit) to exercise the
    # auto-failure path: supervised PRs are still polled.
    if [ -f "$FX/search-error" ]; then exit 1; fi
    [ -f "$FX/prs" ] && cat "$FX/prs"
    exit 0
    ;;
  api)
    # Injectable transient API error: when $FX/api-error exists, emit a GitHub
    # error body to stdout and exit non-zero — exactly how real gh behaves on a
    # 401/5xx (the --jq template is bypassed on error responses). This is the
    # bug surface: the raw error JSON reached stdout and was parsed as CI data.
    if [ -f "$FX/api-error" ]; then
      printf '{"message":"Bad credentials","documentation_url":"https://docs.github.com/rest","status":"401"}\n'
      exit 1
    fi
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
        [ -f "$f" ] || exit 0
        # The watcher passes --jq to roll check-runs up into a single overall
        # state; run that same filter against the JSON fixture so the real
        # roll-up logic (success/failure/pending/neutral) is exercised, not
        # just the comparison. Falls back to cat for any caller without --jq.
        jq_expr=""
        prev=""
        for a in "$@"; do
          if [ "$prev" = "--jq" ]; then jq_expr=$a; fi
          prev=$a
        done
        if [ -n "$jq_expr" ]; then
          jq -r "$jq_expr" "$f"
        else
          cat "$f"
        fi
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

# seed_meta <case-dir> <id> <pr-url>: write a state/<id>.meta with a pr= line so
# discover_supervised_prs finds it.
seed_meta() {
  local dir=$1 id=$2 url=$3
  printf 'window=firstmate:fm-%s\nworktree=/tmp/%s\npr=%s\n' "$id" "$id" "$url" > "$dir/state/$id.meta"
}

# seed_ci <dir> <sha> <conclusion...> -> write a JSON check-runs fixture the
# fake gh feeds through the watcher's real --jq roll-up. Each conclusion arg is
# a Checks-API value ("success","failure","neutral","skipped","timed_out",...)
# or the literal "pending" for a still-running check (status in_progress,
# conclusion null). The fake gh runs the watcher's --jq filter on this JSON, so
# the actual roll-up logic (not just the comparison) is what the tests exercise.
seed_ci() {
  local f="$1/fixture/ci-$2"
  shift 2
  printf '%s' '{"check_runs":[' > "$f"
  local first=1 c status conclusion
  for c in "$@"; do
    [ "$first" = 1 ] || printf ',' >> "$f"
    first=0
    if [ "$c" = "pending" ]; then
      status="in_progress"; conclusion="null"
    else
      status="completed"; conclusion="\"$c\""
    fi
    printf '{"status":"%s","conclusion":%s}' "$status" "$conclusion" >> "$f"
  done
  printf '%s' ']}' >> "$f"
}

# seed_ci_named <dir> <sha> <name=conclusion>...
# Like seed_ci but each check-run carries a name, so name-based ignore filters
# (FM_GH_IGNORE_CHECKS) can be exercised through the real --jq roll-up. The
# literal "pending" still means a running check (conclusion null). A name is
# embedded as a JSON string literal (backslash and double-quote escaped).
seed_ci_named() {
  local f="$1/fixture/ci-$2"
  shift 2
  printf '%s' '{"check_runs":[' > "$f"
  local first=1 arg name c status conclusion esc
  for arg in "$@"; do
    name=${arg%%=*}; c=${arg#*=}
    [ "$first" = 1 ] || printf ',' >> "$f"
    first=0
    if [ "$c" = "pending" ]; then status="in_progress"; conclusion="null"; else status="completed"; conclusion="\"$c\""; fi
    esc=${name//\\/\\\\}; esc=${esc//\"/\\\"}
    printf '{"status":"%s","conclusion":%s,"name":"%s"}' "$status" "$conclusion" "$esc" >> "$f"
  done
  printf '%s' ']}' >> "$f"
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
  if printf '%s\n' "$out" | grep -Fq "MERGED"; then fail "merge event re-reported after settling"; fi

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
  if printf '%s\n' "$out" | grep -Fq "CLOSED"; then fail "CLOSED re-emitted while settled"; fi

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
  if printf '%s\n' "$out" | grep -Fq "MERGED"; then
    fail "aged-out CLOSED PR was re-probed (cost not bounded)"
  fi
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
  seed_ci "$dir" abcdef1 success success success
  sf="$dir/state/.github-watch-seen/kunchenguid-no-mistakes-310"

  run_poll "$dir" >/dev/null
  grep -Fxq "ci=success" "$sf" || fail "baseline ci state not rolled up to success"

  # One check goes red: the overall state flips success -> failure (one event).
  seed_ci "$dir" abcdef1 failure success success
  out=$(run_poll "$dir")
  printf '%s\n' "$out" | grep -Fq "CI: kunchenguid/no-mistakes#310 -> failure" \
    || fail "ci state change did not emit event; got: $out"
  grep -Fxq "ci=failure" "$sf" || fail "ci state not advanced to failure"

  # Steady state again: silence.
  out=$(run_poll "$dir")
  [ -z "$out" ] || fail "steady-state ci poll should be silent; got: $out"

  pass "overall CI state change emits a single CI event"
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
  seed_ci "$dir" sha1 success success
  sf="$dir/state/.github-watch-seen/kunchenguid-no-mistakes-310"

  # Baseline: CI passing for sha1 (rolled up to success).
  run_poll "$dir" >/dev/null
  grep -Fxq "ci=success" "$sf" || fail "baseline ci state not recorded"

  # New commit: sha changes, check-runs not populated yet (empty ci_state).
  printf 'sha2\n' > "$dir/fixture/sha-kunchenguid-no-mistakes-310"
  rm -f "$dir/fixture/ci-sha1"
  # No ci-sha2 fixture yet -> ci_state returns empty.
  out=$(run_poll "$dir")
  [ -z "$out" ] || fail "transient empty ci window should be silent; got: $out"
  # seen_ci must be carried forward (not dropped) so a later change still fires.
  grep -Fxq "ci=success" "$sf" || fail "ci state was dropped during empty window"

  # CI completes for sha2 and FAILS: state differs from carried-forward success.
  seed_ci "$dir" sha2 failure success
  out=$(run_poll "$dir")
  printf '%s\n' "$out" | grep -Fq "CI: kunchenguid/no-mistakes#310 -> failure" \
    || fail "ci completion after empty window did not fire; got: $out"

  pass "overall CI state carries forward across an empty window and fires on change"
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

test_parallel_poll_is_lossless_and_does_not_cross_contaminate() {
  # With PRs polled concurrently (bounded by FM_GH_CONCURRENCY), the per-PR
  # losslessness invariant (print before seen write) and per-PR seen-file
  # independence must both hold. Seed many PRs across distinct repos so several
  # parallel waves run, each worker owning its own seen file.
  local dir out i sf n=12
  dir=$(make_case parallel)

  local pr_lines=()
  for i in $(seq 1 "$n"); do
    pr_lines+=( "$(printf 'org/r%d\t1' "$i")" )
    printf '5\n' > "$dir/fixture/comments-org-r$i-1"
  done
  seed_prs "$dir" "${pr_lines[@]}"
  run_poll "$dir" >/dev/null   # baseline all n PRs (comments=5 each)

  # Each PR gains a DISTINCT count (PR i -> 5+i) so a worker that crossed wires
  # would stamp another PR's count into the wrong seen file.
  for i in $(seq 1 "$n"); do
    printf '%d\n' "$((5 + i))" > "$dir/fixture/comments-org-r$i-1"
  done

  # Losslessness under concurrency: make the seen dir read-only so every
  # worker's seen write fails, then poll with concurrency well below n. Every
  # PR's event must STILL print this cycle (each worker prints before its seen
  # write, independent of the other workers).
  chmod a-w "$dir/state/.github-watch-seen"
  out=$(FM_GH_CONCURRENCY=4 run_poll "$dir")
  chmod u+w "$dir/state/.github-watch-seen"
  for i in $(seq 1 "$n"); do
    printf '%s\n' "$out" | grep -Fq "COMMENT: org/r$i#1 has $i new comment(s)" \
      || fail "parallel poll did not emit PR r$i before its seen write; out: $out"
  done

  # No cross-contamination: after a writable concurrent poll, each PR's seen
  # file holds its OWN advanced count and its own identity (never another PR's
  # values), even though workers ran concurrently with a shared .tmp stage.
  out=$(FM_GH_CONCURRENCY=4 run_poll "$dir")
  for i in $(seq 1 "$n"); do
    sf="$dir/state/.github-watch-seen/org-r$i-1"
    grep -Fxq "comments=$((5 + i))" "$sf" \
      || fail "r$i seen file has wrong count (cross-contamination?): $(cat "$sf")"
    grep -Fxq "owner=org" "$sf" || fail "r$i seen file lost owner identity"
    grep -Fxq "repo=r$i"  "$sf" || fail "r$i seen file has wrong repo (cross-contamination?)"
    grep -Fxq "pr=1"      "$sf" || fail "r$i seen file lost pr identity"
  done

  pass "parallel poll emits before each seen write and never cross-contaminates seen files"
}

test_ci_debounces_staggered_checks() {
  # Reproduces the no-mistakes#312 chatter: a PR whose many check-runs complete
  # at staggered times. Under the old per-multiset logic each completion changed
  # the signature and fired (one event per check). The roll-up keeps the state
  # at "pending" while ANY check is still running, then flips to green exactly
  # once when the last one completes.
  local dir out sf finished i
  dir=$(make_case ci-debounce)
  seed_prs "$dir" $'kunchenguid/no-mistakes\t312'
  printf 'sha7\n' > "$dir/fixture/sha-kunchenguid-no-mistakes-312"
  sf="$dir/state/.github-watch-seen/kunchenguid-no-mistakes-312"

  # Cycle 1: 7 checks, all pending -> baseline (no event, first run).
  seed_ci "$dir" sha7 pending pending pending pending pending pending pending
  run_poll "$dir" >/dev/null
  grep -Fxq "ci=pending" "$sf" || fail "baseline should roll 7 pending checks up to pending"

  # Checks complete a few at a time: state stays pending, so every one of these
  # cycles must stay silent (under the old logic each would have fired).
  for finished in 1 3 6; do
    local args=()
    for i in $(seq 1 7); do
      if [ "$i" -le "$finished" ]; then args+=(success); else args+=(pending); fi
    done
    seed_ci "$dir" sha7 "${args[@]}"
    out=$(run_poll "$dir")
    if printf '%s\n' "$out" | grep -Fq "CI:"; then
      fail "fired while still pending after $finished/7 checks done; got: $out"
    fi
  done

  # Last check completes: pending -> green fires exactly once.
  seed_ci "$dir" sha7 success success success success success success success
  out=$(run_poll "$dir")
  printf '%s\n' "$out" | grep -Fq "CI: kunchenguid/no-mistakes#312 -> green" \
    || fail "pending->success transition did not fire once; got: $out"
  # No second fire on the next (steady) cycle.
  out=$(run_poll "$dir")
  if printf '%s\n' "$out" | grep -Fq "CI:"; then
    fail "steady success re-fired; got: $out"
  fi

  pass "staggered checks debounce to a single overall-state transition"
}

test_ci_state_transitions() {
  # The three transitions the captain cares about, each firing exactly once:
  # pending->green, green->green (silent), green->failure.
  local dir out sf
  dir=$(make_case ci-trans)
  seed_prs "$dir" $'kunchenguid/no-mistakes\t320'
  printf 'shat\n' > "$dir/fixture/sha-kunchenguid-no-mistakes-320"
  sf="$dir/state/.github-watch-seen/kunchenguid-no-mistakes-320"

  seed_ci "$dir" shat pending
  run_poll "$dir" >/dev/null   # baseline pending

  # pending -> green fires once.
  seed_ci "$dir" shat success
  out=$(run_poll "$dir")
  printf '%s\n' "$out" | grep -Fq "CI: kunchenguid/no-mistakes#320 -> green" \
    || fail "pending->success did not fire; got: $out"
  grep -Fxq "ci=success" "$sf" || fail "state not advanced to success"

  # green -> green does not fire.
  out=$(run_poll "$dir")
  if printf '%s\n' "$out" | grep -Fq "CI:"; then fail "success->success re-fired; got: $out"; fi

  # green -> failure fires once.
  seed_ci "$dir" shat success failure
  out=$(run_poll "$dir")
  printf '%s\n' "$out" | grep -Fq "CI: kunchenguid/no-mistakes#320 -> failure" \
    || fail "success->failure did not fire; got: $out"
  grep -Fxq "ci=failure" "$sf" || fail "state not advanced to failure"

  pass "pending->green fires once, green->green is silent, green->failure fires once"
}

test_ci_rollup_precedence() {
  # The rolled-up state follows GitHub's combined-status precedence: a red check
  # settles failure even while others are still pending; neutral checks are
  # ignored entirely (never red, never green, never block).
  local dir out sf
  dir=$(make_case ci-rollup)
  seed_prs "$dir" $'kunchenguid/no-mistakes\t321'
  printf 'shar\n' > "$dir/fixture/sha-kunchenguid-no-mistakes-321"
  sf="$dir/state/.github-watch-seen/kunchenguid-no-mistakes-321"

  # Baseline: a passing check plus a neutral informational check rolls up to
  # success (neutral ignored).
  seed_ci "$dir" shar success neutral
  run_poll "$dir" >/dev/null
  grep -Fxq "ci=success" "$sf" || fail "success+neutral should roll up to success"

  # A failure landing while another check is still pending settles failure
  # immediately (no transient pending event).
  seed_ci "$dir" shar success failure pending
  out=$(run_poll "$dir")
  printf '%s\n' "$out" | grep -Fq "CI: kunchenguid/no-mistakes#321 -> failure" \
    || fail "failure+pending should roll straight up to failure; got: $out"
  grep -Fxq "ci=failure" "$sf" || fail "state not advanced to failure"

  # The pending check then succeeds: state stays failure (no second fire).
  seed_ci "$dir" shar success failure success
  out=$(run_poll "$dir")
  if printf '%s\n' "$out" | grep -Fq "CI:"; then fail "failure->failure re-fired; got: $out"; fi

  pass "roll-up precedence: failure beats pending, neutral checks are ignored"
}

test_silent_baseline_on_schema_migration() {
  # Reproduces the debounce deploy flood: a seen file written by an OLDER
  # watcher version (here, an old per-multiset ci signature, no schema= field).
  # Without the schema guard, the first poll under the new code sees
  # seen_ci="success:success:failure" != ci_st="success" and fires a spurious
  # CI transition for EVERY migrated PR at once. The guard treats a schema
  # mismatch as a silent re-baseline: write the new schema + correct values,
  # emit nothing. A subsequent REAL transition still fires.
  local dir out sf
  dir=$(make_case ci-migrate)
  seed_prs "$dir" $'kunchenguid/no-mistakes\t330'
  printf 'sham\n' > "$dir/fixture/sha-kunchenguid-no-mistakes-330"
  printf 'OPEN\n' > "$dir/fixture/state-kunchenguid-no-mistakes-330"
  sf="$dir/state/.github-watch-seen/kunchenguid-no-mistakes-330"
  mkdir -p "$(dirname "$sf")"

  # An old-format seen file: initialized but no schema=, and a stale ci value
  # that the new roll-up would read as "different" from the fresh success.
  cat > "$sf" <<'OLD'
owner=kunchenguid
repo=no-mistakes
pr=330
initialized=1
ci=success:success:failure
state=OPEN
OLD

  # Fresh roll-up is plain success; under the old code this != the stale sig.
  seed_ci "$dir" sham success success success

  # First poll after migration: SILENT (no flood), seen rewritten to new schema.
  out=$(run_poll "$dir")
  [ -z "$out" ] || fail "schema migration should baseline silently; got: $out"
  grep -Fxq "schema=2" "$sf" || fail "seen file not stamped with current schema"
  grep -Fxq "ci=success" "$sf" || fail "ci not re-baselined to the rolled-up success"

  # A subsequent REAL transition still fires (migration only silenced once).
  seed_ci "$dir" sham success failure success
  out=$(run_poll "$dir")
  printf '%s\n' "$out" | grep -Fq "CI: kunchenguid/no-mistakes#330 -> failure" \
    || fail "post-migration real transition did not fire; got: $out"

  pass "schema mismatch is silently re-baselined; real transitions still fire"
}

test_ci_ignore_excludes_known_gap_check() {
  # A kunchenguid fork-PR whose ONLY failing check is the known fork-routing
  # signature gap (#293: "PR must be raised via no-mistakes") must roll up to
  # green when its real checks pass, not a false failure. The default
  # FM_GH_IGNORE_CHECKS regex drops that name from the roll-up. A REAL failure
  # (different name) must still roll up to failure, so the filter is not just
  # disabling failure detection.
  local dir out sf
  dir=$(make_case ci-ignore)
  seed_prs "$dir" $'kunchenguid/firstmate\t38'
  printf 'sha38\n' > "$dir/fixture/sha-kunchenguid-firstmate-38"
  sf="$dir/state/.github-watch-seen/kunchenguid-firstmate-38"

  # 3 real checks pass; the gap check fails by name. run_poll uses the default
  # FM_GH_IGNORE_CHECKS, so the gap name is excluded -> rolls up to success.
  seed_ci_named "$dir" sha38 \
    "build=success" "test=success" "lint=success" \
    "PR must be raised via no-mistakes=failure"

  run_poll "$dir" >/dev/null   # baseline: gap excluded -> success, not failure
  grep -Fxq "ci=success" "$sf" \
    || fail "gap-excluded PR should roll up to success, got: $(cat "$sf")"

  # A REAL check failing (different name) must still surface failure despite the
  # gap check also failing: the ignore list is not a blanket failure suppressor.
  seed_ci_named "$dir" sha38 \
    "build=success" "test=failure" "lint=success" \
    "PR must be raised via no-mistakes=failure"
  out=$(run_poll "$dir")
  printf '%s\n' "$out" | grep -Fq "CI: kunchenguid/firstmate#38 -> failure" \
    || fail "real check failure should still roll up to failure; got: $out"

  pass "known fork-routing gap check excluded from roll-up; real failures still surface"
}

test_api_error_skips_pr_without_event() {
  # Reproduces the bug: a transient 401 makes `gh api` write the error body
  # {"message":"Bad credentials",...} to stdout (bypassing --jq). The old ghc()
  # swallowed stderr + the exit code, so the watcher parsed that JSON as CI state
  # and fired a bogus "CI: ... -> { \"message\": ... }" event. The fix detects the
  # API error (non-zero exit OR an error-body shape) and skips the PR for the
  # cycle: no event, no crash, seen left untouched so the next (recovered) cycle
  # still fires the real transition (lossless).
  local dir out sf
  dir=$(make_case api-error)
  seed_prs "$dir" $'kunchenguid/no-mistakes\t500'
  printf 'sha500\n' > "$dir/fixture/sha-kunchenguid-no-mistakes-500"
  seed_ci "$dir" sha500 success
  sf="$dir/state/.github-watch-seen/kunchenguid-no-mistakes-500"

  # Baseline: CI green.
  run_poll "$dir" >/dev/null
  grep -Fxq "ci=success" "$sf" || fail "baseline ci not recorded as success"

  # Inject a transient 401 on every `gh api` call this cycle.
  : > "$dir/fixture/api-error"
  out=$(run_poll "$dir" 2>/dev/null)
  [ -z "$out" ] || fail "transient API error must not surface as an event; got: $out"
  # seen must be untouched (ci still the prior success, not the error JSON).
  grep -Fxq "ci=success" "$sf" \
    || fail "seen state was clobbered during API error: $(cat "$sf")"

  # Recover: remove the blip and flip CI to failure. The real transition fires.
  rm -f "$dir/fixture/api-error"
  seed_ci "$dir" sha500 failure
  out=$(run_poll "$dir")
  printf '%s\n' "$out" | grep -Fq "CI: kunchenguid/no-mistakes#500 -> failure" \
    || fail "post-blip real transition did not fire; got: $out"

  pass "transient GitHub API error skips the PR without emitting an event"
}

# ---- supervised-discovery (state/*.meta) + union reconciliation tests ----

test_supervised_pr_discovered_via_meta() {
  # A PR recorded only in state/<id>.meta (not in gh search --author) is still
  # discovered and watched: comments on it fire. This is the supervised-discovery
  # half of the union, covering PRs firstmate is actively tracking that
  # auto-discovery would miss (e.g. an external-contributor PR).
  local dir out sf
  dir=$(make_case meta-discover)
  seed_meta "$dir" task-aa "https://github.com/acme/widgets/pull/5"
  seed_prs "$dir"   # nothing in the open search
  printf '3\n' > "$dir/fixture/comments-acme-widgets-5"
  sf="$dir/state/.github-watch-seen/acme-widgets-5"

  # Cycle 1: baseline silently.
  out=$(run_poll "$dir")
  [ -z "$out" ] || fail "first supervised poll should baseline silently; got: $out"
  [ -f "$sf" ] || fail "supervised PR seen file was not written"
  grep -Fxq "comments=3" "$sf" || fail "supervised PR comments not baselined"

  # Cycle 2: a new comment fires (the PR is watched even though search is empty).
  printf '6\n' > "$dir/fixture/comments-acme-widgets-5"
  out=$(run_poll "$dir")
  printf '%s\n' "$out" | grep -Fq "COMMENT: acme/widgets#5 has 3 new comment(s)" \
    || fail "supervised PR comment did not fire; got: $out"

  pass "a PR recorded only in state/*.meta is discovered and watched"
}

test_union_dedup_watches_overlapping_pr_once() {
  # A PR that is BOTH auto-discovered (gh search) and supervised (state/*.meta)
  # is watched exactly once: a single comment increase emits exactly ONE event
  # and writes exactly one seen file. Without dedupe it would be polled twice
  # and double-report.
  local dir out sf nevents
  dir=$(make_case union-dedup)
  seed_meta "$dir" task-bb "https://github.com/acme/widgets/pull/7"
  seed_prs "$dir" $'acme/widgets\t7'
  printf '2\n' > "$dir/fixture/comments-acme-widgets-7"
  sf="$dir/state/.github-watch-seen/acme-widgets-7"

  run_poll "$dir" >/dev/null   # baseline
  [ -f "$sf" ] || fail "overlapping PR seen file not written"

  printf '5\n' > "$dir/fixture/comments-acme-widgets-7"
  out=$(run_poll "$dir")
  nevents=$(printf '%s\n' "$out" | grep -Fc "COMMENT: acme/widgets#7 has 3 new comment(s)")
  [ "$nevents" -eq 1 ] || fail "overlapping PR emitted $nevents comment events (expected 1); got: $out"
  grep -Fxq "comments=5" "$sf" || fail "overlapping PR seen not advanced once"

  pass "a PR in both discovery sources is watched once (union dedupe)"
}

test_supervised_pr_skips_merge_detection() {
  # A supervised (meta-tracked) PR defers merge/close detection to
  # bin/fm-pr-check.sh's per-task poll, so this watcher neither fetches its
  # state nor emits a MERGED/CLOSED event for it. Its seen file carries no
  # state= line. (fm-pr-check owns that signal; duplicating it would
  # double-report.) Once its task tears down it drops from the supervised set
  # and merge detection picks it up via auto-discovery + detect_left_open.
  local dir out sf
  dir=$(make_case meta-merge-skip)
  seed_meta "$dir" task-cc "https://github.com/acme/widgets/pull/9"
  seed_prs "$dir"   # meta-only: not in the open search
  printf 'MERGED\n' > "$dir/fixture/state-acme-widgets-9"
  # Turn every filter except merge off so the ONLY thing that could emit is merge.
  FM_STATE_OVERRIDE="$dir/state" bash "$GH_WATCH" filter comments off >/dev/null
  FM_STATE_OVERRIDE="$dir/state" bash "$GH_WATCH" filter ci off >/dev/null
  FM_STATE_OVERRIDE="$dir/state" bash "$GH_WATCH" filter reviews off >/dev/null
  sf="$dir/state/.github-watch-seen/acme-widgets-9"

  out=$(run_poll "$dir")
  if printf '%s\n' "$out" | grep -Fq "MERGED"; then
    fail "supervised PR emitted a MERGED event (should defer to fm-pr-check); got: $out"
  fi
  if printf '%s\n' "$out" | grep -Fq "CLOSED"; then
    fail "supervised PR emitted a CLOSED event; got: $out"
  fi
  # No state tracking for a meta-tracked PR.
  if [ -f "$sf" ] && grep -q '^state=' "$sf"; then
    fail "supervised PR seen file tracked state (should not): $(cat "$sf")"
  fi
  pass "supervised PR skips merge/close detection (deferred to fm-pr-check)"
}

test_supervised_pr_picks_up_merge_after_task_tears_down() {
  # When a task tears down, its PR leaves the supervised set and drops back to
  # auto-only. If it is still OPEN at that point, merge detection picks it up:
  # a later open->merged transition emits MERGED here exactly once. This is the
  # torn-down-PR coverage the auto-discovery design exists to provide.
  local dir out sf
  dir=$(make_case meta-teardown)
  seed_meta "$dir" task-dd "https://github.com/acme/widgets/pull/11"
  seed_prs "$dir"   # not yet in the open search (e.g. search filtered it out)
  printf 'OPEN\n' > "$dir/fixture/state-acme-widgets-11"
  sf="$dir/state/.github-watch-seen/acme-widgets-11"

  # Cycle 1: supervised (meta-tracked). No state tracked.
  run_poll "$dir" >/dev/null
  if [ -f "$sf" ] && grep -q '^state=' "$sf"; then
    fail "supervised PR tracked state prematurely: $(cat "$sf")"
  fi

  # Task tears down: meta removed. PR is now OPEN and shows up in auto-discovery.
  rm -f "$dir/state/task-dd.meta"
  seed_prs "$dir" $'acme/widgets\t11'
  # First auto-only cycle: baselines state=OPEN silently (first state tracking).
  run_poll "$dir" >/dev/null
  grep -Fxq "state=OPEN" "$sf" || fail "auto-only cycle did not baseline state=OPEN"

  # PR merges: leaves the open search -> MERGED fires once.
  : > "$dir/fixture/prs"
  printf 'MERGED\n' > "$dir/fixture/state-acme-widgets-11"
  out=$(run_poll "$dir")
  printf '%s\n' "$out" | grep -Fq "MERGED: acme/widgets#11" \
    || fail "torn-down supervised PR did not emit MERGED; got: $out"
  grep -Fxq "state=MERGED" "$sf" || fail "state not advanced to MERGED after teardown"
  # Not re-reported next cycle.
  out=$(run_poll "$dir")
  if printf '%s\n' "$out" | grep -Fq "MERGED"; then fail "MERGED re-reported after settling"; fi

  pass "torn-down supervised PR picks up merge detection via auto-discovery"
}

test_supervised_pr_lossless() {
  # The losslessness invariant (print before seen advance) holds for a
  # supervised-discovered PR exactly as for an auto-discovered one: a failing
  # seen write leaves the event re-detectable next cycle.
  local dir out sf
  dir=$(make_case meta-lossless)
  seed_meta "$dir" task-ee "https://github.com/acme/widgets/pull/13"
  seed_prs "$dir"
  printf '4\n' > "$dir/fixture/comments-acme-widgets-13"
  sf="$dir/state/.github-watch-seen/acme-widgets-13"

  run_poll "$dir" >/dev/null   # baseline
  grep -Fxq "comments=4" "$sf" || fail "supervised baseline not written"

  printf '8\n' > "$dir/fixture/comments-acme-widgets-13"
  chmod a-w "$dir/state/.github-watch-seen"
  out=$(run_poll "$dir")
  chmod u+w "$dir/state/.github-watch-seen"
  printf '%s\n' "$out" | grep -Fq "COMMENT: acme/widgets#13 has 4 new comment(s)" \
    || fail "supervised PR event did not print when seen write failed; got: $out"
  grep -Fxq "comments=4" "$sf" || fail "supervised seen advanced despite failing write"

  out=$(run_poll "$dir")
  printf '%s\n' "$out" | grep -Fq "COMMENT: acme/widgets#13 has 4 new comment(s)" \
    || fail "supervised PR event not re-detected after failed seen write; got: $out"

  pass "supervised-discovered PR is lossless (event prints before seen advances)"
}

test_auto_discovery_failure_still_polls_supervised() {
  # When auto-discovery (gh search) fails transitively, supervised PRs are still
  # polled for comments/ci/reviews, and detect_left_open is skipped (the open
  # set is not authoritative, so a missing PR must not be reported as merged).
  # Lossless: once discovery recovers, detect_left_open catches real changes.
  local dir out sf
  dir=$(make_case meta-autofail)
  seed_meta "$dir" task-ff "https://github.com/acme/widgets/pull/15"
  printf '2\n' > "$dir/fixture/comments-acme-widgets-15"
  sf="$dir/state/.github-watch-seen/acme-widgets-15"

  # search-error makes gh search prs fail; the supervised PR is still baselined.
  : > "$dir/fixture/search-error"
  out=$(run_poll "$dir" 2>/dev/null)
  [ -z "$out" ] || fail "supervised baseline should be silent under auto-failure; got: $out"
  grep -Fxq "comments=2" "$sf" || fail "supervised PR not polled when auto-discovery failed"

  # A new comment still fires while auto-discovery is down.
  printf '5\n' > "$dir/fixture/comments-acme-widgets-15"
  out=$(run_poll "$dir" 2>/dev/null)
  printf '%s\n' "$out" | grep -Fq "COMMENT: acme/widgets#15 has 3 new comment(s)" \
    || fail "supervised PR comment did not fire under auto-failure; got: $out"

  pass "auto-discovery failure still polls supervised PRs (fail-open)"
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
test_parallel_poll_is_lossless_and_does_not_cross_contaminate
test_silent_baseline_on_schema_migration
test_ci_ignore_excludes_known_gap_check
test_api_error_skips_pr_without_event
# supervised-discovery (state/*.meta) + union reconciliation
test_supervised_pr_discovered_via_meta
test_union_dedup_watches_overlapping_pr_once
test_supervised_pr_skips_merge_detection
test_supervised_pr_picks_up_merge_after_task_tears_down
test_supervised_pr_lossless
test_auto_discovery_failure_still_polls_supervised
