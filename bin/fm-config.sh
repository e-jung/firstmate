#!/usr/bin/env bash
# fm-config.sh — view and edit fm-supervise-daemon tunables through one sourced
# config file (config/daemon.conf).
#
# The daemon sources config/daemon.conf at startup (see fm-supervise-daemon.sh).
# Precedence everywhere is: env var > config file > built-in default, because the
# file uses the `FM_X=${FM_X:-value}` form (an explicit env var wins). This CLI
# reads the BUILT-IN DEFAULTS by parsing the scripts that define them (it does
# not duplicate the values), reads the CURRENT value from env + the file, and
# `set` edits config/daemon.conf in place, preserving the inline comment.
#
# config/daemon.conf is local and gitignored (like config/crew-harness), so it is
# never committed; `set` creates it on first use.
#
# Usage:
#   fm-config.sh list                  every knob: name . current . default . description
#   fm-config.sh get <KEY>             resolve one knob (env > file > default)
#   fm-config.sh set <KEY> <VALUE>     write KEY into config/daemon.conf (creates it)
#   fm-config.sh -h|--help
#
# Overrides (testing):
#   FM_DAEMON_CONF=<path>   config file to read/write (default $FM_ROOT/config/daemon.conf)
#   FM_ROOT_OVERRIDE=<path> canonical firstmate root (default: parent of this script)
set -euo pipefail

CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$CONFIG_DIR/.." && pwd)}"
DAEMON="$FM_ROOT/bin/fm-supervise-daemon.sh"
WATCH="$FM_ROOT/bin/fm-watch.sh"
DISK="$FM_ROOT/bin/fm-disk-health.sh"
CONF="${FM_DAEMON_CONF:-$FM_ROOT/config/daemon.conf}"

# The knob registry: name + one-line description. Default VALUES are parsed from
# the scripts above (see default_for), never duplicated here. Order is the
# display/sort order. Each line: "KEY<TAB>description".
REGISTRY=(
$'FM_BUSY_REGEX\tOR-ed busy signatures (mirror fm-watch.sh); claude/codex/opencode/pi footers'
$'FM_CHECK_INTERVAL\tseconds between state/*.check.sh sweeps (read by fm-watch.sh)'
$'FM_CHECK_TIMEOUT\tseconds allowed per state/*.check.sh before it is killed (fm-watch.sh)'
$'FM_COMPOSER_IDLE_RE\tregex matching an empty composer line (idle prompt); non-match means pending input'
$'FM_DISK_ALERT_PCT\tdisk usage percent that triggers a disk-health ALERT line (fm-disk-health.sh)'
$'FM_ESCALATE_BATCH_SECS\tseconds to buffer escalations before flushing one digest; 0 = immediate'
$'FM_GH_CONTRIBUTOR\tGitHub login whose open PRs are watched (default: authenticated gh user)'
$'FM_HEARTBEAT_SCAN_SECS\tcadence (s) for the catch-all captain-relevant status scan'
$'FM_INJECT_SKIP\t|-separated wake kinds force-self-handled (prefix match); empty disables'
$'FM_STALE_ESCALATE_SECS\tidle seconds before a stale crewmate pane escalates as a possible wedge'
)

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# Strip one surrounding quote pair from a value (if present).
_strip_quotes() {  # <value> -> prints unquoted
  local v=$1
  case "$v" in
    \'*\') v=${v#\'}; v=${v%\'} ;;
    \"*\") v=${v#\"}; v=${v%\"} ;;
  esac
  printf '%s' "$v"
}

# Extract KEY's value from $CONF (unquoted). Empty if KEY is absent or file missing.
# A "set" line has the shape:  FM_KEY=${FM_KEY:-VALUE}  # comment
file_value() {  # <KEY>
  local key=$1 line rest
  [ -f "$CONF" ] || return 0
  line=$(grep -E "^${key}=" "$CONF" 2>/dev/null | head -1) || true
  [ -n "$line" ] || return 0
  # Drop the "FM_KEY=${FM_KEY:-" prefix, then cut at the first '}'.
  rest=${line#"${key}=\${${key}:-"}
  _strip_quotes "${rest%%\}*}"
}

# Parse the built-in default for KEY from the script that defines it. Prints
# "(none)" when the knob has no static default (e.g. FM_GH_CONTRIBUTOR).
default_for() {  # <KEY>
  local key=$1 short def val
  short=${key#FM_}
  # 1. A "<SHORT>_DEFAULT=<val>" constant in the daemon.
  def=$(grep -E "^${short}_DEFAULT=" "$DAEMON" 2>/dev/null | head -1) || true
  if [ -n "$def" ]; then
    _strip_quotes "${def#*=}"; return
  fi
  # 2. An inline "FM_<KEY>:-<val>" default in fm-watch.sh / fm-disk-health.sh.
  def=$(grep -E "${key}:-" "$WATCH" "$DISK" 2>/dev/null | head -1) || true
  if [ -n "$def" ]; then
    val=${def#*"${key}:-"}       # after "FM_KEY:-"
    val=${val%%\}*}              # up to the first '}'
    _strip_quotes "$val"; return
  fi
  printf '(none)'
}

# Resolve the CURRENT value: env (set & non-empty) > config file > default.
current_for() {  # <KEY>
  local key=$1 fv
  if [ -n "${!key+x}" ] && [ -n "${!key:-}" ]; then
    printf '%s' "${!key}"
    return
  fi
  fv=$(file_value "$key")
  if [ -n "$fv" ]; then
    printf '%s' "$fv"
    return
  fi
  default_for "$key"
}

desc_for() {  # <KEY>
  local entry
  for entry in "${REGISTRY[@]}"; do
    if [ "${entry%%$'\t'*}" = "$1" ]; then
      printf '%s' "${entry#*$'\t'}"
      return
    fi
  done
  printf '(no description)'
}

is_known_key() {  # <KEY>
  local entry
  for entry in "${REGISTRY[@]}"; do
    [ "${entry%%$'\t'*}" = "$1" ] && return 0
  done
  return 1
}

# Escape a value for single-quoting: each ' becomes '\'' (close, escaped, reopen).
_sq() { printf '%s' "${1//\'/\'\\\'\'}"; }

# Quote a value for embedding as ${FM_X:-VALUE} so it round-trips when sourced.
# Simple tokens stay bare; anything with spaces/special chars is single-quoted.
quote_val() {  # <value>
  local v=$1
  [ -n "$v" ] || return 0
  case "$v" in
    *[!A-Za-z0-9_./:@,+=-]*) printf "'%s'" "$(_sq "$v")" ;;
    *) printf '%s' "$v" ;;
  esac
}

# Create config/daemon.conf with every documented knob (defaults parsed live),
# unless it already exists.
bootstrap_conf() {
  [ -f "$CONF" ] && return 0
  local dir entry key desc def quoted
  dir=$(dirname "$CONF")
  mkdir -p "$dir"
  {
    printf '# fm-supervise-daemon tunables. Sourced at startup.\n'
    printf '# Precedence: env var > this file > built-in default (the \x24{FM_X:-value} form).\n'
    printf '# Local + gitignored; managed by bin/fm-config.sh. See PLUGINS.md.\n'
    printf '\n'
    for entry in "${REGISTRY[@]}"; do
      key=${entry%%$'\t'*}
      desc=${entry#*$'\t'}
      def=$(default_for "$key")
      [ "$def" = "(none)" ] && def=""   # no static default -> leave empty when sourced
      quoted=$(quote_val "$def")
      printf '%s=\x24{%s:-%s}  # %s\n' "$key" "$key" "$quoted" "$desc"
    done
  } > "$CONF"
}

cmd_list() {
  local entry key cur def desc
  printf 'NAME · CURRENT · DEFAULT · DESCRIPTION\n'
  for entry in "${REGISTRY[@]}"; do
    key=${entry%%$'\t'*}
    desc=${entry#*$'\t'}
    cur=$(current_for "$key")
    def=$(default_for "$key")
    printf '%s · %s · %s · %s\n' "$key" "$cur" "$def" "$desc"
  done
}

cmd_get() {  # <KEY>
  local key=$1
  is_known_key "$key" || die "unknown knob '$key' (see: $0 list)"
  current_for "$key"
  printf '\n'
}

cmd_set() {  # <KEY> <VALUE>
  local key=$1 val=$2
  is_known_key "$key" || die "unknown knob '$key' (see: $0 list)"
  local dir quoted desc tmp found=0 line comment
  dir=$(dirname "$CONF")
  mkdir -p "$dir"
  bootstrap_conf
  quoted=$(quote_val "$val")
  desc=$(desc_for "$key")
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-config.XXXXXX")
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "${line%%=*}" = "$key" ]; then
      found=1
      # Preserve an existing trailing "  # comment"; else use the canonical one.
      comment=$(printf '%s' "$line" | sed -n 's/^.*  # \(.*\)$/  # \1/p')
      [ -n "$comment" ] || comment="  # $desc"
      printf '%s=\x24{%s:-%s}%s\n' "$key" "$key" "$quoted" "$comment"
    else
      printf '%s\n' "$line"
    fi
  done < "$CONF" > "$tmp"
  if [ "$found" -eq 0 ]; then
    printf '%s=\x24{%s:-%s}  # %s\n' "$key" "$key" "$quoted" "$desc" >> "$tmp"
  fi
  mv "$tmp" "$CONF"
  printf '%s=%s (written to %s)\n' "$key" "$val" "$CONF"
}

usage() {
  sed -n '2,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

main() {
  case "${1:-}" in
    list) cmd_list ;;
    get)
      [ $# -ge 2 ] || die "usage: $0 get <KEY>"
      cmd_get "$2" ;;
    set)
      [ $# -ge 3 ] || die "usage: $0 set <KEY> <VALUE>"
      cmd_set "$2" "$3" ;;
    -h|--help) usage; exit 0 ;;
    "") echo "usage: $0 {list|get|set}" >&2; exit 2 ;;
    *) die "unknown command '$1' (list|get|set)" ;;
  esac
}

main "$@"
