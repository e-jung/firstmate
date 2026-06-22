#!/usr/bin/env bash
# fm-github-watch.sh — GitHub events watcher for the fleet's open PRs.
#
# Discovers all of a contributor's open PRs and surfaces new maintainer
# comments, CI status changes, reviews, and merge/close transitions as
# one-line events on stdout. Built to run as a watcher check script: it
# prints iff firstmate should wake, and stays silent otherwise.
#
# Wire it in with a check script the existing watcher already sweeps, e.g.:
#   ln -s ../bin/fm-github-watch.sh state/github-events.check.sh
# bin/fm-watch.sh runs state/*.check.sh every FM_CHECK_INTERVAL (default
# 300s); any stdout is captured, classified as a `check` wake, escalated.
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
# Losslessness: seen markers are written ONLY as the last action of a poll,
# after every event line has already been emitted. A crash between print and
# the seen write at worst causes a redundant re-detect next cycle, never a
# permanent swallow. A failing seen write leaves the old marker in place, so
# the same event fires again next cycle.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
STATE="${FM_STATE_OVERRIDE:-$FM_ROOT/state}"
CONFIG="$STATE/.github-watch-config"
SEEN_DIR="$STATE/.github-watch-seen"
DEFAULT_CONTRIBUTOR="${FM_GH_CONTRIBUTOR:-e-jung}"
ALL_FILTERS="comments,ci,reviews,merge"
DEFAULT_POLL_SECS="${FM_GH_POLL_SECS:-300}"

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
  local v
  v=$(cfg_read contributor)
  printf '%s' "${v:-$DEFAULT_CONTRIBUTOR}"
}

get_filters() {
  local v
  v=$(cfg_read filters)
  [ -n "$v" ] || v=$ALL_FILTERS
  printf '%s' "$v"
}

filter_enabled() {
  case ",$(get_filters)," in *",$1,"*) return 0 ;; *) return 1 ;; esac
}

get_poll() {
  local v
  v=$(cfg_read poll_interval)
  case "${v:-}" in ''|*[!0-9]*) printf '%s' "$DEFAULT_POLL_SECS" ;; *) printf '%s' "$v" ;; esac
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
  ghc search prs --author="$contributor" --state=open \
    --json repository,number \
    --jq '.[] | [.repository.nameWithOwner, .number] | @tsv'
}

# count_comments <owner> <repo> <pr> <contributor>
count_comments() {
  CONTRIB_WATCH="$4" ghc api "repos/$1/$2/issues/$3/comments" \
    --jq '[.[] | select(.user.login != env.CONTRIB_WATCH)] | length'
}

# count_reviews <owner> <repo> <pr>
count_reviews() {
  ghc api "repos/$1/$2/pulls/$3/reviews" --jq 'length'
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
  ghc api "repos/$1/$2/commits/$3/check-runs" \
    --jq '[.check_runs[] | (.conclusion // .status)] | sort | join(",")'
}

# ---- the poll ----

# Emit one poll cycle. Events for ALL prs are accumulated in memory, printed in
# a single burst, and only then are seen markers advanced — so a crash can never
# advance a marker past an event that was not yet emitted.
poll_once() {
  local contributor prs EVENTS="" pending
  contributor=$(get_contributor)
  prs=$(discover_prs)

  # Staged seen updates: written to a scratch dir during the loop, moved into
  # place only AFTER events are printed (the last action of the poll).
  pending=$(mktemp -d "${TMPDIR:-/tmp}/fm-ghwatch.XXXXXX")

  local fullname pr owner repo sf basename initialized
  local c_count r_count p_state sha ci_sig
  local seen_c seen_r seen_state seen_ci new_c new_r
  local open_basenames=""
  local block

  while IFS=$'\t' read -r fullname pr; do
    [ -n "${fullname:-}" ] || continue
    owner=${fullname%%/*}
    repo=${fullname#*/}
    { [ -n "$owner" ] && [ -n "$repo" ] && [ "$owner" != "$fullname" ] && [ -n "${pr:-}" ]; } || continue

    sf=$(seen_file "$owner" "$repo" "$pr")
    basename=${sf##*/}
    open_basenames="$open_basenames $basename"

    # Gather fresh data only for enabled filters.
    c_count="" r_count="" p_state="" sha="" ci_sig=""
    filter_enabled comments && c_count=$(count_comments "$owner" "$repo" "$pr" "$contributor")
    filter_enabled reviews  && r_count=$(count_reviews "$owner" "$repo" "$pr")
    filter_enabled merge    && p_state=$(pr_state "$owner" "$repo" "$pr")
    if filter_enabled ci; then
      sha=$(head_sha "$owner" "$repo" "$pr")
      ci_sig=$(ci_signature "$owner" "$repo" "$sha")
    fi

    initialized=$(seen_get "$sf" initialized)
    seen_c="" seen_r="" seen_state="" seen_ci=""
    block=$(printf 'owner=%s\nrepo=%s\npr=%s\ninitialized=1\n' "$owner" "$repo" "$pr")

    if [ -z "$initialized" ]; then
      # First sight of this PR: baseline silently (no events).
      :
    else
      seen_c=$(seen_get "$sf" comments)
      seen_r=$(seen_get "$sf" reviews)
      seen_state=$(seen_get "$sf" state)
      seen_ci=$(seen_get "$sf" ci)

      # comments (high-water): event on increase only.
      if is_int "$c_count" && is_int "$seen_c" && [ "$c_count" -gt "$seen_c" ]; then
        EVENTS="${EVENTS}COMMENT: ${fullname}#${pr} has $((c_count - seen_c)) new maintainer comment(s)
"
      fi
      # reviews (high-water): event on increase only.
      if is_int "$r_count" && is_int "$seen_r" && [ "$r_count" -gt "$seen_r" ]; then
        EVENTS="${EVENTS}REVIEW: ${fullname}#${pr} has $((r_count - seen_r)) new review(s)
"
      fi
      # ci: event on any signature change.
      if [ -n "$ci_sig" ] && [ -n "$seen_ci" ] && [ "$seen_ci" != "$ci_sig" ]; then
        EVENTS="${EVENTS}CI: ${fullname}#${pr} checks changed
"
      fi
      # merge: event on open -> merged/closed transition.
      if [ -n "$p_state" ] && [ "$p_state" != "$seen_state" ]; then
        case "$p_state" in
          MERGED) [ "${seen_state:-OPEN}" = "OPEN" ] && EVENTS="${EVENTS}MERGED: ${fullname}#${pr}
" ;;
          CLOSED) [ "${seen_state:-OPEN}" = "OPEN" ] && EVENTS="${EVENTS}CLOSED: ${fullname}#${pr}
" ;;
        esac
      fi
    fi

    # Build the staged seen block: high-water for counts, current for ci/state.
    new_c=$seen_c; new_r=$seen_r
    if is_int "$c_count"; then
      if is_int "$seen_c"; then new_c=$((seen_c > c_count ? seen_c : c_count)); else new_c=$c_count; fi
    fi
    if is_int "$r_count"; then
      if is_int "$seen_r"; then new_r=$((seen_r > r_count ? seen_r : r_count)); else new_r=$r_count; fi
    fi
    is_int "$new_c"  && block=$(printf '%s\ncomments=%s' "$block" "$new_c")
    is_int "$new_r"  && block=$(printf '%s\nreviews=%s'  "$block" "$new_r")
    [ -n "$ci_sig" ] && block=$(printf '%s\nci=%s'       "$block" "$ci_sig")
    [ -n "$sha" ]    && block=$(printf '%s\nsha=%s'      "$block" "$sha")
    [ -n "$p_state" ] && block=$(printf '%s\nstate=%s'   "$block" "$p_state")
    printf '%s\n' "$block" > "$pending/$basename"
  done <<EOF
$prs
EOF

  # Merge/close detection for PRs that left the open set since last poll.
  detect_left_open "$pending" "$open_basenames"

  # --- LOSSLESSNESS BOUNDARY ---
  # All events are emitted FIRST. Seen markers are advanced ONLY afterward.
  if [ -n "$EVENTS" ]; then
    printf '%s' "$EVENTS"
  fi

  # Last action of the poll: advance seen markers.
  apply_pending "$pending"
  rm -rf "$pending"
}

# Detect PRs previously seen as OPEN that no longer appear in the open search.
# detect_left_open <pending-dir> <space-separated open basenames>
detect_left_open() {
  local pending=$1 open_basenames=$2 f base owner repo pr seen_state p_state
  [ -d "$SEEN_DIR" ] || return 0
  for f in "$SEEN_DIR"/*; do
    [ -e "$f" ] || continue
    base=${f##*/}
    case "$open_basenames" in *" $base "*) continue ;; esac
    # Only re-check PRs we last recorded as OPEN; merged/closed are settled.
    seen_state=$(seen_get "$f" state)
    [ -n "$(seen_get "$f" initialized)" ] || continue
    { [ -z "$seen_state" ] || [ "$seen_state" = "OPEN" ]; } || continue
    owner=$(seen_get "$f" owner)
    repo=$(seen_get "$f" repo)
    pr=$(seen_get "$f" pr)
    [ -n "$owner" ] && [ -n "$repo" ] && [ -n "$pr" ] || continue
    p_state=$(pr_state "$owner" "$repo" "$pr")
    case "$p_state" in
      MERGED) EVENTS="${EVENTS:-}MERGED: ${owner}/${repo}#${pr}
" ;;
      CLOSED) EVENTS="${EVENTS:-}CLOSED: ${owner}/${repo}#${pr}
" ;;
      *) continue ;;
    esac
    # Carry forward prior seen fields, updating only state.
    carry_seen_forward "$pending" "$base" "$f" "$p_state"
  done
}

# carry_seen_forward <pending-dir> <basename> <real-seen-file> <new-state>
# Reproduce the PR's current seen block with the state field replaced, into the
# pending dir, so a left-open PR's marker advances atomically with the rest.
carry_seen_forward() {
  local pending=$1 base=$2 real=$3 newstate=$4
  awk -F= -v s="$newstate" '$1!="state" { print } END { print "state=" s }' \
    "$real" > "$pending/$base"
}

# apply_pending <dir> — atomically move each staged seen file into place.
# A failed move (e.g. read-only state dir) is non-fatal: the seen marker simply
# stays at its prior value and the event re-fires next cycle (lossless).
apply_pending() {
  local dir=$1 f
  [ -d "$dir" ] || return 0
  for f in "$dir"/*; do
    [ -e "$f" ] || continue
    mv -f "$f" "$SEEN_DIR/${f##*/}" 2>/dev/null || true
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
    seen_count=$(find "$SEEN_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
  fi
  printf 'seen PRs: %s\n' "$seen_count"
}

usage() {
  sed -n '2,/^$/p' < "$0" | sed 's/^# \{0,1\}//'
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
