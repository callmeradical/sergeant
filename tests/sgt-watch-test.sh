#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fleet="$TEST_ROOT/fleet"
task="$fleet/task-1"
fake_bin="$TEST_ROOT/fake-bin"
mkdir -p "$task/live" "$task/dead" "$task/remote" "$TEST_ROOT/live-wt" "$TEST_ROOT/dead-wt" "$TEST_ROOT/remote-wt" "$TEST_ROOT/remote-project" "$fake_bin"
printf 'Brief: watcher lifecycle test\n' > "$task/brief.md"
printf '%s\n' "$TEST_ROOT/live-wt" > "$task/live/worktree"
printf '%s\n' "$TEST_ROOT/dead-wt" > "$task/dead/worktree"
printf '%s\n' "$TEST_ROOT/remote-wt" > "$task/remote/worktree"
printf 'local-tmux\n' > "$task/live/backend"
printf 'local-tmux\n' > "$task/dead/backend"
printf 'remote-babydriver\n' > "$task/remote/backend"
printf 'remote-drive\n' > "$task/remote/remote_session"
printf 'remote-window\n' > "$task/remote/remote_window"
printf '%s\n' "$TEST_ROOT/remote-project" > "$task/remote/remote_project_dir"
printf '%%live\n' > "$task/live/pane"
printf '%%dead\n' > "$task/dead/pane"
printf 'needs_input\n' > "$TEST_ROOT/live-wt/.sergeant-status"
printf 'blocked\n' > "$TEST_ROOT/dead-wt/.sergeant-status"
printf 'Question remains active.\n' > "$TEST_ROOT/live-wt/.sergeant-message"
printf 'Blocker remains active.\n' > "$TEST_ROOT/dead-wt/.sergeant-message"

cat > "$fake_bin/tmux" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *%live*) printf '0|sgt-worker:%s/live\n' "$TASK_ROOT" ;;
  *%dead*) printf '1|sgt-worker:%s/dead\n' "$TASK_ROOT" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$fake_bin/tmux"
cat > "$fake_bin/babydriver" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BABYDRIVER_LOG"
case "$1" in
  status) cat "$BABYDRIVER_STATUS_FILE" ;;
  logs) cat "$BABYDRIVER_LOGS_FILE" ;;
  restart)
    if [[ -n "${REMOTE_RESPONSE_PATH:-}" ]]; then
      [[ -f "$REMOTE_RESPONSE_PATH" ]] || exit 29
      [[ "$(cat "$REMOTE_RESPONSE_PATH")" == "${REMOTE_RESPONSE_TEXT:-}" ]] || exit 31
    fi
    ;;
esac
EOF
chmod +x "$fake_bin/babydriver"
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
cat > "$TEST_ROOT/remote-status.json" <<'EOF'
{"tmux_alive":true,"tasks":[{"window":"remote-window","status":"blocked","message":"Remote blocker remains active.","task_id":"td-remote-1"}]}
EOF
printf 'remote blocker logs\n' > "$TEST_ROOT/remote-logs.txt"

PATH="$fake_bin:$PATH" TASK_ROOT="$task" TD_LOG="$TEST_ROOT/td.log" SERGEANT_FLEET="$fleet" BABYDRIVER_LOG="$TEST_ROOT/babydriver.log" \
BABYDRIVER_STATUS_FILE="$TEST_ROOT/remote-status.json" BABYDRIVER_LOGS_FILE="$TEST_ROOT/remote-logs.txt" \
  "$ROOT_DIR/bin/sgt-watch" --sync task-1
[[ "$(cat "$task/live/status")" == "needs_input" ]]
[[ "$(cat "$task/dead/status")" == "orphaned" ]]
[[ "$(cat "$TEST_ROOT/dead-wt/.sergeant-status")" == "orphaned" ]]
[[ "$(cat "$task/remote/status")" == "blocked" ]]
grep -Fq 'recorded pane %dead is dead or is not the expected worker supervisor' "$task/dead/diagnostic"
grep -Fq 'handoff td-123' "$TEST_ROOT/td.log"
cmp "$TEST_ROOT/live-wt/.sergeant-message" "$task/live/message"
grep -Fq 'Remote blocker remains active.' "$task/remote/message"
[[ "$(cat "$task/remote/remote_td_task")" == "td-remote-1" ]]
[[ ! -e "$task/live/result" && ! -e "$task/dead/result" && ! -e "$task/remote/result" ]]

list_output="$(PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" "$ROOT_DIR/bin/sgt-watch" --list)"
[[ "$list_output" == *'1 needs-input'* ]]
[[ "$list_output" == *'1 orphaned'* ]]
[[ "$list_output" == *'1 blocked'* ]]

watch_output="$TEST_ROOT/watch-output"
set +e
PATH="$fake_bin:$PATH" TASK_ROOT="$task" SERGEANT_FLEET="$fleet" SERGEANT_WATCH_INTERVAL=0.01 BABYDRIVER_LOG="$TEST_ROOT/babydriver.log" \
BABYDRIVER_STATUS_FILE="$TEST_ROOT/remote-status.json" BABYDRIVER_LOGS_FILE="$TEST_ROOT/remote-logs.txt" \
  "$ROOT_DIR/bin/sgt-watch" task-1 > "$watch_output" 2>&1
watch_status=$?
set -e
[[ "$watch_status" -eq 1 ]]
grep -Fq 'Question remains active.' "$watch_output"
grep -Fq 'Remote blocker remains active.' "$watch_output"
grep -Fq 'recorded pane %dead is dead or is not the expected worker supervisor' "$watch_output"
grep -Fq 'Fleet finished with failures.' "$watch_output"

cat > "$TEST_ROOT/remote-status.json" <<'EOF'
{"tmux_alive":true,"tasks":[{"window":"remote-window","status":"in_review","task_id":"td-remote-1"}]}
EOF
PATH="$fake_bin:$PATH" TASK_ROOT="$task" TD_LOG="$TEST_ROOT/td.log" SERGEANT_FLEET="$fleet" BABYDRIVER_LOG="$TEST_ROOT/babydriver.log" \
BABYDRIVER_STATUS_FILE="$TEST_ROOT/remote-status.json" BABYDRIVER_LOGS_FILE="$TEST_ROOT/remote-logs.txt" \
  "$ROOT_DIR/bin/sgt-watch" --sync task-1
[[ "$(cat "$task/remote/status")" == "in_progress" ]]
[[ "$(cat "$TEST_ROOT/remote-wt/.sergeant-status")" == "in_progress" ]]
grep -Fq 'in_review' "$task/remote/message"
[[ ! -e "$task/remote/result" ]]

cat > "$TEST_ROOT/remote-status.json" <<'EOF'
{"tmux_alive":true,"tasks":[{"name":"remote-window:review follow-up [sgt:task-1]","status":"blocked","message":"Composite remote name still matches.","task_id":"td-remote-2"}]}
EOF
printf 'remote-window:review follow-up [sgt:task-1]\n' > "$task/remote/remote_task_name"
PATH="$fake_bin:$PATH" TASK_ROOT="$task" TD_LOG="$TEST_ROOT/td.log" SERGEANT_FLEET="$fleet" BABYDRIVER_LOG="$TEST_ROOT/babydriver.log" \
BABYDRIVER_STATUS_FILE="$TEST_ROOT/remote-status.json" BABYDRIVER_LOGS_FILE="$TEST_ROOT/remote-logs.txt" \
  "$ROOT_DIR/bin/sgt-watch" --sync task-1
[[ "$(cat "$task/remote/status")" == "blocked" ]]
[[ "$(cat "$TEST_ROOT/remote-wt/.sergeant-status")" == "blocked" ]]
grep -Fq 'Composite remote name still matches.' "$task/remote/message"
[[ "$(cat "$task/remote/remote_td_task")" == "td-remote-2" ]]
grep -Fq 'logs remote-drive --window remote-window:review follow-up [sgt:task-1] -n 40' "$TEST_ROOT/babydriver.log"

cat > "$TEST_ROOT/remote-status.json" <<'EOF'
{"tmux_alive":false,"tasks":[{"name":"remote-window:review follow-up [sgt:task-1]","status":"blocked","task_id":"td-remote-1"}]}
EOF
PATH="$fake_bin:$PATH" TASK_ROOT="$task" TD_LOG="$TEST_ROOT/td.log" SERGEANT_FLEET="$fleet" BABYDRIVER_LOG="$TEST_ROOT/babydriver.log" \
BABYDRIVER_STATUS_FILE="$TEST_ROOT/remote-status.json" BABYDRIVER_LOGS_FILE="$TEST_ROOT/remote-logs.txt" \
  "$ROOT_DIR/bin/sgt-watch" --sync task-1
[[ "$(cat "$task/remote/status")" == "orphaned" ]]
grep -Fq 'remote worker session is not alive' "$task/remote/diagnostic"
grep -Fq 'remote blocker logs' "$task/remote/diagnostic"
grep -Fq 'logs remote-drive --window remote-window:review follow-up [sgt:task-1] -n 40' "$TEST_ROOT/babydriver.log"
grep -Fq 'handoff td-remote-1' "$TEST_ROOT/td.log"

printf 'orphaned\n' > "$task/remote/status"
printf 'orphaned\n' > "$TEST_ROOT/remote-wt/.sergeant-status"
printf 'preserved remote answer\n' > "$task/remote/response"
printf 'preserved remote answer\n' > "$TEST_ROOT/remote-wt/.sergeant-response"
printf '0123456789abcdef0123456789abcdef\n' > "$task/remote/response_id"
printf 'babydriver restart failed for remote-drive/remote-window:review follow-up [sgt:task-1]\nexit 23\n' > "$task/remote/diagnostic"
cat > "$TEST_ROOT/remote-status.json" <<'EOF'
{"tmux_alive":true,"tasks":[{"name":"remote-window:review follow-up [sgt:task-1]","status":"blocked","message":"Remote blocker remains active after failed restart.","task_id":"td-remote-1"}]}
EOF
PATH="$fake_bin:$PATH" TASK_ROOT="$task" TD_LOG="$TEST_ROOT/td.log" SERGEANT_FLEET="$fleet" BABYDRIVER_LOG="$TEST_ROOT/babydriver.log" \
BABYDRIVER_STATUS_FILE="$TEST_ROOT/remote-status.json" BABYDRIVER_LOGS_FILE="$TEST_ROOT/remote-logs.txt" \
  "$ROOT_DIR/bin/sgt-watch" --sync task-1
[[ "$(cat "$task/remote/status")" == "orphaned" ]]
[[ "$(cat "$TEST_ROOT/remote-wt/.sergeant-status")" == "orphaned" ]]
[[ "$(cat "$task/remote/response")" == 'preserved remote answer' ]]
[[ "$(cat "$TEST_ROOT/remote-wt/.sergeant-response")" == 'preserved remote answer' ]]
grep -Fq 'babydriver restart failed for remote-drive/remote-window:review follow-up [sgt:task-1]' "$task/remote/diagnostic"
grep -Fq 'Remote blocker remains active after failed restart.' "$task/remote/message"

PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" BABYDRIVER_LOG="$TEST_ROOT/remote-retry.log" \
TD_LOG="$TEST_ROOT/remote-retry-td.log" REMOTE_RESPONSE_PATH="$TEST_ROOT/remote-project/.sergeant-response" \
REMOTE_RESPONSE_TEXT='preserved remote answer' \
  "$ROOT_DIR/bin/sgt-respond" task-1 remote 'ignored retry text' >/dev/null 2>"$TEST_ROOT/remote-retry.err"
[[ "$(cat "$task/remote/status")" == "in_progress" ]]
[[ "$(cat "$TEST_ROOT/remote-wt/.sergeant-status")" == "in_progress" ]]
[[ "$(cat "$task/remote/response_id")" == '0123456789abcdef0123456789abcdef' ]]
[[ ! -e "$task/remote/response" && ! -e "$TEST_ROOT/remote-wt/.sergeant-response" ]]
[[ "$(cat "$TEST_ROOT/remote-project/.sergeant-response")" == 'preserved remote answer' ]]
grep -Fq 'reusing stored recovery response' "$TEST_ROOT/remote-retry.err"
if [[ -e "$TEST_ROOT/remote-retry-td.log" ]]; then
  printf 'watch-preserved retry should not log a duplicate td decision\n' >&2
  exit 1
fi

printf 'done\n' > "$TEST_ROOT/live-wt/.sergeant-status"
rm -f "$TEST_ROOT/live-wt/.sergeant-result"
printf 'stale terminal result\n' > "$task/live/result"
PATH="$fake_bin:$PATH" TASK_ROOT="$task" TD_LOG="$TEST_ROOT/td.log" SERGEANT_FLEET="$fleet" BABYDRIVER_LOG="$TEST_ROOT/babydriver.log" \
BABYDRIVER_STATUS_FILE="$TEST_ROOT/remote-status.json" BABYDRIVER_LOGS_FILE="$TEST_ROOT/remote-logs.txt" \
  "$ROOT_DIR/bin/sgt-watch" --sync task-1
[[ "$(cat "$task/live/status")" == "orphaned" ]]
grep -Fq 'terminal status done requires result' "$task/live/diagnostic"
grep -Fq 'handoff td-456' "$TEST_ROOT/td.log"
[[ ! -e "$task/live/result" ]]

printf 'done\n' > "$TEST_ROOT/live-wt/.sergeant-status"
printf 'live result\n' > "$TEST_ROOT/live-wt/.sergeant-result"
printf 'done\n' > "$TEST_ROOT/dead-wt/.sergeant-status"
printf 'dead result\n' > "$TEST_ROOT/dead-wt/.sergeant-result"
cat > "$TEST_ROOT/remote-status.json" <<'EOF'
{"tmux_alive":true,"tasks":[{"window":"remote-window","status":"failed","error":"fixture failure"}]}
EOF
set +e
terminal_output="$(PATH="$fake_bin:$PATH" TASK_ROOT="$task" SERGEANT_FLEET="$fleet" SERGEANT_WATCH_INTERVAL=0.01 \
  BABYDRIVER_LOG="$TEST_ROOT/babydriver.log" \
  BABYDRIVER_STATUS_FILE="$TEST_ROOT/remote-status.json" BABYDRIVER_LOGS_FILE="$TEST_ROOT/remote-logs.txt" \
  "$ROOT_DIR/bin/sgt-watch" task-1 2>&1)"
terminal_status=$?
set -e
[[ "$terminal_status" -eq 1 ]]
[[ "$terminal_output" == *'Fleet finished with failures.'* ]]
[[ "$(cat "$TEST_ROOT/remote-wt/.sergeant-status")" == 'failed: remote execution failed' ]]

printf 'sgt-watch detects dead workers: ok\n'
