#!/usr/bin/env bash
# TAP-style behavior tests for bin/fm-disk-health.sh.
# Tools the script shells out to (npm, go, docker, journalctl, sudo, sqlite3,
# pgrep, df) are mocked via a fakebin on PATH; core GNU utils (du, awk, stat,
# cut, wc, tr, rm, date, uname) are symlinked into a minimal realbin so the runs
# are deterministic regardless of what is installed on the host.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/bin/fm-disk-health.sh"
TMP_ROOT=

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

cleanup() {
  [ -n "${TMP_ROOT:-}" ] && rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-disk-health-tests.XXXXXX")

link_real() {
  local dst=$1 t src
  # bash must be discoverable on PATH because every script shebang is
  # "#!/usr/bin/env bash", and env resolves bash via PATH.
  for t in bash du awk stat cut wc tr rm date uname head sleep mktemp dirname basename; do
    src=$(command -v "$t" 2>/dev/null || true)
    [ -n "$src" ] && ln -sf "$src" "$dst/$t"
  done
}

write_df() {
  cat > "$1/df" <<'SH'
#!/usr/bin/env bash
pct="${FM_FAKE_DF_PCT:-50}"
case "$*" in
  *-h*)
    printf 'Filesystem      Size  Used Avail Use%% Mounted on\n'
    printf '/dev/fake        45G   36G  9.0G  %s%% /home\n' "$pct"
    ;;
  *)
    printf 'Filesystem     1024-blocks    Used Available Capacity Mounted on\n'
    printf '/dev/fake        47185920  37748736 9437184 %s%% /home\n' "$pct"
    ;;
esac
SH
  chmod +x "$1/df"
}

write_pgrep() {
  cat > "$1/pgrep" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *opencode*)
    [ "${FM_FAKE_OPENCODE:-0}" = 1 ] && { printf '%s\n' 4242; exit 0; }
    exit 1 ;;
esac
exit 1
SH
  chmod +x "$1/pgrep"
}

write_tool() {
  local fb=$1 tool=$2
  case "$tool" in
    npm)
      cat > "$fb/npm" <<'SH'
#!/usr/bin/env bash
printf 'npm %s\n' "$*" >> "${FM_FAKE_LOG:-/dev/null}"
exit 0
SH
      ;;
    go)
      cat > "$fb/go" <<'SH'
#!/usr/bin/env bash
printf 'go %s\n' "$*" >> "${FM_FAKE_LOG:-/dev/null}"
exit 0
SH
      ;;
    journalctl)
      cat > "$fb/journalctl" <<'SH'
#!/usr/bin/env bash
printf 'journalctl %s\n' "$*" >> "${FM_FAKE_LOG:-/dev/null}"
exit 0
SH
      ;;
    sudo)
      cat > "$fb/sudo" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in -n) shift ;; esac
if [ "${1:-}" = "true" ]; then
  [ "${FM_FAKE_SUDO_NOPASS:-0}" = 1 ] && exit 1
  exit 0
fi
printf 'sudo %s\n' "$*" >> "${FM_FAKE_LOG:-/dev/null}"
exec "$@"
SH
      ;;
    docker)
      cat > "$fb/docker" <<'SH'
#!/usr/bin/env bash
LOG="${FM_FAKE_LOG:-/dev/null}"
case "${1:-}" in
  info) exit 0 ;;
  images) exit 0 ;;
  ps)
    if [ "${2:-}" = "-q" ] && [ "${FM_FAKE_DOCKER_RUNNING:-0}" = 1 ]; then
      printf '%s\n' c1
    fi
    exit 0 ;;
  system)
    case "${2:-}" in
      df) printf 'TYPE TOTAL ACTIVE SIZE RECLAIMABLE\nImages 3 1 9.6GB 8.0GB\n' ;;
      prune) printf 'docker system prune %s %s\n' "${3:-}" "${4:-}" >> "$LOG" ;;
    esac
    exit 0 ;;
esac
exit 0
SH
      ;;
    sqlite3)
      cat > "$fb/sqlite3" <<'SH'
#!/usr/bin/env bash
printf 'sqlite3 %s\n' "$*" >> "${FM_FAKE_LOG:-/dev/null}"
exit 0
SH
      ;;
  esac
  chmod +x "$fb/$tool"
}

# make_env <name> <tool>...  -> echoes the dir path. Always provides df + pgrep.
make_env() {
  local name=$1; shift
  local dir="$TMP_ROOT/$name" fb rb tool
  mkdir -p "$dir/home/.local/share/opencode" "$dir/state" "$dir/home/.cache" "$dir/home/.npm"
  : > "$dir/home/.local/share/opencode/opencode.db"
  printf 'npm-cache-bytes\n' > "$dir/home/.npm/placeholder"
  fb="$dir/fakebin"; rb="$dir/realbin"
  mkdir -p "$fb" "$rb"
  link_real "$rb"
  write_df "$fb"
  write_pgrep "$fb"
  for tool in "$@"; do write_tool "$fb" "$tool"; done
  printf '%s\n' "$dir"
}

run_disk() {
  local dir=$1; shift
  PATH="$dir/fakebin:$dir/realbin" \
  HOME="$dir/home" \
  FM_STATE_OVERRIDE="$dir/state" \
  FM_OPENCODE_DB="$dir/home/.local/share/opencode/opencode.db" \
  FM_DISK_ALERT_PCT="${FM_DISK_ALERT_PCT:-85}" \
  FM_FAKE_OPENCODE="${FM_FAKE_OPENCODE:-0}" \
  FM_FAKE_DOCKER_RUNNING="${FM_FAKE_DOCKER_RUNNING:-0}" \
  FM_FAKE_SUDO_NOPASS="${FM_FAKE_SUDO_NOPASS:-0}" \
  FM_FAKE_LOG="$dir/calls.log" \
  FM_FAKE_DF_PCT="${FM_FAKE_DF_PCT:-50}" \
  FM_DISK_SKIP_NPM="${FM_DISK_SKIP_NPM:-0}" \
  FM_DISK_SKIP_GO="${FM_DISK_SKIP_GO:-0}" \
  FM_DISK_SKIP_JOURNAL="${FM_DISK_SKIP_JOURNAL:-0}" \
  FM_DISK_SKIP_DOCKER="${FM_DISK_SKIP_DOCKER:-0}" \
  FM_DISK_SKIP_CACHE="${FM_DISK_SKIP_CACHE:-0}" \
  FM_DISK_VACUUM_ON_CLEAN="${FM_DISK_VACUUM_ON_CLEAN:-0}" \
  "$SCRIPT" "$@"
}

# 1. --check reports disk usage + opencode.db size, ALERTs above threshold, and
#    mutates nothing (no reclaim tool runs, protected caches intact).
test_check_reports_alerts_and_is_readonly() {
  local dir out
  dir=$(make_env check npm go journalctl sudo docker)
  mkdir -p "$dir/home/.cache/pip" "$dir/home/.cache/go-build" \
           "$dir/home/.cache/ms-playwright" "$dir/home/.cache/foo-pp-cli"
  # Above threshold -> ALERT.
  FM_FAKE_DF_PCT=90 run_disk "$dir" --check > "$dir/check.out" || fail "--check exited non-zero"
  out=$(cat "$dir/check.out")
  printf '%s\n' "$out" | grep -F 'disk usage: 90%' >/dev/null || fail "--check did not report disk usage"
  printf '%s\n' "$out" | grep -F 'opencode.db:' >/dev/null || fail "--check did not report opencode.db"
  printf '%s\n' "$out" | grep -E '^  size:' >/dev/null || fail "--check did not report db size"
  printf '%s\n' "$out" | grep -F 'ALERT: disk usage 90% exceeds threshold 85%' >/dev/null \
    || fail "--check did not ALERT above threshold"
  # Below threshold -> no ALERT.
  FM_FAKE_DF_PCT=40 run_disk "$dir" --check > "$dir/check2.out" || fail "--check (low) exited non-zero"
  if grep -F 'ALERT:' "$dir/check2.out" >/dev/null; then
    fail "--check raised ALERT below threshold"
  fi
  # Zero mutations: no reclaim tool was invoked and nothing was deleted.
  local log
  log=$(cat "$dir/calls.log" 2>/dev/null || true)
  printf '%s\n' "$log" | grep -F 'npm cache clean' >/dev/null && fail "--check ran npm cache clean"
  printf '%s\n' "$log" | grep -F 'go clean' >/dev/null && fail "--check ran go clean"
  printf '%s\n' "$log" | grep -F 'docker system prune' >/dev/null && fail "--check ran docker prune"
  printf '%s\n' "$log" | grep -F 'sqlite3' >/dev/null && fail "--check ran sqlite3 (VACUUM)"
  [ -d "$dir/home/.cache/ms-playwright" ] || fail "--check removed ms-playwright"
  [ -d "$dir/home/.cache/foo-pp-cli" ] || fail "--check removed foo-pp-cli"
  [ -d "$dir/home/.npm" ] || fail "--check removed ~/.npm"
  pass "--check reports usage + db size, alerts above threshold, mutates nothing"
}

# 2. --clean invokes every guarded reclaim, and skips cleanly when a tool absent.
test_clean_invokes_reclaims_and_skips_absent() {
  local dir out status
  dir=$(make_env clean npm go journalctl sudo docker)
  mkdir -p "$dir/home/.cache/pip" "$dir/home/.cache/go-build"
  status=0
  run_disk "$dir" --clean > "$dir/clean.out" 2>"$dir/clean.err" || status=$?
  [ "$status" -eq 0 ] || fail "--clean exited non-zero with all tools present"
  out=$(cat "$dir/clean.out")
  printf '%s\n' "$out" | grep -F 'before:' >/dev/null || fail "--clean did not print before summary"
  printf '%s\n' "$out" | grep -F 'after:' >/dev/null || fail "--clean did not print after summary"
  local log
  log=$(cat "$dir/calls.log")
  printf '%s\n' "$log" | grep -F 'npm cache clean --force' >/dev/null || fail "--clean did not run npm cache clean"
  printf '%s\n' "$log" | grep -F 'go clean -modcache' >/dev/null || fail "--clean did not run go clean -modcache"
  printf '%s\n' "$log" | grep -F 'go clean -cache' >/dev/null || fail "--clean did not run go clean -cache"
  printf '%s\n' "$log" | grep -F 'journalctl --vacuum-size=200M' >/dev/null || fail "--clean did not run journalctl vacuum"
  printf '%s\n' "$log" | grep -F 'docker system prune -af' >/dev/null || fail "--clean did not run docker system prune"

  # Absent tool -> skipped cleanly, exit 0, other reclaims still attempted.
  local dir2
  dir2=$(make_env clean-absent go journalctl sudo docker)  # no npm
  status=0
  run_disk "$dir2" --clean > "$dir2/clean.out" 2>"$dir2/clean.err" || status=$?
  [ "$status" -eq 0 ] || fail "--clean exited non-zero when a tool was absent"
  grep -F 'npm:     skipped (npm absent)' "$dir2/clean.out" >/dev/null \
    || fail "--clean did not report npm absent as skipped"
  pass "--clean invokes each guarded reclaim and skips cleanly when a tool is absent"
}

# 3. VACUUM guard: refuses while opencode is live; proceeds (mock sqlite3) idle.
test_vacuum_guard() {
  local dir out log status

  # Live -> refuses, no sqlite3 call.
  dir=$(make_env vacuum-live sqlite3)
  status=0
  FM_FAKE_OPENCODE=1 run_disk "$dir" --vacuum-opencode-db > "$dir/v.out" 2>&1 || status=$?
  out=$(cat "$dir/v.out")
  printf '%s\n' "$out" | grep -F 'skipped (opencode is running' >/dev/null \
    || fail "vacuum did not refuse while opencode is running"
  printf '%s\n' "$out" | grep -F 'fleet is idle' >/dev/null \
    || fail "vacuum did not print the idle-required message"
  log=$(cat "$dir/calls.log" 2>/dev/null || true)
  printf '%s\n' "$log" | grep -F 'sqlite3' >/dev/null && fail "vacuum ran sqlite3 while opencode was live"

  # Idle -> proceeds via mock sqlite3.
  dir=$(make_env vacuum-idle sqlite3)
  status=0
  FM_FAKE_OPENCODE=0 run_disk "$dir" --vacuum-opencode-db > "$dir/v.out" 2>&1 || status=$?
  [ "$status" -eq 0 ] || fail "vacuum exited non-zero when idle"
  out=$(cat "$dir/v.out")
  printf '%s\n' "$out" | grep -F 'VACUUM:  done' >/dev/null || fail "vacuum did not complete when idle"
  log=$(cat "$dir/calls.log")
  printf '%s\n' "$log" | grep -E 'sqlite3 [^ ]+ VACUUM;' >/dev/null \
    || fail "vacuum did not invoke sqlite3 VACUUM when idle"
  pass "VACUUM guard refuses while opencode is live and proceeds when idle"
}

# 4. docker prune is skipped when a container is running.
test_docker_prune_skipped_when_running() {
  local dir out log
  dir=$(make_env docker-running npm go journalctl sudo docker)
  status=0
  FM_FAKE_DOCKER_RUNNING=1 run_disk "$dir" --clean > "$dir/c.out" 2>&1 || status=$?
  [ "$status" -eq 0 ] || fail "--clean exited non-zero when a container was running"
  out=$(cat "$dir/c.out")
  printf '%s\n' "$out" | grep -E 'docker: +skipped .*container\(s\) running' >/dev/null \
    || fail "--clean did not skip docker prune when a container was running"
  log=$(cat "$dir/calls.log")
  printf '%s\n' "$log" | grep -F 'docker system prune' >/dev/null \
    && fail "docker system prune ran while a container was running"
  pass "docker prune is skipped when a container is running"
}

# 5. ms-playwright and *-pp-cli caches are preserved by --clean.
test_cache_preserves_protected() {
  local dir out
  dir=$(make_env cache-keep journalctl sudo docker)  # npm/go absent or skipped
  mkdir -p "$dir/home/.cache/pip" "$dir/home/.cache/go-build" \
           "$dir/home/.cache/ms-playwright" "$dir/home/.cache/foo-pp-cli" \
           "$dir/home/.cache/bar-pp-cli"
  FM_DISK_SKIP_NPM=1 FM_DISK_SKIP_GO=1 FM_DISK_SKIP_JOURNAL=1 FM_DISK_SKIP_DOCKER=1 \
    run_disk "$dir" --clean > "$dir/c.out" 2>&1 || fail "--clean exited non-zero"
  out=$(cat "$dir/c.out")
  printf '%s\n' "$out" | grep -F 'cache:   cleared ~/.cache/pip' >/dev/null \
    || fail "--clean did not clear pip cache"
  [ ! -d "$dir/home/.cache/pip" ] || fail "pip cache was not removed"
  [ ! -d "$dir/home/.cache/go-build" ] || fail "go-build cache was not removed"
  [ -d "$dir/home/.cache/ms-playwright" ] || fail "ms-playwright was not preserved"
  [ -d "$dir/home/.cache/foo-pp-cli" ] || fail "foo-pp-cli was not preserved"
  [ -d "$dir/home/.cache/bar-pp-cli" ] || fail "bar-pp-cli was not preserved"
  printf '%s\n' "$out" | grep -F 'preserved ~/.cache/ms-playwright' >/dev/null \
    || fail "--clean did not report ms-playwright preserved"
  printf '%s\n' "$out" | grep -F 'preserved ~/.cache/foo-pp-cli' >/dev/null \
    || fail "--clean did not report foo-pp-cli preserved"
  pass "ms-playwright and *-pp-cli caches are preserved"
}

test_check_reports_alerts_and_is_readonly
test_clean_invokes_reclaims_and_skips_absent
test_vacuum_guard
test_docker_prune_skipped_when_running
test_cache_preserves_protected
