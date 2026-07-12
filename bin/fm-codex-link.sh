#!/usr/bin/env bash
# fm-codex-link.sh - print safe Codex app deep links for firstmate task context.
#
# The Codex app supports codex://new?path=<absolute-dir>&prompt=<text>.
# This helper never opens links or mutates state; it resolves known task/report
# paths and prints both the deep link and the raw local path so the captain has
# a fallback if the app is not registered on the current device.
#
# Usage:
#   fm-codex-link.sh task <task-id>
#   fm-codex-link.sh report <task-id-or-report-path>
#   fm-codex-link.sh project <absolute-project-dir> [prompt]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

usage() {
  sed -n '2,12p' "$0" >&2
  exit 2
}

meta_value() {  # <meta-file> <key>
  local meta=$1 key=$2
  [ -f "$meta" ] || return 0
  grep "^$key=" "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

urlencode() {
  local LC_ALL=C s=${1:-} i c hex out=
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) printf -v hex '%02X' "'$c"; out+="%$hex" ;;
    esac
  done
  printf '%s' "$out"
}

abs_dir() {
  local path=$1
  [ -d "$path" ] || { echo "error: not a directory: $path" >&2; return 1; }
  cd "$path" && pwd -P
}

link_for_dir() {
  local label=$1 dir=$2 prompt=${3:-} abs qpath qprompt
  abs=$(abs_dir "$dir") || return 1
  qpath=$(urlencode "$abs")
  qprompt=$(urlencode "$prompt")
  printf '%s path: %s\n' "$label" "$abs"
  if [ -n "$prompt" ]; then
    printf '%s codex: codex://new?path=%s&prompt=%s\n' "$label" "$qpath" "$qprompt"
  else
    printf '%s codex: codex://new?path=%s\n' "$label" "$qpath"
  fi
}

report_path_for() {
  local arg=$1
  if [ -f "$arg" ]; then
    printf '%s' "$arg"
    return 0
  fi
  if [ -f "$DATA/$arg/report.md" ]; then
    printf '%s' "$DATA/$arg/report.md"
    return 0
  fi
  echo "error: no report found for $arg (expected file or $DATA/$arg/report.md)" >&2
  return 1
}

task_links() {
  local id=$1 meta wt project report
  meta="$STATE/$id.meta"
  [ -f "$meta" ] || { echo "error: no metadata for task $id in $STATE" >&2; return 1; }
  wt=$(meta_value "$meta" worktree)
  project=$(meta_value "$meta" project)
  report="$DATA/$id/report.md"
  printf 'task: %s\n' "$id"
  if [ -n "$wt" ] && [ -d "$wt" ]; then
    link_for_dir "worktree" "$wt" "Review firstmate task $id in this worktree. Summarize status, diff, blockers, and next steps."
  elif [ -n "$project" ] && [ -d "$project" ]; then
    link_for_dir "project" "$project" "Review firstmate task $id for this project. Summarize status, blockers, and next steps."
  else
    printf 'worktree path: %s\n' "${wt:--}"
    printf 'worktree codex: -\n'
  fi
  if [ -f "$report" ]; then
    link_for_dir "report" "$(dirname "$report")" "Review report $report for firstmate task $id. Summarize the conclusion and recommended next action."
  else
    printf 'report path: -\n'
    printf 'report codex: -\n'
  fi
}

[ "$#" -ge 1 ] || usage

case "$1" in
  task)
    [ "$#" -eq 2 ] || usage
    task_links "$2"
    ;;
  report)
    [ "$#" -eq 2 ] || usage
    report=$(report_path_for "$2") || exit 1
    link_for_dir "report" "$(dirname "$report")" "Review report $report. Summarize the conclusion and recommended next action."
    ;;
  project)
    if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
      usage
    fi
    link_for_dir "project" "$2" "${3:-}"
    ;;
  *)
    if [ "$#" -eq 1 ]; then
      task_links "$1"
    else
      usage
    fi
    ;;
esac
