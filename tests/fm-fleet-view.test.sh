#!/usr/bin/env bash
# Behavior tests for Codex GUI-friendly fleet visibility helpers.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FLEET_VIEW="$ROOT/bin/fm-fleet-view.sh"
CODEX_LINK="$ROOT/bin/fm-codex-link.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-view)
fm_git_identity fmtest fmtest@example.invalid

make_fakebin() {
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'idle\n> \n' ;;
esac
exit 0
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux"
  printf '%s\n' "$fb"
}

new_home() {
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/state" "$d/data" "$d/projects"
  printf '%s\n' "$d"
}

make_repo() {
  local dir=$1
  fm_git_init_commit "$dir"
}

run_view() {
  local home=$1
  PATH="$home/fakebin:$PATH" FM_HOME="$home" "$FLEET_VIEW"
}

run_link() {
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" "$CODEX_LINK" "$@"
}

# --- fleet table ------------------------------------------------------------

home=$(new_home table)
make_fakebin "$home" >/dev/null
make_repo "$home/projects/alpha"
make_repo "$home/projects/bravo"
mkdir -p "$home/data/bravo-scout"

fm_write_meta "$home/state/alpha-ship.meta" \
  "window=firstmate:fm-alpha-ship" \
  "worktree=$home/projects/alpha" \
  "project=$home/projects/alpha" \
  "harness=codex" \
  "kind=ship" \
  "mode=direct-PR" \
  "yolo=off" \
  "pr=https://github.com/acme/alpha/pull/12"
printf '%s\n' "needs-decision: approve API shape" > "$home/state/alpha-ship.status"

fm_write_meta "$home/state/bravo-scout.meta" \
  "window=firstmate:fm-bravo-scout" \
  "worktree=$home/projects/bravo" \
  "project=$home/projects/bravo" \
  "harness=codex" \
  "kind=scout" \
  "mode=scout" \
  "yolo=off"
printf '%s\n' "done: report ready" > "$home/state/bravo-scout.status"
printf '%s\n' "# Report" > "$home/data/bravo-scout/report.md"
cat > "$home/data/backlog.md" <<'EOF'
## In flight

- [ ] alpha-ship implement alpha
- [ ] orphan-task recover missing task

## Queued

- [ ] queued-task wait
EOF

out=$(run_view "$home")
assert_contains "$out" "ID | REPO | KIND | BACKEND | STATUS | PR/REPORT | PATH | WATCH / STEER" "fleet view prints stable header"
assert_contains "$out" "alpha-ship | alpha | ship | tmux | state: parked" "fleet view includes ship current state"
assert_contains "$out" "PR https://github.com/acme/alpha/pull/12" "fleet view includes PR pointer from meta"
assert_contains "$out" "$home/projects/alpha" "fleet view includes worktree path"
assert_contains "$out" "watch: bin/fm-peek.sh fm-alpha-ship" "fleet view includes watch command"
assert_contains "$out" "steer: bin/fm-send.sh fm-alpha-ship '<message>'" "fleet view includes steer command"
assert_contains "$out" "links: bin/fm-codex-link.sh task alpha-ship" "fleet view points to codex link helper"
assert_contains "$out" "bravo-scout | bravo | scout | tmux" "fleet view includes scout row"
assert_contains "$out" "report $home/data/bravo-scout/report.md" "fleet view includes report pointer"
assert_contains "$out" "orphan-task | - | backlog | - | state: unknown (backlog in-flight, no metadata); recover missing task" "fleet view surfaces in-flight backlog rows without metadata"
assert_not_contains "$out" "queued-task" "fleet view does not show queued backlog rows"
pass "fleet view prints compact task table with status, artifact, paths, and actions"

empty_home=$(new_home empty)
make_fakebin "$empty_home" >/dev/null
empty_out=$(run_view "$empty_home")
assert_contains "$empty_out" "no in-flight tasks" "fleet view handles empty fleet"
pass "fleet view handles empty state"

# --- Codex deep links -------------------------------------------------------

link_home=$(new_home links)
make_fakebin "$link_home" >/dev/null
make_repo "$link_home/projects/with space"
mkdir -p "$link_home/data/link-task"
printf '%s\n' "# Link report" > "$link_home/data/link-task/report.md"
fm_write_meta "$link_home/state/link-task.meta" \
  "window=firstmate:fm-link-task" \
  "worktree=$link_home/projects/with space" \
  "project=$link_home/projects/with space" \
  "harness=codex" \
  "kind=ship" \
  "mode=direct-PR" \
  "yolo=off"

links=$(run_link "$link_home" task link-task)
assert_contains "$links" "task: link-task" "codex link prints task id"
assert_contains "$links" "worktree path: $link_home/projects/with space" "codex link prints raw worktree path"
assert_contains "$links" "codex://new?path=" "codex link prints new-thread deeplink"
assert_contains "$links" "with%20space" "codex link URL-encodes spaces"
assert_contains "$links" "report path: $link_home/data/link-task" "codex link prints report directory"
assert_contains "$links" "Review%20report%20" "codex link URL-encodes report prompt"
pass "codex link prints task worktree and report deep links"

project_link=$(run_link "$link_home" project "$link_home/projects/with space" "Inspect this repo")
assert_contains "$project_link" "project path: $link_home/projects/with space" "project link prints raw path"
assert_contains "$project_link" "prompt=Inspect%20this%20repo" "project link includes encoded prompt"
pass "codex link prints project deep link"

set +e
missing=$(run_link "$link_home" task missing 2>&1)
rc=$?
set -e
expect_code 1 "$rc" "missing task link exits non-zero"
assert_contains "$missing" "no metadata for task missing" "missing task reports clear error"
pass "codex link rejects unknown task ids"
