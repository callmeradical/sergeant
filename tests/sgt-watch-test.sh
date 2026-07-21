#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fleet="$TEST_ROOT/fleet"
task="$fleet/task-1"
fake_bin="$TEST_ROOT/fake-bin"
mkdir -p "$task/live" "$task/dead" "$task/remote" "$TEST_ROOT/live-wt" "$TEST_ROOT/dead-wt" "$TEST_ROOT/remote-wt" "$fake_bin"
printf 'Brief: watcher lifecycle test\n' > "$task/brief.md"
printf '%s\n' "$TEST_ROOT/live-wt" > "$task/live/worktree"
printf '%s\n' "$TEST_ROOT/dead-wt" > "$task/dead/worktree"
printf '%s\n' "$TEST_ROOT/remote-wt" > "$task/remote/worktree"
printf '%%live\n' > "$task/live/pane"
printf '%%dead\n' > "$task/dead/pane"
printf 'needs_input\n' > "$TEST_ROOT/live-wt/.sergeant-status"
printf 'blocked\n' > "$TEST_ROOT/dead-wt/.sergeant-status"
printf 'blocked\n' > "$TEST_ROOT/remote-wt/.sergeant-status"
printf 'Question remains active.\n' > "$TEST_ROOT/live-wt/.sergeant-message"
printf 'Blocker remains active.\n' > "$TEST_ROOT/dead-wt/.sergeant-message"
printf 'Remote blocker remains active.\n' > "$TEST_ROOT/remote-wt/.sergeant-message"

cat > "$fake_bin/tmux" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *%live*) printf '0|sgt-worker:%s/live\n' "$TASK_ROOT" ;;
  *%dead*) printf '1|sgt-worker:%s/dead\n' "$TASK_ROOT" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$fake_bin/tmux"
cat > "$fake_bin/td" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TD_LOG"
EOF
chmod +x "$fake_bin/td"
printf 'td-123\n' > "$task/dead/td_task"
printf 'td-456\n' > "$task/live/td_task"
printf 'stale live\n' > "$task/live/result"
printf 'stale dead\n' > "$task/dead/result"
printf 'stale remote\n' > "$task/remote/result"

PATH="$fake_bin:$PATH" TASK_ROOT="$task" TD_LOG="$TEST_ROOT/td.log" SERGEANT_FLEET="$fleet" "$ROOT_DIR/bin/sgt-watch" --sync task-1
[[ "$(cat "$task/live/status")" == "needs_input" ]]
[[ "$(cat "$task/dead/status")" == "orphaned" ]]
[[ "$(cat "$TEST_ROOT/dead-wt/.sergeant-status")" == "orphaned" ]]
grep -Fq 'recorded pane %dead is dead or is not the expected worker supervisor' "$task/dead/diagnostic"
grep -Fq 'handoff td-123' "$TEST_ROOT/td.log"
cmp "$TEST_ROOT/live-wt/.sergeant-message" "$task/live/message"
[[ ! -e "$task/live/result" && ! -e "$task/dead/result" && ! -e "$task/remote/result" ]]

list_output="$(PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" "$ROOT_DIR/bin/sgt-watch" --list)"
[[ "$list_output" == *'1 needs-input'* ]]
[[ "$list_output" == *'1 orphaned'* ]]
[[ "$list_output" == *'1 blocked'* ]]

watch_output="$TEST_ROOT/watch-output"
set +e
PATH="$fake_bin:$PATH" TASK_ROOT="$task" SERGEANT_FLEET="$fleet" SERGEANT_WATCH_INTERVAL=0.01 \
  "$ROOT_DIR/bin/sgt-watch" task-1 > "$watch_output" 2>&1
watch_status=$?
set -e
[[ "$watch_status" -eq 1 ]]
grep -Fq 'Question remains active.' "$watch_output"
grep -Fq 'Remote blocker remains active.' "$watch_output"
grep -Fq 'recorded pane %dead is dead or is not the expected worker supervisor' "$watch_output"
grep -Fq 'Fleet finished with failures.' "$watch_output"

printf 'done\n' > "$TEST_ROOT/live-wt/.sergeant-status"
rm -f "$TEST_ROOT/live-wt/.sergeant-result"
printf 'stale terminal result\n' > "$task/live/result"
PATH="$fake_bin:$PATH" TASK_ROOT="$task" TD_LOG="$TEST_ROOT/td.log" SERGEANT_FLEET="$fleet" "$ROOT_DIR/bin/sgt-watch" --sync task-1
[[ "$(cat "$task/live/status")" == "orphaned" ]]
grep -Fq 'terminal status done requires result' "$task/live/diagnostic"
grep -Fq 'handoff td-456' "$TEST_ROOT/td.log"
[[ ! -e "$task/live/result" ]]

printf 'done\n' > "$TEST_ROOT/live-wt/.sergeant-status"
printf 'live result\n' > "$TEST_ROOT/live-wt/.sergeant-result"
printf 'done\n' > "$TEST_ROOT/dead-wt/.sergeant-status"
printf 'dead result\n' > "$TEST_ROOT/dead-wt/.sergeant-result"
printf 'failed: fixture failure\n' > "$TEST_ROOT/remote-wt/.sergeant-status"
set +e
terminal_output="$(PATH="$fake_bin:$PATH" TASK_ROOT="$task" SERGEANT_FLEET="$fleet" SERGEANT_WATCH_INTERVAL=0.01 \
  "$ROOT_DIR/bin/sgt-watch" task-1 2>&1)"
terminal_status=$?
set -e
[[ "$terminal_status" -eq 1 ]]
[[ "$terminal_output" == *'Fleet finished with failures.'* ]]

printf 'sgt-watch detects dead workers: ok\n'
