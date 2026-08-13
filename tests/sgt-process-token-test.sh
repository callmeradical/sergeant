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

# Sergeant supports Python 3 versions before str.removeprefix was added in 3.9.
if grep -q '\.removeprefix' "$ROOT/bin/_sgt-process-token.py"; then
  echo "process token helper requires Python 3.9 str.removeprefix" >&2
  exit 1
fi

make_marker() {
  marker_path="$(mktemp "$TEST_ROOT/marker.XXXXXX")"
  marker_identity="$(stat -Lc '%d:%i' "$marker_path")"
  generation="$(printf '%032x' "$RANDOM")"
  printf '%s\n' "$generation" > "$marker_path"
  marker_floor="$(awk '{ line=$0; sub(/^.*\) /, "", line); split(line,f," "); print f[20] }' "/proc/$$/stat")"
  printf '%s|%s|%s\n' "$generation" "$marker_identity" "$marker_floor" > "$TEST_ROOT/markers"
  chmod 600 "$TEST_ROOT/markers"
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
[[ "$unreadable_status" -ne 0 && "$unreadable_output" == *'cannot inspect '*"PID $unreadable"*' fd ownership'* ]]
kill -0 "$unreadable"
kill -KILL "$unreadable" 2>/dev/null || true
wait "$unreadable" 2>/dev/null || true

# Every same-UID process launched after a retained marker generation is part of
# the holder proof. An unreadable, unrecorded fd table is actionable ambiguity;
# it cannot silently certify a drain or cleanup as complete.
make_marker
python3 - "$TEST_ROOT/unreadable-unrecorded.pid" <<'PY' &
import ctypes, os, pathlib, sys, time
pathlib.Path(sys.argv[1]).write_text(str(os.getpid()))
ctypes.CDLL(None).prctl(4, 0)
time.sleep(60)
PY
unreadable_unrecorded=$!
OWNED_PIDS+=" $unreadable_unrecorded"
disown "$unreadable_unrecorded" 2>/dev/null || true
for _ in $(seq 1 100); do [[ -s "$TEST_ROOT/unreadable-unrecorded.pid" ]] && break; sleep 0.01; done
set +e
ambiguous_output="$(python3 "$ROOT/bin/_sgt-process-token.py" holders "$TEST_ROOT/markers" 2>&1)"
ambiguous_status=$?
set -e
[[ "$ambiguous_status" -ne 0 && "$ambiguous_output" == *'cannot inspect same-UID post-launch PID'* ]]
kill -KILL "$unreadable_unrecorded" 2>/dev/null || true
wait "$unreadable_unrecorded" 2>/dev/null || true

# Device/inode reuse is insufficient without the generation bytes stored in the
# open capability. A same-inode file with unrelated content is not attributed,
# and compact retires its closed generation from bounded history.
make_marker
printf 'not-the-generation\n' > "$marker_path"
bash -c "exec 198<'$marker_path'; rm -f '$marker_path'; exec sleep 60" & reused=$!
OWNED_PIDS+=" $reused"
disown "$reused" 2>/dev/null || true
for _ in $(seq 1 100); do [[ ! -e "$marker_path" ]] && break; sleep 0.01; done
[[ -z "$(python3 "$ROOT/bin/_sgt-process-token.py" holders "$TEST_ROOT/markers")" ]]
python3 "$ROOT/bin/_sgt-process-token.py" compact "$TEST_ROOT/markers"
[[ ! -s "$TEST_ROOT/markers" ]]

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

# Every public token operation independently descriptor-binds marker history.
# Mode relaxation, symlink substitution, and replacement after open all fail at
# the ownership boundary before command-specific holder semantics are reached.
token_command() {
  local operation="$1" history="$2"
  case "$operation" in
    holders) python3 "$ROOT/bin/_sgt-process-token.py" holders "$history" ;;
    compact) python3 "$ROOT/bin/_sgt-process-token.py" compact "$history" ;;
    check) python3 "$ROOT/bin/_sgt-process-token.py" check "$history" "$$" \
      "$marker_floor" "$marker_identity" ;;
    retire) python3 "$ROOT/bin/_sgt-process-token.py" retire "$history" "$TEST_ROOT/phase" ;;
  esac
}

security_line="11111111111111111111111111111111|1:1|1"
for operation in holders check retire compact; do
  insecure="$TEST_ROOT/$operation-mode-history"
  printf '%s\n' "$security_line" > "$insecure"
  chmod 644 "$insecure"
  set +e
  insecure_output="$(token_command "$operation" "$insecure" 2>&1)"
  insecure_status=$?
  set -e
  [[ "$insecure_status" -ne 0 && "$insecure_output" == *'mode must be 0600'* ]]

  target="$TEST_ROOT/$operation-symlink-target"
  link="$TEST_ROOT/$operation-symlink-history"
  printf '%s\n' "$security_line" > "$target"
  chmod 600 "$target"
  ln -s "$target" "$link"
  set +e
  symlink_output="$(token_command "$operation" "$link" 2>&1)"
  symlink_status=$?
  set -e
  [[ "$symlink_status" -ne 0 && "$symlink_output" == *'not an owned regular file'* ]]

  swapped="$TEST_ROOT/$operation-swap-history"
  replacement="$TEST_ROOT/$operation-swap-replacement"
  pause="$TEST_ROOT/$operation-swap"
  printf '%s\n' "$security_line" > "$swapped"
  printf '%s\n' "$security_line" > "$replacement"
  chmod 600 "$swapped" "$replacement"
  SGT_PROCESS_TOKEN_TEST_PAUSE_AFTER_OPEN="$pause" \
    token_command "$operation" "$swapped" > "$pause.output" 2>&1 & swap_command=$!
  for _ in $(seq 1 200); do [[ -e "$pause.opened" ]] && break; sleep 0.01; done
  [[ -e "$pause.opened" ]]
  mv "$replacement" "$swapped"
  : > "$pause.release"
  set +e
  wait "$swap_command"
  swap_status=$?
  set -e
  [[ "$swap_status" -ne 0 ]]
  grep -Fq 'changed while reading' "$pause.output"
done

printf 'sgt process marker retirement: ok\n'
