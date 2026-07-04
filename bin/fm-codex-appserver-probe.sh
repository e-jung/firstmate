#!/usr/bin/env bash
# fm-codex-appserver-probe.sh - opt-in Codex app-server probe for backend spikes.
#
# Default mode is a dry run: it prints the safe probe commands without starting
# Codex app-server or writing Codex thread state. Live modes use stdio by
# default, never a network listener.
set -u

usage() {
  cat <<'EOF'
usage: fm-codex-appserver-probe.sh [options]

Safe defaults:
  With no options this is a dry run. It does not start app-server, create
  threads, expose listeners, or touch project worktrees.

Options:
  --dry-run                 Print the probe plan only (default)
  --schema-dir DIR          Generate the installed app-server JSON schema bundle
                            into DIR and summarize lifecycle methods
  --experimental-schema     Include experimental schema methods/fields
  --live-handshake          Start app-server over stdio and run initialize +
                            thread/list only
  --create-thread           With the live stdio probe, create a thread in a temp
                            cwd and read it; archive is best-effort because a
                            no-turn thread may not have a rollout yet
  --keep-thread             Do not archive a created thread; prints codex:// link
  --cwd DIR                 cwd for --create-thread (default: fresh temp dir)
  --model MODEL             model override for --create-thread
  --listen URL              Transport to validate. Live probe supports stdio://
                            only; ws:// non-loopback requires auth flags.
  --ws-auth MODE            capability-token or signed-bearer-token
  --ws-token-file PATH      capability token file for ws auth
  --ws-token-sha256 HEX     capability token verifier for ws auth
  --ws-shared-secret-file PATH
                            signed bearer shared secret file for ws auth
  -h, --help                Show this help

Examples:
  fm-codex-appserver-probe.sh
  fm-codex-appserver-probe.sh --schema-dir /tmp/fm-codex-schema
  fm-codex-appserver-probe.sh --live-handshake
  fm-codex-appserver-probe.sh --live-handshake --create-thread --keep-thread
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

is_loopback_ws() {
  case "$1" in
    ws://127.*|ws://localhost:*|ws://[[]::1[]]:*) return 0 ;;
    *) return 1 ;;
  esac
}

has_ws_auth_material() {
  [ -n "$WS_AUTH" ] || return 1
  case "$WS_AUTH" in
    capability-token)
      [ -n "$WS_TOKEN_FILE$WS_TOKEN_SHA256" ]
      ;;
    signed-bearer-token)
      [ -n "$WS_SHARED_SECRET_FILE" ]
      ;;
    *)
      return 1
      ;;
  esac
}

summarize_schema() {
  local schema_dir=$1
  node - "$schema_dir" <<'NODE'
const fs = require("fs");
const path = require("path");
const dir = process.argv[2];
const clientRequest = path.join(dir, "ClientRequest.json");
if (!fs.existsSync(clientRequest)) {
  console.error(`error: schema bundle missing ${clientRequest}`);
  process.exit(1);
}
const schema = JSON.parse(fs.readFileSync(clientRequest, "utf8"));
const methods = [];
for (const variant of schema.oneOf || []) {
  const method = variant?.properties?.method?.enum?.[0];
  if (method) methods.push(method);
}
const required = [
  "initialize",
  "thread/start",
  "thread/list",
  "thread/read",
  "thread/archive",
  "turn/start",
  "turn/steer",
  "turn/interrupt",
];
const missing = required.filter((m) => !methods.includes(m));
console.log(`schema_dir: ${dir}`);
console.log(`schema_method_count: ${methods.length}`);
console.log(`schema_required_lifecycle: ${missing.length === 0 ? "present" : "missing " + missing.join(",")}`);
console.log(`schema_thread_methods: ${methods.filter((m) => m.startsWith("thread/")).sort().join(",")}`);
console.log(`schema_turn_methods: ${methods.filter((m) => m.startsWith("turn/")).sort().join(",")}`);
if (missing.length) process.exit(2);
NODE
}

run_live_stdio_probe() {
  local create_thread=$1 keep_thread=$2 cwd=$3 model=$4
  node - "$create_thread" "$keep_thread" "$cwd" "$model" <<'NODE'
const { spawn } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");
const readline = require("readline");

const createThread = process.argv[2] === "1";
const keepThread = process.argv[3] === "1";
let cwd = process.argv[4] || "";
const model = process.argv[5] || "";
let ownedTemp = "";

if (createThread && !cwd) {
  ownedTemp = fs.mkdtempSync(path.join(os.tmpdir(), "fm-codex-appserver-probe-"));
  cwd = ownedTemp;
}
if (createThread && !path.isAbsolute(cwd)) {
  console.error("error: --cwd must be absolute for --create-thread");
  process.exit(2);
}

const child = spawn("codex", ["app-server", "--stdio"], {
  stdio: ["pipe", "pipe", "pipe"],
});
const rl = readline.createInterface({ input: child.stdout });
const pending = new Map();
const notifications = {};
let nextId = 1;
let shuttingDown = false;

function send(method, params = {}) {
  const id = nextId++;
  child.stdin.write(`${JSON.stringify({ id, method, params })}\n`);
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject, method });
  });
}

function notify(method, params = {}) {
  child.stdin.write(`${JSON.stringify({ method, params })}\n`);
}

function finish(code) {
  if (shuttingDown) return;
  shuttingDown = true;
  try { child.stdin.end(); } catch (_) {}
  try { child.kill("SIGTERM"); } catch (_) {}
  if (ownedTemp) fs.rmSync(ownedTemp, { recursive: true, force: true });
  process.exitCode = code;
}

const timer = setTimeout(() => {
  console.error("error: timed out waiting for app-server response");
  finish(124);
}, 15000);

child.stderr.on("data", (buf) => process.stderr.write(buf));
child.on("error", (err) => {
  clearTimeout(timer);
  console.error(`error: failed to start codex app-server: ${err.message}`);
  finish(1);
});
child.on("exit", (code, signal) => {
  if (shuttingDown) return;
  clearTimeout(timer);
  for (const { reject, method } of pending.values()) {
    reject(new Error(`app-server exited before ${method} completed (code=${code}, signal=${signal})`));
  }
  if (ownedTemp) fs.rmSync(ownedTemp, { recursive: true, force: true });
  process.exit(code ?? 1);
});
rl.on("line", (line) => {
  let msg;
  try {
    msg = JSON.parse(line);
  } catch (err) {
    console.error(`error: invalid app-server JSON: ${err.message}: ${line}`);
    finish(1);
    return;
  }
  if (Object.prototype.hasOwnProperty.call(msg, "id")) {
    const p = pending.get(msg.id);
    if (!p) return;
    pending.delete(msg.id);
    if (msg.error) {
      p.reject(new Error(`${p.method}: ${msg.error.message || JSON.stringify(msg.error)}`));
    } else {
      p.resolve(msg.result || {});
    }
    return;
  }
  if (msg.method) notifications[msg.method] = (notifications[msg.method] || 0) + 1;
});

(async () => {
  try {
    const init = await send("initialize", {
      clientInfo: {
        name: "firstmate_appserver_probe",
        title: "Firstmate app-server probe",
        version: "0.1.0",
      },
      capabilities: { experimentalApi: true },
    });
    console.log("live_initialize: ok");
    console.log(`codex_home: ${init.codexHome || ""}`);
    notify("initialized", {});

    const list = await send("thread/list", {
      limit: 1,
      archived: false,
      useStateDbOnly: true,
    });
    const listed = Array.isArray(list.threads) ? list.threads.length : 0;
    console.log(`live_thread_list: ok count=${listed}`);

    if (createThread) {
      const params = {
        cwd,
        approvalPolicy: "on-request",
        sandbox: "read-only",
        threadSource: "firstmate_probe",
        ephemeral: false,
      };
      if (model) params.model = model;
      const started = await send("thread/start", params);
      const thread = started.thread || started;
      const threadId = thread.id || started.threadId || started.id;
      if (!threadId) throw new Error(`thread/start did not return a thread id: ${JSON.stringify(started)}`);
      console.log(`created_thread_id: ${threadId}`);
      console.log(`codex_thread_url: codex://threads/${encodeURIComponent(threadId)}`);
      try {
        await send("thread/read", { threadId, includeTurns: true });
        console.log("thread_read_after_create: ok includeTurns=true");
      } catch (_) {
        await send("thread/read", { threadId, includeTurns: false });
        console.log("thread_read_after_create: ok includeTurns=false");
      }
      if (keepThread) {
        console.log("archived_created_thread: no");
      } else {
        try {
          await send("thread/archive", { threadId });
          console.log("archived_created_thread: yes");
        } catch (err) {
          const archiveMsg = String(err.message || "").toLowerCase();
          if (archiveMsg.includes("rollout")) {
            console.log("archived_created_thread: unavailable-no-rollout");
          } else {
            console.log(`archived_created_thread: unavailable: ${err.message || "unknown error"}`);
          }
        }
      }
      console.log(`thread_cwd: ${cwd}`);
    }

    const summary = Object.entries(notifications)
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([k, v]) => `${k}=${v}`)
      .join(",");
    console.log(`notifications_seen: ${summary}`);
    clearTimeout(timer);
    finish(0);
  } catch (err) {
    clearTimeout(timer);
    console.error(`error: ${err.message}`);
    finish(1);
  }
})();
NODE
}

DRY_RUN=1
SCHEMA_DIR=
EXPERIMENTAL_SCHEMA=0
LIVE_HANDSHAKE=0
CREATE_THREAD=0
KEEP_THREAD=0
CWD_ARG=
MODEL_ARG=
LISTEN_URL="stdio://"
WS_AUTH=
WS_TOKEN_FILE=
WS_TOKEN_SHA256=
WS_SHARED_SECRET_FILE=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --schema-dir) [ "$#" -ge 2 ] || die "--schema-dir requires DIR"; SCHEMA_DIR=$2; DRY_RUN=0; shift 2 ;;
    --experimental-schema) EXPERIMENTAL_SCHEMA=1; shift ;;
    --live-handshake) LIVE_HANDSHAKE=1; DRY_RUN=0; shift ;;
    --create-thread) CREATE_THREAD=1; LIVE_HANDSHAKE=1; DRY_RUN=0; shift ;;
    --keep-thread) KEEP_THREAD=1; shift ;;
    --cwd) [ "$#" -ge 2 ] || die "--cwd requires DIR"; CWD_ARG=$2; shift 2 ;;
    --model) [ "$#" -ge 2 ] || die "--model requires MODEL"; MODEL_ARG=$2; shift 2 ;;
    --listen) [ "$#" -ge 2 ] || die "--listen requires URL"; LISTEN_URL=$2; shift 2 ;;
    --ws-auth) [ "$#" -ge 2 ] || die "--ws-auth requires MODE"; WS_AUTH=$2; shift 2 ;;
    --ws-token-file) [ "$#" -ge 2 ] || die "--ws-token-file requires PATH"; WS_TOKEN_FILE=$2; shift 2 ;;
    --ws-token-sha256) [ "$#" -ge 2 ] || die "--ws-token-sha256 requires HEX"; WS_TOKEN_SHA256=$2; shift 2 ;;
    --ws-shared-secret-file) [ "$#" -ge 2 ] || die "--ws-shared-secret-file requires PATH"; WS_SHARED_SECRET_FILE=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

case "$LISTEN_URL" in
  stdio://|stdio) ;;
  ws://*)
    if ! is_loopback_ws "$LISTEN_URL" && ! has_ws_auth_material; then
      die "refusing unauthenticated non-loopback WebSocket listener '$LISTEN_URL'"
    fi
    [ "$LIVE_HANDSHAKE" -eq 0 ] || die "live probe currently supports stdio:// only; use codex app-server directly for authenticated WebSocket testing"
    ;;
  unix://*) [ "$LIVE_HANDSHAKE" -eq 0 ] || die "live probe currently supports stdio:// only" ;;
  off) [ "$LIVE_HANDSHAKE" -eq 0 ] || die "cannot run live handshake with --listen off" ;;
  *) die "unsupported --listen URL: $LISTEN_URL" ;;
esac

if [ "$DRY_RUN" -eq 1 ]; then
  cat <<EOF
mode: dry-run
would_check: codex --help
would_generate_schema: codex app-server generate-json-schema --out <dir>
would_live_handshake: codex app-server --stdio
would_create_thread: no (pass --create-thread to create/read a throwaway no-turn thread)
safety: no listener opened; no Codex thread created; no project worktree modified
EOF
  exit 0
fi

command -v codex >/dev/null 2>&1 || die "codex CLI not found on PATH"
command -v node >/dev/null 2>&1 || die "node is required for JSON-RPC probing"

echo "codex_cli: $(codex --version 2>/dev/null || echo unknown)"

if [ -n "$SCHEMA_DIR" ]; then
  mkdir -p "$SCHEMA_DIR"
  schema_args=(app-server generate-json-schema --out "$SCHEMA_DIR")
  [ "$EXPERIMENTAL_SCHEMA" -eq 0 ] || schema_args+=(--experimental)
  schema_rc=0
  codex "${schema_args[@]}" || schema_rc=$?
  if [ "$schema_rc" -eq 0 ]; then
    summarize_schema "$SCHEMA_DIR" || schema_rc=$?
  fi
  if [ "$schema_rc" -ne 0 ]; then
    exit "$schema_rc"
  fi
fi

if [ "$LIVE_HANDSHAKE" -eq 1 ]; then
  run_live_stdio_probe "$CREATE_THREAD" "$KEEP_THREAD" "$CWD_ARG" "$MODEL_ARG"
fi
