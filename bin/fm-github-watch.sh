#!/usr/bin/env bash
# fm-github-watch.sh — GitHub events watcher for the fleet's open PRs.
#
# Discovers PRs by a UNION of two sources and surfaces new comments (from
# maintainers, reviewers, or bots), CI status changes, reviews, and
# merge/close transitions as one-line events on stdout. Built to run as a
# watcher check script: it prints iff firstmate should wake, and stays silent
# otherwise.
#
# Discovery (the union, deduped by owner/repo/num so a PR in both is watched
# exactly once):
#   1. Auto-discovery: every OPEN PR authored by the contributor (gh search prs
#      --author). This is the strictly-broad net — it catches standalone or
#      already-torn-down PRs that no live task references, which is the whole
#      point (the gap that left firstmate blind to PRs going stale un-noticed).
#   2. Supervised discovery: every PR recorded in a state/<id>.meta pr= line.
#      This catches PRs firstmate is actively supervising that auto-discovery
#      would miss — most importantly external-contributor PRs on repos the
#      captain maintains, which are not authored by the contributor.
# Comments, rolled-up CI state, and reviews apply uniformly to the whole union.
# Merge/close detection applies only to auto-only PRs: a PR that is currently
# supervised already has bin/fm-pr-check.sh's per-task merge poll owning that
# signal, so duplicating it here would double-report; once its task tears down
# it drops out of the supervised set and merge detection picks it up here.
#
# Wire it in with a check script the existing watcher already sweeps, e.g.:
#   ln -s ../bin/fm-github-watch.sh state/github-events.check.sh
# bin/fm-watch.sh runs state/*.check.sh every FM_CHECK_INTERVAL (default 300s);
# any stdout is captured, classified as a `check` wake, escalated.
# A full poll issues up to 5 gh calls per open PR, but PRs are polled
# concurrently (bounded by FM_GH_CONCURRENCY, default 8) so a sweep across the
# fleet finishes in well under the watcher's 30s check-script timeout. Events
# emit per-PR (not all-at-end), so a timeout still surfaces partial progress.
#
# Usage:
#   fm-github-watch.sh                 # one poll cycle (same as --once)
#   fm-github-watch.sh --once          # one poll cycle
#   fm-github-watch.sh --daemon        # loop, polling every poll_interval
#   fm-github-watch.sh filter list     # show active filters
#   fm-github-watch.sh filter <name> on|off
#   fm-github-watch.sh contributor     # show configured contributor
#   fm-github-watch.sh contributor <user>
#   fm-github-watch.sh status          # show config + seen-state summary
#
# Filter names: comments, ci, reviews, merge.
# Config: state/.github-watch-config (key=value lines).
# Seen:   state/.github-watch-seen/<owner>-<repo>-<pr> (key=value lines).
#
# The ci filter rolls the Checks API (check-runs) up to a single overall state
# per PR (green/failure/pending) and fires one event only when that state flips,
# not once per check landing — so a PR whose many checks trickle in reports a
# single transition, not a burst. CI providers that report only via the legacy
# commit status API (some older Travis/Coveralls setups) are not covered; use
# `gh pr checks` directly for a unified view.
# Comment, review, and check-run counts fetch up to 100 items per type per PR
# (per_page=100, no pagination); a single PR with >100 of one kind would cap.
#
# Losslessness: for each PR, events are emitted BEFORE its seen marker advances
# (and bash's builtin printf write()s to the capture pipe immediately, so an
# emitted event survives even a SIGKILL). A crash between the print and the seen
# write at worst causes a redundant re-detect next cycle, never a permanent
# swallow. A failing seen write leaves the old marker in place, so the same
# event fires again next cycle. PRs are polled concurrently but each worker
# owns its own per-PR seen file, so this ordering holds per-worker exactly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
STATE="${FM_STATE_OVERRIDE:-$FM_ROOT/state}"
CONFIG="$STATE/.github-watch-config"
SEEN_DIR="$STATE/.github-watch-seen"
ALL_FILTERS="comments,ci,reviews,merge"
DEFAULT_POLL_SECS="${FM_GH_POLL_SECS:-300}"
# How long after a PR closes to keep re-probing it for a close->reopen->merge.
# Bounds API cost: a closed PR is re-checked only within this window, then
# treated as settled. ~2h at the default 300s poll.
CLOSE_REPROBE_SECS="${FM_GH_CLOSE_REPROBE_SECS:-7200}"
# Max number of PRs polled concurrently in a single sweep. Bounded so a large
# fleet can't burst GitHub's rate limit or hammer the API. ~88 calls/sweep at
# the captain's ~22 PRs is well under the 5000/hr ceiling even at 12 sweeps/hr.
# Set FM_GH_CONCURRENCY to tune (>=1; 0/non-numeric falls back to the default 8).
DEFAULT_CONCURRENCY=8
# Seen-state schema version. Bump when a stored field's meaning or the field set
# changes in a way that would make a prior value miscompare (e.g. the ci roll-up
# changed `ci` from a multiset signature to a single state). On a schema mismatch
# the first poll silently re-baselines: it writes the new seen state and emits no
# event, so deploying a schema change never floods once as every PR appears to
# "transition" off the old format. Only subsequent real transitions fire.
SEEN_SCHEMA=2
# Regex (Oniguruma) of check-run NAMES to drop from the CI roll-up before it is
# computed. Default: the known fork-routing signature gap #293 ("PR must be
# raised via no-mistakes"), which fails on kunchenguid fork-PRs even though the
# PR's real checks pass. With it excluded such PRs roll up to green when their
# real checks pass, instead of a false failure. Set FM_GH_IGNORE_CHECKS to a
# custom regex, or to empty to disable filtering entirely. Only the CI roll-up
# applies this; the raw check list and the other filters are unchanged.
IGNORE_CHECKS="${FM_GH_IGNORE_CHECKS-PR must be raised via no-mistakes}"

mkdir -p "$STATE" "$SEEN_DIR"

# ---- small helpers ----

is_int() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

valid_filter() {
  case "$1" in comments|ci|reviews|merge) return 0 ;; *) return 1 ;; esac
}

# A GitHub REST API error body is a JSON object carrying top-level "message" and
# "documentation_url" (e.g. {"message":"Bad credentials","documentation_url":"...","status":"401"}).
# On a transient API failure (401, 5xx, rate limit) gh writes that body to stdout
# — bypassing any --jq template — and exits non-zero. Every successful probe
# output is a scalar/number/TSV, never this shape, so the pair is a safe signal.
is_gh_error() {
  case "$1" in
    *'"message"'*)
      case "$1" in *'"documentation_url"'*) return 0 ;; esac
      ;;
  esac
  return 1
}

# Run gh, capturing its stdout. Returns non-zero if gh exited non-zero OR its
# output is a GitHub API error body; in either case the body is suppressed so a
# caller that ignores the exit status can never parse an error response as data
# (the bug: a 401 body reached stdout and was parsed as CI state, firing a bogus
# "CI: ... -> { \"message\": ... }" event). Probe callers treat a non-zero return
# as "skip this PR this cycle" so a transient blip never surfaces as an event.
# stderr is always swallowed so a missing gh or a transient failure never spams
# the watcher's own capture pipe.
ghc() {
  local out rc
  out=$(command gh "$@" 2>/dev/null); rc=$?
  if [ "$rc" -ne 0 ] || is_gh_error "$out"; then
    return 1
  fi
  printf '%s' "$out"
}

# cfg_read <key> -> prints value (empty if missing/unset)
cfg_read() {
  local key=$1
  [ -f "$CONFIG" ] || return 0
  awk -F= -v k="$key" '$1==k { sub(/^[^=]*=/, ""); print; exit }' "$CONFIG"
}

# cfg_has <key> -> 0 if the key exists in the config (distinguishes a configured
# empty value, e.g. `filters=`, from a missing key so "all filters off" sticks).
cfg_has() {
  local key=$1
  [ -f "$CONFIG" ] && grep -q "^${key}=" "$CONFIG"
}

# cfg_write <key> <value> (upsert a single key=value line)
cfg_write() {
  local key=$1 val=$2 tmp
  val=$(printf '%s' "$val" | tr '\n' ' ')
  if [ -f "$CONFIG" ] && grep -q "^${key}=" "$CONFIG"; then
    tmp="${CONFIG}.tmp.$$"
    awk -F= -v k="$key" -v v="$val" '$1==k { print k"="v; next } { print }' \
      "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  else
    printf '%s=%s\n' "$key" "$val" >> "$CONFIG"
  fi
}

get_contributor() {
  # Precedence: configured value > FM_GH_CONTRIBUTOR env > authenticated gh user.
  # No hardcoded default: a shared tool should poll whoever is logged in.
  local v
  v=$(cfg_read contributor)
  if [ -n "$v" ]; then printf '%s' "$v"; return; fi
  if [ -n "${FM_GH_CONTRIBUTOR:-}" ]; then printf '%s' "$FM_GH_CONTRIBUTOR"; return; fi
  ghc api user -q .login | tr -d '\n' || true
}

get_filters() {
  # A configured value (even empty = all filters off) is respected; only a
  # never-configured key falls back to the full default set.
  if cfg_has filters; then
    cfg_read filters
  else
    printf '%s' "$ALL_FILTERS"
  fi
}

filter_enabled() {
  case ",$(get_filters)," in *",$1,"*) return 0 ;; *) return 1 ;; esac
}

get_poll() {
  local v
  v=$(cfg_read poll_interval)
  case "${v:-}" in ''|*[!0-9]*) printf '%s' "$DEFAULT_POLL_SECS" ;; *) printf '%s' "$v" ;; esac
}

# Max concurrent per-PR workers in a sweep. FM_GH_CONCURRENCY overrides; a
# missing, empty, non-numeric, or zero value falls back to the sane default.
get_concurrency() {
  local v="${FM_GH_CONCURRENCY:-}"
  case "$v" in ''|*[!0-9]*|0) printf '%s' "$DEFAULT_CONCURRENCY" ;; *) printf '%s' "$v" ;; esac
}

# seen_file <owner> <repo> <pr> -> path to that PR's seen-state file
seen_file() { printf '%s/%s-%s-%s\n' "$SEEN_DIR" "$1" "$2" "$3"; }

# seen_get <file> <key> -> value (empty if missing)
seen_get() {
  local f=$1 key=$2
  [ -f "$f" ] || return 0
  awk -F= -v k="$key" '$1==k { sub(/^[^=]*=/, ""); print; exit }' "$f"
}

# ---- comma-list set ops ----

# list_contains "a,b,c" "b" -> 0 if present
list_contains() {
  case ",$1," in *",$2,"*) return 0 ;; *) return 1 ;; esac
}

# list_add "a,b,c" "d" -> "a,b,c,d" (dedup; preserves order)
list_add() {
  local list=$1 item=$2
  if list_contains "$list" "$item"; then
    printf '%s' "$list"
  else
    if [ -z "$list" ]; then printf '%s' "$item"; else printf '%s,%s' "$list" "$item"; fi
  fi
}

# list_remove "a,b,c" "b" -> "a,c"
list_remove() {
  local list=$1 item=$2 out="" i
  local IFS=,
  for i in $list; do
    [ "$i" = "$item" ] && continue
    if [ -z "$out" ]; then out=$i; else out="$out,$i"; fi
  done
  printf '%s' "$out"
}

# ---- discovery (two sources, unioned in poll_once) + per-PR probes ----

# Prints "owner/repo<TAB>number" per open PR by the contributor (auto-discovery).
discover_prs() {
  local contributor
  contributor=$(get_contributor)
  # An empty contributor (gh missing/unauthed) must NOT pass --author="" to the
  # search: GitHub treats an empty author qualifier as no filter, which would
  # match open PRs across every repo and flood the seen state.
  [ -n "$contributor" ] || return 0
  ghc search prs --author="$contributor" --state=open --limit 1000 \
    --json repository,number \
    --jq '.[] | [.repository.nameWithOwner, .number] | @tsv'
}

# Parse a pr=<url> value into "owner<TAB>repo<TAB>num" on stdout, or empty if
# not a parseable github.com pull URL. Tolerates a trailing slash or /files
# suffix by taking only the leading digits of the number segment. Always exits 0
# (empty output signals an unparseable URL); a caller checks for empty output.
parse_pr_url() {
  local url=$1 rest owner repo num
  case "$url" in
    https://github.com/*/pull/*) ;;
    *) return 0 ;;
  esac
  rest=${url#https://github.com/}   # OWNER/REPO/pull/NUM...
  owner=${rest%%/*}
  rest=${rest#*/}                   # REPO/pull/NUM...
  repo=${rest%%/*}
  rest=${rest#*/}                   # pull/NUM...
  case "$rest" in
    pull/*) num=${rest#pull/}; num=${num%%[!0-9]*} ;;
    *) return 0 ;;
  esac
  [ -n "$owner" ] && [ -n "$repo" ] && is_int "$num" || return 0
  printf '%s\t%s\t%s\n' "$owner" "$repo" "$num"
}

# Discover PRs Firstmate is actively supervising, from state/<id>.meta pr= lines.
# Prints unique "owner/repo<TAB>num" lines (same shape as discover_prs). A pure
# local read, so it costs nothing and never fails: empty when no task records a
# pr=. These are unioned with auto-discovery so the watcher covers supervised
# PRs that gh search --author would miss (e.g. external-contributor PRs on repos
# the captain maintains). A meta may carry several pr= lines over its life (a
# task re-pointed after a force-push/reopen); the last one is current.
discover_supervised_prs() {
  local meta url rec owner rest repo num key seen=$'\n'
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    url=$(grep '^pr=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    [ -n "$url" ] || continue
    rec=$(parse_pr_url "$url")
    [ -n "$rec" ] || continue
    owner=${rec%%$'\t'*}; rest=${rec#*$'\t'}
    repo=${rest%%$'\t'*}; num=${rest#*$'\t'}
    key="$owner/$repo/$num"
    # Newline-anchored dedup so a shorter PR number (e.g. #4) is not shadowed
    # by a longer one already seen (#42): the stored form is "\nkey\n".
    case "$seen" in
      *$'\n'"$key"$'\n'*) continue ;;
    esac
    seen="$seen$key"$'\n'
    printf '%s/%s\t%s\n' "$owner" "$repo" "$num"
  done
}

# count_comments <owner> <repo> <pr> <contributor>
count_comments() {
  CONTRIB_WATCH="$4" ghc api "repos/$1/$2/issues/$3/comments?per_page=100" \
    --jq '[.[] | select(.user.login != env.CONTRIB_WATCH)] | length'
}

# count_reviews <owner> <repo> <pr> <contributor>
# Excludes the contributor's own reviews (self-reviews) but keeps maintainer and
# bot reviews (Greptile, coderabbit, etc. have distinct logins).
count_reviews() {
  CONTRIB_WATCH="$4" ghc api "repos/$1/$2/pulls/$3/reviews?per_page=100" \
    --jq '[.[] | select(.user.login != env.CONTRIB_WATCH)] | length'
}

# pr_state <owner> <repo> <pr> -> OPEN|MERGED|CLOSED (empty on failure)
pr_state() {
  ghc pr view "$3" -R "$1/$2" --json state -q .state
}

# head_sha <owner> <repo> <pr>
head_sha() {
  ghc pr view "$3" -R "$1/$2" --json headRefOid -q .headRefOid
}

# ci_state <owner> <repo> <sha> -> the commit's rolled-up overall CI state:
#   success  every non-neutral check passed (conclusion success/skipped), none still running
#   failure  at least one non-neutral check failed (failure/timed_out/cancelled/action_required/stale)
#   pending  at least one non-neutral check is still queued/in_progress (no conclusion yet)
#   neutral  only neutral check-runs are present
#   (empty)  no check-runs reported yet; the caller carries forward the prior state
# Rolled up from the Checks API so a PR with many staggered checks surfaces a
# single green/red transition instead of one event per check landing. Failure
# beats pending (a red check already settles the PR's outcome), matching
# GitHub's own combined-status precedence. Check-runs whose NAME matches the
# IGNORE_CHECKS regex (default: the known fork-routing gap #293) are dropped
# before the roll-up, so a PR that fails ONLY that signature check still rolls
# up to green when its real checks pass. The regex is embedded into the jq
# program (escaped for a JSON string literal) because `gh api` has no --arg
# binding for its --jq filter; a malformed regex fails open to empty (carried
# forward), never crashing the poll.
ci_state() {
  [ -n "$3" ] || return 0
  local ignore_escaped jq_filter
  ignore_escaped=${IGNORE_CHECKS//\\/\\\\}
  ignore_escaped=${ignore_escaped//\"/\\\"}
  # The regex is embedded into the jq program (escaped for a JSON string
  # literal) because `gh api` has no --arg binding for its --jq filter. Every jq
  # binding ($ignore/$raw/$all/$rel) is backslash-escaped so the heredoc leaves
  # it literal; only $ignore_escaped expands.
  # shellcheck disable=SC2016
  jq_filter=$(cat <<JQ
"$ignore_escaped" as \$ignore
| (.check_runs // []) as \$raw
| (if \$ignore == "" then \$raw else [\$raw[] | select(((.name // "") | test(\$ignore)) | not)] end) as \$all
| (\$all | map(select(.conclusion != "neutral"))) as \$rel
| if   (\$all | length) == 0 then ""
  elif (\$rel | length) == 0 then "neutral"
  elif any(\$rel[]; .conclusion != null and .conclusion != "success" and .conclusion != "skipped") then "failure"
  elif any(\$rel[]; .conclusion == null) then "pending"
  else "success" end
JQ
)
  ghc api "repos/$1/$2/commits/$3/check-runs?per_page=100" --jq "$jq_filter"
}

# ci_label <state> -> the word printed in a CI event line (success -> green).
ci_label() {
  case "${1:-}" in
    success) printf 'green' ;;
    *) printf '%s' "${1:-unknown}" ;;
  esac
}

# ---- the poll ----

# atomic_write <file> <content> — write seen state via temp + rename so a crash
# or a read-only state dir can never leave a partial file. On any failure the
# prior file is left untouched, so the event re-fires next cycle (lossless).
# The temp lives in a hidden .tmp subdir of the seen dir (same filesystem, so
# the rename is atomic) so a crash-leaked temp never matches detect_left_open's
# `"$SEEN_DIR"/*` glob and cause a double-fire.
atomic_write() {
  local file=$1 content=$2 tmp stagedir
  stagedir="$SEEN_DIR/.tmp"
  tmp="$stagedir/$(basename "$file").$$"
  mkdir -p "$stagedir" 2>/dev/null || true
  # Redirect fd 2 to /dev/null BEFORE the output redirect so a failure to open
  # the temp (read-only dir) is reported to /dev/null, not the terminal.
  if printf '%s\n' "$content" 2>/dev/null > "$tmp"; then
    mv -f "$tmp" "$file" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  else
    rm -f "$tmp" 2>/dev/null
  fi
}

# build_seen <prior-seen-file> <owner> <repo> <pr> <c_count> <r_count> <ci_state> <sha> <p_state>
# Compose the seen-state block: high-water marks for counts, current value for
# ci/state. Fields with no fresh value this cycle are carried forward from the
# prior block, so toggling a filter off never wipes its remembered high-water.
# CI is the rolled-up overall state; it is carried forward across a transiently
# empty fetch (a new commit whose check-runs have not populated yet) so a later
# state transition still fires.
build_seen() {
  local sf=$1 owner=$2 repo=$3 pr=$4 c_count=$5 r_count=$6 ci_st=$7 sha=$8 p_state=$9
  local seen_c seen_r seen_ci seen_state new_c new_r ci_val state_val block
  seen_c=$(seen_get "$sf" comments)
  seen_r=$(seen_get "$sf" reviews)
  seen_ci=$(seen_get "$sf" ci)
  seen_state=$(seen_get "$sf" state)
  new_c=$seen_c; new_r=$seen_r
  if is_int "$c_count"; then
    if is_int "$seen_c"; then new_c=$((seen_c > c_count ? seen_c : c_count)); else new_c=$c_count; fi
  fi
  if is_int "$r_count"; then
    if is_int "$seen_r"; then new_r=$((seen_r > r_count ? seen_r : r_count)); else new_r=$r_count; fi
  fi
  ci_val=$ci_st
  [ -n "$ci_val" ] || ci_val=$seen_ci
  state_val=$p_state
  [ -n "$state_val" ] || state_val=$seen_state
  block=$(printf 'owner=%s\nrepo=%s\npr=%s\nschema=%s\ninitialized=1' "$owner" "$repo" "$pr" "$SEEN_SCHEMA")
  is_int "$new_c"     && block=$(printf '%s\ncomments=%s' "$block" "$new_c")
  is_int "$new_r"     && block=$(printf '%s\nreviews=%s'  "$block" "$new_r")
  [ -n "$ci_val" ]    && block=$(printf '%s\nci=%s'       "$block" "$ci_val")
  [ -n "$sha" ]       && block=$(printf '%s\nsha=%s'      "$block" "$sha")
  [ -n "$state_val" ] && block=$(printf '%s\nstate=%s'    "$block" "$state_val")
  printf '%s' "$block"
}

# process_pr <owner> <repo> <pr> <contributor> <meta_tracked>
# Gather fresh data for the enabled filters, EMIT any new events for this PR,
# then advance this PR's seen marker. Per-PR ordering (print before seen) plus
# bash's immediate write() to the capture pipe make this lossless even if the
# poll is killed mid-cycle: an emitted event is already in the pipe, and a PR
# whose marker never advanced simply re-fires next cycle. Runs one worker per
# PR under poll_once's bounded concurrency; each worker writes only this PR's
# own seen file, so concurrent workers never contend on seen state.
# meta_tracked=1 (this PR is in a live task's state/*.meta) skips the merge
# filter entirely: bin/fm-pr-check.sh's per-task merge poll already owns that
# signal, so emitting MERGED/CLOSED here would double-report. comments/ci/reviews
# still run, because fm-pr-check does not cover them. A meta_tracked PR's seen
# file therefore carries no state=/closed_at= until its task tears down and it
# drops back to auto-only, at which point merge detection picks it up here.
process_pr() {
  local owner=$1 repo=$2 pr=$3 contributor=$4 meta_tracked=${5:-0}
  local sf c_count r_count p_state sha ci_st
  local initialized seen_c seen_r seen_state seen_ci ev=""
  sf=$(seen_file "$owner" "$repo" "$pr")

  local api_err=0
  c_count="" r_count="" p_state="" sha="" ci_st=""
  if filter_enabled comments; then c_count=$(count_comments "$owner" "$repo" "$pr" "$contributor") || api_err=1; fi
  if filter_enabled reviews;  then r_count=$(count_reviews  "$owner" "$repo" "$pr" "$contributor") || api_err=1; fi
  # Merge detection only for auto-only PRs (meta_tracked=0). See function header.
  if filter_enabled merge && [ "$meta_tracked" -eq 0 ]; then
    p_state=$(pr_state "$owner" "$repo" "$pr") || api_err=1
  fi
  if filter_enabled ci; then
    sha=$(head_sha "$owner" "$repo" "$pr") || api_err=1
    if [ -n "$sha" ]; then ci_st=$(ci_state "$owner" "$repo" "$sha") || api_err=1; fi
  fi
  # If any enabled probe hit a GitHub API error this cycle, skip the whole PR:
  # emit nothing and do not advance seen, so a transient blip can never surface
  # as an event (e.g. an error JSON parsed as CI data). The next cycle
  # re-evaluates from the same baseline — lossless, never a permanent swallow.
  if [ "$api_err" -ne 0 ]; then
    printf 'fm-github-watch: skipping %s/%s#%s this cycle (GitHub API error)\n' \
      "$owner" "$repo" "$pr" >&2
    return 0
  fi

  initialized=$(seen_get "$sf" initialized)
  # A prior seen file whose schema does not match the current version is treated
  # as a first-run baseline: emit nothing this cycle (so deploying a schema
  # change never floods as every PR appears to "transition" off the old format)
  # and let build_seen rewrite it at the current schema with carried-forward
  # values. Only subsequent real transitions fire.
  if [ -n "$initialized" ] && [ "$(seen_get "$sf" schema)" = "$SEEN_SCHEMA" ]; then
    seen_c=$(seen_get "$sf" comments)
    seen_r=$(seen_get "$sf" reviews)
    seen_state=$(seen_get "$sf" state)
    seen_ci=$(seen_get "$sf" ci)

    # comments (high-water): event on increase only.
    if is_int "$c_count" && is_int "$seen_c" && [ "$c_count" -gt "$seen_c" ]; then
      ev="${ev}COMMENT: ${owner}/${repo}#${pr} has $((c_count - seen_c)) new comment(s)
"
    fi
    # reviews (high-water): event on increase only.
    if is_int "$r_count" && is_int "$seen_r" && [ "$r_count" -gt "$seen_r" ]; then
      ev="${ev}REVIEW: ${owner}/${repo}#${pr} has $((r_count - seen_r)) new review(s)
"
    fi
    # ci: event on overall-state transition only (debounced). A PR with many
    # staggered checks surfaces one event per green/red/pending flip, not one
    # per check landing. No event while the rolled-up state is unchanged.
    if [ -n "$ci_st" ] && [ -n "$seen_ci" ] && [ "$seen_ci" != "$ci_st" ]; then
      ev="${ev}CI: ${owner}/${repo}#${pr} -> $(ci_label "$ci_st")
"
    fi
    # merge: event on open -> merged/closed transition. Only evaluated when
    # p_state was fetched (auto-only PRs); a meta_tracked PR has p_state="" so
    # this block is inert for it.
    if [ -n "$p_state" ] && [ "$p_state" != "$seen_state" ]; then
      case "$p_state" in
        MERGED) [ "${seen_state:-OPEN}" = "OPEN" ] && ev="${ev}MERGED: ${owner}/${repo}#${pr}
" ;;
        CLOSED) [ "${seen_state:-OPEN}" = "OPEN" ] && ev="${ev}CLOSED: ${owner}/${repo}#${pr}
" ;;
      esac
    fi
  fi

  # --- LOSSLESSNESS BOUNDARY (per-PR) ---
  # Emit this PR's events first (bash's printf write()s to the pipe at once),
  # then advance its seen marker. A crash between the two leaves the event
  # delivered and the marker stale -> a redundant re-detect, never a swallow.
  [ -n "$ev" ] && printf '%s' "$ev"
  local block
  block=$(build_seen "$sf" "$owner" "$repo" "$pr" "$c_count" "$r_count" "$ci_st" "$sha" "$p_state")
  atomic_write "$sf" "$block"
}

# Emit one poll cycle.
poll_once() {
  local contributor auto_prs meta_prs auto_failed=0
  local max_jobs running
  max_jobs=$(get_concurrency)
  running=0
  contributor=$(get_contributor)

  # Auto-discovery: the contributor's whole open-PR fleet. A failure (transient
  # API blip) is recorded but not fatal: supervised PRs are still polled below,
  # and detect_left_open is skipped because the open set is no longer
  # authoritative (we cannot tell whether an absent PR really merged or the
  # search just failed). Lossless: next cycle, once discovery recovers,
  # detect_left_open runs and catches the transition.
  auto_prs=$(discover_prs) || auto_failed=1

  # Supervised discovery: PRs recorded in state/<id>.meta. Pure local read.
  meta_prs=$(discover_supervised_prs)

  # Build the union with a per-PR meta_tracked flag, deduped by owner/repo/num.
  # meta_tracked=1 if the PR is in the supervised set (covers it even when also
  # auto-discovered, so a live task's PR is watched once, with merge deferred to
  # fm-pr-check). The dedup set is newline-anchored so #4 is not shadowed by #42.
  local keys=$'\n' union="" key owner_repo num meta_tracked
  if [ -n "$meta_prs" ]; then
    while IFS=$'\t' read -r owner_repo num; do
      [ -n "${owner_repo:-}" ] || continue
      key="$owner_repo/$num"
      case "$keys" in
        *$'\n'"$key"$'\n'*) continue ;;
      esac
      keys="$keys$key"$'\n'
      union="${union}${owner_repo}"$'\t'"${num}"$'\t'"1"$'\n'
    done <<EOF
$meta_prs
EOF
  fi
  if [ -n "$auto_prs" ]; then
    while IFS=$'\t' read -r owner_repo num; do
      [ -n "${owner_repo:-}" ] || continue
      key="$owner_repo/$num"
      case "$keys" in
        *$'\n'"$key"$'\n'*) continue ;;
      esac
      keys="$keys$key"$'\n'
      union="${union}${owner_repo}"$'\t'"${num}"$'\t'"0"$'\n'
    done <<EOF
$auto_prs
EOF
  fi

  # No PRs discovered this cycle: the per-PR polling loop below is simply inert.
  # detect_left_open still runs (when auto-discovery succeeded) so a PR that
  # merged/closed since the last poll is still caught — that is the whole point
  # of merge detection for torn-down/standalone PRs.
  local open_basenames=" "
  local meta_keys=$'\n'
  if [ -n "$meta_prs" ]; then
    while IFS=$'\t' read -r owner_repo num; do
      [ -n "${owner_repo:-}" ] || continue
      meta_keys="${meta_keys}${owner_repo}/${num}"$'\n'
    done <<EOF
$meta_prs
EOF
  fi

  # Parallel per-PR polling. Each worker is a subshell running process_pr; each
  # owns its own seen file (seen_file is keyed by owner/repo/pr), so concurrent
  # seen writes never collide. Concurrency is bounded by FM_GH_CONCURRENCY
  # (default 8) via a counting semaphore so a large fleet can't burst the GitHub
  # rate limit. Each worker prints its whole event block in a single printf
  # (one write() of a few hundred bytes, atomic under PIPE_BUF, so lines never
  # interleave), and only then advances its own seen marker — the losslessness
  # invariant (print before seen) holds per-worker exactly as in the serial
  # model: a crash/timeout mid-sweep at worst re-detects, never swallows.
  while IFS=$'\t' read -r owner_repo num meta_tracked; do
    [ -n "${owner_repo:-}" ] || continue
    local owner repo basename
    owner=${owner_repo%%/*}
    repo=${owner_repo#*/}
    if [ -z "$owner" ] || [ -z "$repo" ] || [ "$owner" = "$owner_repo" ] || [ -z "${num:-}" ]; then
      continue
    fi
    basename=$(seen_file "$owner" "$repo" "$num"); basename=${basename##*/}
    open_basenames="${open_basenames}${basename} "

    # Throttle: at capacity, wait for one worker to finish before launching the
    # next. wait -n (bash >= 4.3) blocks until any child exits; the decrement
    # keeps the running count honest (it can only under-count finished workers,
    # which is conservative — concurrency never exceeds the cap).
    while [ "$running" -ge "$max_jobs" ]; do
      wait -n 2>/dev/null || wait
      running=$((running - 1))
    done

    # </dev/null so no worker's gh children can consume this loop's stdin.
    process_pr "$owner" "$repo" "$num" "$contributor" "$meta_tracked" </dev/null &
    running=$((running + 1))
  done <<EOF
$union
EOF

  # Wait for every worker before detect_left_open, so the per-PR seen files are
  # settled and open_basenames is complete — a live worker must not be writing a
  # seen file while detect_left_open scans the seen dir.
  wait
  running=0

  # detect_left_open only runs when auto-discovery succeeded: the open set must
  # be authoritative to conclude a missing PR merged/closed. On an auto-failure
  # cycle we skip it entirely (lossless: next good cycle catches the change).
  if [ "$auto_failed" -eq 0 ]; then
    detect_left_open "$open_basenames" "$meta_keys"
  fi
}

# Detect PRs that left the open search (merged or closed) since the last poll.
# For each, emit a state transition and advance its seen state. Only MERGED is
# terminal: a CLOSED PR can be reopened and later merged, so CLOSED PRs are
# re-probed within a bounded window (CLOSE_REPROBE_SECS after they closed) so a
# close->reopen->merge still fires, without an unbounded per-cycle API cost as
# closed PRs accumulate. detect_left_open <open-basenames> <meta-keys>
# (open_basenames is space-padded: " key1 key2 " so the last entry matches too;
# meta-keys is newline-anchored: "\nowner/repo/num\n" for supervised PRs).
# Supervised PRs (in meta-keys) are skipped: fm-pr-check.sh owns their merge
# signal and process_pr did not track their state, so a "left open" reading
# would be spurious. Once a task tears down, its PR leaves meta-keys and merge
# detection picks it up here.
detect_left_open() {
  local open_basenames=$1 meta_keys=$2
  local f base owner repo pr seen_state p_state block closed_at now
  filter_enabled merge || return 0
  [ -d "$SEEN_DIR" ] || return 0
  now=$(date +%s)
  for f in "$SEEN_DIR"/*; do
    [ -e "$f" ] || continue
    base=${f##*/}
    case "$base" in *.tmp.*) continue ;; esac
    case "$open_basenames" in *" $base "*) continue ;; esac
    [ -n "$(seen_get "$f" initialized)" ] || continue
    owner=$(seen_get "$f" owner)
    repo=$(seen_get "$f" repo)
    pr=$(seen_get "$f" pr)
    # Skip supervised PRs: fm-pr-check.sh owns their merge signal.
    if [ -n "$owner" ] && [ -n "$repo" ] && [ -n "$pr" ]; then
      case "$meta_keys" in
        *$'\n'"${owner}/${repo}/${pr}"$'\n'*) continue ;;
      esac
    fi
    seen_state=$(seen_get "$f" state)
    [ "$seen_state" = "MERGED" ] && continue   # merged is the only terminal state
    # A CLOSED PR older than the re-probe window is settled: skip the API call
    # so accumulated closed PRs cannot push the fleet past the rate limit.
    if [ "$seen_state" = "CLOSED" ]; then
      closed_at=$(seen_get "$f" closed_at)
      if [ -n "$closed_at" ] && [ $((now - closed_at)) -ge "$CLOSE_REPROBE_SECS" ]; then
        continue
      fi
    fi
    if [ -z "$owner" ] || [ -z "$repo" ] || [ -z "$pr" ]; then continue; fi
    p_state=$(pr_state "$owner" "$repo" "$pr") || continue
    [ -n "$p_state" ] || continue   # transient gh failure: leave seen state untouched
    # Migration: a prior seen file whose schema does not match the current
    # version is silently re-baselined — stamp the current schema + observed
    # state, emit nothing — so a schema change never floods as every PR appears
    # to "transition" off the old format. All other fields (closed_at, counts,
    # ci) are preserved; only schema/state are re-stamped.
    if [ "$(seen_get "$f" schema)" != "$SEEN_SCHEMA" ]; then
      block=$(awk -F= -v sch="$SEEN_SCHEMA" -v s="$p_state" \
        '$1 != "schema" && $1 != "state" { print } END { print "schema=" sch; print "state=" s }' "$f")
      atomic_write "$f" "$block"
      continue
    fi
    [ "$p_state" = "$seen_state" ] && continue   # unchanged: no event, no rewrite
    case "$p_state" in
      MERGED|CLOSED)
        # Emit, then advance state (same per-PR losslessness ordering).
        printf '%s: %s/%s#%s\n' "$p_state" "$owner" "$repo" "$pr"
        ;;
      *)
        # Reopened back to OPEN (or unknown): no event, but track the new state
        # so a later merge still fires from the right baseline.
        ;;
    esac
    # Rewrite state; stamp closed_at when entering CLOSED so the re-probe window
    # can age it out, and clear it on any other transition.
    local cat=""
    [ "$p_state" = "CLOSED" ] && cat=$now
    block=$(awk -F= -v s="$p_state" -v cat="$cat" \
      '$1!="state" && $1!="closed_at" { print } END { print "state=" s; if (cat != "") print "closed_at=" cat }' "$f")
    atomic_write "$f" "$block"
  done
}

# ---- daemon ----

poll_daemon() {
  local interval
  interval=$(get_poll)
  trap 'exit 0' INT TERM
  while :; do
    poll_once
    sleep "$interval"
  done
}

# ---- CLI subcommands ----

cmd_filter() {
  # filter list                 -> show active filters
  # filter <name> on|off        -> toggle a filter
  local name="${1:-}" state="${2:-}"
  if [ -z "$name" ] || [ "$name" = "list" ]; then
    local IFS=,
    for f in $(get_filters); do printf '%s\n' "$f"; done
    return
  fi
  valid_filter "$name" || { echo "error: unknown filter '$name' (comments|ci|reviews|merge)" >&2; exit 2; }
  case "$state" in
    on|off) ;;
    *) echo "usage: fm-github-watch.sh filter [list | <name> on|off]" >&2; exit 2 ;;
  esac
  local cur new
  cur=$(get_filters)
  if [ "$state" = "on" ]; then
    new=$(list_add "$cur" "$name")
  else
    new=$(list_remove "$cur" "$name")
  fi
  cfg_write filters "$new"
  echo "filters=$new"
}

cmd_contributor() {
  if [ "$#" -gt 0 ]; then
    cfg_write contributor "$1"
    echo "contributor=$1"
  else
    get_contributor
  fi
}

cmd_status() {
  local contributor filters f on seen_count
  contributor=$(get_contributor)
  filters=$(get_filters)
  printf 'contributor: %s\n' "$contributor"
  printf 'filters:\n'
  for f in comments ci reviews merge; do
    if list_contains "$filters" "$f"; then on=on; else on=off; fi
    printf '  %s: %s\n' "$f" "$on"
  done
  printf 'poll interval: %ss\n' "$(get_poll)"
  seen_count=0
  if [ -d "$SEEN_DIR" ]; then
    # Exclude the .tmp staging subdir so leaked temps never inflate the count.
    seen_count=$(find "$SEEN_DIR" -type f -not -path '*/.tmp/*' 2>/dev/null | wc -l | tr -d ' ')
  fi
  printf 'seen PRs: %s\n' "$seen_count"
}

usage() {
  # Print the leading `#` header comment (lines 2..) up to the first non-comment
  # line, stripping the `# ` prefix. Stops before `set -u` so no code leaks.
  awk 'NR==1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

# ---- entry ----

case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  --once|"") poll_once ;;
  --daemon) poll_daemon ;;
  filter) shift; cmd_filter "$@" ;;
  contributor) shift; cmd_contributor "$@" ;;
  status) cmd_status ;;
  *)
    echo "error: unknown command '${1:-}'" >&2
    usage >&2
    exit 2
    ;;
esac
