#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
OWNED_PIDS=""
cleanup() {
  local pid
  for pid in $OWNED_PIDS; do
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

python3 - <<'PY'
import os, signal
assert hasattr(os, "pidfd_open") and hasattr(signal, "pidfd_send_signal")
PY

token="$(printf 'c%.0s' $(seq 1 64))"
SERGEANT_WORKER_PROCESS_TOKEN="$token" python3 - "$TEST_ROOT/unreadable.pid" >/dev/null 2>&1 <<'PY' &
import ctypes, os, pathlib, time, sys
pathlib.Path(sys.argv[1]).write_text(str(os.getpid()))
ctypes.CDLL(None).prctl(4, 0)  # PR_SET_DUMPABLE
time.sleep(60)
PY
launcher=$!
OWNED_PIDS+=" $launcher"
disown "$launcher" 2>/dev/null || true
for _ in $(seq 1 100); do [[ -s "$TEST_ROOT/unreadable.pid" ]] && break; sleep 0.01; done
pid="$(cat "$TEST_ROOT/unreadable.pid")"
start="$(awk '{ line=$0; sub(/^.*\) /, "", line); split(line,f," "); print f[20] }' "/proc/$pid/stat")"
set +e
unreadable="$(python3 "$ROOT/bin/_sgt-process-token.py" retire "$token" "$start" 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 && "$unreadable" == *'cannot read /proc/'*'/environ'* ]]
kill -0 "$pid"

# A stale starttime (the PID-reuse boundary) and a conflicting token both fail
# before a signal is sent through a pidfd.
set +e
python3 "$ROOT/bin/_sgt-process-token.py" check "$token" "$pid" "$((start + 1))" >/dev/null 2>&1
reuse_status=$?
other="$(printf 'd%.0s' $(seq 1 64))"
python3 "$ROOT/bin/_sgt-process-token.py" check "$other" "$pid" "$start" >/dev/null 2>&1
conflict_status=$?
set -e
[[ "$reuse_status" -ne 0 && "$conflict_status" -ne 0 ]]
kill -0 "$pid"

# Zombies carrying the token are terminal evidence, not unreadable live owners.
zombie_token="$(printf 'e%.0s' $(seq 1 64))"
SERGEANT_WORKER_PROCESS_TOKEN="$zombie_token" python3 - "$TEST_ROOT/zombie.pid" >/dev/null 2>&1 <<'PY' &
import os, pathlib, time, sys
child = os.fork()
if child == 0:
    os._exit(0)
pathlib.Path(sys.argv[1]).write_text(str(os.getpid()))
time.sleep(60)
PY
zombie_parent=$!
OWNED_PIDS+=" $zombie_parent"
disown "$zombie_parent" 2>/dev/null || true
for _ in $(seq 1 100); do [[ -s "$TEST_ROOT/zombie.pid" ]] && break; sleep 0.01; done
zombie_start="$(awk '{ line=$0; sub(/^.*\) /, "", line); split(line,f," "); print f[20] }' "/proc/$zombie_parent/stat")"
python3 "$ROOT/bin/_sgt-process-token.py" retire "$zombie_token" "$zombie_start"
wait "$zombie_parent" 2>/dev/null || true

printf 'sgt process token retirement: ok\n'
