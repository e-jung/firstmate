#!/usr/bin/env bash
# Watcher check plugin: detect crewmates that reported a terminal status
# (done/failed/blocked) but whose tmux window is still alive - i.e. finished
# work firstmate has not yet progressed (validated / PR'd / merged) or torn down.
#
# Why this exists: a status write fires exactly once, on change. If firstmate
# gets the `done` signal, starts acting, then drops the thread, nothing re-nudges
# it - the stale-pane detector fires on the idle pane, but that alarm is
# indistinguishable from a stuck crewmate until firstmate re-reads the status, so
# a busy firstmate dismisses it as noise. This check is the deterministic,
# recurring backstop: every FM_CHECK_INTERVAL it re-asserts "done work is still
# sitting there" until the crewmate is torn down.
#
# Watcher check contract (same as bin/fm-pr-check.sh's per-task checks):
#   print exactly one line  -> wake firstmate (reason wrapped as
#                              `check: <this-script>: <line>`)
#   print nothing           -> fleet healthy; keep sleeping
# Runs via the watcher's state/*.check.sh glob (state/done-crewmate.check.sh is
# a symlink to this canonical copy under bin/check-plugins/; see bin/fm-plugin.sh).
# Fast by design: only tmux list-windows + small file reads, no network.
set -u

# Resolve FM_ROOT independent of cwd and of symlink indirection
# (state/<name>.check.sh -> bin/check-plugins/<name>.check.sh). Prefer an explicit
# override, then cwd (the watcher runs from FM_ROOT, so state/ and bin/ are
# siblings of $PWD), then walk up from this script's resolved real path.
fm_root() {
  [ -n "${FM_ROOT_OVERRIDE:-}" ] && { printf '%s\n' "$FM_ROOT_OVERRIDE"; return; }
  if [ -d state ] && [ -d bin ]; then printf '%s\n' "$PWD"; return; fi
  local src="${BASH_SOURCE[0]}" real d
  real="$(readlink -f "$src" 2>/dev/null)" && [ -n "$real" ] && src="$real"
  d="$(cd "$(dirname "$src")" 2>/dev/null && pwd)" || { printf '%s\n' "$PWD"; return; }
  if [ -d "$d/../.." ]; then (cd "$d/../.." && pwd); return; fi   # bin/check-plugins -> root
  if [ -d "$d/.." ];    then (cd "$d/.." && pwd);    return; fi   # direct state/ invocation
  printf '%s\n' "$PWD"
}
FM_ROOT="$(fm_root)"
STATE="$FM_ROOT/state"

[ -d "$STATE" ] || exit 0

# A terminal status means the crewmate's work is complete (or halted pending
# firstmate) and it should not still be occupying a tmux window. needs-decision
# is intentionally excluded: it escalates immediately through the signal layer on
# write, so it never needs this recurring backstop.
is_terminal() {
  case "$1" in
    done:*|failed:*|blocked:*) return 0 ;;
    *) return 1 ;;
  esac
}

# Live crewmate windows, one '<session>:<window>' per line (matches the watcher's
# own enumeration in bin/fm-watch.sh). Empty if tmux is absent or no fm windows
# exist - which means nothing can be idle-done, so we stay silent.
WINDOWS="$(tmux list-windows -a -F '#{session_name}:#{window_name}' 2>/dev/null | grep ':fm-' || true)"
[ -n "$WINDOWS" ] || exit 0

offenders=""
for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || continue
  id="$(basename "$meta" .meta)"
  status_file="$STATE/$id.status"
  [ -f "$status_file" ] || continue        # no status reported yet -> still working

  # Current state = the last non-empty status line (crewmates append; a later
  # `working:` means it resumed, which is not idle-done). Tolerate a missing
  # trailing newline via the `|| [ -n "$line" ]` guard.
  last=""
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] && last="$line"
  done < "$status_file"
  is_terminal "$last" || continue

  # Cross-reference tmux: is this crewmate's window still alive? The meta's
  # window= target is authoritative (recorded by fm-spawn as <session>:<window>).
  win="$(grep -m1 '^window=' "$meta" 2>/dev/null | cut -d= -f2-)"
  [ -n "$win" ] || continue
  case "$WINDOWS" in
    *"$win"*) offenders="${offenders:+$offenders }$id" ;;
  esac
done

[ -n "$offenders" ] || exit 0
# One line listing every offender so a single wake carries the whole picture.
printf 'done crewmate %s still alive in tmux - progress or tear down\n' "$offenders"
