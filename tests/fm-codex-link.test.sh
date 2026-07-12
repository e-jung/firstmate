#!/usr/bin/env bash
# Behavior tests for bin/fm-codex-link.sh.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CODEX_LINK="$ROOT/bin/fm-codex-link.sh"
TMP_ROOT=$(fm_test_tmproot fm-codex-link)

new_home() {
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/state" "$d/data" "$d/projects"
  printf '%s\n' "$d"
}

canonical_dir() {  # <dir>
  cd "$1" && pwd -P
}

encoded_path() {  # <path>
  local LC_ALL=C s=$1 i c hex out=
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) printf -v hex '%02X' "'$c"; out+="%$hex" ;;
    esac
  done
  printf '%s' "$out"
}

run_link() {
  local home=$1
  shift
  FM_HOME="$home" "$CODEX_LINK" "$@"
}

home=$(new_home main)
mkdir -p "$home/projects/with space" "$home/projects/project only" "$home/data/link-task"
printf '# Link report\n' > "$home/data/link-task/report.md"
fm_write_meta "$home/state/link-task.meta" \
  "window=firstmate:fm-link-task" \
  "worktree=$home/projects/with space" \
  "project=$home/projects/project only" \
  "harness=codex" \
  "kind=ship" \
  "mode=direct-PR" \
  "yolo=off"

worktree_abs=$(canonical_dir "$home/projects/with space")
report_abs=$(canonical_dir "$home/data/link-task")
worktree_encoded=$(encoded_path "$worktree_abs")
report_encoded=$(encoded_path "$report_abs")

links=$(run_link "$home" task link-task)
assert_contains "$links" "task: link-task" "task link prints task id"
assert_contains "$links" "worktree path: $worktree_abs" "task link prints canonical worktree path"
assert_contains "$links" "worktree codex: codex://new?path=$worktree_encoded&prompt=" "task link prints encoded worktree deep link"
assert_contains "$links" "with%20space" "task link URL-encodes spaces"
assert_contains "$links" "report path: $report_abs" "task link prints report directory"
assert_contains "$links" "report codex: codex://new?path=$report_encoded&prompt=Review%20report%20" "task link prints encoded report deep link"
pass "task links include worktree and report deep links"

short_links=$(run_link "$home" link-task)
assert_contains "$short_links" "task: link-task" "positional shorthand resolves task id"
assert_contains "$short_links" "worktree path: $worktree_abs" "positional shorthand prints worktree path"
pass "task id shorthand works"

report_by_id=$(run_link "$home" report link-task)
assert_contains "$report_by_id" "report path: $report_abs" "report link resolves task id"
assert_contains "$report_by_id" "Summarize%20the%20conclusion" "report link includes review prompt"
pass "report links resolve task ids"

report_by_file=$(run_link "$home" report "$home/data/link-task/report.md")
assert_contains "$report_by_file" "report path: $report_abs" "report link accepts a file path"
pass "report links accept explicit report files"

project_abs=$(canonical_dir "$home/projects/project only")
project_encoded=$(encoded_path "$project_abs")
project_link=$(run_link "$home" project "$home/projects/project only" "Inspect this repo")
assert_contains "$project_link" "project path: $project_abs" "project link prints canonical project path"
assert_contains "$project_link" "project codex: codex://new?path=$project_encoded&prompt=Inspect%20this%20repo" "project link includes encoded prompt"
pass "project links include optional prompts"

mkdir -p "$home/projects/fallback only"
fallback_abs=$(canonical_dir "$home/projects/fallback only")
fm_write_meta "$home/state/project-only.meta" \
  "window=firstmate:fm-project-only" \
  "project=$home/projects/fallback only" \
  "harness=codex" \
  "kind=ship" \
  "mode=direct-PR" \
  "yolo=off"
fallback=$(run_link "$home" task project-only)
assert_contains "$fallback" "project path: $fallback_abs" "task link falls back to project path when worktree is absent"
assert_contains "$fallback" "report codex: -" "task link reports absent report clearly"
pass "task links fall back to project path"

set +e
missing_task=$(run_link "$home" task missing 2>&1)
missing_task_rc=$?
missing_report=$(run_link "$home" report missing 2>&1)
missing_report_rc=$?
missing_dir=$(run_link "$home" project "$home/projects/nope" 2>&1)
missing_dir_rc=$?
usage_out=$(run_link "$home" 2>&1)
usage_rc=$?
set -e

expect_code 1 "$missing_task_rc" "missing task exits non-zero"
assert_contains "$missing_task" "no metadata for task missing" "missing task reports clear error"
expect_code 1 "$missing_report_rc" "missing report exits non-zero"
assert_contains "$missing_report" "no report found for missing" "missing report reports clear error"
expect_code 1 "$missing_dir_rc" "missing project dir exits non-zero"
assert_contains "$missing_dir" "not a directory" "missing project dir reports clear error"
expect_code 2 "$usage_rc" "no-args usage exits 2"
assert_contains "$usage_out" "fm-codex-link.sh task <task-id>" "usage prints task form"
assert_not_contains "$usage_out" "set -u" "usage does not leak live code"
pass "error and usage paths are stable"
