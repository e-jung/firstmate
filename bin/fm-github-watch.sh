#!/usr/bin/env bash
# fm-github-watch.sh — GitHub events watcher for the fleet's open PRs.
#
# Discovers all of a contributor's open PRs and surfaces new comments (from
# maintainers, reviewers, or bots), CI status changes, reviews, and
# merge/close transitions as one-line events on stdout. Built to run as a
# watcher check script: it prints iff firstmate should wake, and stays
# silent otherwise.
#
# Wire it in with a check script the existing watcher already sweeps, e.g.:
#   ln -s ../bin/fm-github-watch.sh state/github-events.check.sh
# bin/fm-watch.sh runs state/*.check.sh every FM_CHECK_INTERVAL (default
# 300s); any stdout is captured, classified as a `check` wake, escalated.
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
# The ci filter reads the Checks API (check-runs); CI providers that report
# only via the legacy commit status API (some older Travis/Coveralls setups)
# are not covered. Use `gh pr checks` directly for a unified view.
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
set -u

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

mkdir -p "$STATE" "$SEEN_DIR"

# ---- small helpers ----

is_int() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

valid_filter() {
  case "$1" in comments|ci|reviews|merge) return 0 ;; *) return 1 ;; esac
}

# Run gh, swallowing errors and stderr so a missing gh or a transient API
# failure never kills the poll (output is simply empty for that call).
ghc() { command gh "$@" 2>/dev/null || true; }

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
  ghc api user -q .login 2>/dev/null | tr -d '\n'
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

# ---- discovery + per-PR probes (each fails open: empty output, no crash) ----

# Prints "owner/repo<TAB>number" per open PR by the contributor.
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

# ci_signature <owner> <repo> <sha> -> sorted multiset of check conclusions/statuses
ci_signature() {
  [ -n "$3" ] || return 0
  ghc api "repos/$1/$2/commits/$3/check-runs?per_page=100" \
    --jq '[.check_runs[] | (.conclusion // .status)] | sort | join(",")'
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

# build_seen <prior-seen-file> <owner> <repo> <pr> <c_count> <r_count> <ci_sig> <sha> <p_state>
# Compose the seen-state block: high-water marks for counts, current value for
# ci/state. Fields with no fresh value this cycle are carried forward from the
# prior block, so toggling a filter off never wipes its remembered high-water.
# CI is carried forward across a transiently-empty fetch (a new commit whose
# check-runs have not populated yet) so a later status change still fires.
build_seen() {
  local sf=$1 owner=$2 repo=$3 pr=$4 c_count=$5 r_count=$6 ci_sig=$7 sha=$8 p_state=$9
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
  ci_val=$ci_sig
  [ -n "$ci_val" ] || ci_val=$seen_ci
  state_val=$p_state
  [ -n "$state_val" ] || state_val=$seen_state
  block=$(printf 'owner=%s\nrepo=%s\npr=%s\ninitialized=1' "$owner" "$repo" "$pr")
  is_int "$new_c"     && block=$(printf '%s\ncomments=%s' "$block" "$new_c")
  is_int "$new_r"     && block=$(printf '%s\nreviews=%s'  "$block" "$new_r")
  [ -n "$ci_val" ]    && block=$(printf '%s\nci=%s'       "$block" "$ci_val")
  [ -n "$sha" ]       && block=$(printf '%s\nsha=%s'      "$block" "$sha")
  [ -n "$state_val" ] && block=$(printf '%s\nstate=%s'    "$block" "$state_val")
  printf '%s' "$block"
}

# process_pr <owner> <repo> <pr> <contributor>
# Gather fresh data for the enabled filters, EMIT any new events for this PR,
# then advance this PR's seen marker. Per-PR ordering (print before seen) plus
# bash's immediate write() to the capture pipe make this lossless even if the
# poll is killed mid-cycle: an emitted event is already in the pipe, and a PR
# whose marker never advanced simply re-fires next cycle. Runs one worker per
# PR under poll_once's bounded concurrency; each worker writes only this PR's
# own seen file, so concurrent workers never contend on seen state.
process_pr() {
  local owner=$1 repo=$2 pr=$3 contributor=$4
  local sf c_count r_count p_state sha ci_sig
  local initialized seen_c seen_r seen_state seen_ci ev=""
  sf=$(seen_file "$owner" "$repo" "$pr")

  c_count="" r_count="" p_state="" sha="" ci_sig=""
  filter_enabled comments && c_count=$(count_comments "$owner" "$repo" "$pr" "$contributor")
  filter_enabled reviews  && r_count=$(count_reviews "$owner" "$repo" "$pr" "$contributor")
  filter_enabled merge    && p_state=$(pr_state "$owner" "$repo" "$pr")
  if filter_enabled ci; then
    sha=$(head_sha "$owner" "$repo" "$pr")
    ci_sig=$(ci_signature "$owner" "$repo" "$sha")
  fi

  initialized=$(seen_get "$sf" initialized)
  if [ -n "$initialized" ]; then
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
    # ci: event on any signature change.
    if [ -n "$ci_sig" ] && [ -n "$seen_ci" ] && [ "$seen_ci" != "$ci_sig" ]; then
      ev="${ev}CI: ${owner}/${repo}#${pr} checks changed
"
    fi
    # merge: event on open -> merged/closed transition.
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
  block=$(build_seen "$sf" "$owner" "$repo" "$pr" "$c_count" "$r_count" "$ci_sig" "$sha" "$p_state")
  atomic_write "$sf" "$block"
}

# Emit one poll cycle.
poll_once() {
  local contributor prs fullname pr owner repo basename
  local open_basenames=" "
  local max_jobs running
  max_jobs=$(get_concurrency)
  running=0
  contributor=$(get_contributor)
  prs=$(discover_prs)

  # Parallel per-PR polling. Each worker is a subshell running process_pr; each
  # owns its own seen file (seen_file is keyed by owner/repo/pr), so concurrent
  # seen writes never collide. Concurrency is bounded by FM_GH_CONCURRENCY
  # (default 8) via a counting semaphore so a large fleet can't burst the GitHub
  # rate limit. Each worker prints its whole event block in a single printf
  # (one write() of a few hundred bytes, atomic under PIPE_BUF, so lines never
  # interleave), and only then advances its own seen marker — the losslessness
  # invariant (print before seen) holds per-worker exactly as in the serial
  # model: a crash/timeout mid-sweep at worst re-detects, never swallows.
  while IFS=$'\t' read -r fullname pr; do
    [ -n "${fullname:-}" ] || continue
    owner=${fullname%%/*}
    repo=${fullname#*/}
    if [ -z "$owner" ] || [ -z "$repo" ] || [ "$owner" = "$fullname" ] || [ -z "${pr:-}" ]; then
      continue
    fi
    basename=$(seen_file "$owner" "$repo" "$pr"); basename=${basename##*/}
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
    process_pr "$owner" "$repo" "$pr" "$contributor" </dev/null &
    running=$((running + 1))
  done <<EOF
$prs
EOF

  # Wait for every worker before detect_left_open, so the per-PR seen files are
  # settled and open_basenames is complete — a live worker must not be writing a
  # seen file while detect_left_open scans the seen dir.
  wait
  running=0

  detect_left_open "$open_basenames"
}

# Detect PRs that left the open search (merged or closed) since the last poll.
# For each, emit a state transition and advance its seen state. Only MERGED is
# terminal: a CLOSED PR can be reopened and later merged, so CLOSED PRs are
# re-probed within a bounded window (CLOSE_REPROBE_SECS after they closed) so a
# close->reopen->merge still fires, without an unbounded per-cycle API cost as
# closed PRs accumulate. detect_left_open <open-basenames> (space-padded:
# " key1 key2 " so the last entry matches too).
detect_left_open() {
  local open_basenames=$1 f base owner repo pr seen_state p_state block closed_at now
  filter_enabled merge || return 0
  [ -d "$SEEN_DIR" ] || return 0
  now=$(date +%s)
  for f in "$SEEN_DIR"/*; do
    [ -e "$f" ] || continue
    base=${f##*/}
    case "$base" in *.tmp.*) continue ;; esac
    case "$open_basenames" in *" $base "*) continue ;; esac
    [ -n "$(seen_get "$f" initialized)" ] || continue
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
    owner=$(seen_get "$f" owner)
    repo=$(seen_get "$f" repo)
    pr=$(seen_get "$f" pr)
    if [ -z "$owner" ] || [ -z "$repo" ] || [ -z "$pr" ]; then continue; fi
    p_state=$(pr_state "$owner" "$repo" "$pr")
    [ -n "$p_state" ] || continue   # transient gh failure: leave seen state untouched
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
