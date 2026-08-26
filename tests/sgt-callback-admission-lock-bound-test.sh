#!/usr/bin/env bash
# Regression test for Deloitte support #33: sgt-callback's admission lock
# blocked indefinitely on a bare fcntl.flock(LOCK_EX) with no bound, so a
# correlated dispatch whose lock was held by another (or a stuck) process
# could never fail or report which preflight stage was stuck -- it just hung,
# exceeding external timeouts with no durable dispatch owner ever created.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

home="$TEST_ROOT/home"
fleet="$TEST_ROOT/fleet"
callbacks="$TEST_ROOT/callbacks"
mkdir -p "$home" "$fleet" "$callbacks"
chmod 700 "$fleet" "$callbacks"

callback_env=(
  HOME="$home"
  SERGEANT_FLEET="$fleet"
  SERGEANT_CALLBACKS="$callbacks"
)

callback() {
  env "${callback_env[@]}" "$ROOT/bin/sgt-callback" "$@"
}

begin_json="$(callback begin-admission held-task hermes-discord req-hold-001)"
lock_path="$(printf '%s' "$begin_json" | python3 -c \
  'import json,sys; print(json.load(sys.stdin)["lock_path"])')"

# Hold the lock exclusively from a separate process for slightly longer than
# the bounded timeout under test, simulating another correlated dispatch (or
# a stuck one) that still holds it.
holder_release="$TEST_ROOT/release"
python3 - "$lock_path" "$holder_release" <<'PY' &
import fcntl
import sys
import time

lock_path, release_marker = sys.argv[1], sys.argv[2]
fd = open(lock_path, "r+")
fcntl.flock(fd, fcntl.LOCK_EX)
open(release_marker, "w").close()
time.sleep(2)
PY
holder_pid=$!

for _ in $(seq 1 50); do
  [[ -e "$holder_release" ]] && break
  sleep 0.1
done
[[ -e "$holder_release" ]] || {
  printf 'FAIL: holder never acquired the lock\n' >&2
  exit 1
}

exec 197>>"$lock_path"
start=$(date +%s)
if env "${callback_env[@]}" SERGEANT_ADMISSION_LOCK_TIMEOUT_SECS=1 \
    "$ROOT/bin/sgt-callback" lock-admission req-hold-001 197 2>"$TEST_ROOT/err.log"; then
  printf 'FAIL: lock-admission acquired a lock still held by another process\n' >&2
  exit 1
fi
elapsed=$(( $(date +%s) - start ))
exec 197>&-

[[ "$elapsed" -ge 1 && "$elapsed" -le 5 ]] || {
  printf 'FAIL: lock-admission did not time out within the bounded window (elapsed=%ss)\n' \
    "$elapsed" >&2
  cat "$TEST_ROOT/err.log" >&2
  exit 1
}
grep -q "admission-lock" "$TEST_ROOT/err.log" || {
  printf 'FAIL: timeout error did not name the admission-lock stage\n' >&2
  cat "$TEST_ROOT/err.log" >&2
  exit 1
}

wait "$holder_pid" 2>/dev/null || true

printf 'lock-admission times out and names its stage when contended: ok\n'

# Once the holder releases, a fresh attempt succeeds promptly rather than
# waiting out the full timeout window.
exec 198>>"$lock_path"
start=$(date +%s)
env "${callback_env[@]}" SERGEANT_ADMISSION_LOCK_TIMEOUT_SECS=5 \
  "$ROOT/bin/sgt-callback" lock-admission req-hold-001 198
elapsed=$(( $(date +%s) - start ))
exec 198>&-
[[ "$elapsed" -le 2 ]] || {
  printf 'FAIL: lock-admission was slow to acquire an uncontended lock (elapsed=%ss)\n' \
    "$elapsed" >&2
  exit 1
}

printf 'lock-admission acquires promptly once the lock is free: ok\n'
