#!/usr/bin/env bash
# Emit deterministic harness-native todo rows from firstmate's backlog.
# Usage: fm-todos.sh [--json] [--file <backlog.md>]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
BACKLOG="${FM_BACKLOG_FILE:-$DATA/backlog.md}"
OUTPUT=tsv

usage() {
  cat >&2 <<'EOF'
Usage: fm-todos.sh [--json] [--file <backlog.md>]

Print one current fleet-work item per line:
  <state>\t<priority>\t<id>\t<one-line>

States come from data/backlog.md:
  ## In flight -> in_progress high
  ## Queued    -> pending     medium
EOF
}

json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\t'/\\t}
  s=${s//$'\r'/\\r}
  s=${s//$'\n'/\\n}
  printf '%s' "$s"
}

json_started=false

emit_row() {
  local state=$1 priority=$2 id=$3 one_line=$4
  if [ "$OUTPUT" = json ]; then
    if [ "$json_started" = true ]; then
      printf ','
    fi
    json_started=true
    printf '{"state":"%s","priority":"%s","id":"%s","one_line":"%s"}' \
      "$(json_escape "$state")" \
      "$(json_escape "$priority")" \
      "$(json_escape "$id")" \
      "$(json_escape "$one_line")"
  else
    printf '%s\t%s\t%s\t%s\n' "$state" "$priority" "$id" "$one_line"
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --json)
      OUTPUT=json
      ;;
    --file)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      BACKLOG=$2
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
  shift
done

if [ "$OUTPUT" = json ]; then
  printf '['
fi

if [ -f "$BACKLOG" ]; then
  section=
  checkbox_re='^-[[:space:]]+\[[^]]+\][[:space:]]+([^[:space:]]+)[[:space:]]+-[[:space:]]*(.*)$'
  bold_re='^-[[:space:]]+\*\*([^*]+)\*\*[[:space:]]+-[[:space:]]*(.*)$'
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ $line =~ ^##[[:space:]]+In[[:space:]]+flight[[:space:]]*$ ]]; then
      section=in_flight
      continue
    fi
    if [[ $line =~ ^##[[:space:]]+Queued[[:space:]]*$ ]]; then
      section=queued
      continue
    fi
    if [[ $line =~ ^##[[:space:]]+ ]]; then
      section=
      continue
    fi

    case "$section" in
      in_flight)
        state=in_progress
        priority=high
        ;;
      queued)
        state=pending
        priority=medium
        ;;
      *)
        continue
        ;;
    esac

    if [[ $line =~ $checkbox_re ]]; then
      emit_row "$state" "$priority" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    elif [[ $line =~ $bold_re ]]; then
      emit_row "$state" "$priority" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    fi
  done < "$BACKLOG"
fi

if [ "$OUTPUT" = json ]; then
  printf ']\n'
fi
