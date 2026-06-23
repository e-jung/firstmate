#!/usr/bin/env bash
# fm-plugin.sh — manage event-source plugins for the supervision watcher.
#
# fm-watch.sh sweeps state/*.check.sh every FM_CHECK_INTERVAL and treats any
# stdout as a `check` wake (one line per wake-worthy event). The contract every
# check script must honor is SILENT-UNLESS-WAKE: print one line per event, print
# NOTHING when there is nothing to escalate, and finish under FM_CHECK_TIMEOUT.
#
# Hand-writing a wrapper is error-prone. The classic flood: a report-style
# script (e.g. fm-disk-health.sh --check, which always prints a status report)
# wrapped naively as state/*.check.sh makes the watcher read the whole report as
# ~17 events every cycle and floods escalations. This CLI generates the wrapper
# CORRECTLY and lints the contract, so correctness comes from tooling, not from
# the author re-reading docs.
#
# Two safe paths when adding a plugin (see PLUGINS.md):
#   * Report-style script (always prints)  -> use --filter REGEX so only
#     wake-worthy lines survive:  add <script> --check --filter '^ALERT:'
#   * Natively silent-unless-wake script   -> run it raw (no --filter); `add`
#     validates it with `check` first and refuses to create a flooding wrapper.
#
# Usage:
#   fm-plugin.sh add <script> [--check|--once] [--filter REGEX] [--name NAME]
#   fm-plugin.sh list [--describe]
#   fm-plugin.sh check <script> [--check|--once] [--filter REGEX]
#   fm-plugin.sh disable <name>
#   fm-plugin.sh enable <name>
#   fm-plugin.sh -h|--help
#
# Self-describing plugins: a script run with --describe prints key=value lines
# (name=, watches=, config_keys=, wake_contract=, recommended_wrapper=).
# `list --describe` calls it. See PLUGINS.md.
#
# Overrides (testing):
#   FM_STATE_OVERRIDE=<path>  state dir holding *.check.sh (default $FM_HOME/state)
#   FM_ROOT_OVERRIDE=<path>   canonical firstmate root
set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$PLUGIN_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DISABLED="$STATE/.disabled"
CHECK_TIMEOUT="${FM_CHECK_TIMEOUT:-30}"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# Resolve a possibly-relative path to an absolute one.
_abs() {  # <path>
  local p=$1 d
  case "$p" in
    /*) printf '%s' "$p" ;;
    *)
      if d=$(cd "$p" 2>/dev/null && pwd); then
        printf '%s' "$d"
      else
        d=$(cd "$(dirname "$p")" 2>/dev/null && pwd)
        printf '%s/%s' "$d" "$(basename "$p")"
      fi ;;
  esac
}

# Escape a value for single-quoting: each ' becomes '\'' .
_sq() { printf '%s' "${1//\'/\'\\\'\'}"; }

# Default plugin name from a script path: strip dir, .sh, and a leading fm-.
_name_from_script() {  # <path>
  local b
  b=$(basename "$1"); b=${b%.sh}; b=${b#fm-}
  printf '%s' "$b"
}

# Whether a script supports the --describe convention (prints a name= line).
_supports_describe() {  # <abs-script>
  local out
  out=$("$1" --describe 2>/dev/null || true)
  printf '%s' "$out" | grep -q '^name='
}

# ---------------------------------------------------------------------------
# check: contract lint — run against a no-event fixture and assert SILENT.
# ---------------------------------------------------------------------------
# Fixture: a temp state dir with nothing in it. Plugins that respect
# FM_STATE_OVERRIDE see no events and stay silent; a report-style script (which
# ignores state and always prints) is exposed as a flood risk.
cmd_check() {  # <script> [--check|--once] [--filter REGEX]
  local script=$1; shift
  [ -n "$script" ] || die "check: missing <script>"
  [ -f "$script" ] || die "check: script not found: $script"
  local mode="" filter=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --check) mode="--check" ;;
      --once)  mode="--once" ;;
      --filter) [ $# -ge 2 ] || die "check: --filter needs a REGEX"; filter=$2; shift ;;
      *) die "check: unknown option: $1" ;;
    esac
    shift || true
  done
  script=$(_abs "$script")

  local runner=()
  if command -v timeout >/dev/null 2>&1; then runner=(timeout "$CHECK_TIMEOUT");
  elif command -v gtimeout >/dev/null 2>&1; then runner=(gtimeout "$CHECK_TIMEOUT");
  else runner=(); fi

  local fixture out rc
  fixture=$(mktemp -d "${TMPDIR:-/tmp}/fm-plugin-check.XXXXXX")
  mkdir -p "$fixture"
  local -a argv=("$script")
  [ "$mode" = "--check" ] && argv+=(--check)
  [ "$mode" = "--once" ] && argv+=(--once)

  rc=0
  if [ "${#runner[@]}" -gt 0 ]; then
    out=$(FM_STATE_OVERRIDE="$fixture" FM_HOME="$fixture" "${runner[@]}" "${argv[@]}" 2>/dev/null) || rc=$?
  else
    out=$(FM_STATE_OVERRIDE="$fixture" FM_HOME="$fixture" "${argv[@]}" 2>/dev/null) || rc=$?
  fi
  rm -rf "$fixture"

  if [ -n "$filter" ]; then
    out=$(printf '%s' "$out" | grep -E -- "$filter" 2>/dev/null || true)
  fi

  if [ "$rc" -eq 124 ]; then
    printf 'FAIL: %s exceeded FM_CHECK_TIMEOUT (%ss) on a no-event fixture\n' "$script" "$CHECK_TIMEOUT" >&2
    return 1
  fi
  if [ -n "$out" ]; then
    printf 'FAIL: %s is not silent-unless-wake (printed on a no-event fixture):\n' "$script" >&2
    printf '%s\n' "$out" | head -5 >&2
    printf '\nIf this is a report-style script, wrap it with --filter REGEX.\n' >&2
    return 1
  fi
  printf 'OK: %s is silent-unless-wake on a no-event fixture\n' "$script"
}

# ---------------------------------------------------------------------------
# add: generate the state/<name>.check.sh wrapper correctly.
# ---------------------------------------------------------------------------
cmd_add() {  # <script> [--check|--once] [--filter REGEX] [--name NAME]
  local script=$1; shift
  [ -n "$script" ] || die "add: missing <script>"
  [ -f "$script" ] || die "add: script not found: $script"
  local mode="" filter="" name=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --check) mode="--check" ;;
      --once)  mode="--once" ;;
      --filter) [ $# -ge 2 ] || die "add: --filter needs a REGEX"; filter=$2; shift ;;
      --name) [ $# -ge 2 ] || die "add: --name needs a NAME"; name=$2; shift ;;
      *) die "add: unknown option: $1" ;;
    esac
    shift || true
  done
  script=$(_abs "$script")
  name=${name:-$(_name_from_script "$script")}

  # No filter => the script must be NATIVELY silent-unless-wake. Validate before
  # creating the wrapper; refuse to install a flooding plugin.
  if [ -z "$filter" ]; then
    local -a cargs=("$script")
    [ "$mode" = "--check" ] && cargs+=(--check)
    [ "$mode" = "--once" ] && cargs+=(--once)
    if ! cmd_check "${cargs[@]}" >/dev/null; then
      die "add: '$script' is not natively silent-unless-wake; wrap it with --filter REGEX (e.g. for report-style scripts)"
    fi
  fi

  mkdir -p "$STATE"
  local wrapper="$STATE/$name.check.sh"
  _write_wrapper "$wrapper" "$script" "$mode" "$filter"
  chmod +x "$wrapper"
  printf 'added %s -> %s\n' "$name" "$wrapper"
}

# Render the wrapper. Filter path pipes through grep; raw path execs the script.
_write_wrapper() {  # <wrapper> <abs-script> <mode> <filter>
  local wrapper=$1 script=$2 mode=$3 filter=$4
  local mode_label=${mode:-raw}
  local script_q invoc
  script_q="'$(_sq "$script")'"
  invoc=$script_q
  [ -n "$mode" ] && invoc="$script_q $mode"

  {
    printf '#!/usr/bin/env bash\n'
    printf '# Auto-generated by bin/fm-plugin.sh - DO NOT EDIT (regenerate via fm-plugin.sh add).\n'
    printf '# Source:   %s\n' "$script"
    printf '# Mode:     %s\n' "$mode_label"
    printf '# Filter:   %s\n' "${filter:-(none)}"
    printf '# Contract: silent-unless-wake - stdout is captured by fm-watch.sh as wake\n'
    printf '#           events (one line per event). Print NOTHING when there is nothing\n'
    printf '#           to escalate. Finish < FM_CHECK_TIMEOUT.\n'
    if [ -n "$filter" ]; then
      printf '# This source prints a REPORT, so only lines matching the filter are kept;\n'
      printf '# the rest is discarded so a report cannot flood wakes.\n'
      printf '%s 2>&1 | grep -E -- '\''%s'\'' || true\n' "$invoc" "$(_sq "$filter")"
    else
      printf '# This source is NATIVELY silent-unless-wake (validated by fm-plugin.sh check).\n'
      printf 'exec %s\n' "$invoc"
    fi
  } > "$wrapper"
}

# ---------------------------------------------------------------------------
# list: scan state/*.check.sh and report name . source . mode . filter.
# ---------------------------------------------------------------------------
cmd_list() {  # [--describe]
  local describe=0
  [ "${1:-}" = "--describe" ] && describe=1
  [ $# -gt 0 ] && [ "${1:-}" != "--describe" ] && die "list: unknown option: $1"

  local f name source mode filter line
  printf 'NAME · SOURCE · MODE · FILTER\n'
  shopt -s nullglob
  for f in "$STATE"/*.check.sh; do
    name=${f##*/}; name=${name%.check.sh}
    source=$(grep -m1 '^# Source:' "$f" 2>/dev/null | sed 's/^# Source:[[:space:]]*//') || true
    mode=$(grep -m1 '^# Mode:' "$f" 2>/dev/null | sed 's/^# Mode:[[:space:]]*//') || true
    filter=$(grep -m1 '^# Filter:' "$f" 2>/dev/null | sed 's/^# Filter:[[:space:]]*//') || true
    printf '%s · %s · %s · %s\n' "$name" "${source:-(unknown)}" "${mode:-(unknown)}" "${filter:-(none)}"
    if [ "$describe" -eq 1 ] && [ -n "$source" ] && _supports_describe "$source"; then
      while IFS= read -r line; do
        printf '    %s\n' "$line"
      done < <("$source" --describe 2>/dev/null)
    fi
  done
  shopt -u nullglob
}

# ---------------------------------------------------------------------------
# disable / enable: move the wrapper in/out of state/.disabled/.
# ---------------------------------------------------------------------------
cmd_disable() {  # <name>
  local name=$1 src="$STATE/$1.check.sh"
  [ -f "$src" ] || die "disable: no plugin '$name' (missing $src)"
  mkdir -p "$DISABLED"
  mv "$src" "$DISABLED/$name.check.sh"
  printf 'disabled %s\n' "$name"
}

cmd_enable() {  # <name>
  local name=$1 src="$DISABLED/$1.check.sh"
  [ -f "$src" ] || die "enable: no disabled plugin '$name' (missing $src)"
  mv "$src" "$STATE/$name.check.sh"
  printf 'enabled %s\n' "$name"
}

usage() {
  sed -n '2,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

main() {
  [ $# -ge 1 ] || { usage >&2; exit 2; }
  case "$1" in
    add)
      [ $# -ge 2 ] || die "usage: $0 add <script> [--check|--once] [--filter REGEX] [--name NAME]"
      shift; cmd_add "$@" ;;
    list)
      shift; cmd_list "$@" ;;
    check)
      [ $# -ge 2 ] || die "usage: $0 check <script> [--check|--once] [--filter REGEX]"
      shift; cmd_check "$@" ;;
    disable)
      [ $# -ge 2 ] || die "usage: $0 disable <name>"
      shift; cmd_disable "$1" ;;
    enable)
      [ $# -ge 2 ] || die "usage: $0 enable <name>"
      shift; cmd_enable "$1" ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown command '$1' (add|list|check|disable|enable)" ;;
  esac
}

main "$@"
