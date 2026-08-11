#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
OWNED_PIDS=""
cleanup() {
  local pid
  for pid in $OWNED_PIDS; do kill -KILL "$pid" 2>/dev/null || true; done
  for pid in $OWNED_PIDS; do wait "$pid" 2>/dev/null || true; done
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

make_marker() {
  marker_path="$(mktemp "$TEST_ROOT/marker.XXXXXX")"
  marker_identity="$(stat -Lc '%d:%i' "$marker_path")"
  generation="$(printf '%032x' "$RANDOM")"
  marker_floor="$(awk '{ line=$0; sub(/^.*\) /, "", line); split(line,f," "); print f[20] }' "/proc/$$/stat")"
  printf '%s|%s|%s\n' "$generation" "$marker_identity" "$marker_floor" > "$TEST_ROOT/markers"
  printf 'version=1\nmember=99999999|linux:1|1|1|1\n' > "$TEST_ROOT/phase"
}

python3 - <<'PY'
import os, signal
assert hasattr(os, "pidfd_open") and hasattr(signal, "pidfd_send_signal")
PY

# A same-user environment spoofer has no capability FD and is untouched.
SERGEANT_WORKER_PROCESS_TOKEN=spoof sleep 60 & spoofer=$!
OWNED_PIDS+=" $spoofer"
disown "$spoofer" 2>/dev/null || true
make_marker
bash -c "exec 198<'$marker_path'; rm -f '$marker_path'; exec env -i PATH='$PATH' sleep 60" & holder=$!
OWNED_PIDS+=" $holder"
disown "$holder" 2>/dev/null || true
for _ in $(seq 1 100); do [[ ! -e "$marker_path" ]] && break; sleep 0.01; done
[[ ! -e "$marker_path" ]]
start="$(awk '{ line=$0; sub(/^.*\) /, "", line); split(line,f," "); print f[20] }' "/proc/$holder/stat")"
printf 'version=1\nmember=%s|linux:%s|1|1|1\n' "$holder" "$start" > "$TEST_ROOT/phase"
python3 "$ROOT/bin/_sgt-process-token.py" retire "$TEST_ROOT/markers" "$TEST_ROOT/phase"
kill -0 "$spoofer"

# A live attributable process that deliberately closes the inherited marker is
# actionable and is never falsely reported retired.
make_marker
bash -c "exec 198<'$marker_path'; rm -f '$marker_path'; exec 198<&-; exec sleep 60" & closed=$!
OWNED_PIDS+=" $closed"
disown "$closed" 2>/dev/null || true
closed_start="$(awk '{ line=$0; sub(/^.*\) /, "", line); split(line,f," "); print f[20] }' "/proc/$closed/stat")"
printf 'version=1\nmember=%s|linux:%s|1|1|1\n' "$closed" "$closed_start" > "$TEST_ROOT/phase"
set +e
closed_output="$(python3 "$ROOT/bin/_sgt-process-token.py" retire "$TEST_ROOT/markers" "$TEST_ROOT/phase" 2>&1)"
closed_status=$?
set -e
[[ "$closed_status" -ne 0 && "$closed_output" == *'closed its ownership marker FD'* ]]
kill -0 "$closed"

# Unreadable fd provenance fails closed, and stale starttime check never signals.
make_marker
python3 - "$marker_path" "$TEST_ROOT/unreadable.pid" <<'PY' &
import ctypes, os, pathlib, sys, time
fd = os.open(sys.argv[1], os.O_RDONLY)
os.dup2(fd, 198)
os.unlink(sys.argv[1])
pathlib.Path(sys.argv[2]).write_text(str(os.getpid()))
ctypes.CDLL(None).prctl(4, 0)
time.sleep(60)
PY
unreadable=$!
OWNED_PIDS+=" $unreadable"
disown "$unreadable" 2>/dev/null || true
for _ in $(seq 1 100); do [[ -s "$TEST_ROOT/unreadable.pid" ]] && break; sleep 0.01; done
unreadable_start="$(awk '{ line=$0; sub(/^.*\) /, "", line); split(line,f," "); print f[20] }' "/proc/$unreadable/stat")"
printf 'version=1\nmember=%s|linux:%s|1|1|1\n' "$unreadable" "$unreadable_start" > "$TEST_ROOT/phase"
set +e
unreadable_output="$(python3 "$ROOT/bin/_sgt-process-token.py" retire "$TEST_ROOT/markers" "$TEST_ROOT/phase" 2>&1)"
unreadable_status=$?
set -e
[[ "$unreadable_status" -ne 0 && "$unreadable_output" == *'cannot inspect attributable worker PID'* ]]
kill -0 "$unreadable"

# A zombie has already dropped every FD and cannot execute again, so it is
# terminal at each retirement phase rather than an unreadable live holder.
make_marker
python3 - "$marker_path" "$TEST_ROOT/zombie.pid" <<'PY' &
import os, pathlib, sys, time
child = os.fork()
if child == 0:
    fd = os.open(sys.argv[1], os.O_RDONLY)
    os.dup2(fd, 198)
    os.unlink(sys.argv[1])
    os._exit(0)
pathlib.Path(sys.argv[2]).write_text(str(child))
time.sleep(60)
PY
zombie_parent=$!
OWNED_PIDS+=" $zombie_parent"
disown "$zombie_parent" 2>/dev/null || true
for _ in $(seq 1 100); do [[ -s "$TEST_ROOT/zombie.pid" ]] && break; sleep 0.01; done
zombie="$(cat "$TEST_ROOT/zombie.pid")"
for _ in $(seq 1 100); do [[ "$(awk '{print $3}' "/proc/$zombie/stat" 2>/dev/null || true)" == Z ]] && break; sleep 0.01; done
zombie_start="$(awk '{ line=$0; sub(/^.*\) /, "", line); split(line,f," "); print f[20] }' "/proc/$zombie/stat")"
printf 'version=1\nmember=%s|linux:%s|1|1|1\n' "$zombie" "$zombie_start" > "$TEST_ROOT/phase"
python3 "$ROOT/bin/_sgt-process-token.py" retire "$TEST_ROOT/markers" "$TEST_ROOT/phase"

printf 'sgt process marker retirement: ok\n'
