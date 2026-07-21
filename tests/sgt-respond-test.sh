#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fleet="$TEST_ROOT/fleet"
repo_state="$fleet/task-1/app"
worktree="$TEST_ROOT/worktree"
fake_bin="$TEST_ROOT/fake-bin"
mkdir -p "$repo_state" "$worktree" "$fake_bin"
printf '%s\n' "$worktree" > "$repo_state/worktree"
printf '%%42\n' > "$repo_state/pane"
printf 'sgt\n' > "$repo_state/tmux_session"
printf 'task/app\n' > "$repo_state/window_name"
printf 'fake-opencode\n' > "$repo_state/agent"
printf 'initial mission\n' > "$repo_state/initial_message"
printf 'needs_input\n' > "$worktree/.sergeant-status"
printf 'needs_input\n' > "$repo_state/status"

cat > "$fake_bin/tmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TMUX_LOG"
case "$1" in
  display-message)
    [[ "${PANE_ALIVE:-0}" == 1 ]] || exit 1
    printf '0|%s\n' "${PANE_IDENTITY:-sgt-worker:$EXPECTED_WORKER}"
    ;;
  new-window)
    [[ "${FAIL_WINDOW:-0}" == 0 ]] || exit 7
    [[ "${EMPTY_WINDOW:-0}" == 0 ]] || exit 0
    printf '%%99\n'
    ;;
  send-keys) exit 0 ;;
esac
EOF
chmod +x "$fake_bin/tmux"
cat > "$fake_bin/babydriver" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BABYDRIVER_LOG"
case "$1" in
  restart)
    [[ "${FAIL_RESTART:-0}" == 0 ]] || exit 23
    ;;
esac
EOF
chmod +x "$fake_bin/babydriver"
cat > "$fake_bin/td" <<'EOF'
#!/usr/bin/env bash
[[ ! -e "$TD_RESPONSE_FILE" ]] || {
  printf 'response was delivered before td decision log\n' >&2
  exit 1
}
printf '%s\n' "$*" >> "$TD_LOG"
EOF
chmod +x "$fake_bin/td"
printf 'td-123\n' > "$repo_state/td_task"

# shellcheck disable=SC2016
# Literal metacharacters verify response data is never evaluated.
response='Use option A; $(touch should-not-exist)'
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/live.log" TD_LOG="$TEST_ROOT/td.log" \
TD_RESPONSE_FILE="$worktree/.sergeant-response" PANE_ALIVE=1 EXPECTED_WORKER="$repo_state" SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-respond" task-1 app "$response" >/dev/null
[[ "$(cat "$repo_state/response")" == "$response" ]]
[[ "$(cat "$worktree/.sergeant-response")" == "$response" ]]
[[ "$(cat "$repo_state/pane")" == "%42" ]]
grep -Fq 'send-keys -t %42' "$TEST_ROOT/live.log"
[[ ! -e "$ROOT_DIR/should-not-exist" ]]
grep -Fq 'log td-123' "$TEST_ROOT/td.log"
grep -Fq -- '--decision' "$TEST_ROOT/td.log"
grep -Eq 'response-id=[a-f0-9]{32}' "$TEST_ROOT/td.log"
[[ "$(cat "$repo_state/response_id")" =~ ^[a-f0-9]{32}$ ]]
if grep -Fq 'sha256=' "$TEST_ROOT/td.log"; then
  printf 'response-derived digest leaked into td\n' >&2
  exit 1
fi
if grep -Fq 'Use option A' "$TEST_ROOT/td.log"; then
  printf 'raw response leaked into td\n' >&2
  exit 1
fi
set +e
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/duplicate.log" TD_LOG="$TEST_ROOT/duplicate-td.log" \
TD_RESPONSE_FILE="$worktree/.sergeant-response" PANE_ALIVE=1 EXPECTED_WORKER="$repo_state" SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-respond" task-1 app 'Use option B' >/dev/null 2>&1
duplicate_status=$?
set -e
[[ "$duplicate_status" -ne 0 ]]
[[ "$(cat "$repo_state/response")" == "$response" ]]
[[ "$(cat "$worktree/.sergeant-response")" == "$response" ]]
if [[ -e "$TEST_ROOT/duplicate-td.log" ]]; then
  printf 'duplicate response should not log a new td decision\n' >&2
  exit 1
fi

rm -f "$worktree/.sergeant-response" "$repo_state/response"
mkdir "$repo_state/response.lock"
printf '%s\n' "$$" > "$repo_state/response.lock/pid"
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/locked.log" TD_LOG="$TEST_ROOT/locked-td.log" \
TD_RESPONSE_FILE="$worktree/.sergeant-response" PANE_ALIVE=1 EXPECTED_WORKER="$repo_state" SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-respond" task-1 app 'serialized response' >/dev/null &
locked_pid=$!
sleep 0.05
[[ ! -e "$worktree/.sergeant-response" && ! -e "$repo_state/response" ]]
rm "$repo_state/response.lock/pid"
rmdir "$repo_state/response.lock"
wait "$locked_pid"
[[ "$(cat "$worktree/.sergeant-response")" == 'serialized response' ]]

rm -f "$worktree/.sergeant-response" "$repo_state/response"
printf 'done\n' > "$worktree/.sergeant-status"
printf 'done\n' > "$repo_state/status"
set +e
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/late.log" TD_LOG="$TEST_ROOT/late-td.log" \
TD_RESPONSE_FILE="$worktree/.sergeant-response" PANE_ALIVE=1 EXPECTED_WORKER="$repo_state" SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-respond" task-1 app 'late response' >/dev/null 2>&1
late_status=$?
set -e
[[ "$late_status" -ne 0 ]]
[[ ! -e "$worktree/.sergeant-response" && ! -e "$repo_state/response" ]]

printf 'in_progress\n' > "$worktree/.sergeant-status"
printf 'in_progress\n' > "$repo_state/status"
set +e
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/active.log" TD_LOG="$TEST_ROOT/active-td.log" \
TD_RESPONSE_FILE="$worktree/.sergeant-response" PANE_ALIVE=1 EXPECTED_WORKER="$repo_state" SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-respond" task-1 app 'active response' >/dev/null 2>&1
active_status=$?
set -e
[[ "$active_status" -ne 0 ]]
[[ ! -e "$worktree/.sergeant-response" && ! -e "$repo_state/response" ]]

printf 'needs_input\n' > "$worktree/.sergeant-status"
printf 'needs_input\n' > "$repo_state/status"

rm -f "$worktree/.sergeant-response"
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/dead.log" TD_LOG="$TEST_ROOT/td.log" \
TD_RESPONSE_FILE="$worktree/.sergeant-response" PANE_ALIVE=1 PANE_IDENTITY='bash:other-worker' EXPECTED_WORKER="$repo_state" SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-respond" task-1 app 'resume dead worker' >/dev/null
[[ "$(cat "$repo_state/pane")" == "%99" ]]
grep -Fq 'new-window -P -F #{pane_id} -t sgt: -n task/app' "$TEST_ROOT/dead.log"
grep -Fq "$ROOT_DIR/bin/sgt-worker" "$TEST_ROOT/dead.log"

rm "$worktree/.sergeant-response" "$repo_state/response"
cat > "$fake_bin/td" <<'EOF'
#!/usr/bin/env bash
exit 19
EOF
chmod +x "$fake_bin/td"
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/td-failure-tmux.log" PANE_ALIVE=1 \
SERGEANT_FLEET="$fleet" "$ROOT_DIR/bin/sgt-respond" task-1 app 'still deliver safely' >/dev/null
[[ "$(cat "$worktree/.sergeant-response")" == 'still deliver safely' ]]
grep -Fq 'td decision log failed' "$repo_state/diagnostic"
if compgen -G "$worktree/.sergeant-response.tmp.*" >/dev/null; then
  printf 'atomic response temporary file was retained\n' >&2
  exit 1
fi

printf 'needs_input\n' > "$repo_state/status"
printf 'needs_input\n' > "$worktree/.sergeant-status"
rm -f "$worktree/.sergeant-response" "$repo_state/response"
set +e
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/relaunch-fail.log" PANE_ALIVE=0 FAIL_WINDOW=1 \
SERGEANT_FLEET="$fleet" "$ROOT_DIR/bin/sgt-respond" task-1 app 'relaunch fails' >/dev/null 2>&1
status=$?
set -e
[[ "$status" -ne 0 ]]
[[ "$(cat "$worktree/.sergeant-status")" == 'orphaned' ]]
grep -Fq 'tmux failed to relaunch worker supervisor' "$repo_state/diagnostic"

cat > "$fake_bin/td" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TD_LOG"
EOF
chmod +x "$fake_bin/td"
printf 'needs_input\n' > "$repo_state/status"
printf 'needs_input\n' > "$worktree/.sergeant-status"
rm -f "$worktree/.sergeant-response" "$repo_state/response" "$repo_state/response_id"
set +e
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/empty-pane.log" TD_LOG="$TEST_ROOT/empty-pane-td.log" \
PANE_ALIVE=0 EMPTY_WINDOW=1 SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-respond" task-1 app 'empty pane' >/dev/null 2>&1
status=$?
set -e
[[ "$status" -ne 0 ]]
[[ "$(cat "$worktree/.sergeant-status")" == 'orphaned' ]]
grep -Fq 'tmux returned no pane for relaunched worker supervisor' "$repo_state/diagnostic"
grep -Fq 'handoff td-123' "$TEST_ROOT/empty-pane-td.log"

remote_repo_state="$fleet/task-1/remote"
remote_worktree="$TEST_ROOT/remote-worktree"
mkdir -p "$remote_repo_state" "$remote_worktree"
printf '%s\n' "$remote_worktree" > "$remote_repo_state/worktree"
printf 'remote-babydriver\n' > "$remote_repo_state/backend"
printf 'remote-drive\n' > "$remote_repo_state/remote_session"
printf 'remote-window\n' > "$remote_repo_state/remote_window"
printf 'needs_input\n' > "$remote_repo_state/status"
printf 'needs_input\n' > "$remote_worktree/.sergeant-status"
printf 'Need a remote answer.\n' > "$remote_worktree/.sergeant-message"
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/remote-live.log" BABYDRIVER_LOG="$TEST_ROOT/remote-babydriver.log" \
TD_LOG="$TEST_ROOT/remote-td.log" TD_RESPONSE_FILE="$remote_worktree/.sergeant-response" SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-respond" task-1 remote 'remote response' >/dev/null
[[ "$(cat "$remote_repo_state/response")" == 'remote response' ]]
[[ "$(cat "$remote_worktree/.sergeant-response")" == 'remote response' ]]
[[ "$(cat "$remote_repo_state/status")" == 'in_progress' ]]
[[ "$(cat "$remote_worktree/.sergeant-status")" == 'in_progress' ]]
grep -Fq 'restart remote-drive --window remote-window' "$TEST_ROOT/remote-babydriver.log"
[[ ! -e "$remote_repo_state/message" && ! -e "$remote_worktree/.sergeant-message" ]]

remote_name_repo_state="$fleet/task-1/remote-name"
remote_name_worktree="$TEST_ROOT/remote-name-worktree"
mkdir -p "$remote_name_repo_state" "$remote_name_worktree"
printf '%s\n' "$remote_name_worktree" > "$remote_name_repo_state/worktree"
printf 'remote-babydriver\n' > "$remote_name_repo_state/backend"
printf 'remote-drive\n' > "$remote_name_repo_state/remote_session"
printf 'remote-window\n' > "$remote_name_repo_state/remote_window"
printf 'remote-window:Need a remote answer. [sgt:task-1]\n' > "$remote_name_repo_state/remote_task_name"
printf 'needs_input\n' > "$remote_name_repo_state/status"
printf 'needs_input\n' > "$remote_name_worktree/.sergeant-status"
printf 'Need a remote answer.\n' > "$remote_name_worktree/.sergeant-message"
PATH="$fake_bin:$PATH" BABYDRIVER_LOG="$TEST_ROOT/remote-name-babydriver.log" \
TD_LOG="$TEST_ROOT/remote-name-td.log" TD_RESPONSE_FILE="$remote_name_worktree/.sergeant-response" SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-respond" task-1 remote-name 'remote name response' >/dev/null
[[ "$(cat "$remote_name_repo_state/response")" == 'remote name response' ]]
[[ "$(cat "$remote_name_worktree/.sergeant-response")" == 'remote name response' ]]
[[ "$(cat "$remote_name_repo_state/status")" == 'in_progress' ]]
[[ "$(cat "$remote_name_worktree/.sergeant-status")" == 'in_progress' ]]
grep -Fq 'restart remote-drive --window remote-window:Need a remote answer. [sgt:task-1]' "$TEST_ROOT/remote-name-babydriver.log"
[[ ! -e "$remote_name_repo_state/message" && ! -e "$remote_name_worktree/.sergeant-message" ]]
set +e
PATH="$fake_bin:$PATH" BABYDRIVER_LOG="$TEST_ROOT/remote-duplicate.log" \
TD_LOG="$TEST_ROOT/remote-duplicate-td.log" TD_RESPONSE_FILE="$remote_worktree/.sergeant-response" SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-respond" task-1 remote 'remote response 2' >/dev/null 2>&1
remote_duplicate_status=$?
set -e
[[ "$remote_duplicate_status" -ne 0 ]]
[[ "$(cat "$remote_repo_state/response")" == 'remote response' ]]
[[ "$(cat "$remote_worktree/.sergeant-response")" == 'remote response' ]]
[[ ! -e "$TEST_ROOT/remote-duplicate.log" ]]

printf 'failed: remote execution failed\n' > "$remote_repo_state/status"
printf 'needs_input\n' > "$remote_worktree/.sergeant-status"
rm -f "$remote_worktree/.sergeant-response" "$remote_repo_state/response"
set +e
PATH="$fake_bin:$PATH" BABYDRIVER_LOG="$TEST_ROOT/remote-terminal.log" \
TD_LOG="$TEST_ROOT/remote-terminal-td.log" TD_RESPONSE_FILE="$remote_worktree/.sergeant-response" SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-respond" task-1 remote 'too late' >/dev/null 2>&1
status=$?
set -e
[[ "$status" -ne 0 ]]
[[ ! -e "$remote_worktree/.sergeant-response" && ! -e "$remote_repo_state/response" ]]
[[ ! -e "$TEST_ROOT/remote-terminal.log" ]]

printf 'needs_input\n' > "$remote_repo_state/status"
printf 'needs_input\n' > "$remote_worktree/.sergeant-status"
set +e
PATH="$fake_bin:$PATH" BABYDRIVER_LOG="$TEST_ROOT/remote-babydriver-fail.log" FAIL_RESTART=1 \
TD_LOG="$TEST_ROOT/remote-fail-td.log" TD_RESPONSE_FILE="$remote_worktree/.sergeant-response" SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-respond" task-1 remote 'remote failure' >/dev/null 2>&1
status=$?
set -e
[[ "$status" -ne 0 ]]
[[ "$(cat "$remote_repo_state/status")" == 'orphaned' ]]
grep -Fq 'babydriver restart failed for remote-drive/remote-window' "$remote_repo_state/diagnostic"

printf 'needs_input\n' > "$remote_name_repo_state/status"
printf 'needs_input\n' > "$remote_name_worktree/.sergeant-status"
rm -f "$remote_name_worktree/.sergeant-response" "$remote_name_repo_state/response"
set +e
PATH="$fake_bin:$PATH" BABYDRIVER_LOG="$TEST_ROOT/remote-name-babydriver-fail.log" FAIL_RESTART=1 \
TD_LOG="$TEST_ROOT/remote-name-fail-td.log" TD_RESPONSE_FILE="$remote_name_worktree/.sergeant-response" SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-respond" task-1 remote-name 'remote name failure' >/dev/null 2>&1
status=$?
set -e
[[ "$status" -ne 0 ]]
[[ "$(cat "$remote_name_repo_state/status")" == 'orphaned' ]]
grep -Fq 'babydriver restart failed for remote-drive/remote-window:Need a remote answer. [sgt:task-1]' "$remote_name_repo_state/diagnostic"

printf 'sgt-respond resumes workers: ok\n'
