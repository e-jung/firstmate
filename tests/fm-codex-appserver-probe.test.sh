#!/usr/bin/env bash
# tests/fm-codex-appserver-probe.test.sh - safety and protocol-shape tests for
# the experimental Codex app-server probe helper.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-codex-appserver-probe-tests)

make_fake_codex() {  # <dir> -> echoes fakebin
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/codex" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = "--version" ]; then
  echo "codex-cli 0.142.5-test"
  exit 0
fi
if [ "${1:-}" = "app-server" ] && [ "${2:-}" = "generate-json-schema" ]; then
  out=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --out) out=$2; shift 2 ;;
      *) shift ;;
    esac
  done
  [ -n "$out" ] || { echo "missing --out" >&2; exit 2; }
  mkdir -p "$out"
  cat > "$out/ClientRequest.json" <<'JSON'
{
  "oneOf": [
    {"properties":{"method":{"enum":["initialize"]}}},
    {"properties":{"method":{"enum":["thread/start"]}}},
    {"properties":{"method":{"enum":["thread/list"]}}},
    {"properties":{"method":{"enum":["thread/read"]}}},
    {"properties":{"method":{"enum":["thread/archive"]}}},
    {"properties":{"method":{"enum":["turn/start"]}}},
    {"properties":{"method":{"enum":["turn/steer"]}}},
    {"properties":{"method":{"enum":["turn/interrupt"]}}}
  ]
}
JSON
  exit 0
fi
if [ "${1:-}" = "app-server" ] && [ "${2:-}" = "--stdio" ]; then
  while IFS= read -r line; do
    case "$line" in
      *'"method":"initialize"'*) printf '{"id":1,"result":{"codexHome":"/tmp/fake-codex"}}\n' ;;
      *'"method":"thread/list"'*) printf '{"id":2,"result":{"threads":[]}}\n' ;;
      *'"method":"thread/start"'*) printf '{"id":3,"result":{"thread":{"id":"00000000-0000-4000-8000-000000000001"}}}\n' ;;
      *'"method":"thread/read"'*) printf '{"id":4,"result":{"thread":{"id":"00000000-0000-4000-8000-000000000001"},"turns":[]}}\n' ;;
      *'"method":"thread/archive"'*) printf '{"id":5,"result":{}}\n' ;;
      *) : ;;
    esac
  done
  exit 0
fi
echo "unexpected fake codex args: $*" >&2
exit 64
SH
  chmod +x "$fb/codex"
  printf '%s\n' "$fb"
}

test_default_is_dry_run() {
  local out
  out=$(bash "$ROOT/bin/fm-codex-appserver-probe.sh")
  assert_contains "$out" "mode: dry-run" "default invocation should be dry-run"
  assert_contains "$out" "no Codex thread created" "dry-run should state no thread is created"
  pass "fm-codex-appserver-probe: default invocation is safe dry-run"
}

test_refuses_unauthenticated_non_loopback_ws() {
  local out status
  set +e
  out=$(bash "$ROOT/bin/fm-codex-appserver-probe.sh" --live-handshake --listen ws://0.0.0.0:4500 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "non-loopback ws listener without auth should fail"
  assert_contains "$out" "refusing unauthenticated non-loopback WebSocket listener" \
    "unsafe ws refusal should explain the safety issue"
  pass "fm-codex-appserver-probe: refuses unauthenticated non-loopback WebSocket listener"
}

test_schema_generation_summarizes_required_methods() {
  local case_dir fb out schema_dir
  case_dir="$TMP_ROOT/schema"
  fb=$(make_fake_codex "$case_dir")
  schema_dir="$case_dir/schema-out"
  out=$(PATH="$fb:$PATH" bash "$ROOT/bin/fm-codex-appserver-probe.sh" --schema-dir "$schema_dir")
  assert_present "$schema_dir/ClientRequest.json" "schema generation should write ClientRequest.json"
  assert_contains "$out" "schema_required_lifecycle: present" \
    "schema summary should confirm lifecycle methods"
  assert_contains "$out" "schema_turn_methods: turn/interrupt,turn/start,turn/steer" \
    "schema summary should list turn methods"
  pass "fm-codex-appserver-probe: schema generation summarizes lifecycle methods"
}

test_live_stdio_probe_can_create_read_archive_thread() {
  local case_dir fb out
  case_dir="$TMP_ROOT/live"
  fb=$(make_fake_codex "$case_dir")
  out=$(PATH="$fb:$PATH" bash "$ROOT/bin/fm-codex-appserver-probe.sh" --live-handshake --create-thread)
  assert_contains "$out" "live_initialize: ok" "live probe should initialize"
  assert_contains "$out" "live_thread_list: ok count=0" "live probe should list threads"
  assert_contains "$out" "created_thread_id: 00000000-0000-4000-8000-000000000001" \
    "live probe should report created thread id"
  assert_contains "$out" "thread_read_after_create: ok" "live probe should read created thread"
  assert_contains "$out" "archived_created_thread: yes" "live probe should archive by default"
  pass "fm-codex-appserver-probe: live stdio probe drives create/read/archive protocol path"
}

test_default_is_dry_run
test_refuses_unauthenticated_non_loopback_ws
test_schema_generation_summarizes_required_methods
test_live_stdio_probe_can_create_read_archive_thread
