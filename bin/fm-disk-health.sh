#!/usr/bin/env bash
# Recurring disk-health maintenance: report reclaimable space and, with --clean,
# reclaim it safely. Structural countermeasure for the 2026-06-22 incident where
# the 45G VPS hit 100% ("No space left on device") under multi-crewmate load from
# unmanaged caches (~18G waste: ~/.npm, ~/go, /var/log/journal, dangling docker
# images, ~/.cache) plus an ever-growing opencode.db whose cleanup prune=7.days
# deletes rows but never reclaims SQLite file space without a VACUUM.
#
# Never touches crewmate worktrees, projects/, ~/.treehouse, ~/.openclaw, or live
# session state. --check is read-only (safe to run from bootstrap on every
# session); --clean performs the safe reclaims; --vacuum-opencode-db reclaims
# SQLite file space and refuses to run while opencode is live.
#
# Usage:
#   fm-disk-health.sh [--check]    Print disk usage, each reclaimable target's
#                                 size, opencode.db size + growth, and whether a
#                                 VACUUM is safe to run now (no opencode running).
#                                 Prints one ALERT line if usage exceeds
#                                 FM_DISK_ALERT_PCT (default 85). No mutations.
#   fm-disk-health.sh --clean      Perform the safe reclaims (npm/go/journal/
#                                 docker/~.cache), then print a before/after
#                                 summary. Idempotent; each step is skippable.
#   fm-disk-health.sh --vacuum-opencode-db
#                                 VACUUM the opencode SQLite db to reclaim file
#                                 space. Refuses while opencode is running.
#   fm-disk-health.sh -h|--help    Show this usage.
#
# Env knobs:
#   FM_DISK_ALERT_PCT (85)             Alert threshold for disk usage percent.
#   FM_JOURNAL_KEEP (200M)             journalctl --vacuum-size target.
#   FM_CACHE_SAFE_SUBDIRS              Space-separated ~/.cache subdirs to clear
#                                      (default: "pip go-build pypoetry").
#   FM_DISK_SKIP_NPM/_GO/_JOURNAL/_DOCKER/_CACHE=1
#                                      Skip an individual reclaim in --clean.
#   FM_DISK_VACUUM_ON_CLEAN=1          Run the opencode.db VACUUM during --clean
#                                      when the fleet is idle.
#   FM_OPENCODE_DB                     Override the opencode.db path (tests).
#   FM_STATE_OVERRIDE                  Override the state dir (tests).
set -euo pipefail

FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="${FM_STATE_OVERRIDE:-$FM_ROOT/state}"
OPENCODE_DB="${FM_OPENCODE_DB:-$HOME/.local/share/opencode/opencode.db}"
ALERT_PCT="${FM_DISK_ALERT_PCT:-85}"
JOURNAL_KEEP="${FM_JOURNAL_KEEP:-200M}"
CACHE_SAFE_SUBDIRS="${FM_CACHE_SAFE_SUBDIRS:-pip go-build pypoetry}"
DB_MARKER="$STATE/.disk-health-opencode-db"

log() { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }

if [ "$(uname)" = Darwin ]; then
  file_bytes() { stat -f %z "$1" 2>/dev/null || printf '%s\n' 0; }
else
  file_bytes() { stat -c %s "$1" 2>/dev/null || printf '%s\n' 0; }
fi

human_bytes() {
  awk -v b="$1" 'BEGIN{
    if (b < 0) { sign="-"; b=-b } else sign="";
    if (b < 1024)        printf "%s%dB",  sign, b;
    else if (b < 1048576)   printf "%s%.1fKB", sign, b/1024;
    else if (b < 1073741824) printf "%s%.1fMB", sign, b/1048576;
    else                 printf "%s%.2fGB", sign, b/1073741824;
  }'
}

# Human-readable size of a path ("3.2G"), "-" if absent, "?" if inaccessible.
size_of() {
  local path=$1
  [ -e "$path" ] || { printf '%s\n' "-"; return 0; }
  du -sh "$path" 2>/dev/null | cut -f1 || printf '%s\n' "?"
}

# Human-readable size of a root-owned path via passwordless sudo; "-" if absent.
size_of_sudo() {
  local path=$1
  [ -d "$path" ] || { printf '%s\n' "-"; return 0; }
  sudo -n du -sh "$path" 2>/dev/null | cut -f1 || printf '%s\n' "?"
}

# Disk usage percent (integer, no '%') on the filesystem holding $HOME.
disk_use_percent() {
  df -P "${HOME}" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5+0}'
}

# Detect a live opencode process. pgrep excludes its own pid; we additionally
# exclude this script's main pid so the marker/db strings in our own command line
# can never cause a false positive. Returns 0 (running) / 1 (idle).
opencode_running() {
  local matches pid
  matches=$(pgrep -f opencode 2>/dev/null || true)
  [ -n "$matches" ] || return 1
  for pid in $matches; do
    [ "$pid" != "$$" ] || continue
    return 0
  done
  return 1
}

usage() {
  sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# ---------------------------------------------------------------------------
# --check: read-only report
# ---------------------------------------------------------------------------
do_check() {
  local pct cur_bytes now prev_bytes prev_ts delta elapsed rate_bph
  log "Disk health check"
  log ""
  pct=$(disk_use_percent || printf '%s\n' 0)
  log "disk usage: ${pct}% on $HOME filesystem"
  df -hP "${HOME}" 2>/dev/null | awk 'NR==2 {printf "  %s  size %s  used %s  avail %s  (%s)\n", $1,$2,$3,$4,$5}' || true
  log ""
  log "Reclaimable targets (run --clean to reclaim):"
  log "  ~/.npm:             $(size_of "$HOME/.npm")"
  if command -v go >/dev/null 2>&1; then
    log "  ~/go/pkg/mod:       $(size_of "$HOME/go/pkg/mod")"
    log "  ~/.cache/go-build:  $(size_of "$HOME/.cache/go-build")"
  else
    log "  ~/go/pkg/mod:       - (go absent)"
  fi
  if [ -d /var/log/journal ]; then
    log "  /var/log/journal:   $(size_of_sudo /var/log/journal) (needs root)"
  else
    log "  /var/log/journal:   - (absent)"
  fi
  if command -v docker >/dev/null 2>&1; then
    log "  docker images:      $(docker images -q 2>/dev/null | wc -l | tr -d ' ') unused/total rows"
  else
    log "  docker images:      - (docker absent)"
  fi
  log "  ~/.cache:           $(size_of "$HOME/.cache") (preserves ms-playwright, *-pp-cli)"
  log ""
  log "opencode.db: $OPENCODE_DB"
  if [ -f "$OPENCODE_DB" ]; then
    log "  size:               $(size_of "$OPENCODE_DB")"
    # Growth vs prior check's marker (firstmate bookkeeping in state/).
    cur_bytes=$(file_bytes "$OPENCODE_DB")
    now=$(date +%s)
    prev_bytes=""
    prev_ts=""
    if [ -f "$DB_MARKER" ]; then
      { read -r prev_bytes prev_ts < "$DB_MARKER" 2>/dev/null || true; }
    fi
    if [ -n "${prev_bytes:-}" ] && [ -n "${prev_ts:-}" ]; then
      delta=$((cur_bytes - prev_bytes))
      elapsed=$((now - prev_ts))
      if [ "$elapsed" -gt 0 ]; then
        rate_bph=$(awk -v d="$delta" -v e="$elapsed" 'BEGIN{ printf "%d", (e>0)? d/e*3600 : 0 }')
        log "  growth:             $(human_bytes "$delta") over ${elapsed}s (~$(human_bytes "$rate_bph")/hr)"
      fi
    else
      log "  growth:             (no prior sample; reports after the next check)"
    fi
    if opencode_running; then
      log "  VACUUM:             pending (opencode is running; run when the fleet is idle)"
    else
      log "  VACUUM:             safe to run now (opencode not running)"
    fi
    # Record this sample so the next check can report growth. This is the only
    # write in --check and it lands in firstmate's own state/, not the system.
    if [ -d "$STATE" ]; then
      printf '%s\t%s\n' "$cur_bytes" "$now" > "$DB_MARKER" 2>/dev/null || true
    fi
  else
    log "  size:               - (db not found)"
    log "  VACUUM:             n/a (db not found)"
  fi
  # Alert when usage exceeds the threshold.
  if [ "${pct:-0}" -gt "$ALERT_PCT" ] 2>/dev/null; then
    log ""
    log "ALERT: disk usage ${pct}% exceeds threshold ${ALERT_PCT}% -- consider: bin/fm-disk-health.sh --clean"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# --clean: safe reclaims
# ---------------------------------------------------------------------------
reclaim_npm() {
  [ "${FM_DISK_SKIP_NPM:-0}" = 1 ] && { log "npm:     skipped (FM_DISK_SKIP_NPM=1)"; return 0; }
  command -v npm >/dev/null 2>&1 || { log "npm:     skipped (npm absent)"; return 0; }
  local before after
  before=$(size_of "$HOME/.npm")
  log "npm:     cleaning ~/.npm ($before) ..."
  if npm cache clean --force >/dev/null 2>&1; then
    after=$(size_of "$HOME/.npm")
    log "npm:     done ($before -> $after)"
  else
    log "npm:     skipped (npm cache clean failed)"
  fi
  return 0
}

reclaim_go() {
  [ "${FM_DISK_SKIP_GO:-0}" = 1 ] && { log "go:      skipped (FM_DISK_SKIP_GO=1)"; return 0; }
  command -v go >/dev/null 2>&1 || { log "go:      skipped (go absent)"; return 0; }
  if pgrep -f 'go build' >/dev/null 2>&1 || pgrep -f 'go test' >/dev/null 2>&1; then
    log "go:      skipped (a go build/test appears in flight)"
    return 0
  fi
  local before_mod before_cache
  before_mod=$(size_of "$HOME/go/pkg/mod")
  before_cache=$(size_of "$HOME/.cache/go-build")
  log "go:      cleaning modcache ($before_mod) and build cache ($before_cache) ..."
  go clean -modcache >/dev/null 2>&1 || { log "go:      skipped (go clean -modcache failed)"; return 0; }
  go clean -cache >/dev/null 2>&1 || true
  log "go:      done"
  return 0
}

reclaim_journal() {
  [ "${FM_DISK_SKIP_JOURNAL:-0}" = 1 ] && { log "journal: skipped (FM_DISK_SKIP_JOURNAL=1)"; return 0; }
  command -v journalctl >/dev/null 2>&1 || { log "journal: skipped (journalctl absent)"; return 0; }
  [ -d /var/log/journal ] || { log "journal: skipped (no /var/log/journal)"; return 0; }
  if ! sudo -n true 2>/dev/null; then
    log "journal: skipped (no passwordless sudo); run manually: sudo journalctl --vacuum-size=${JOURNAL_KEEP}"
    return 0
  fi
  log "journal: vacuuming to ${JOURNAL_KEEP} ..."
  if sudo -n journalctl --vacuum-size="$JOURNAL_KEEP" >/dev/null 2>&1; then
    log "journal: done"
  else
    log "journal: skipped (journalctl vacuum failed)"
  fi
  return 0
}

reclaim_docker() {
  [ "${FM_DISK_SKIP_DOCKER:-0}" = 1 ] && { log "docker:  skipped (FM_DISK_SKIP_DOCKER=1)"; return 0; }
  command -v docker >/dev/null 2>&1 || { log "docker:  skipped (docker absent)"; return 0; }
  if ! docker info >/dev/null 2>&1; then
    log "docker:  skipped (daemon not reachable)"
    return 0
  fi
  local running
  running=$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')
  running=${running:-0}
  if [ "$running" -gt 0 ]; then
    log "docker:  skipped ($running container(s) running; not pruning)"
    return 0
  fi
  local before after
  before=$(docker system df 2>/dev/null | awk 'NR==2{print $4}' || printf '%s\n' "?")
  log "docker:  pruning unused images (docker system prune -af) ..."
  if docker system prune -af >/dev/null 2>&1; then
    after=$(docker system df 2>/dev/null | awk 'NR==2{print $4}' || printf '%s\n' "?")
    log "docker:  done (images size: $before -> $after)"
  else
    log "docker:  skipped (docker system prune failed)"
  fi
  return 0
}

reclaim_cache() {
  [ "${FM_DISK_SKIP_CACHE:-0}" = 1 ] && { log "cache:   skipped (FM_DISK_SKIP_CACHE=1)"; return 0; }
  local cache_dir="$HOME/.cache" sub before removed="" d
  [ -d "$cache_dir" ] || { log "cache:   skipped (no ~/.cache)"; return 0; }
  for sub in $CACHE_SAFE_SUBDIRS; do
    # Protected caches are never removed, even if misconfigured into the list.
    case "$sub" in
      ms-playwright|*-pp-cli) continue ;;
    esac
    [ -d "$cache_dir/$sub" ] || continue
    before=$(size_of "$cache_dir/$sub")
    if rm -rf -- "${cache_dir:?}/$sub" 2>/dev/null; then
      log "cache:   cleared ~/.cache/$sub ($before)"
      removed="$removed $sub"
    else
      log "cache:   skipped ~/.cache/$sub (remove failed)"
    fi
  done
  # Confirm protected caches were left intact.
  if [ -d "$cache_dir/ms-playwright" ]; then
    log "cache:   preserved ~/.cache/ms-playwright"
  fi
  for d in "$cache_dir"/*-pp-cli; do
    [ -e "$d" ] || continue
    log "cache:   preserved ~/.cache/$(basename "$d")"
  done
  [ -n "$removed" ] || log "cache:   nothing to clear (safe subdirs: $CACHE_SAFE_SUBDIRS)"
  return 0
}

# Shared VACUUM; caller guarantees opencode is idle and sqlite3 is present.
vacuum_db() {
  if [ ! -f "$OPENCODE_DB" ]; then
    warn "VACUUM:  skipped (db not found at $OPENCODE_DB)"
    return 0
  fi
  local before after
  before=$(file_bytes "$OPENCODE_DB")
  log "VACUUM:  $(size_of "$OPENCODE_DB") (~$(human_bytes "$before")); needs temporary free space ..."
  if sqlite3 "$OPENCODE_DB" 'VACUUM;' 2>/dev/null; then
    after=$(file_bytes "$OPENCODE_DB")
    log "VACUUM:  done ($(human_bytes "$before") -> $(human_bytes "$after"); reclaimed $(human_bytes $((before - after))))"
  else
    warn "VACUUM:  failed (sqlite3 returned non-zero); db untouched"
  fi
  return 0
}

opencode_db_advise() {
  log "opencode.db:"
  if [ ! -f "$OPENCODE_DB" ]; then
    log "  - (db not found at $OPENCODE_DB)"
    return 0
  fi
  log "  size: $(size_of "$OPENCODE_DB")"
  if opencode_running; then
    log "  VACUUM: pending (opencode is running); run --vacuum-opencode-db after all crewmates tear down"
  elif ! command -v sqlite3 >/dev/null 2>&1; then
    log "  VACUUM: available but sqlite3 absent; install sqlite3 then run: bin/fm-disk-health.sh --vacuum-opencode-db"
  else
    if [ "${FM_DISK_VACUUM_ON_CLEAN:-0}" = 1 ]; then
      log "  VACUUM: running (FM_DISK_VACUUM_ON_CLEAN=1, fleet idle) ..."
      vacuum_db
    else
      log "  VACUUM: available (fleet idle); run: bin/fm-disk-health.sh --vacuum-opencode-db"
    fi
  fi
  return 0
}

do_clean() {
  local before_pct after_pct
  log "Disk health clean"
  before_pct=$(disk_use_percent || printf '%s\n' 0)
  log "before: ${before_pct}% disk usage"
  log ""
  reclaim_npm
  reclaim_go
  reclaim_journal
  reclaim_docker
  reclaim_cache
  log ""
  opencode_db_advise
  log ""
  after_pct=$(disk_use_percent || printf '%s\n' 0)
  log "after: ${after_pct}% disk usage (was ${before_pct}%)"
  return 0
}

do_vacuum() {
  log "opencode.db VACUUM"
  if opencode_running; then
    warn "VACUUM:  skipped (opencode is running; a VACUUM would corrupt the live db)."
    warn "VACUUM:  run again when the fleet is idle (after all crewmates tear down)."
    return 0
  fi
  if ! command -v sqlite3 >/dev/null 2>&1; then
    warn "VACUUM:  skipped (sqlite3 absent). Install sqlite3, then re-run."
    return 0
  fi
  vacuum_db
  return 0
}

# Self-description for fm-plugin.sh (see PLUGINS.md). disk-health is REPORT-style:
# --check always prints a status report, so it is NOT natively silent-unless-wake
# and must be wrapped with a filter (e.g. --filter '^ALERT:') when used as a
# watcher check script.
do_describe() {
  printf 'name=disk-health\n'
  printf 'watches=disk usage, reclaimable caches, opencode.db growth\n'
  printf 'config_keys=FM_DISK_ALERT_PCT FM_JOURNAL_KEEP FM_CACHE_SAFE_SUBDIRS FM_DISK_SKIP_NPM FM_DISK_SKIP_GO FM_DISK_SKIP_JOURNAL FM_DISK_SKIP_DOCKER FM_DISK_SKIP_CACHE FM_DISK_VACUUM_ON_CLEAN FM_OPENCODE_DB\n'
  printf 'wake_contract=report\n'
  printf 'recommended_wrapper=--check --filter ^ALERT:\n'
}

case "${1:---check}" in
  --check) do_check ;;
  --clean) do_clean ;;
  --vacuum-opencode-db) do_vacuum ;;
  --describe) do_describe ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 1 ;;
esac
