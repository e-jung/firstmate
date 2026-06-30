#!/usr/bin/env bash
# Manage durable watcher check plugins.
#
# The watcher discovers check scripts via a state/*.check.sh glob, but state/ is
# gitignored (volatile runtime signals) - fine for per-task checks that fm-pr-check
# writes at runtime, but a fleet-wide plugin must survive a fresh clone. So a
# plugin's source lives tracked under bin/check-plugins/<name>.check.sh and is
# symlinked into state/<name>.check.sh at runtime so the watcher picks it up with
# no watcher changes. This script owns that lifecycle.
#
#   fm-plugin.sh add <name> <source-script>
#       Install <source-script> as plugin <name>: copy its content to the tracked
#       canonical home bin/check-plugins/<name>.check.sh and point
#       state/<name>.check.sh at it. If state/<name>.check.sh already exists as a
#       real file (e.g. it is the source you just named), its content is now held
#       canonically and the path becomes the symlink.
#   fm-plugin.sh remove <name>
#       Drop the state/ symlink and the tracked canonical source.
#   fm-plugin.sh list
#       Print installed plugins and whether their state/ symlink is live.
#   fm-plugin.sh sync
#       Recreate state/ symlinks for every canonical plugin. Idempotent and
#       non-fatal; bootstrap calls this so plugins come back alive after a fresh
#       clone. Never clobbers a real (non-symlink) state file - that may be a live
#       per-task check.
set -eu

FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGINS="$FM_ROOT/bin/check-plugins"
STATE="$FM_ROOT/state"

die() { printf 'fm-plugin: %s\n' "$*" >&2; exit 1; }

valid_name() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
    fm-*) return 1 ;;   # reserved for task ids (state/<id>.check.sh)
  esac
  return 0
}

ensure_dirs() { mkdir -p "$PLUGINS" "$STATE"; }
canonical_for() { printf '%s/%s.check.sh' "$PLUGINS" "$1"; }
state_link_for() { printf '%s/%s.check.sh' "$STATE" "$1"; }

cmd_add() {
  [ $# -eq 2 ] || die "usage: fm-plugin.sh add <name> <source-script>"
  local name=$1 src=$2 canon link
  valid_name "$name" || die "invalid plugin name: '$name' (use [A-Za-z0-9._-], must not start with 'fm-')"
  [ -f "$src" ] || die "source script not found: $src"
  ensure_dirs
  canon="$(canonical_for "$name")"
  link="$(state_link_for "$name")"
  # Copy content FIRST: <src> may itself be the state path we are about to replace
  # with a symlink.
  cp -f "$src" "$canon"
  chmod +x "$canon"
  # If a real (non-symlink) file sits at the state path, drop it - its content now
  # lives canonically. A pre-existing symlink is just refreshed by ln -sfn.
  if [ -e "$link" ] && [ ! -L "$link" ]; then rm -f "$link"; fi
  ln -sfn "$canon" "$link"
  printf 'added plugin %s\n  canonical: %s\n  state link: %s\n' "$name" "$canon" "$link"
}

cmd_remove() {
  [ $# -eq 1 ] || die "usage: fm-plugin.sh remove <name>"
  local name=$1 canon link
  valid_name "$name" || die "invalid plugin name: '$name'"
  canon="$(canonical_for "$name")"
  link="$(state_link_for "$name")"
  { [ -e "$canon" ] || [ -L "$link" ]; } || die "no such plugin: $name"
  rm -f "$link" "$canon"
  printf 'removed plugin %s\n' "$name"
}

cmd_list() {
  ensure_dirs
  local f name link
  if [ -z "$(ls -A "$PLUGINS" 2>/dev/null || true)" ]; then
    printf '(no plugins installed)\n'
    return
  fi
  for f in "$PLUGINS"/*.check.sh; do
    [ -e "$f" ] || continue
    name="$(basename "$f" .check.sh)"
    link="$(state_link_for "$name")"
    if [ -L "$link" ] && [ -e "$link" ]; then
      printf '%s\tlive\n' "$name"
    else
      printf '%s\tstale (run: bin/fm-plugin.sh sync)\n' "$name"
    fi
  done
}

cmd_sync() {
  ensure_dirs
  [ -d "$PLUGINS" ] || return 0
  local f name link n=0
  for f in "$PLUGINS"/*.check.sh; do
    [ -e "$f" ] || continue
    name="$(basename "$f" .check.sh)"
    valid_name "$name" || continue
    link="$(state_link_for "$name")"
    # Never clobber a real (non-symlink) state file: it may be a live per-task
    # check that happens to share the name.
    if [ -e "$link" ] && [ ! -L "$link" ]; then continue; fi
    ln -sfn "$f" "$link"
    n=$((n + 1))
  done
  return 0
}

[ $# -ge 1 ] || die "usage: fm-plugin.sh <add|remove|list|sync> ..."
cmd=$1; shift
case "$cmd" in
  add) cmd_add "$@" ;;
  remove|rm) cmd_remove "$@" ;;
  list|ls) cmd_list "$@" ;;
  sync) cmd_sync "$@" ;;
  -h|--help|help)
    sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    ;;
  *) die "unknown command: $cmd (use add|remove|list|sync)" ;;
esac
