#!/usr/bin/env bash
# Behavior tests for durable watcher check plugins: the fm-plugin.sh lifecycle
# (add/remove/list/sync) and the shipped done-crewmate.check.sh detector.
#
# A plugin's canonical source lives tracked under bin/check-plugins/<name>.check.sh
# and is symlinked into state/<name>.check.sh so the watcher's state/*.check.sh glob
# sweeps it. state/ is gitignored, so bootstrap calls `fm-plugin.sh sync` to recreate
# those symlinks after a fresh clone. These cases pin:
#   - add: copies content to the canonical home and points state/ at it via symlink;
#   - remove: drops both the symlink and the canonical source;
#   - list: reports live vs stale, and '(no plugins installed)' when empty;
#   - sync: recreates missing symlinks idempotently, never clobbering a real
#     (non-symlink) state file that may be a live per-task check;
#   - invalid-name / not-found / usage guards;
#   - done-crewmate.check.sh: surfaces terminal-status (done/failed/blocked) crewmates
#     whose tmux window is still alive, excludes secondmates and needs-decision,
#     stays silent when the window is gone / crew resumed / no window recorded,
#     and emits exactly one line listing every offender.
#
# fm-plugin.sh resolves FM_ROOT from its own script location (it operates on its
# own repo), so each case copies the script into a fresh temp FM_ROOT to keep the
# real repo untouched. done-crewmate.check.sh honors FM_ROOT_OVERRIDE, so it is
# pointed at a temp state dir directly.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PLUGIN_SH="$ROOT/bin/fm-plugin.sh"
DONE_CHECK="$ROOT/bin/check-plugins/done-crewmate.check.sh"

TMP_ROOT=$(fm_test_tmproot fm-plugin)

# A fresh fake FM_ROOT with bin/check-plugins and state, plus a copy of fm-plugin.sh
# inside bin/ so the script resolves this temp dir as its own FM_ROOT. Echoes the dir.
make_root() {
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/bin/check-plugins" "$dir/state"
  cp "$PLUGIN_SH" "$dir/bin/fm-plugin.sh"
  chmod +x "$dir/bin/fm-plugin.sh"
  printf '%s\n' "$dir"
}

# A trivial source check script that prints a line. Echoes its path.
make_source() {
  local f="$TMP_ROOT/source-$1.check.sh"
  cat > "$f" <<'SH'
#!/usr/bin/env bash
printf 'sample fired\n'
SH
  chmod +x "$f"
  printf '%s\n' "$f"
}

# A fake tmux that lists the windows in FM_FAKE_WINDOWS (one '<sess>:<win>'/line).
# Installed into the given fakebin.
install_fake_tmux() {
  local fakebin=$1
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = "list-windows" ]; then
  [ -n "${FM_FAKE_WINDOWS:-}" ] && printf '%s\n' "$FM_FAKE_WINDOWS"
  exit 0
fi
exit 1
SH
  chmod +x "$fakebin/tmux"
}

# Run done-crewmate.check.sh against a temp root with a fake tmux on PATH.
# Args: <root> <fakebin> [FM_FAKE_WINDOWS value]
run_done_check() {
  local root=$1 fakebin=$2
  FM_ROOT_OVERRIDE="$root" PATH="$fakebin:$PATH" FM_FAKE_WINDOWS="${3:-}" "$DONE_CHECK"
}

# --- fm-plugin.sh: add / list / remove --------------------------------------

test_add_creates_canonical_and_symlink() {
  local root src canon link
  root=$(make_root add-basic); src=$(make_source add)
  "$root/bin/fm-plugin.sh" add sample "$src" >/dev/null || fail "add failed"
  canon="$root/bin/check-plugins/sample.check.sh"
  link="$root/state/sample.check.sh"
  [ -f "$canon" ] || fail "canonical source was not created"
  [ -L "$link" ] || fail "state link is not a symlink"
  [ "$(readlink -f "$link")" = "$(cd -P "$root/bin/check-plugins" && pwd)/sample.check.sh" ] \
    || fail "state symlink does not point at the canonical source"
  diff -q "$src" "$canon" >/dev/null || fail "canonical content does not match source"
  [ -x "$canon" ] || fail "canonical source is not executable"
  pass "add copies content to the canonical home and points state/ at it via symlink"
}

test_list_reports_live_stale_and_empty() {
  local root src out
  root=$(make_root list-cases)
  out=$("$root/bin/fm-plugin.sh" list) || fail "list failed on empty"
  assert_contains "$out" "(no plugins installed)" "empty list message"
  src=$(make_source list)
  "$root/bin/fm-plugin.sh" add sample "$src" >/dev/null
  out=$("$root/bin/fm-plugin.sh" list)
  assert_contains "$out" $'sample\tlive' "live plugin not reported"
  rm -f "$root/state/sample.check.sh"   # simulate a fresh clone / dropped symlink
  out=$("$root/bin/fm-plugin.sh" list)
  assert_contains "$out" "sample" "stale plugin name missing"
  assert_contains "$out" "stale" "stale plugin not marked stale"
  pass "list reports '(no plugins installed)', live, and stale states"
}

test_remove_drops_symlink_and_canonical() {
  local root src
  root=$(make_root remove-case); src=$(make_source rm)
  "$root/bin/fm-plugin.sh" add sample "$src" >/dev/null
  "$root/bin/fm-plugin.sh" remove sample >/dev/null || fail "remove failed"
  [ ! -e "$root/bin/check-plugins/sample.check.sh" ] || fail "canonical source not removed"
  [ ! -e "$root/state/sample.check.sh" ] || fail "state symlink not removed"
  pass "remove drops both the state symlink and the canonical source"
}

# --- fm-plugin.sh: sync (the bootstrap fresh-clone path) --------------------

test_sync_recreates_missing_symlink() {
  local root src link
  root=$(make_root sync-restore); src=$(make_source sync)
  "$root/bin/fm-plugin.sh" add sample "$src" >/dev/null
  link="$root/state/sample.check.sh"
  rm -f "$link"   # fresh clone: state/ is gitignored and empty
  "$root/bin/fm-plugin.sh" sync || fail "sync failed"
  [ -L "$link" ] || fail "sync did not recreate the symlink"
  [ "$(readlink -f "$link")" = "$(cd -P "$root/bin/check-plugins" && pwd)/sample.check.sh" ] \
    || fail "sync recreated symlink points at the wrong target"
  # Idempotent: a second sync is a no-op.
  "$root/bin/fm-plugin.sh" sync || fail "second sync failed"
  pass "sync recreates a missing plugin symlink after a fresh clone (idempotent)"
}

test_sync_never_clobbers_a_real_state_file() {
  local root src link
  root=$(make_root sync-noclobber); src=$(make_source sync2)
  "$root/bin/fm-plugin.sh" add sample "$src" >/dev/null
  link="$root/state/sample.check.sh"
  rm -f "$link"
  # A real (non-symlink) file at the state path may be a live per-task check that
  # happens to share the name; sync must leave it untouched.
  cat > "$link" <<'SH'
#!/usr/bin/env bash
echo "i am a live per-task check"
SH
  "$root/bin/fm-plugin.sh" sync || fail "sync failed"
  [ ! -L "$link" ] || fail "sync clobbered a real per-task check file (turned it into a symlink)"
  grep -F "live per-task check" "$link" >/dev/null || fail "sync altered the real file's content"
  pass "sync never clobbers a real (non-symlink) state file that may be a live per-task check"
}

# --- fm-plugin.sh: guards ---------------------------------------------------

test_invalid_names_rejected() {
  local root src
  root=$(make_root invalid-names); src=$(make_source inv)
  if "$root/bin/fm-plugin.sh" add "fm-task1" "$src" 2>/dev/null; then
    fail "fm- prefix (reserved for task ids) was accepted"
  fi
  if "$root/bin/fm-plugin.sh" add "bad name!" "$src" 2>/dev/null; then
    fail "a name with invalid characters was accepted"
  fi
  if "$root/bin/fm-plugin.sh" add "" "$src" 2>/dev/null; then
    fail "an empty name was accepted"
  fi
  pass "invalid plugin names (fm- prefix, bad chars, empty) are rejected"
}

test_remove_unknown_fails() {
  local root
  root=$(make_root rm-unknown)
  if "$root/bin/fm-plugin.sh" remove nosuch 2>/dev/null; then
    fail "remove of a non-existent plugin succeeded"
  fi
  pass "remove of an unknown plugin fails"
}

test_add_accepts_state_path_as_source() {
  # The doc contract: if state/<name>.check.sh already exists as a real file (it is
  # the source you just named), add holds its content canonically and replaces the
  # path with the symlink. Copy content first, then symlink, so the source survives.
  local root canon link
  root=$(make_root add-from-state)
  cat > "$root/state/sample.check.sh" <<'SH'
#!/usr/bin/env bash
echo "promoted from a real state file"
SH
  "$root/bin/fm-plugin.sh" add sample "$root/state/sample.check.sh" >/dev/null || fail "add failed"
  canon="$root/bin/check-plugins/sample.check.sh"
  link="$root/state/sample.check.sh"
  [ -f "$canon" ] || fail "canonical source not created from the real state file"
  [ -L "$link" ] || fail "the real state file was not replaced by a symlink"
  grep -F "promoted from a real state file" "$canon" >/dev/null \
    || fail "canonical content did not capture the original state file content"
  pass "add promotes a real state file to the canonical source + symlink"
}

# --- done-crewmate.check.sh: detection --------------------------------------

test_done_crewmate_with_live_window_surfaces() {
  local root fakebin
  root=$(make_root dc-done); fakebin="$root/fakebin"; mkdir -p "$fakebin"
  install_fake_tmux "$fakebin"
  printf 'window=firstmate:fm-task-aaa\nkind=ship\n' > "$root/state/task-aaa.meta"
  printf 'working: step 1\ndone: PR https://example.test/pr/9\n' > "$root/state/task-aaa.status"
  out=$(run_done_check "$root" "$fakebin" "firstmate:fm-task-aaa")
  [ -n "$out" ] || fail "a done crewmate with a live window was not reported"
  assert_contains "$out" "task-aaa" "done offender not named in the wake line"
  pass "a terminal (done:) crewmate whose window is alive is reported"
}

test_terminal_verbes_failed_and_blocked_count() {
  local root fakebin out
  root=$(make_root dc-verbs); fakebin="$root/fakebin"; mkdir -p "$fakebin"
  install_fake_tmux "$fakebin"
  printf 'window=firstmate:fm-c1\nkind=ship\n' > "$root/state/c1.meta"
  printf 'failed: tests blew up\n' > "$root/state/c1.status"
  printf 'window=firstmate:fm-c2\nkind=ship\n' > "$root/state/c2.meta"
  printf 'blocked: waiting on auth\n' > "$root/state/c2.status"
  out=$(run_done_check "$root" "$fakebin" $'firstmate:fm-c1\nfirstmate:fm-c2')
  assert_contains "$out" "c1" "failed: offender missed"
  assert_contains "$out" "c2" "blocked: offender missed"
  pass "failed: and blocked: terminal statuses are both reported"
}

test_needs_decision_excluded() {
  # needs-decision escalates immediately through the signal layer on write, so it
  # never needs this recurring backstop.
  local root fakebin out
  root=$(make_root dc-nd); fakebin="$root/fakebin"; mkdir -p "$fakebin"
  install_fake_tmux "$fakebin"
  printf 'window=firstmate:fm-nd\nkind=ship\n' > "$root/state/nd.meta"
  printf 'needs-decision: pick A or B\n' > "$root/state/nd.status"
  out=$(run_done_check "$root" "$fakebin" "firstmate:fm-nd")
  [ -z "$out" ] || fail "needs-decision was reported (should be excluded): $out"
  pass "needs-decision is excluded (it escalates on write, not via this backstop)"
}

test_secondmate_skipped() {
  local root fakebin out
  root=$(make_root dc-sm); fakebin="$root/fakebin"; mkdir -p "$fakebin"
  install_fake_tmux "$fakebin"
  printf 'window=firstmate:fm-domain\nkind=secondmate\nhome=%s/h\n' "$root" > "$root/state/domain.meta"
  printf 'done: routine charter\n' > "$root/state/domain.status"
  out=$(run_done_check "$root" "$fakebin" "firstmate:fm-domain")
  [ -z "$out" ] || fail "a terminal secondmate was reported (should be skipped): $out"
  pass "kind=secondmate is skipped even with a terminal status"
}

test_window_gone_silent() {
  local root fakebin out
  root=$(make_root dc-gone); fakebin="$root/fakebin"; mkdir -p "$fakebin"
  install_fake_tmux "$fakebin"
  printf 'window=firstmate:fm-task-aaa\nkind=ship\n' > "$root/state/task-aaa.meta"
  printf 'done: PR https://example.test/pr/9\n' > "$root/state/task-aaa.status"
  out=$(run_done_check "$root" "$fakebin" "")   # tmux reports no fm windows
  [ -z "$out" ] || fail "a done crewmate whose window is gone was reported: $out"
  pass "a done crewmate whose window is already gone (progressed/torn down) is silent"
}

test_resumed_crew_silent() {
  # A later non-terminal line (working:) means the crew resumed after a done:, so it
  # is not idle-done. The current state is the LAST non-empty status line.
  local root fakebin out
  root=$(make_root dc-resumed); fakebin="$root/fakebin"; mkdir -p "$fakebin"
  install_fake_tmux "$fakebin"
  printf 'window=firstmate:fm-task-aaa\nkind=ship\n' > "$root/state/task-aaa.meta"
  printf 'done: PR x\nworking: fixing review nits\n' > "$root/state/task-aaa.status"
  out=$(run_done_check "$root" "$fakebin" "firstmate:fm-task-aaa")
  [ -z "$out" ] || fail "a resumed crew (last line working:) was reported: $out"
  pass "a crew whose last status line is non-terminal (resumed) is silent"
}

test_no_window_recorded_silent() {
  local root fakebin out
  root=$(make_root dc-nowin); fakebin="$root/fakebin"; mkdir -p "$fakebin"
  install_fake_tmux "$fakebin"
  printf 'kind=ship\n' > "$root/state/nowin.meta"   # no window= recorded
  printf 'done: x\n' > "$root/state/nowin.status"
  out=$(run_done_check "$root" "$fakebin" "firstmate:fm-other")
  assert_not_contains "$out" "nowin" "a crew with no window= was reported"
  pass "a crew with no window= recorded is skipped (cannot cross-reference tmux)"
}

test_all_offenders_in_one_line() {
  local root fakebin out nlines
  root=$(make_root dc-oneline); fakebin="$root/fakebin"; mkdir -p "$fakebin"
  install_fake_tmux "$fakebin"
  printf 'window=firstmate:fm-a\nkind=ship\n' > "$root/state/a.meta"
  printf 'done: a\n' > "$root/state/a.status"
  printf 'window=firstmate:fm-b\nkind=ship\n' > "$root/state/b.meta"
  printf 'failed: b\n' > "$root/state/b.status"
  printf 'window=firstmate:fm-c\nkind=ship\n' > "$root/state/c.meta"
  printf 'blocked: c\n' > "$root/state/c.status"
  out=$(run_done_check "$root" "$fakebin" $'firstmate:fm-a\nfirstmate:fm-b\nfirstmate:fm-c')
  nlines=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
  [ "$nlines" = "1" ] || fail "multiple offenders produced $nlines lines instead of one: $out"
  assert_contains "$out" "a" "offender a missing"
  assert_contains "$out" "b" "offender b missing"
  assert_contains "$out" "c" "offender c missing"
  pass "every offender is listed in a single wake line"
}

# --- bootstrap integration: sync is wired into bootstrap --------------------

test_bootstrap_invokes_plugin_sync() {
  # Bootstrap's final step must call fm-plugin.sh sync so plugins come back alive
  # after a fresh clone (state/ is gitignored). Assert the call is present and
  # guarded so a missing executable or a sync failure never aborts bootstrap.
  local boot="$ROOT/bin/fm-bootstrap.sh"
  grep -F 'fm-plugin.sh' "$boot" >/dev/null \
    || fail "bootstrap does not reference fm-plugin.sh"
  # shellcheck disable=SC2016  # single quotes are deliberate: literal source string
  grep -F '[ -x "$FM_ROOT/bin/fm-plugin.sh" ] && "$FM_ROOT/bin/fm-plugin.sh" sync' "$boot" >/dev/null \
    || fail "bootstrap does not invoke the sync subcommand with the documented guard"
  pass "bootstrap invokes 'fm-plugin.sh sync' (guarded, best-effort) as its final step"
}

test_add_creates_canonical_and_symlink
test_list_reports_live_stale_and_empty
test_remove_drops_symlink_and_canonical
test_sync_recreates_missing_symlink
test_sync_never_clobbers_a_real_state_file
test_invalid_names_rejected
test_remove_unknown_fails
test_add_accepts_state_path_as_source
test_done_crewmate_with_live_window_surfaces
test_terminal_verbes_failed_and_blocked_count
test_needs_decision_excluded
test_secondmate_skipped
test_window_gone_silent
test_resumed_crew_silent
test_no_window_recorded_silent
test_all_offenders_in_one_line
test_bootstrap_invokes_plugin_sync

printf 'all fm-plugin / done-crewmate tests passed\n'
