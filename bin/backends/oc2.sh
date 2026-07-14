#!/usr/bin/env bash
# bin/backends/oc2.sh - the opencode2 HTTP-API session-provider adapter.
#
# EXPERIMENTAL, additive-only. Reached exclusively through `--harness opencode2`,
# which forces backend=oc2; it is NOT a runtime-auto-detected backend and is NOT
# independently selectable via `--backend oc2` (fm-spawn rejects the combo when
# the harness is not opencode2). v1 opencode stays the fleet default; this path
# never touches it.
#
# Unlike every pane-based backend (tmux/herdr/zellij/orca/cmux), an oc2 task has
# NO terminal pane. The crewmate is an opencode2 server session: launch creates a
# session and submits the brief as its initial prompt over the HTTP API; busy
# detection reads `v2.session.active`; the turn-end signal fires when a busy
# session goes idle; steer/interrupt/peek are all API calls. There is no
# send-text, no Enter keystroke, no pane capture, and no turn-end plugin.
#
# Verified against opencode-ai@0.0.0-next-202606270058 (binary `opencode2`,
# self-reports `opencode2 vlocal`) driving a real GLM-5.2 turn end-to-end
# (data/oc2-spike-v9/report.md). The REST operation IDs and SSE event type
# strings are the stable wire contract (the OpenAPI spec at /openapi.json),
# independent of the in-flight TypeScript client rename tracked in upstream
# #34359.
#
# Isolation model (spike §5): one shared opencode2 server per firstmate home,
# N sessions. The server is session-centric: concurrent sessions are isolated by
# sessionID (verified). The backing `opencode-next.db` lives in firstmate's
# isolated `state/.oc2/` XDG tree, NEVER in the live v1 `~/.local/share/opencode/`
# (spike §0 safety rail). v1's opencode.db is never opened, migrated, or written.
#
# Auth transfer (spike §1.2): v2 does not read v1's auth.json. The GLM API key
# is surfaced read-only as ZHIPU_API_KEY (extracted from the v1 credential, never
# modifying the original file). The v1 auth.json at the real data dir is opened
# READ-ONLY to extract the key; no write ever touches it.
#
# Binary safety rail (spike §0): `npm i -g opencode-ai@next` silently removes
# the global v1 `opencode` binary. firstmate obtains `opencode2` via an isolated
# npm prefix, never a global install. Set FM_OPENCODE2_BIN to the binary path, or
# place `opencode2` on PATH. The adapter never runs `npm i -g`.

OC2_DATA_HOME="${FM_HOME}/state/.oc2"
OC2_SERVER_FILE="${FM_HOME}/state/.oc2-server"
OC2_AUTH_FILE="${OC_OPENCODE_AUTH_FILE:-${HOME}/.local/share/opencode/auth.json}"

# Resolve the opencode2 binary path. FM_OPENCODE2_BIN wins; else `command -v`.
fm_backend_oc2_bin() {
  local bin
  bin="${FM_OPENCODE2_BIN:-}"
  if [ -n "$bin" ] && [ -x "$bin" ]; then
    printf '%s' "$bin"
    return 0
  fi
  bin=$(command -v opencode2 2>/dev/null || true)
  if [ -n "$bin" ] && [ -x "$bin" ]; then
    printf '%s' "$bin"
    return 0
  fi
  return 1
}

# Run an opencode2 CLI command with the isolated XDG dirs exported.
fm_backend_oc2_run() {
  local bin
  bin=$(fm_backend_oc2_bin) || { echo "error: opencode2 binary not found (set FM_OPENCODE2_BIN or put opencode2 on PATH)" >&2; return 1; }
  XDG_DATA_HOME="$OC2_DATA_HOME/data" \
  XDG_CONFIG_HOME="$OC2_DATA_HOME/config" \
  XDG_STATE_HOME="$OC2_DATA_HOME/state" \
  XDG_CACHE_HOME="$OC2_DATA_HOME/cache" \
  "$bin" "$@"
}

# Extract ZHIPU_API_KEY read-only from the v1 auth.json (spike §1.2).
# Prints the key to stdout; returns 1 if the file or key is absent.
fm_backend_oc2_zhipu_key() {
  [ -f "$OC2_AUTH_FILE" ] || return 1
  if command -v jq >/dev/null 2>&1; then
    jq -r '."zai-coding-plan".key // empty' "$OC2_AUTH_FILE" 2>/dev/null
  else
    python3 -c "import json,sys; d=json.load(open(sys.argv[1])); v=d.get('zai-coding-plan',{}); print(v.get('key','')) if isinstance(v,dict) else None" "$OC2_AUTH_FILE" 2>/dev/null
  fi
}

# Ensure the shared opencode2 server is running. Idempotent: if a server file
# exists and the server responds, reuses it. Otherwise starts a fresh managed
# server. Prints "url\tpassword" to stdout; writes the same to OC2_SERVER_FILE.
# Exports ZHIPU_API_KEY into the server's environment (read-only transfer).
fm_backend_oc2_server_ensure() {
  local url password

  if [ -f "$OC2_SERVER_FILE" ]; then
    url=$(grep '^url=' "$OC2_SERVER_FILE" | cut -d= -f2- || true)
    password=$(grep '^password=' "$OC2_SERVER_FILE" | cut -d= -f2- || true)
    if [ -n "$url" ] && [ -n "$password" ]; then
      if curl -sf -m 3 -u "x:${password}" "${url}/api/session/active" >/dev/null 2>&1; then
        printf '%s\t%s' "$url" "$password"
        return 0
      fi
    fi
  fi

  mkdir -p "$OC2_DATA_HOME/data" "$OC2_DATA_HOME/config" "$OC2_DATA_HOME/state" "$OC2_DATA_HOME/cache"

  local zhipu_key
  zhipu_key=$(fm_backend_oc2_zhipu_key 2>/dev/null || true)
  if [ -z "$zhipu_key" ]; then
    echo "error: cannot extract ZHIPU_API_KEY from $OC2_AUTH_FILE (opencode2 needs it for zai-coding-plan)" >&2
    return 1
  fi

  # `opencode2 service start` prints the server URL to stdout and writes the
  # password to config/opencode/service.json. The URL is the default
  # http://127.0.0.1:4096 unless a custom port/hostname was configured.
  # ZHIPU_API_KEY must be in the server's env at start time so zai-coding-plan
  # is available for session prompts (spike §1.2 auth transfer).
  url=$(ZHIPU_API_KEY="$zhipu_key" fm_backend_oc2_run service start 2>/dev/null | head -1 | tr -d '[:space:]' || true)
  local svc_json
  svc_json="$OC2_DATA_HOME/config/opencode/service.json"
  if [ ! -f "$svc_json" ]; then
    echo "error: opencode2 service start did not write $svc_json" >&2
    return 1
  fi
  if command -v jq >/dev/null 2>&1; then
    password=$(jq -r '.password // empty' "$svc_json" 2>/dev/null)
  else
    password=$(python3 -c "import json; d=json.load(open('$svc_json')); print(d.get('password',''))" 2>/dev/null)
  fi
  [ -n "$url" ] || url='http://127.0.0.1:4096'
  if [ -z "$password" ]; then
    echo "error: opencode2 service.json missing password" >&2
    return 1
  fi

  printf 'url=%s\npassword=%s\n' "$url" "$password" > "$OC2_SERVER_FILE"
  printf 'zhipu_key_present=yes\n' >> "$OC2_SERVER_FILE"
  printf '%s\t%s' "$url" "$password"
}

# Read the server URL + password from the persisted file.
fm_backend_oc2_server_info() {
  [ -f "$OC2_SERVER_FILE" ] || return 1
  local url password
  url=$(grep '^url=' "$OC2_SERVER_FILE" | cut -d= -f2- || true)
  password=$(grep '^password=' "$OC2_SERVER_FILE" | cut -d= -f2- || true)
  [ -n "$url" ] && [ -n "$password" ] || return 1
  printf '%s\t%s' "$url" "$password"
}

# Run `opencode2 api <args>` with the ZHIPU_API_KEY exported and the right XDG
# dirs. This is the authenticated CLI path (it reads service.json for Basic auth
# internally), so callers never handle the password.
fm_backend_oc2_api() {
  local zhipu_key
  zhipu_key=$(fm_backend_oc2_zhipu_key 2>/dev/null || true)
  if [ -n "$zhipu_key" ]; then
    ZHIPU_API_KEY="$zhipu_key" fm_backend_oc2_run api "$@"
  else
    fm_backend_oc2_run api "$@"
  fi
}

# Create a session. Args: <worktree-dir> <model-id> <provider-id> <variant>
# Prints the sessionID (ses_...) to stdout.
fm_backend_oc2_session_create() {
  local dir=$1 model_id=$2 provider=$3 variant=$4 body resp
  if command -v jq >/dev/null 2>&1; then
    if [ -n "$variant" ]; then
      body=$(jq -nc --arg m "$model_id" --arg p "$provider" --arg v "$variant" --arg d "$dir" \
        '{"agent":"build","model":{"id":$m,"providerID":$p,"variant":$v},"location":{"directory":$d}}')
    else
      body=$(jq -nc --arg m "$model_id" --arg p "$provider" --arg d "$dir" \
        '{"agent":"build","model":{"id":$m,"providerID":$p},"location":{"directory":$d}}')
    fi
  else
    if [ -n "$variant" ]; then
      body=$(python3 -c "import json,sys; print(json.dumps({'agent':'build','model':{'id':sys.argv[1],'providerID':sys.argv[2],'variant':sys.argv[3]},'location':{'directory':sys.argv[4]}}))" \
        "$model_id" "$provider" "$variant" "$dir")
    else
      body=$(python3 -c "import json,sys; print(json.dumps({'agent':'build','model':{'id':sys.argv[1],'providerID':sys.argv[2]},'location':{'directory':sys.argv[3]}}))" \
        "$model_id" "$provider" "$dir")
    fi
  fi
  resp=$(fm_backend_oc2_api v2.session.create -d "$body" 2>&1) || {
    echo "error: opencode2 session.create failed: $resp" >&2; return 1; }
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$resp" | jq -r '.data.id // empty' 2>/dev/null
  else
    printf '%s' "$resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('data',{}).get('id',''))" 2>/dev/null
  fi
}

# Submit a prompt to a session. Args: <sessionID> <text>
fm_backend_oc2_prompt() {
  local sid=$1 text=$2 body
  if command -v jq >/dev/null 2>&1; then
    body=$(jq -nc --arg t "$text" '{"prompt":{"text":$t}}')
  else
    body=$(python3 -c "import json,sys; print(json.dumps({'prompt':{'text':sys.argv[1]}}))" "$text")
  fi
  fm_backend_oc2_api v2.session.prompt --param "sessionID=$sid" -d "$body" >/dev/null 2>&1
}

# Submit a prompt from a file to a session. Args: <sessionID> <file-path>
fm_backend_oc2_prompt_file() {
  local sid=$1 file=$2 body
  if command -v jq >/dev/null 2>&1; then
    body=$(jq -nc --rawfile t "$file" '{"prompt":{"text":$t}}')
  else
    body=$(python3 -c "import json,sys; print(json.dumps({'prompt':{'text':open(sys.argv[1]).read()}}))" "$file")
  fi
  fm_backend_oc2_api v2.session.prompt --param "sessionID=$sid" -d "$body" >/dev/null 2>&1
}

# Query v2.session.active. Prints the raw JSON response.
fm_backend_oc2_active_raw() {
  fm_backend_oc2_api v2.session.active 2>/dev/null || printf '{"data":{}}'
}

# Check whether a specific session is busy (present in v2.session.active).
# Args: <sessionID>. Returns 0 (busy) or 1 (idle).
fm_backend_oc2_session_is_busy() {
  local sid=$1 active
  active=$(fm_backend_oc2_active_raw)
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$active" | jq -e --arg sid "$sid" '.data[$sid] != null' >/dev/null 2>&1
  else
    python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if sys.argv[1] in d.get('data',{}) else 1)" "$sid" >/dev/null 2>&1
  fi
}

# Interrupt a session. Args: <sessionID>
fm_backend_oc2_interrupt() {
  local sid=$1
  fm_backend_oc2_api v2.session.interrupt --param "sessionID=$sid" >/dev/null 2>&1 || true
}

# Check whether a session exists (is queryable). Args: <sessionID>
fm_backend_oc2_session_exists() {
  local sid=$1
  fm_backend_oc2_api v2.session.get --param "sessionID=$sid" >/dev/null 2>&1
}

# Read the last N messages from a session as plain text (for peek/capture).
# Args: <target> <lines>
# Message format (verified): user messages carry `text` directly; assistant
# messages carry a `content` array of `{type:"text", text:"..."}` items.
fm_backend_oc2_capture() {
  local target=$1 lines=$2 sid
  sid=${target#oc2:}
  [ "$sid" != "$target" ] || return 1
  local resp
  resp=$(fm_backend_oc2_api v2.session.messages --param "sessionID=$sid" 2>/dev/null || true)
  [ -n "$resp" ] || return 1
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$resp" | jq -r --argjson n "$lines" '
      (.data // []) | .[-($n):] |
      .[] |
      if .type == "assistant" then
        "[assistant] " + ((.content // []) | map(select(.type == "text") | .text) | join("\n"))
      elif .type == "user" then
        "[user] " + (.text // "")
      else
        "[\(.type // "unknown")] " + (.text // "")
      end
    ' 2>/dev/null
  else
    printf '%s' "$resp" | python3 -c "
import json,sys
d=json.load(sys.stdin)
msgs=(d.get('data') or [])[-$lines:]
for m in msgs:
    t=m.get('type','?')
    if t=='assistant':
        parts=[p.get('text','') for p in m.get('content',[]) if p.get('type')=='text']
        print(f'[assistant] ' + chr(10).join(parts))
    elif t=='user':
        print(f'[user] {m.get(\"text\",\"\")}')
    else:
        print(f'[{t}] {m.get(\"text\",\"\")}')
" 2>/dev/null
  fi
}

# Semantic busy state for the watcher's window_is_busy. Args: <target>
fm_backend_oc2_busy_state() {
  local target=$1 sid
  sid=${target#oc2:}
  [ "$sid" != "$target" ] || { printf 'unknown'; return 0; }
  if fm_backend_oc2_session_is_busy "$sid"; then
    printf 'busy'
  else
    printf 'idle'
  fi
}

# Send a prompt (steer). Args: <target> <text>
# Returns the submit verdict: "sent" on success.
fm_backend_oc2_send_text_submit() {
  local target=$1 text=$2
  local sid
  sid=${target#oc2:}
  [ "$sid" != "$target" ] || { printf 'send-failed'; return 1; }
  if fm_backend_oc2_prompt "$sid" "$text"; then
    printf 'sent'
  else
    printf 'send-failed'
  fi
}

# Send a named key. Only Escape (interrupt) is meaningful for oc2.
fm_backend_oc2_send_key() {
  local target=$1 key=$2 sid
  sid=${target#oc2:}
  [ "$sid" != "$target" ] || return 1
  case "$key" in
    Escape|C-c|c-c) fm_backend_oc2_interrupt "$sid" ;;
    *) return 0 ;;
  esac
}

# Kill (interrupt + leave the session to the server). Args: <target>
fm_backend_oc2_kill() {
  local target=$1 sid
  sid=${target#oc2:}
  [ "$sid" != "$target" ] || return 0
  fm_backend_oc2_interrupt "$sid"
}

# Target exists: is the session queryable? Args: <target>
fm_backend_oc2_target_ready() {
  local target=$1 sid
  sid=${target#oc2:}
  [ "$sid" != "$target" ] || return 1
  fm_backend_oc2_session_exists "$sid"
}

# Tool check: is the opencode2 binary available?
fm_backend_oc2_tool_check() {
  fm_backend_oc2_bin >/dev/null 2>&1
}
