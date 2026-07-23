#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
TMUX_SESSION="sgt-cleanup-test-$$"

cleanup_fixture() {
  tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
  rm -rf "$TEST_ROOT"
}
trap cleanup_fixture EXIT

assert_not_running() {
  local pid="$1"
  if kill -0 "$pid" 2>/dev/null; then
    printf 'process %s is still running\n' "$pid" >&2
    exit 1
  fi
}

assert_tmux_pane_missing() {
  local pane="$1"
  if tmux display-message -p -t "$pane" '#{pane_id}' >/dev/null 2>&1; then
    printf 'tmux pane still exists: %s\n' "$pane" >&2
    exit 1
  fi
}

mkdir -p "$TEST_ROOT/fleet/task-123/app" "$TEST_ROOT/fake-bin" "$TEST_ROOT/repo"
git -C "$TEST_ROOT/repo" init -q
git -C "$TEST_ROOT/repo" config user.name Test
git -C "$TEST_ROOT/repo" config user.email test@example.invalid
touch "$TEST_ROOT/repo/README.md"
git -C "$TEST_ROOT/repo" add README.md
git -C "$TEST_ROOT/repo" commit -qm fixture

worktree="$TEST_ROOT/repo-sgt-task-123"
repo_state="$TEST_ROOT/fleet/task-123/app"
git -C "$TEST_ROOT/repo" worktree add -q -b test-cleanup "$worktree"
printf '%s\n' "$worktree" > "$repo_state/worktree"
printf 'git\n' > "$repo_state/wt_type"
printf '%s\n' "$TMUX_SESSION" > "$repo_state/tmux_session"

cat > "$TEST_ROOT/fake-bin/fake-agent" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$AGENT_PID_FILE"
trap '' TERM HUP
trap 'exit 0' INT
while :; do sleep 1; done
EOF
chmod +x "$TEST_ROOT/fake-bin/fake-agent"

cat > "$TEST_ROOT/fake-bin/sgt-worker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$WORKER_PID_FILE"
"$FAKE_AGENT" &
wait "$!"
EOF
chmod +x "$TEST_ROOT/fake-bin/sgt-worker"

tmux new-session -d -s "$TMUX_SESSION" -n unrelated \
  "while :; do sleep 1; done"
unrelated_pid="$(tmux display-message -p -t "$TMUX_SESSION:unrelated" '#{pane_pid}')"
worker_pane="$(tmux new-window -P -F '#{pane_id}' -t "$TMUX_SESSION:" -n worker \
  "env WORKER_PID_FILE='$TEST_ROOT/worker.pid' AGENT_PID_FILE='$TEST_ROOT/agent.pid' \
  FAKE_AGENT='$TEST_ROOT/fake-bin/fake-agent' \
  '$TEST_ROOT/fake-bin/sgt-worker' '$repo_state' '$worktree'")"
printf '%s\n' "$worker_pane" > "$repo_state/pane"

for pid_file in "$TEST_ROOT/worker.pid" "$TEST_ROOT/agent.pid"; do
  for _ in $(seq 1 100); do
    [[ -s "$pid_file" ]] && break
    sleep 0.01
  done
  [[ -s "$pid_file" ]]
done
worker_pid="$(cat "$TEST_ROOT/worker.pid")"
agent_pid="$(cat "$TEST_ROOT/agent.pid")"

mkdir "$worktree/held-subdirectory"
holder_pane="$(tmux new-window -P -F '#{pane_id}' -t "$TMUX_SESSION:" -n holder \
  -c "$worktree/held-subdirectory" "while :; do sleep 1; done")"
set +e
SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" task-123 > "$TEST_ROOT/blocked-cleanup.log" 2>&1
cleanup_status=$?
set -e
[[ "$cleanup_status" -ne 0 ]]
grep -Fq 'Other processes still have' "$TEST_ROOT/blocked-cleanup.log" || {
  printf 'unexpected cleanup failure:\n%s\n' "$(cat "$TEST_ROOT/blocked-cleanup.log")" >&2
  exit 1
}
tmux display-message -p -t "$holder_pane" '#{pane_id}' >/dev/null
[[ -d "$worktree" && -d "$TEST_ROOT/fleet/task-123" ]]
assert_not_running "$worker_pid"
assert_not_running "$agent_pid"

tmux kill-pane -t "$holder_pane"
SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" task-123 >/dev/null

assert_tmux_pane_missing "$worker_pane"
tmux has-session -t "$TMUX_SESSION"
tmux display-message -p -t "$TMUX_SESSION:unrelated" '#{pane_id}' >/dev/null
kill -0 "$unrelated_pid"
assert_not_running "$worker_pid"
assert_not_running "$agent_pid"
[[ ! -e "$worktree" ]]
[[ ! -e "$TEST_ROOT/fleet/task-123" ]]

SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" task-123 >/dev/null

printf 'sgt-cleanup worker termination: ok\n'
