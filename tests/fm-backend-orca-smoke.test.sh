#!/usr/bin/env bash
# tests/fm-backend-orca-smoke.test.sh - real Orca smoke test for the Orca
# session-provider adapter (bin/backends/orca.sh). Mirrors the real-backend
# smoke-test pattern of tests/fm-backend-cmux-smoke.test.sh (the closest
# analog): every other Orca suite (tests/fm-backend-orca.test.sh) fakes the CLI,
# this one talks to the REAL Orca runtime - but, like cmux, there is no isolated
# throwaway runtime to spin up. Orca is one shared instance (the desktop app on
# macOS, or `orca serve` headless on Linux - the adapter has no macOS-specific
# code and the runtime is verified on both), so this test creates ONLY
# `fm-test-smoke-`-prefixed disposable repo/worktree/terminal artifacts, touches
# and closes ONLY what it created, never enumerates-and-closes unrelated Orca
# state, and never quits or relaunches the runtime. Cleanup is trapped on EXIT.
#
# Skips cleanly when the `orca` CLI or `node` (the adapter's JSON parser) is not
# on PATH, or when the runtime is not reachable+ready, so CI/dev machines without
# Orca are completely unaffected. Design and empirical evidence live in
# data/fm-orca-linux-tests-c8/report.md.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

# orca_term_is_live: print yes|no for whether <handle> is in the live-terminal
# registry (`orca terminal list`). Read-only membership check, scoped to the one
# handle this test created - it never acts on any other terminal (the same
# cmux-smoke discipline of "never enumerates-and-closes").
orca_term_is_live() {  # <handle> -> yes|no
  orca terminal list --json 2>/dev/null | node -e '
    const fs = require("fs");
    const handle = process.argv[1];
    let data;
    try {
      data = JSON.parse(fs.readFileSync(0, "utf8"));
    } catch (e) {
      process.stdout.write("no");
      process.exit(0);
    }
    const r = data.result || {};
    const terms = r.terminals || (Array.isArray(r) ? r : []);
    const arr = Array.isArray(terms) ? terms : [];
    const hit = arr.some(function (t) { return String((t && (t.handle || t.id)) || t) === handle; });
    process.stdout.write(hit ? "yes" : "no");
  ' "$1"
}

command -v orca >/dev/null 2>&1 || { echo "skip: orca CLI not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found (required by the Orca adapter)"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "skip: git not found (needed for the scratch repo fixture)"; exit 0; }

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
fm_backend_source orca || { echo "skip: could not source the Orca adapter"; exit 0; }

fm_backend_orca_tool_check >/dev/null 2>&1 || { echo "skip: orca CLI not found on PATH"; exit 0; }
fm_backend_orca_runtime_check >/dev/null 2>&1 \
  || { echo "skip: Orca runtime not ready (reachable=true, state=ready required)"; exit 0; }

# --- scratch world: a stable, reused throwaway git repo -----------------------
# Deterministic path (no random suffix) so fm_backend_orca_repo_ensure reuses the
# SAME Orca registration across runs instead of adding a path-dangling one each
# run. Idempotent setup (git init no-ops on an existing repo; the commit is a
# no-op once initial exists), so repeated runs reuse it cleanly. Physically
# resolved under a pwd -P tmp root so Orca's path: selector and the adapter's
# pwd -P canonicalization agree.
TMP_ROOT=$(cd "${TMPDIR:-/tmp}" && pwd -P)
SCRATCH_REPO="$TMP_ROOT/fm-test-smoke-orca-repo"
mkdir -p "$SCRATCH_REPO" || { echo "skip: could not create a scratch directory"; exit 0; }
git -C "$SCRATCH_REPO" init -q
printf '# scratch\n' > "$SCRATCH_REPO/README.md"
git -C "$SCRATCH_REPO" add README.md
git -C "$SCRATCH_REPO" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial 2>/dev/null || true
SCRATCH_REPO=$(cd "$SCRATCH_REPO" && pwd -P)
LOCK_DIR="$SCRATCH_REPO.lock"

LABEL="fm-test-smoke-$$"
WT_ID=""
TERMINAL=""

cleanup_all() {
  # Best-effort, ordered, idempotent: close the terminal, then remove the
  # worktree (which also stops its terminals). Never touches any Orca state this
  # test did not create; the stable scratch repo is intentionally reused across
  # runs (its path is what keeps the Orca repo registration idempotent), not rm'd.
  if [ -n "${TERMINAL:-}" ]; then
    fm_backend_orca_kill "$TERMINAL" >/dev/null 2>&1 || true
    TERMINAL=""
  fi
  if [ -n "${WT_ID:-}" ]; then
    fm_backend_orca_remove_worktree "$WT_ID" >/dev/null 2>&1 || true
    WT_ID=""
  fi
}
trap cleanup_all EXIT

# orca_smoke_repo_ensure_locked: mkdir-serialize repo_ensure (atomic, no flock,
# Linux+macOS) so concurrent runs reuse one registration instead of racing on
# show-then-add. Reclaimed when the holder is gone (or past a ~30s backstop) and
# always released on exit. <project-path> <lock-dir> -> repo id.
orca_smoke_repo_ensure_locked() {  # <project-path> <lock-dir>
  local project=$1 lock_dir=$2 spins=0 holder id rc
  while ! mkdir "$lock_dir" 2>/dev/null; do
    holder=$(cat "$lock_dir/pid" 2>/dev/null || true)
    if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
      rm -rf "$lock_dir"
      continue
    fi
    sleep 0.2
    spins=$((spins + 1))
    if [ "$spins" -ge 150 ]; then
      rm -rf "$lock_dir"
      spins=0
    fi
  done
  printf '%s\n' "$$" > "$lock_dir/pid"
  id=$(fm_backend_orca_repo_ensure "$project")
  rc=$?
  rm -rf "$lock_dir"
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s' "$id"
}

# 1. Readiness: the skip gate above already ran runtime_check against the real
#    `orca status --json`; re-affirm it as a numbered assertion.
pass "real orca: runtime_check accepts a ready Orca runtime (reachable=true, state=ready)"

# 2. Repo registration: path: lookup with an add fallback.
REPO_ID=$(orca_smoke_repo_ensure_locked "$SCRATCH_REPO" "$LOCK_DIR") \
  || fail "repo_ensure failed to register the scratch repo"
[ -n "$REPO_ID" ] || fail "repo_ensure returned an empty repo id"
pass "real orca: repo_ensure registers the scratch repo and returns a repo id"

# A second repo_ensure reuses the registration (the happy path: show hits, no add).
REPO_ID_2=$(fm_backend_orca_repo_ensure "$SCRATCH_REPO") \
  || fail "second repo_ensure failed"
[ "$REPO_ID_2" = "$REPO_ID" ] \
  || fail "repo_ensure was not idempotent: '$REPO_ID' vs '$REPO_ID_2'"
pass "real orca: repo_ensure reuses an existing registration (idempotent show-then-skip)"

# 3. Worktree creation: returns "<wt-id>\t<wt-path>[\t<terminal>]".
CREATE_RAW=$(fm_backend_orca_worktree_create "$SCRATCH_REPO" "$LABEL") \
  || fail "worktree_create failed"
# Parse with the same parameter-expansion idiom as parse_orca_worktree_result
# (bin/fm-spawn.sh), not a heredoc, to stay shellcheck-clean.
WT_ID=${CREATE_RAW%%$'\t'*}
[ "$CREATE_RAW" != "$WT_ID" ] || fail "worktree_create did not return a worktree path"
_rest=${CREATE_RAW#*$'\t'}
WT_PATH=${_rest%%$'\t'*}
if [ "$_rest" != "$WT_PATH" ]; then
  IMPLICIT_TERM=${_rest#*$'\t'}
else
  IMPLICIT_TERM=""
fi
[ -n "$WT_ID" ] || fail "worktree_create did not return a worktree id"
[ -n "$WT_PATH" ] || fail "worktree_create did not return a worktree path"
pass "real orca: worktree_create returns a worktree id and path"

# 4. Path identity: the worktree is a real, local, isolated directory.
[ -d "$WT_PATH" ] || fail "worktree_create returned a non-directory path: $WT_PATH"
WT_CANON=$(cd "$WT_PATH" && pwd -P) || fail "could not canonicalize the worktree path: $WT_PATH"
[ "$WT_CANON" != "$SCRATCH_REPO" ] \
  || fail "worktree_create returned the scratch repo itself, not an isolated worktree"
pass "real orca: the worktree path is real, local, and isolated (distinct from the scratch repo)"

# 5. Terminal creation: explicit when worktree create omitted one (Linux headless).
if [ -n "$IMPLICIT_TERM" ]; then
  TERMINAL="$IMPLICIT_TERM"
  pass "real orca: worktree_create embedded an implicit terminal handle (no explicit create needed)"
else
  TERMINAL=$(fm_backend_orca_terminal_create "$WT_ID" "$LABEL") \
    || fail "terminal_create failed (worktree create returned no implicit terminal)"
  pass "real orca: terminal_create returns an explicit handle when worktree create omits one"
fi
[ -n "$TERMINAL" ] || fail "no terminal handle available for send/read"

# Give the headless PTY shell a moment to present a prompt before driving it.
sleep 1

# 6. Send + read round trip over a real PTY, with a bounded retry so a
#    slow-to-start shell still passes without a long fixed sleep.
fm_backend_orca_send_text_line "$TERMINAL" "echo orca-smoke-ok" \
  || fail "send_text_line failed"
OUT=""
_i=0
while [ "$_i" -lt 10 ]; do
  sleep 0.5
  OUT=$(fm_backend_orca_capture "$TERMINAL" 40 2>/dev/null || true)
  case "$OUT" in
    *orca-smoke-ok*) break ;;
  esac
  _i=$((_i + 1))
done
case "$OUT" in
  *orca-smoke-ok*) : ;;
  *) fail "real orca: send_text_line did not run and echo the marker"$'\n'"$OUT" ;;
esac
pass "real orca: send_text_line + capture round-trip a real PTY echo"

# 7. Ctrl-C interrupt (the adapter's --interrupt primitive).
fm_backend_orca_send_key "$TERMINAL" C-c \
  || fail "send_key C-c (normalized to --interrupt) failed"
pass "real orca: send_key C-c (the --interrupt primitive) succeeds against a live PTY"

# 8. Worktree-path lookup: orca worktree show round-trips to the same path
#    (the path-identity primitive teardown relies on).
RESOLVED_PATH=$(fm_backend_orca_worktree_path "$WT_ID") \
  || fail "worktree_path lookup failed"
[ "$RESOLVED_PATH" = "$WT_PATH" ] \
  || fail "worktree_path returned a different path than creation: '$RESOLVED_PATH' vs '$WT_PATH'"
pass "real orca: worktree_path round-trips orca worktree show to the created path"

# 9. busy_state: Orca has no native agent-state primitive, so the dispatcher
#    falls through to unknown (watcher falls back to pane-regex), like tmux.
BS=$(fm_backend_busy_state orca "$TERMINAL")
[ "$BS" = unknown ] || fail "fm_backend_busy_state should report unknown for orca, got '$BS'"
pass "real orca: fm_backend_busy_state reports unknown (watcher falls back to pane-regex)"

# 10. Terminal close: a closed terminal drops out of `orca terminal list` (the
#     live-terminal registry). read/show still see the stale record after close,
#     so live-list membership is the reliable signal (verified empirically).
fm_backend_orca_kill "$TERMINAL"
sleep 0.5
LIVE=$(orca_term_is_live "$TERMINAL")
[ "$LIVE" = no ] || fail "kill did not drop the terminal from the live-terminal registry"
# Best-effort contract: closing an already-closed terminal must not error.
fm_backend_orca_kill "$TERMINAL" || fail "kill on an already-closed terminal must stay best-effort"
TERMINAL=""
pass "real orca: kill closes the terminal (drops from the live list) and is idempotent/best-effort"

# 11. Worktree removal: orca worktree rm removes it; a subsequent path lookup
#     fails with selector_not_found (the teardown cleanup primitive).
fm_backend_orca_remove_worktree "$WT_ID" || fail "remove_worktree failed"
if fm_backend_orca_worktree_path "$WT_ID" >/dev/null 2>&1; then
  fail "worktree was still resolvable after remove_worktree"
fi
WT_ID=""
pass "real orca: remove_worktree removes the worktree (subsequent lookup reports it gone)"

cleanup_all
trap - EXIT
