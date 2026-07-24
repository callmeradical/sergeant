#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
TMUX_SESSION="sgt-interactive-worker-test-$$"
trap 'tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true; rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/fake-bin" "$TEST_ROOT/done/state" "$TEST_ROOT/done/worktree" \
  "$TEST_ROOT/goose/state" "$TEST_ROOT/goose/worktree" \
  "$TEST_ROOT/claude/state" "$TEST_ROOT/claude/worktree" \
  "$TEST_ROOT/needs-input/state" "$TEST_ROOT/needs-input/worktree" \
  "$TEST_ROOT/blocked/state" "$TEST_ROOT/blocked/worktree" \
  "$TEST_ROOT/rejected" \
  "$TEST_ROOT/orphan/state" "$TEST_ROOT/orphan/worktree"

cat > "$TEST_ROOT/fake-bin/opencode" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s\n' "$#" "$*" > "$ARG_LOG"
if [[ "${FAKE_MODE:-}" == "done" ]]; then
  printf 'done\n' > .sergeant-status
  printf 'https://example.invalid/pr/1\n' > .sergeant-result
elif [[ "${FAKE_MODE:-}" == "needs_input" ]]; then
  printf 'needs_input\n' > .sergeant-status
  printf 'Choose safely.\n' > .sergeant-message
elif [[ "${FAKE_MODE:-}" == "blocked" ]]; then
  printf 'blocked\n' > .sergeant-status
  printf 'Waiting for dependency.\n' > .sergeant-message
fi
EOF
chmod +x "$TEST_ROOT/fake-bin/opencode"
ln -s opencode "$TEST_ROOT/fake-bin/goose"
ln -s opencode "$TEST_ROOT/fake-bin/claude"

if ARG_LOG="$TEST_ROOT/non-tty.args" \
  "$ROOT_DIR/bin/sgt-interactive-worker" "$TEST_ROOT/done/state" \
    "$TEST_ROOT/done/worktree" "$TEST_ROOT/fake-bin/opencode" >/dev/null 2>&1; then
  printf 'interactive worker accepted a non-terminal launch\n' >&2
  exit 1
fi
[[ ! -e "$TEST_ROOT/non-tty.args" ]]

if ARG_LOG="$TEST_ROOT/rejected.args" \
  "$ROOT_DIR/bin/sgt-interactive-worker" "$TEST_ROOT/rejected/state" \
    "$TEST_ROOT/done/worktree" "$TEST_ROOT/fake-bin/opencode" >/dev/null 2>&1; then
  printf 'interactive worker accepted another non-terminal launch\n' >&2
  exit 1
fi
[[ ! -e "$TEST_ROOT/rejected/state" && ! -e "$TEST_ROOT/rejected.args" ]]

tmux new-session -d -s "$TMUX_SESSION" -n keepalive \
  "while :; do sleep 1; done"
tmux new-window -d -t "$TMUX_SESSION:" -n "done" \
  "env ARG_LOG='$TEST_ROOT/done.args' FAKE_MODE=done \
  '$ROOT_DIR/bin/sgt-interactive-worker' '$TEST_ROOT/done/state' \
  '$TEST_ROOT/done/worktree' '$TEST_ROOT/fake-bin/opencode'"
for _ in $(seq 1 100); do
  [[ -f "$TEST_ROOT/done/state/result" ]] && break
  sleep 0.02
done
[[ "$(cat "$TEST_ROOT/done.args")" == "1|--dangerously-skip-permissions" ]]
[[ "$(cat "$TEST_ROOT/done/state/status")" == "done" ]]
[[ "$(cat "$TEST_ROOT/done/state/worker_mode")" == "interactive" ]]
[[ -s "$TEST_ROOT/done/state/result" ]]

tmux new-window -d -t "$TMUX_SESSION:" -n goose \
  "env ARG_LOG='$TEST_ROOT/goose.args' FAKE_MODE=done \
  '$ROOT_DIR/bin/sgt-interactive-worker' '$TEST_ROOT/goose/state' \
  '$TEST_ROOT/goose/worktree' '$TEST_ROOT/fake-bin/goose'"
tmux new-window -d -t "$TMUX_SESSION:" -n claude \
  "env ARG_LOG='$TEST_ROOT/claude.args' FAKE_MODE=done \
  '$ROOT_DIR/bin/sgt-interactive-worker' '$TEST_ROOT/claude/state' \
  '$TEST_ROOT/claude/worktree' '$TEST_ROOT/fake-bin/claude'"
for _ in $(seq 1 100); do
  [[ -f "$TEST_ROOT/goose/state/result" && -f "$TEST_ROOT/claude/state/result" ]] && break
  sleep 0.02
done
[[ "$(cat "$TEST_ROOT/goose.args")" == "1|session" ]]
[[ "$(cat "$TEST_ROOT/claude.args")" == "0|" ]]
[[ "$(cat "$TEST_ROOT/goose/state/status")" == "done" ]]
[[ "$(cat "$TEST_ROOT/claude/state/status")" == "done" ]]

for waiting_status in needs_input blocked; do
  state_dir="$TEST_ROOT/${waiting_status//_/-}/state"
  worktree_dir="$TEST_ROOT/${waiting_status//_/-}/worktree"
  tmux new-window -d -t "$TMUX_SESSION:" -n "$waiting_status" \
    "env ARG_LOG='$TEST_ROOT/$waiting_status.args' FAKE_MODE='$waiting_status' \
    '$ROOT_DIR/bin/sgt-interactive-worker' '$state_dir' \
    '$worktree_dir' '$TEST_ROOT/fake-bin/claude'"
  for _ in $(seq 1 100); do
    [[ -f "$state_dir/status" ]] && [[ "$(cat "$state_dir/status")" == "$waiting_status" ]] && break
    sleep 0.02
  done
  [[ "$(cat "$state_dir/status")" == "$waiting_status" ]]
  [[ "$(cat "$worktree_dir/.sergeant-status")" == "$waiting_status" ]]
  [[ ! -e "$state_dir/diagnostic" ]]
done

tmux new-window -d -t "$TMUX_SESSION:" -n orphan \
  "env ARG_LOG='$TEST_ROOT/orphan.args' \
  '$ROOT_DIR/bin/sgt-interactive-worker' '$TEST_ROOT/orphan/state' \
  '$TEST_ROOT/orphan/worktree' '$TEST_ROOT/fake-bin/opencode'"
for _ in $(seq 1 100); do
  [[ -f "$TEST_ROOT/orphan/state/diagnostic" ]] && break
  sleep 0.02
done
[[ "$(cat "$TEST_ROOT/orphan.args")" == "1|--dangerously-skip-permissions" ]]
[[ "$(cat "$TEST_ROOT/orphan/state/status")" == "orphaned" ]]
grep -Fq 'interactive opencode session exited before terminal completion' \
  "$TEST_ROOT/orphan/state/diagnostic"

printf 'sgt-interactive-worker lifecycle: ok\n'
