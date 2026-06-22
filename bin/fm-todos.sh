#!/usr/bin/env bash
# Parse data/backlog.md into machine-readable fleet work for the supervisor's
# harness-native todo/task list. Pure bash+awk: no network, no gh calls,
# deterministic for a given backlog.
#
# Default output is one tab-separated row per active item:
#   <state>\t<priority>\t<id>\t<one-line>
#   In flight -> state "in_progress", priority "high"
#   Queued    -> state "pending",    priority "medium" (blocked-by preserved)
#   Done      -> excluded
# With --json, emits a JSON array of objects with the same fields instead.
#
# The supervisor (firstmate) reads this output and translates each row into its
# harness's native todo tool (opencode: todowrite; claude: TodoWrite). This
# script never calls that tool itself - it is only the parser.
#
# Backlog line shape (see AGENTS.md section 10):
#   ## In flight / ## Queued / ## Done        section headers
#   - [ ] <id> - <one line> [blocked-by: ...]  open item (In flight / Queued)
#   - [x] <id> - ...                           done item (Done), excluded
# Blank lines and unrecognized lines are ignored.
#
# Usage: fm-todos.sh [--json]
# Override the parsed file with FM_BACKLOG=<path>.
set -eu

FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKLOG="${FM_BACKLOG:-$FM_ROOT/data/backlog.md}"

JSON=0
for a in "$@"; do
  case "$a" in
    --json) JSON=1 ;;
    --help|-h)
      cat <<EOF
usage: fm-todos.sh [--json]
Parse ${BACKLOG} into fleet todos (override with FM_BACKLOG=<path>).
Default: one TSV row per active item:
  <state>\t<priority>\t<id>\t<one-line>
In flight -> in_progress/high, Queued -> pending/medium, Done excluded.
--json emits a JSON array of objects with the same fields.
EOF
      exit 0
      ;;
    *)
      echo "error: unknown argument: $a" >&2
      exit 1
      ;;
  esac
done

if [ ! -f "$BACKLOG" ]; then
  # No backlog yet: nothing active. An empty TSV stream is the correct output;
  # in JSON mode emit a bare empty array.
  if [ "$JSON" -eq 1 ]; then
    printf '[]\n'
  fi
  exit 0
fi

if [ "$JSON" -eq 1 ]; then
  MODE=json
else
  MODE=tsv
fi

awk -v MODE="$MODE" '
  function esc(s,   r) {
    r = s
    gsub(/\\/, "\\\\", r)
    gsub(/"/, "\\\"", r)
    gsub(/\t/, "\\t", r)
    gsub(/\r/, "\\r", r)
    gsub(/\n/, "\\n", r)
    return r
  }
  BEGIN { section = ""; count = 0 }
  # Track the current section from its header. Whitespace-flexible, so a
  # reformatted header still resolves.
  /^##[[:space:]]/ {
    section = ""
    if ($0 ~ /In[[:space:]]+flight/) section = "in_flight"
    else if ($0 ~ /Queued/) section = "queued"
    else if ($0 ~ /Done/) section = "done"
    next
  }
  # Open list item: "- [ ] ...". Only active sections emit rows.
  /^[[:space:]]*-[[:space:]]\[[[:space:]]\][[:space:]]/ {
    if (section != "in_flight" && section != "queued") next
    rest = $0
    sub(/^[[:space:]]*-[[:space:]]\[[[:space:]]\][[:space:]]+/, "", rest)
    # Split on the first " - " separator: <id> " - " <one-line>.
    # ids may contain dashes, so only the first separator splits.
    sep = index(rest, " - ")
    if (sep == 0) next
    id = substr(rest, 1, sep - 1)
    desc = substr(rest, sep + 3)
    sub(/[[:space:]]+$/, "", desc)
    if (id == "") next
    if (section == "in_flight") {
      state = "in_progress"; priority = "high"
    } else {
      state = "pending"; priority = "medium"
    }
    if (MODE == "json") {
      printf "%s  {\"state\": \"%s\", \"priority\": \"%s\", \"id\": \"%s\", \"title\": \"%s\"}", \
        (count == 0 ? "[\n" : ",\n"), state, priority, esc(id), esc(desc)
      count++
    } else {
      printf "%s\t%s\t%s\t%s\n", state, priority, id, desc
    }
    next
  }
  END {
    if (MODE == "json") {
      if (count == 0) printf "[]\n"
      else printf "\n]\n"
    }
  }
' "$BACKLOG"
