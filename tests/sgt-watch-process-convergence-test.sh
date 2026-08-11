#!/usr/bin/env bash
# Public-CLI regression: terminal sync retires the owned worker process group.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
TMUX_SESSION="sgt-watch-process-convergence-$$"
export TMUX_TMPDIR="$TEST_ROOT/tmux"
mkdir -p "$TMUX_TMPDIR"

cleanup_fixture() {
  local pgid=""
  pgid="$(cat "$TEST_ROOT/fleet/task/app/worker_process_group" 2>/dev/null || true)"
  tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
  if [[ "$pgid" =~ ^[1-9][0-9]*$ ]]; then
    kill -KILL -- -"$pgid" 2>/dev/null || true
  fi
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
kill -0 "$helper_pid"

SERGEANT_FLEET="$TEST_ROOT/fleet" "$ROOT_DIR/bin/sgt-watch" --sync task >/dev/null

if kill -0 "$helper_pid" 2>/dev/null; then
  printf 'terminal sync left owned helper process alive: %s\n' "$helper_pid" >&2
  exit 1
fi
if [[ "$(tmux display-message -p -t "$pane" '#{pane_id}' 2>/dev/null || true)" == \
  "$pane" ]]; then
  printf 'terminal sync left owned worker pane alive: %s\n' "$pane" >&2
  exit 1
fi

printf 'sgt-watch process convergence: ok\n'
