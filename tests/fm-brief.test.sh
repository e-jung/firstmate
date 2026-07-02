#!/usr/bin/env bash
# Behavior tests for bin/fm-brief.sh.
#
# Regression coverage for the heredoc-in-command-substitution parse bug (issue
# #166): each ship-mode branch builds its Definition-of-done text with
# `VAR=$(cat <<EOF ... EOF)`. Bash's lexer tracks quote state through the
# heredoc body while it scans for the matching `)` of the command
# substitution, so a single unescaped apostrophe anywhere in that body breaks
# parsing of the *entire rest of the script* - `bash -n` fails, not just the
# generated brief. A plain `cat > file <<EOF ... EOF` (not wrapped in `$(...)`)
# is unaffected, so the secondmate charter block does not need this guard.
#
# Also covers the local-only DoD regression: no-mistakes (the binary that runs
# the pipeline) must get a build+install+verify clause because a branch commit
# is not observable until the rebuilt binary is installed; other local-only
# projects must not. Also covers the elevation sentence that makes
# task-specific acceptance criteria in the Task body part of the authoritative
# Definition of done.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-brief)

# The script itself must always parse. This is the direct regression test for
# issue #166: a stray apostrophe in any of the three DOD heredoc bodies
# (no-mistakes/direct-PR/local-only) breaks `bash -n` on the whole file.
test_script_parses() {
  bash -n "$ROOT/bin/fm-brief.sh" 2>&1 || fail "bin/fm-brief.sh fails bash -n (heredoc/quote regression)"
  pass "fm-brief.sh: bash -n succeeds"
}

# Registry with one project per delivery mode, so each ship-mode DOD branch is
# exercised. A project absent from the registry defaults to no-mistakes.
# no-mistakes itself is registered local-only so the build+install+verify
# clause path is exercised, alongside a plain local-only project and an
# explicit no-mistakes-mode project.
write_registry() {
  local home=$1
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- no-mistakes [local-only] - the gate tool (added 2026-07-01)
- otherproj [local-only] - a plain local project (added 2026-07-01)
- gatemate [no-mistakes] - a gated project (added 2026-07-01)
- direct-proj [direct-PR] - fixture for direct-PR mode (added 2026-07-01)
- local-proj [local-only] - fixture for local-only mode (added 2026-07-01)
EOF
}

# fm-brief.sh must exit 0 and produce a brief with no unreplaced shell
# metacharacter corruption for every ship delivery mode. This also guards
# against any *new* unescaped apostrophe or unbalanced quote later added to
# one of these DOD blocks, since a broken heredoc corrupts or empties the
# generated brief content, not just the script's own syntax.
test_ship_modes_generate_clean_briefs() {
  local home id proj brief status
  home="$TMP_ROOT/ship-home"
  write_registry "$home"

  for id_proj in "brief-nomistakes-a1:no-registry-proj" "brief-directpr-a2:direct-proj" "brief-localonly-a3:local-proj"; do
    id=${id_proj%%:*}
    proj=${id_proj##*:}
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" "$proj" >/dev/null 2>&1; status=$?
    expect_code 0 "$status" "fm-brief.sh $id $proj should exit 0"
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$id: brief was not scaffolded"
    assert_grep "# Definition of done" "$brief" "$id: brief missing Definition of done section"
    assert_grep "{TASK}" "$brief" "$id: brief missing the {TASK} placeholder"
    assert_no_grep "EOF" "$brief" "$id: brief leaked a heredoc EOF marker (unterminated heredoc)"
  done
  pass "fm-brief.sh: no-mistakes/direct-PR/local-only briefs generate cleanly"
}

# Pin the specific line the bug lived on: the no-mistakes DOD's no-mistakes
# reference must render as plain prose with no dangling apostrophe artifact.
test_no_mistakes_dod_wording() {
  local home id brief
  home="$TMP_ROOT/wording-home"
  mkdir -p "$home/data"
  id="brief-wording-b1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "no-mistakes itself provides for the mechanics" "$brief" \
    "no-mistakes DOD lost its guidance-reference sentence"
  assert_no_grep "no-mistakes' own guidance" "$brief" \
    "no-mistakes DOD regressed to the apostrophe form that breaks bash -n"
  pass "fm-brief.sh: no-mistakes DOD wording avoids the apostrophe regression"
}

# The local-only DoD must add a build+install+verify clause for no-mistakes
# (the binary that runs the pipeline) because a branch commit is otherwise
# unobservable until the rebuilt binary is installed and verified end-to-end.
# Other local-only projects must NOT get it, and non-local-only modes must NOT
# get it either.
test_local_only_dod_build_clause() {
  local home
  home="$TMP_ROOT/dod-home"
  write_registry "$home"

  # Case 1: no-mistakes local-only gets the build+install+verify clause.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" dod-nm no-mistakes >/dev/null 2>&1
  local b_nm="$home/data/dod-nm/brief.md"
  assert_grep "If this task modifies no-mistakes source code" "$b_nm" \
    "no-mistakes local-only brief missing build+install clause"
  assert_grep "make build" "$b_nm" "no-mistakes local-only brief missing build step"
  assert_grep "no-mistakes daemon stop && no-mistakes daemon start" "$b_nm" \
    "no-mistakes local-only brief missing daemon restart"
  assert_grep "verify the fix end-to-end" "$b_nm" "no-mistakes local-only brief missing end-to-end verify"

  # Case 2: a plain local-only project must NOT get the binary clause.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" dod-other otherproj >/dev/null 2>&1
  local b_other="$home/data/dod-other/brief.md"
  ! grep -E "make build|\.no-mistakes/bin" "$b_other" >/dev/null || \
    fail "plain local-only brief must not get the no-mistakes build clause"

  # Case 3: no-mistakes (default) mode must NOT get the local-only binary clause.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" dod-gate gatemate >/dev/null 2>&1
  local b_gate="$home/data/dod-gate/brief.md"
  ! grep -E "make build|\.no-mistakes/bin/no-mistakes" "$b_gate" >/dev/null || \
    fail "no-mistakes-mode brief must not get the local-only build clause"

  pass "fm-brief.sh: local-only DoD build clause gated to the no-mistakes repo"
}

# The elevation sentence must be present in every ship mode, making the
# Task-body acceptance criteria part of the authoritative Definition of done.
test_dod_elevates_task_body_criteria() {
  local home id
  home="$TMP_ROOT/elev-home"
  write_registry "$home"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" elev-nm no-mistakes >/dev/null 2>&1
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" elev-other otherproj >/dev/null 2>&1
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" elev-gate gatemate >/dev/null 2>&1
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" elev-direct direct-proj >/dev/null 2>&1
  for id in elev-nm elev-other elev-gate elev-direct; do
    assert_grep "part of this Definition of done" "$home/data/$id/brief.md" \
      "$id brief missing the DoD elevation sentence"
  done
  pass "fm-brief.sh: all ship-mode briefs elevate task-body criteria into the DoD"
}

# fm-brief.sh must refuse to clobber an existing brief.
test_refuses_to_overwrite() {
  local home id rc
  home="$TMP_ROOT/overwrite-home"
  write_registry "$home"
  id="brief-overwrite-c1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" no-mistakes >/dev/null 2>&1
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" no-mistakes >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "fm-brief.sh must refuse to overwrite an existing brief"
  pass "fm-brief.sh: refuses to overwrite an existing brief"
}

test_script_parses
test_ship_modes_generate_clean_briefs
test_no_mistakes_dod_wording
test_local_only_dod_build_clause
test_dod_elevates_task_body_criteria
test_refuses_to_overwrite
