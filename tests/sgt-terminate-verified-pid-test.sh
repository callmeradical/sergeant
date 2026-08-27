#!/usr/bin/env bash
# Tests for _sgt_terminate_verified_pid (bin/_sgt-process.sh), the shared
# PID-identity-checked SIGTERM->poll->SIGKILL escalation used by both
# sgt-drain-force and bin/sgt-stop-all (openspec/changes/dispatch-admission-control).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

pass=0
fail=0
_pass() { printf '  ok: %s\n' "$*"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n' "$*" >&2; fail=$((fail + 1)); }

_terminate() {
  bash -c 'source "$1"; shift; _sgt_terminate_verified_pid "$@"' _ "$ROOT_DIR/bin/_sgt-process.sh" "$@"
}

_fake_proc_stat() {
  local proc_root="$1" pid="$2" starttime="$3"
  mkdir -p "$proc_root/$pid"
  printf '%s (proc) S 1 %s %s 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 %s 0\n' \
    "$pid" "$pid" "$pid" "$starttime" > "$proc_root/$pid/stat"
}

# ── 1. Verified-live pid: SIGTERM is enough, process exits on its own ───────

sleep 100 & pid1=$!
proc1="$TEST_ROOT/proc1"
_fake_proc_stat "$proc1" "$pid1" 12345
recorded1="linux:12345"
trap 'kill "$pid1" 2>/dev/null || true' RETURN
status=0
SGT_PROC_ROOT="$proc1" _terminate "$pid1" "$recorded1" 50 || status=$?
sleep 0.3
if [[ "$status" -eq 0 ]] && ! kill -0 "$pid1" 2>/dev/null; then
  _pass "_sgt_terminate_verified_pid: verified pid is signaled and exits, returns 0"
else
  _fail "_sgt_terminate_verified_pid: expected exit 0 and process gone; status=$status alive=$(kill -0 "$pid1" 2>/dev/null && echo yes || echo no)"
fi
kill "$pid1" 2>/dev/null || true
wait "$pid1" 2>/dev/null || true
trap - RETURN

# ── 2. Identity mismatch: recorded start does not match actual -> no signal ─

sleep 100 & pid2=$!
proc2="$TEST_ROOT/proc2"
_fake_proc_stat "$proc2" "$pid2" 99999
status=0
SGT_PROC_ROOT="$proc2" _terminate "$pid2" "linux:11111" 50 || status=$?
if [[ "$status" -eq 1 ]] && kill -0 "$pid2" 2>/dev/null; then
  _pass "_sgt_terminate_verified_pid: identity mismatch returns 1 and never signals the process"
else
  _fail "_sgt_terminate_verified_pid: expected status 1 and pid2 still alive; status=$status"
fi
kill "$pid2" 2>/dev/null || true
wait "$pid2" 2>/dev/null || true

# ── 3. PID not alive at all -> returns 0 (nothing to do), no error ──────────

dead_pid=99999
while kill -0 "$dead_pid" 2>/dev/null; do dead_pid=$((dead_pid + 1)); done
status=0
_terminate "$dead_pid" "linux:1" 50 || status=$?
if [[ "$status" -eq 0 ]]; then
  _pass "_sgt_terminate_verified_pid: an already-dead pid returns 0 without error"
else
  _fail "_sgt_terminate_verified_pid: expected 0 for a dead pid, got $status"
fi

# ── 4. A process that ignores SIGTERM is escalated to SIGKILL ──────────────

cat > "$TEST_ROOT/ignore-term.sh" <<'EOF'
#!/usr/bin/env bash
trap '' TERM
while true; do sleep 1; done
EOF
chmod +x "$TEST_ROOT/ignore-term.sh"
"$TEST_ROOT/ignore-term.sh" & pid4=$!
sleep 0.2
proc4="$TEST_ROOT/proc4"
_fake_proc_stat "$proc4" "$pid4" 55555
status=0
SGT_PROC_ROOT="$proc4" _terminate "$pid4" "linux:55555" 3 || status=$?
sleep 0.2
if [[ "$status" -eq 0 ]] && ! kill -0 "$pid4" 2>/dev/null; then
  _pass "_sgt_terminate_verified_pid: a TERM-ignoring process is escalated to SIGKILL after the grace window"
else
  _fail "_sgt_terminate_verified_pid: expected SIGKILL escalation to succeed; status=$status alive=$(kill -0 "$pid4" 2>/dev/null && echo yes || echo no)"
fi
kill -9 "$pid4" 2>/dev/null || true
wait "$pid4" 2>/dev/null || true

printf '\nsgt-terminate-verified-pid: %d passed' "$pass"
if [[ "$fail" -gt 0 ]]; then
  printf ', %d FAILED\n' "$fail" >&2
  exit 1
fi
printf '\n'
