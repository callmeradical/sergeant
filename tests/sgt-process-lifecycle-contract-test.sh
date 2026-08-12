#!/usr/bin/env bash
# Public drain/force contract for detached marker-owning descendants.
set -euo pipefail

ROOT="${SGT_TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TEST_ROOT="$(mktemp -d)"
holder=""
ambiguous=""
cleanup() {
  [[ -z "$holder" ]] || kill -KILL "$holder" 2>/dev/null || true
  [[ -z "$ambiguous" ]] || kill -KILL "$ambiguous" 2>/dev/null || true
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

repo="$TEST_ROOT/fleet/task-detached/repo"
worktree="$TEST_ROOT/worktree"
mkdir -p "$repo" "$worktree" "$TEST_ROOT/drain" "$TEST_ROOT/fake-bin"
printf 'failed: fixture\n' > "$repo/status"
printf '%s\n' "$worktree" > "$repo/worktree"
printf '99999999\n' > "$repo/worker_pid"
printf 'linux:1\n' > "$repo/worker_process_start"
printf '99999999\n' > "$repo/worker_process_group"
printf '99999999\n' > "$repo/worker_session_id"
printf '%%99\n' > "$repo/pane"
printf '1|%%99|99999999|123456|worker\n' > "$repo/pane_identity"
chmod 600 "$repo/pane_identity"

generation="0123456789abcdef0123456789abcdef"
marker="$TEST_ROOT/marker"
printf '%s\n' "$generation" > "$marker"
identity="$(stat -Lc '%d:%i' "$marker")"
floor="$(awk '{ line=$0; sub(/^.*\) /, "", line); split(line,f," "); print f[20] }' /proc/$$/stat)"
printf '%s|%s|%s\n' "$generation" "$identity" "$floor" > "$repo/worker_process_markers"
printf '%s|%s|198|%s\n' "$generation" "$identity" "$marker" \
  > "$repo/worker_process_marker"
chmod 600 "$repo/worker_process_markers"

# The worker root exits; its grandchild escapes through setsid + double fork and
# is discoverable only through the inherited marker capability.
python3 - "$marker" "$TEST_ROOT/holder.pid" <<'PY'
import os, pathlib, sys, time
fd = os.open(sys.argv[1], os.O_RDONLY)
os.dup2(fd, 198)
os.unlink(sys.argv[1])
if os.fork():
    os._exit(0)
os.setsid()
if os.fork():
    os._exit(0)
pathlib.Path(sys.argv[2]).write_text(str(os.getpid()))
time.sleep(60)
PY
for _ in $(seq 1 100); do [[ -s "$TEST_ROOT/holder.pid" ]] && break; sleep 0.01; done
holder="$(cat "$TEST_ROOT/holder.pid")"
kill -0 "$holder"

set +e
drain_output="$(SERGEANT_FLEET="$TEST_ROOT/fleet" SERGEANT_DRAIN_DIR="$TEST_ROOT/drain" \
  "$ROOT/bin/sgt-drain" --global --wait --timeout 0 2>&1)"
drain_status=$?
set -e
[[ "$drain_status" -ne 0 && "$drain_output" == *'task-detached/repo'* ]]
[[ -d "$repo" && "$(cat "$repo/status")" == 'failed: fixture' ]]
kill -0 "$holder"
printf 'force-stopped\n' > "$repo/status"
set +e
terminal_output="$(SERGEANT_FLEET="$TEST_ROOT/fleet" SERGEANT_DRAIN_DIR="$TEST_ROOT/drain" \
  "$ROOT/bin/sgt-drain" --global --wait --timeout 0 2>&1)"
terminal_status=$?
set -e
[[ "$terminal_status" -ne 0 && "$terminal_output" == *'task-detached/repo'* ]]
printf 'in_progress\n' > "$repo/status"

SERGEANT_FLEET="$TEST_ROOT/fleet" SERGEANT_DRAIN_DIR="$TEST_ROOT/drain" \
  "$ROOT/bin/sgt-drain-force" --global --yes >/dev/null
for _ in $(seq 1 100); do kill -0 "$holder" 2>/dev/null || break; sleep 0.01; done
if kill -0 "$holder" 2>/dev/null; then
  printf 'force drain left detached marker holder alive: %s\n' "$holder" >&2
  exit 1
fi
[[ "$(cat "$repo/status")" == force-stopped ]]
[[ "$(cat "$worktree/.sergeant-status")" == force-stopped ]]
[[ -s "$repo/worker_process_markers" ]]
[[ -s "$repo/worker_recycled" ]]

# Force-stop publishes the exact retirement evidence sgt-watch consumes, so the
# terminal status converges without needing the now-retired marker generation.
cat > "$TEST_ROOT/fake-bin/tmux" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$TEST_ROOT/fake-bin/tmux"
PATH="$TEST_ROOT/fake-bin:$PATH" SERGEANT_FLEET="$TEST_ROOT/fleet" \
  "$ROOT/bin/sgt-watch" --sync task-detached >/dev/null

# A symlink is malformed ownership evidence, never equivalent to no history.
symlink_repo="$TEST_ROOT/fleet/task-symlink/repo"
mkdir -p "$symlink_repo"
printf 'failed: fixture\n' > "$symlink_repo/status"
printf '00000000000000000000000000000000|1:1|1\n' > "$TEST_ROOT/outside-history"
ln -s "$TEST_ROOT/outside-history" "$symlink_repo/worker_process_markers"
malformed_repo="$TEST_ROOT/fleet/task-malformed/repo"
mkdir -p "$malformed_repo"
printf 'failed: fixture\n' > "$malformed_repo/status"
printf 'not-marker-history\n' > "$malformed_repo/worker_process_markers"
set +e
symlink_output="$(SERGEANT_FLEET="$TEST_ROOT/fleet" SERGEANT_DRAIN_DIR="$TEST_ROOT/drain" \
  "$ROOT/bin/sgt-drain" --global --wait --timeout 0 2>&1)"
symlink_status=$?
set -e
[[ "$symlink_status" -ne 0 && "$symlink_output" == *'task-symlink/repo'* && \
  "$symlink_output" == *'history is a symlink'* && \
  "$symlink_output" == *'task-malformed/repo'* && \
  "$symlink_output" == *'malformed durable worker process marker history'* ]]
[[ -L "$symlink_repo/worker_process_markers" ]]

# A live recorded PID without an exact start identity may be unrelated. Force
# must not signal it; marker retirement is the only authorised signal path.
unrelated_repo="$TEST_ROOT/fleet/task-unrelated/repo"
mkdir -p "$unrelated_repo"
printf 'in_progress\n' > "$unrelated_repo/status"
printf '%s\n' "$TEST_ROOT/unrelated-worktree" > "$unrelated_repo/worktree"
sleep 60 & unrelated=$!
printf '%s\n' "$unrelated" > "$unrelated_repo/worker_pid"
SERGEANT_FLEET="$TEST_ROOT/fleet" SERGEANT_DRAIN_DIR="$TEST_ROOT/drain" \
  "$ROOT/bin/sgt-drain-force" --global --yes >/dev/null
kill -0 "$unrelated"
kill -KILL "$unrelated" 2>/dev/null || true
wait "$unrelated" 2>/dev/null || true

# Cleanup uses the same proof boundary. An unreadable same-UID holder makes the
# outcome ambiguous, so neither fleet nor marker evidence may be deleted.
ambiguous_repo="$TEST_ROOT/fleet/task-ambiguous/repo"
mkdir -p "$ambiguous_repo"
printf 'failed: fixture\n' > "$ambiguous_repo/status"
printf '%s/missing-worktree\n' "$TEST_ROOT" > "$ambiguous_repo/worktree"
ambiguous_generation="fedcba9876543210fedcba9876543210"
ambiguous_marker="$TEST_ROOT/ambiguous-marker"
printf '%s\n' "$ambiguous_generation" > "$ambiguous_marker"
ambiguous_identity="$(stat -Lc '%d:%i' "$ambiguous_marker")"
printf '%s|%s|%s\n' "$ambiguous_generation" "$ambiguous_identity" "$floor" \
  > "$ambiguous_repo/worker_process_markers"
python3 - "$ambiguous_marker" "$TEST_ROOT/ambiguous.pid" <<'PY' &
import ctypes, os, pathlib, sys, time
fd = os.open(sys.argv[1], os.O_RDONLY)
os.dup2(fd, 198)
os.unlink(sys.argv[1])
pathlib.Path(sys.argv[2]).write_text(str(os.getpid()))
ctypes.CDLL(None).prctl(4, 0)
time.sleep(60)
PY
ambiguous=$!
for _ in $(seq 1 100); do [[ -s "$TEST_ROOT/ambiguous.pid" ]] && break; sleep 0.01; done
set +e
cleanup_output="$(SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT/bin/sgt-cleanup" task-ambiguous 2>&1)"
cleanup_status=$?
set -e
[[ "$cleanup_status" -ne 0 && "$cleanup_output" == *'fleet evidence preserved'* ]]
[[ -d "$TEST_ROOT/fleet/task-ambiguous" && -s "$ambiguous_repo/worker_process_markers" ]]
kill -KILL "$ambiguous" 2>/dev/null || true
wait "$ambiguous" 2>/dev/null || true

printf 'sgt process lifecycle contract: ok\n'
