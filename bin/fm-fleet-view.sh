#!/usr/bin/env bash
# fm-fleet-view.sh - compact, read-only fleet dashboard for the captain.
#
# Prints one paste-friendly table of in-flight tasks from this firstmate home's
# state/*.meta records. It deliberately does not replace the watcher or session
# backends: Herdr/tmux/zellij/Orca still own workers, while this command gives
# the control thread a concise view of what exists, where it lives, what it is
# currently doing, and how to watch or steer it.
#
# Usage: fm-fleet-view.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-backend.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-backend.sh"

usage() {
  echo "usage: fm-fleet-view.sh" >&2
  exit 2
}

[ "$#" -eq 0 ] || usage

trim() {
  local s=${1:-}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

basename_or_value() {
  local v=${1:-}
  [ -n "$v" ] || { printf '-'; return; }
  case "$v" in
    */*) basename "$v" ;;
    *) printf '%s' "$v" ;;
  esac
}

clean_cell() {
  local v=${1:-}
  v=$(printf '%s' "$v" | tr '\n\r\t' '   ')
  v=${v//|/\/}
  v=$(trim "$v")
  [ -n "$v" ] || v='-'
  printf '%s' "$v"
}

status_summary() {
  local id=$1 out last
  out=$(FM_CREW_STATE_NM_TIMEOUT="${FM_FLEET_VIEW_STATE_TIMEOUT:-2}" "$SCRIPT_DIR/fm-crew-state.sh" "$id" 2>/dev/null || true)
  out=$(printf '%s\n' "$out" | tail -1)
  if [ -n "$out" ]; then
    clean_cell "$out"
    return
  fi
  if [ -f "$STATE/$id.status" ]; then
    last=$(grep -v '^[[:space:]]*$' "$STATE/$id.status" 2>/dev/null | tail -1)
    [ -n "$last" ] && { clean_cell "$last"; return; }
  fi
  printf 'state: unknown'
}

backlog_inflight_lines() {
  local backlog="$DATA/backlog.md"
  [ -f "$backlog" ] || return 0
  awk '
    BEGIN { section = "" }
    /^## / { section = $0; next }
    section == "## In flight" && /^- \[[ x]\] / {
      rest = $0
      sub(/^- \[[ x]\] +/, "", rest)
      id = rest
      sub(/[ \t].*/, "", id)
      title = rest
      sub(/^[^ \t]+[ \t]*/, "", title)
      if (id != "") print id "\t" title
    }
  ' "$backlog"
}

artifact_pointer() {
  local id=$1 meta=$2 pr report log_line
  pr=$(fm_meta_get "$meta" pr)
  if [ -n "$pr" ]; then
    printf 'PR %s' "$pr"
    return
  fi
  report="$DATA/$id/report.md"
  if [ -f "$report" ]; then
    printf 'report %s' "$report"
    return
  fi
  if [ -f "$STATE/$id.status" ]; then
    log_line=$(grep -Eo 'https://github\.com/[^[:space:]]+/pull/[0-9]+' "$STATE/$id.status" 2>/dev/null | tail -1)
    if [ -n "$log_line" ]; then
      printf 'PR %s' "$log_line"
      return
    fi
  fi
  printf '-'
}

path_pointer() {
  local meta=$1 backend wt home oid terminal target
  backend=$(fm_backend_of_meta "$meta")
  wt=$(fm_meta_get "$meta" worktree)
  home=$(fm_meta_get "$meta" home)
  oid=$(fm_meta_get "$meta" orca_worktree_id)
  terminal=$(fm_meta_get "$meta" terminal)
  target=$(fm_backend_target_of_meta "$meta")
  case "$backend" in
    orca)
      if [ -n "$wt" ]; then printf '%s' "$wt"
      elif [ -n "$oid" ]; then printf 'orca-worktree:%s' "$oid"
      elif [ -n "$terminal" ]; then printf 'orca-terminal:%s' "$terminal"
      else printf '-' ; fi
      ;;
    *)
      if [ -n "$wt" ]; then printf '%s' "$wt"
      elif [ -n "$home" ]; then printf '%s' "$home"
      elif [ -n "$target" ]; then printf 'endpoint:%s' "$target"
      else printf '-' ; fi
      ;;
  esac
}

repo_name() {
  local meta=$1 project projects wt
  project=$(fm_meta_get "$meta" project)
  projects=$(fm_meta_get "$meta" projects)
  wt=$(fm_meta_get "$meta" worktree)
  if [ -n "$project" ]; then basename_or_value "$project"
  elif [ -n "$projects" ]; then printf '%s' "$projects"
  elif [ -n "$wt" ]; then basename_or_value "$wt"
  else printf '-'; fi
}

printf 'ID | REPO | KIND | BACKEND | STATUS | PR/REPORT | PATH | WATCH / STEER\n'
printf '%s\n' '---|---|---|---|---|---|---|---'

found=0
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  found=1
  id=$(basename "$meta" .meta)
  repo=$(repo_name "$meta")
  kind=$(fm_meta_get "$meta" kind)
  [ -n "$kind" ] || kind=ship
  backend=$(fm_backend_of_meta "$meta")
  status=$(status_summary "$id")
  artifact=$(artifact_pointer "$id" "$meta")
  path=$(path_pointer "$meta")
  actions="watch: bin/fm-peek.sh fm-$id; steer: bin/fm-send.sh fm-$id '<message>'; links: bin/fm-codex-link.sh task $id"
  printf '%s | %s | %s | %s | %s | %s | %s | %s\n' \
    "$(clean_cell "$id")" \
    "$(clean_cell "$repo")" \
    "$(clean_cell "$kind")" \
    "$(clean_cell "$backend")" \
    "$(clean_cell "$status")" \
    "$(clean_cell "$artifact")" \
    "$(clean_cell "$path")" \
    "$(clean_cell "$actions")"
done

while IFS="$(printf '\t')" read -r backlog_id backlog_title; do
  [ -n "$backlog_id" ] || continue
  [ -f "$STATE/$backlog_id.meta" ] && continue
  found=1
  status="state: unknown (backlog in-flight, no metadata)"
  [ -n "$backlog_title" ] && status="$status; $backlog_title"
  actions="create/recover task metadata before watch/steer"
  printf '%s | %s | %s | %s | %s | %s | %s | %s\n' \
    "$(clean_cell "$backlog_id")" \
    '-' \
    'backlog' \
    '-' \
    "$(clean_cell "$status")" \
    '-' \
    '-' \
    "$(clean_cell "$actions")"
done < <(backlog_inflight_lines)

if [ "$found" -eq 0 ]; then
  printf '(none) | - | - | - | no in-flight tasks in %s | - | - | -\n' "$STATE"
fi
