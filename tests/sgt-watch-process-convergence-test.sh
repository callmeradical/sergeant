#!/usr/bin/env bash
# Public-CLI regression: terminal sync retires the owned worker process group.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
TMUX_SESSION="sgt-watch-process-convergence-$$"
FIXTURE_PGIDS=""
export TMUX_TMPDIR="$TEST_ROOT/tmux"
mkdir -p "$TMUX_TMPDIR"

cleanup_fixture() {
  local pgid
  tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
  for pgid in $FIXTURE_PGIDS; do
    kill -KILL -- -"$pgid" 2>/dev/null || true
  done
  rm -rf "$TEST_ROOT"
}
trap cleanup_fixture EXIT

command -v tmux >/dev/null 2>&1 || {
  printf 'sgt-watch process convergence: skipped (tmux unavailable)\n'
  exit 0
}

state="$TEST_ROOT/fleet/task/app"
worktree="$TEST_ROOT/worktree"
mkdir -p "$state" "$worktree"
printf '%s\n' "$worktree" > "$state/worktree"
printf 'done\n' > "$state/status"
printf 'result\n' > "$state/result"
printf 'done\n' > "$worktree/.sergeant-status"
printf 'result\n' > "$worktree/.sergeant-result"

cat > "$TEST_ROOT/sgt-interactive-worker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state="$1"
pid="$$"
pgid="$(ps -o pgid= -p "$pid" | tr -d ' ')"
start="$(ps -o lstart= -p "$pid" | sed 's/^ *//;s/ *$//')"
printf '%s\n' "$pid" > "$state/worker_pid"
printf '%s\n' "$pgid" > "$state/worker_process_group"
printf '%s\n' "$start" > "$state/worker_process_start"
bash -c 'trap "" TERM HUP; while :; do sleep 1; done' &
printf '%s\n' "$!" > "$state/helper_pid"
wait
EOF
chmod +x "$TEST_ROOT/sgt-interactive-worker"

tmux new-session -d -s "$TMUX_SESSION" -n keepalive 'while :; do sleep 1; done'
pane="$(tmux new-window -d -P -F '#{pane_id}' -t "$TMUX_SESSION:" -n worker \
  "$TEST_ROOT/sgt-interactive-worker '$state'")"
printf '%s\n' "$pane" > "$state/pane"
for _ in $(seq 1 100); do
  [[ -s "$state/helper_pid" && -s "$state/worker_process_start" ]] && break
  sleep 0.02
done
[[ -s "$state/helper_pid" && -s "$state/worker_process_start" ]]
tmux display-message -p -t "$pane" \
  '#{pane_dead}|#{pane_id}|#{pane_pid}|#{pane_created}|#{pane_start_command}' \
  > "$state/pane_identity"
chmod 600 "$state/pane_identity"
helper_pid="$(cat "$state/helper_pid")"
FIXTURE_PGIDS+=" $(cat "$state/worker_process_group")"
kill -0 "$helper_pid"

SGT_WATCH_RECYCLE_FAIL_POINT=after-pane-kill SERGEANT_FLEET="$TEST_ROOT/fleet" \
  "$ROOT_DIR/bin/sgt-watch" --sync task >/dev/null 2>&1

if ! kill -0 "$helper_pid" 2>/dev/null; then
  printf 'injected interruption did not preserve the resistant child for retry\n' >&2
  exit 1
fi
[[ -s "$state/worker_recycle_phase" ]]
[[ ! -e "$state/worker_recycled" ]]

SERGEANT_FLEET="$TEST_ROOT/fleet" "$ROOT_DIR/bin/sgt-watch" --sync task >/dev/null
[[ ! -e "$state/worker_recycle_phase" ]]
[[ ! -e "$state/diagnostic" ]]

if kill -0 "$helper_pid" 2>/dev/null; then
  printf 'terminal sync left owned helper process alive: %s\n' "$helper_pid" >&2
  exit 1
fi
if [[ "$(tmux display-message -p -t "$pane" '#{pane_id}' 2>/dev/null || true)" == \
  "$pane" ]]; then
  printf 'terminal sync left owned worker pane alive: %s\n' "$pane" >&2
  exit 1
fi

launch_fixture() {
  local name="$1" status="${2:-done}"
  launched_state="$TEST_ROOT/fleet/$name/app"
  launched_worktree="$TEST_ROOT/$name-worktree"
  mkdir -p "$launched_state" "$launched_worktree"
  printf '%s\n' "$launched_worktree" > "$launched_state/worktree"
  printf '%s\n' "$status" > "$launched_state/status"
  printf '%s\n' "$status" > "$launched_worktree/.sergeant-status"
  if [[ "$status" == "done" ]]; then
    printf 'result\n' > "$launched_state/result"
    printf 'result\n' > "$launched_worktree/.sergeant-result"
  fi
  launched_pane="$(tmux new-window -d -P -F '#{pane_id}' -t "$TMUX_SESSION:" \
    -n "$name" "$TEST_ROOT/sgt-interactive-worker '$launched_state'")"
  printf '%s\n' "$launched_pane" > "$launched_state/pane"
  for _ in $(seq 1 100); do
    [[ -s "$launched_state/helper_pid" && -s "$launched_state/worker_process_start" ]] && break
    sleep 0.02
  done
  tmux display-message -p -t "$launched_pane" \
    '#{pane_dead}|#{pane_id}|#{pane_pid}|#{pane_created}|#{pane_start_command}' \
    > "$launched_state/pane_identity"
  chmod 600 "$launched_state/pane_identity"
  launched_pid="$(cat "$launched_state/helper_pid")"
  launched_pgid="$(cat "$launched_state/worker_process_group")"
  FIXTURE_PGIDS+=" $launched_pgid"
}

# Missing provenance is actionable and cannot be reported as converged.
launch_fixture task-no-provenance
rm -f "$launched_state/worker_pid" "$launched_state/worker_process_group" \
  "$launched_state/worker_process_start"
SERGEANT_FLEET="$TEST_ROOT/fleet" "$ROOT_DIR/bin/sgt-watch" \
  --sync task-no-provenance >/dev/null 2>&1
kill -0 "$launched_pid"
grep -Fq 'process provenance is incomplete' "$launched_state/diagnostic"
kill -KILL -- -"$launched_pgid" 2>/dev/null || true

# PID reuse evidence and a non-leading/shared PGID both fail closed.
launch_fixture task-reused-pid
saved_start="$(cat "$launched_state/worker_process_start")"
printf 'stale start identity\n' > "$launched_state/worker_process_start"
SERGEANT_FLEET="$TEST_ROOT/fleet" "$ROOT_DIR/bin/sgt-watch" \
  --sync task-reused-pid >/dev/null 2>&1
kill -0 "$launched_pid"
grep -Fq 'process identity does not match' "$launched_state/diagnostic"
printf '%s\n' "$saved_start" > "$launched_state/worker_process_start"
SERGEANT_FLEET="$TEST_ROOT/fleet" "$ROOT_DIR/bin/sgt-watch" \
  --sync task-reused-pid >/dev/null

launch_fixture task-shared-pgid
saved_pgid="$launched_pgid"
keepalive_pid="$(tmux display-message -p -t "$TMUX_SESSION:keepalive" '#{pane_pid}')"
keepalive_pgid="$(ps -o pgid= -p "$keepalive_pid" | tr -d ' ')"
printf '%s\n' "$keepalive_pgid" > "$launched_state/worker_process_group"
SERGEANT_FLEET="$TEST_ROOT/fleet" "$ROOT_DIR/bin/sgt-watch" \
  --sync task-shared-pgid >/dev/null 2>&1
kill -0 "$launched_pid"
kill -0 "$keepalive_pid"
printf '%s\n' "$saved_pgid" > "$launched_state/worker_process_group"
SERGEANT_FLEET="$TEST_ROOT/fleet" "$ROOT_DIR/bin/sgt-watch" \
  --sync task-shared-pgid >/dev/null

# Waiting remains resumable and retains its exact worker pane/process group.
launch_fixture task-waiting waiting
SERGEANT_FLEET="$TEST_ROOT/fleet" "$ROOT_DIR/bin/sgt-watch" \
  --sync task-waiting >/dev/null
kill -0 "$launched_pid"
[[ "$(tmux display-message -p -t "$launched_pane" '#{pane_id}')" == "$launched_pane" ]]
kill -KILL -- -"$launched_pgid" 2>/dev/null || true

printf 'sgt-watch process convergence: ok\n'
