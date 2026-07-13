#!/usr/bin/env bash
# fm-github-watch.sh - surface new review comments, changes-requested reviews,
# and failed CI checks on the PRs Firstmate is supervising.
#
# Discovery is authoritative, not contributor-based: it reads the home's
# state/<id>.meta files for pr=<url> lines, so it watches exactly the open PRs
# Firstmate is managing right now and nothing else. It does NOT duplicate merge
# monitoring - the per-task state/<id>.check.sh that bin/fm-pr-check.sh writes
# still owns the merged-PR signal. This watcher owns the three signals that
# check never covered: new comments, a changes-requested review decision, and a
# newly failed check.
#
# Built to run as the body of a watcher check shim (state/github-events.check.sh,
# written idempotently by fm-bootstrap.sh's github_watch_setup). The watcher
# contract (bin/fm-watch.sh's *.check.sh sweep) is: stdout is captured and
# becomes a `check:` wake that escalates to firstmate; silence means keep
# sleeping. So this script prints one concise line per captain-actionable event
# and prints nothing when nothing changed. It must finish within the watcher's
# CHECK_TIMEOUT (default 30s); with a handful of supervised PRs and ~5 serial
# gh calls each it stays well under budget, and events are emitted per-PR BEFORE
# that PR's seen cursor advances (see LOSSLESSNESS below), so even a timeout
# mid-poll surfaces the progress already made rather than swallowing it.
#
# GitHub access: the task asks for gh-axi, but gh-axi's `api` subcommand
# re-encodes JSON into a display format (TOON) and drops `--jq`, so it cannot
# serve the structured count/conclusion queries this watcher needs. The script
# therefore uses `gh api ... --jq` - the same authenticated `gh` that gh-axi
# wraps internally - and degrades safely on any gh/auth/network failure.
#
# Degrade-safely contract: a failing gh call for a field yields empty data for
# that field, and an empty fetch is carried forward from the prior seen block
# rather than treated as a new zero. So a transient outage never corrupts the
# last-seen cursor and never marks an unseen event as handled; the worst case is
# a redundant re-detect next cycle once the outage clears.
#
# Usage:
#   fm-github-watch.sh            # one poll cycle (the check-shim default)
#   fm-github-watch.sh --once     # one poll cycle (explicit)
#   fm-github-watch.sh --help|-h  # print this header
#
# Env:
#   FM_STATE_OVERRIDE  state dir (defaults to $FM_HOME/state, then repo state)
#   FM_GH_SELF         override the "self" login whose own comments/reviews are
#                      excluded (default: the authenticated gh user, once/poll)
#
# Seen state: state/.github-watch-seen/<owner>-<repo>-<num> (key=value lines):
#   comments=<high-water count of non-self issue + review comments>
#   changes_requested=<current count of non-self CHANGES_REQUESTED reviews>
#   ci=<sorted 'name:conclusion' signature of completed check-runs>
# comments is high-water because comments only accumulate; changes_requested is
# current count because reviews are dismissable, so a dismiss->re-request where
# the count drops then rises must fire again.
# A seen file whose PR is no longer in any state/*.meta pr= line is pruned.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME_DIR="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME_DIR/state}"
SEEN_DIR="$STATE/.github-watch-seen"
# GitHub check conclusions counted as failures. `skipped` and `neutral` are not
# failures; `cancelled`/`timed_out`/`action_required` are, because a cancelled
# required check still blocks merge and needs the captain's attention.
CI_FAILURE_CONCLUSIONS='^(failure|startup_failure|timed_out|cancelled|action_required)$'

mkdir -p "$STATE" 2>/dev/null || true

# ---- helpers ----

is_int() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# Run gh api with a jq filter, swallowing stderr and non-zero exits so a missing
# gh, a transient API error, or an auth failure never kills the poll: the field
# is simply empty for this cycle and carried forward from seen state. Prints the
# jq result on stdout (empty on any failure).
ghc() { command gh api "$@" 2>/dev/null || true; }

# Parse a pr=<url> value into "owner<TAB>repo<TAB>num" on stdout, or empty if
# the URL is not a parseable github.com pull URL. Tolerates a trailing slash or
# a /files suffix by taking only the leading digits of the number segment.
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

# seen_get <file> <key> -> value (empty if missing)
seen_get() {
  local f=$1 key=$2
  [ -f "$f" ] || return 0
  awk -F= -v k="$key" '$1==k { sub(/^[^=]*=/, ""); print; exit }' "$f"
}

seen_file() { printf '%s/%s-%s-%s\n' "$SEEN_DIR" "$1" "$2" "$3"; }

# atomic_write <file> <content>: temp + rename so a crash or read-only state dir
# never leaves a partial seen file; on any failure the prior file is untouched so
# the event re-fires next cycle (lossless). The temp lives in the seen dir (same
# filesystem, atomic rename) under a hidden prefix the prune glob excludes.
atomic_write() {
  local file=$1 content=$2 tmp
  mkdir -p "$SEEN_DIR" 2>/dev/null || true
  tmp="$SEEN_DIR/.tmp.$(basename "$file").$$"
  if printf '%s\n' "$content" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$file" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  else
    rm -f "$tmp" 2>/dev/null
  fi
}

# Discover supervised PRs from state/*.meta pr= lines. Prints unique
# "owner<TAB>repo<TAB>num<TAB>url" lines. Empty when no PRs are in flight (and
# then the poll makes zero gh calls, so a home with no supervised PRs is free).
discover_supervised_prs() {
  local meta url rec key seen=""
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    # A meta may carry several pr= lines over its life (a task re-pointed at a
    # new PR after a force-push/reopen); the last one is current.
    url=$(grep '^pr=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    [ -n "$url" ] || continue
    rec=$(parse_pr_url "$url")
    [ -n "$rec" ] || continue
    key=$rec
    # Anchor the dedup match on the trailing newline so a shorter PR number
    # (e.g. #4) cannot be shadowed by a longer one already seen (#42): the
    # stored form is "key\n", so "key\n" only matches a full entry, never a
    # prefix of one.
    case "$seen" in
      *"$key"$'\n'*) continue ;;
    esac
    seen="$seen$key"$'\n'
    printf '%s\t%s\n' "$rec" "$url"
  done
}

# ---- per-PR probes (each fails open: empty output, no crash) ----

# self_login: the authenticated user whose own comments/reviews are excluded.
# Resolved once per poll and exported for the ghc probes via env. A failure to
# resolve yields an empty SELF (nothing excluded), which is safe: it only means
# the contributor's own comments would count, never a swallow.
resolve_self() {
  if [ -n "${FM_GH_SELF:-}" ]; then printf '%s' "$FM_GH_SELF"; return; fi
  command gh api user --jq .login 2>/dev/null | tr -d '\n' || true
}

# pr_head_and_state <owner> <repo> <num> -> "sha<TAB>STATE" (empty on failure)
pr_head_and_state() {
  ghc "repos/$1/$2/pulls/$3" --jq '[.head.sha, .state] | @tsv' | tr -d '\n'
}

# count issue comments excluding self (top-level PR conversation).
count_issue_comments() {
  SELF="$SELF_LOGIN" ghc "repos/$1/$2/issues/$3/comments?per_page=100" \
    --jq '[.[] | select(.user.login != env.SELF)] | length'
}

# count inline review comments excluding self.
count_review_comments() {
  SELF="$SELF_LOGIN" ghc "repos/$1/$2/pulls/$3/comments?per_page=100" \
    --jq '[.[] | select(.user.login != env.SELF)] | length'
}

# count changes-requested reviews excluding self (current count: reviews are
# dismissable, so the cursor tracks the live count and a rise re-fires).
count_changes_requested() {
  SELF="$SELF_LOGIN" ghc "repos/$1/$2/pulls/$3/reviews?per_page=100" \
    --jq '[.[] | select(.user.login != env.SELF) | select(.state == "CHANGES_REQUESTED")] | length'
}

# ci_signature <owner> <repo> <sha>: sorted, single-line "name:conclusion"
# list of completed check-runs, joined with ';' so it survives the line-oriented
# seen file without breaking seen_get. Empty when sha is empty or the call fails
# (carried forward from seen so the cursor survives an outage).
ci_signature() {
  [ -n "$3" ] || return 0
  ghc "repos/$1/$2/commits/$3/check-runs?per_page=100" \
    --jq '[.check_runs[] | select(.conclusion != null) | (.name + ":" + .conclusion)] | sort | join(";")'
}

# failing_checks <ci-signature>: names whose conclusion is a failure, one per
# line (deduped by sort at the signature step). Splits on the ';' delimiter.
failing_checks() {
  local sig=$1 rest entry name concl
  rest=$sig
  while [ -n "$rest" ]; do
    entry=${rest%%;*}
    if [ "$entry" = "$rest" ]; then rest=""; else rest=${rest#*;}; fi
    [ -n "$entry" ] || continue
    name=${entry%:*}
    concl=${entry##*:}
    if printf '%s' "$concl" | grep -qE "$CI_FAILURE_CONCLUSIONS"; then
      printf '%s\n' "$name"
    fi
  done
}

# has_failure <ci-signature> -> 0 if any completed conclusion is a failure.
has_failure() {
  failing_checks "$1" | grep -q . && return 0 || return 1
}

# ---- the per-PR poll ----

# build_seen <prior-file> <owner> <repo> <num> <c_count> <cr_count> <ci_sig>
# Compose the seen block, carrying forward any field whose fresh fetch was empty
# (a transient failure or an in-flight check set), so the cursor is never
# corrupted by an outage and a later change still fires from the right baseline.
build_seen() {
  local sf=$1 owner=$2 repo=$3 num=$4 c_count=$5 cr_count=$6 ci_sig=$7
  local seen_c seen_cr seen_ci new_c new_cr ci_val block
  seen_c=$(seen_get "$sf" comments)
  seen_cr=$(seen_get "$sf" changes_requested)
  seen_ci=$(seen_get "$sf" ci)
  new_c=$seen_c; new_cr=$seen_cr
  if is_int "$c_count"; then
    if is_int "$seen_c"; then new_c=$((seen_c > c_count ? seen_c : c_count)); else new_c=$c_count; fi
  fi
  if is_int "$cr_count"; then
    new_cr=$cr_count
  fi
  ci_val=$ci_sig
  [ -n "$ci_val" ] || ci_val=$seen_ci
  block=$(printf 'owner=%s\nrepo=%s\npr=%s' "$owner" "$repo" "$num")
  is_int "$new_c"  && block=$(printf '%s\ncomments=%s' "$block" "$new_c")
  is_int "$new_cr" && block=$(printf '%s\nchanges_requested=%s' "$block" "$new_cr")
  [ -n "$ci_val" ] && block=$(printf '%s\nci=%s' "$block" "$ci_val")
  printf '%s' "$block"
}

# process_pr <owner> <repo> <num>: gather fresh data, EMIT any new events, then
# advance seen. Per-PR ordering (print before seen) plus bash's immediate
# write() to the capture pipe make this lossless even if the poll is killed
# mid-cycle: an emitted event is already in the pipe, and a PR whose cursor
# never advanced simply re-fires next cycle.
process_pr() {
  local owner=$1 repo=$2 num=$3
  local sf info sha state c_count cr_count ci_sig ev=""
  sf=$(seen_file "$owner" "$repo" "$num")

  info=$(pr_head_and_state "$owner" "$repo" "$num")
  sha=${info%%$'\t'*}
  state=${info#*$'\t'}
  # Only watch open PRs. A merged/closed PR is the merge monitor's job; skip it
  # so a briefly-not-yet-torn-down meta does not waste the comment/review/CI
  # calls. state empty = the fetch failed: carry everything forward silently.
  # The REST pulls endpoint returns lowercase "open"/"closed" (unlike GraphQL's
  # uppercase state enum), so compare against the REST casing.
  if [ -n "$state" ] && [ "$state" != "open" ]; then
    return 0
  fi

  # comments = issue-level + inline review comments (excluding self). Only form a
  # combined count when BOTH fetches succeeded; if either fails the cursor is
  # carried forward unchanged (degrade-safely) rather than freezing the missing
  # half as zero.
  local ic rc
  ic=$(count_issue_comments "$owner" "$repo" "$num")
  rc=$(count_review_comments "$owner" "$repo" "$num")
  if is_int "$ic" && is_int "$rc"; then
    c_count=$(( ic + rc ))
  fi
  cr_count=$(count_changes_requested "$owner" "$repo" "$num")
  ci_sig=$(ci_signature "$owner" "$repo" "$sha")

  local seen_c seen_cr seen_ci
  seen_c=$(seen_get "$sf" comments)
  seen_cr=$(seen_get "$sf" changes_requested)
  seen_ci=$(seen_get "$sf" ci)

  # comments (high-water): event on increase only.
  if is_int "$c_count" && is_int "$seen_c" && [ "$c_count" -gt "$seen_c" ]; then
    ev=$(printf '%sCOMMENT: %s/%s#%s has %d new comment(s)\n' \
      "$ev" "$owner" "$repo" "$num" "$((c_count - seen_c))")
  fi
  # changes-requested (current count): event on increase only; a dismiss drops
  # the cursor silently so a later re-request fires again.
  if is_int "$cr_count" && is_int "$seen_cr" && [ "$cr_count" -gt "$seen_cr" ]; then
    ev=$(printf '%sCHANGES_REQUESTED: %s/%s#%s\n' "$ev" "$owner" "$repo" "$num")
  fi
  # ci: event when the completed-check signature changed AND a failure is
  # present now. A change to all-passing updates the cursor silently so a later
  # re-failure still fires once; an unchanged failing signature stays silent so
  # the same broken CI does not wake every cycle.
  if [ -n "$ci_sig" ] && [ -n "$seen_ci" ] && [ "$seen_ci" != "$ci_sig" ] && has_failure "$ci_sig"; then
    local fails
    fails=$(failing_checks "$ci_sig" | paste -sd ',' -)
    ev=$(printf '%sCI: %s/%s#%s check(s) failed: %s\n' "$ev" "$owner" "$repo" "$num" "$fails")
  fi

  # --- LOSSLESSNESS BOUNDARY (per-PR) ---
  [ -n "$ev" ] && printf '%s' "$ev"
  atomic_write "$sf" "$(build_seen "$sf" "$owner" "$repo" "$num" "$c_count" "$cr_count" "$ci_sig")"
}

# ---- one poll cycle ----

poll_once() {
  local owner repo num url supervised_basenames="" discovered
  discovered=$(discover_supervised_prs)
  # Zero supervised PRs = zero gh calls: a home with no PRs in flight is free,
  # and discovery is a pure local read so it costs nothing to check.
  [ -n "$discovered" ] || return 0
  SELF_LOGIN=$(resolve_self)

  while IFS=$(printf '\t') read -r owner repo num url; do
    [ -n "${owner:-}" ] || continue
    process_pr "$owner" "$repo" "$num"
    supervised_basenames="$supervised_basenames$(basename "$(seen_file "$owner" "$repo" "$num")")"$'\n'
  done <<EOF
$discovered
EOF

  prune_stale_seen "$supervised_basenames"
}

# Remove seen files whose PR is no longer supervised (its task was torn down).
# Keeps the seen dir tidy and bounded; harmless if it runs after every poll.
# A seen file listed in the still-supervised set is never touched.
prune_stale_seen() {
  local supervised=$1 f base
  [ -d "$SEEN_DIR" ] || return 0
  for f in "$SEEN_DIR"/*; do
    [ -e "$f" ] || continue
    base=${f##*/}
    case "$base" in .tmp.*) continue ;; esac
    # Newline-anchored match (see discover_supervised_prs): a shorter basename
    # must not be kept because a longer one (acme-widgets-42 vs -4) contains it.
    case "$supervised" in
      *"$base"$'\n'*) ;;
      *) rm -f "$f" 2>/dev/null || true ;;
    esac
  done
}

usage() {
  awk 'NR==1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  --once|"") poll_once ;;
  *)
    echo "error: unknown command '${1:-}' (use --once or --help)" >&2
    exit 2
    ;;
esac
