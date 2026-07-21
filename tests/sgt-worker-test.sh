#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fake_agent="$TEST_ROOT/fake-opencode"
fake_claude="$TEST_ROOT/claude"
mkdir -p "$TEST_ROOT/fake-bin"
cat > "$TEST_ROOT/fake-bin/td" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TD_LOG"
EOF
chmod +x "$TEST_ROOT/fake-bin/td"
cat > "$fake_agent" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "$FAKE_STATE/args"
turn_file="$FAKE_STATE/turn"
turn="$(cat "$turn_file" 2>/dev/null || echo 0)"
turn=$((turn + 1))
printf '%s\n' "$turn" > "$turn_file"

case "$FAKE_MODE:$turn" in
  needs_input:1)
    printf 'needs_input\n' > .sergeant-status
    printf 'Choose A or B.\n' > .sergeant-message
    printf '%s\n' '{"type":"session","sessionID":"ses-test-123"}'
    ;;
  blocked:1)
    printf 'blocked\n' > .sergeant-status
    printf 'Fixture unavailable.\n' > .sergeant-message
    printf '%s\n' '{"type":"session","sessionID":"ses-test-123"}'
    ;;
  poisoned_session:1)
    printf 'needs_input\n' > .sergeant-status
    printf 'Choose A or B.\n' > .sergeant-message
    printf '%s\n' '{"type":"session","sessionID":"ses-test-123"}'
    printf '%s\n' '{"type":"tool","payload":{"sessionID":"ses-evil-999"}}'
    ;;
  claude_needs_input:1)
    [[ "$*" == *"-p --output-format json --dangerously-skip-permissions"* ]]
    [[ "$*" != *"run --auto"* ]]
    printf 'needs_input\n' > .sergeant-status
    printf 'Choose A or B.\n' > .sergeant-message
    printf '%s\n' '{"type":"session","sessionID":"ses-test-123"}'
    ;;
  claude_needs_input:2)
    [[ "$*" == *"-p --output-format json --dangerously-skip-permissions --resume ses-test-123"* ]]
    [[ "$*" == *"Use option A"* ]]
    printf 'done\n' > .sergeant-status
    printf 'validated Claude result\n' > .sergeant-result
    ;;
  needs_input:2|blocked:2|poisoned_session:2)
    [[ "$*" == *"--session ses-test-123"* ]]
    [[ "$*" != *"ses-evil-999"* ]]
    [[ "$*" == *"Use option A"* ]]
    [[ "$*" == *"td-123"* ]]
    [[ "$*" == *"updated td handoff"* ]]
    [[ ! -e .sergeant-message ]]
    printf 'done\n' > .sergeant-status
    printf 'validated result\n' > .sergeant-result
    ;;
  done_without_result:1)
    printf 'done\n' > .sergeant-status
    printf '%s\n' '{"type":"session","sessionID":"ses-test-123"}'
    ;;
  unexpected_exit:1)
    printf 'in_progress\n' > .sergeant-status
    printf 'agent diagnostic output\n'
    exit 23
    ;;
  missing_session:1)
    printf 'needs_input\n' > .sergeant-status
    printf 'Need a response but no session was emitted.\n' > .sergeant-message
    ;;
  claude_missing_session:1)
    [[ "$*" == *"-p --output-format json --dangerously-skip-permissions"* ]]
    printf 'needs_input\n' > .sergeant-status
    printf 'Need a response but no session was emitted.\n' > .sergeant-message
    ;;
  resume_orphan:1)
    [[ "$*" == *"--session ses-test-123"* ]]
    [[ "$*" == *"Use option A"* ]]
    printf 'done\n' > .sergeant-status
    printf 'resumed result\n' > .sergeant-result
    ;;
  recover_without_session:1)
    [[ "$*" != *"--session"* ]]
    [[ "$*" == *"td-123"* ]]
    [[ "$*" == *"diagnostic"* ]]
    [[ "$*" == *"worker.log"* ]]
    [[ "$*" == *"git state"* ]]
    [[ "$*" != *"same session"* ]]
    printf 'done\n' > .sergeant-status
    printf 'recovered result\n' > .sergeant-result
    ;;
  submitted_response_missing_session:1)
    [[ "$*" == *"Use option A"* ]]
    printf 'needs_input\n' > .sergeant-status
    printf 'Need a response but no session was emitted.\n' > .sergeant-message
    ;;
  resume_after_submitted_response:1)
    [[ "$*" == *"--session ses-test-123"* ]]
    [[ "$*" != *"Use option A"* ]]
    [[ "$*" == *"durable worker state"* ]]
    [[ ! -e .sergeant-response ]]
    printf 'done\n' > .sergeant-status
    printf 'resumed without replay result\n' > .sergeant-result
    ;;
  legacy_response_cleanup:1)
    [[ "$*" == *"--session ses-test-123"* ]]
    [[ "$*" == *"Use option A"* ]]
    printf 'done\n' > .sergeant-status
    printf 'legacy cleanup result\n' > .sergeant-result
    ;;
  serialized_response:1)
    [[ "$*" == *"new response"* ]]
    [[ "$*" != *"old response"* ]]
    printf 'done\n' > .sergeant-status
    printf 'serialized result\n' > .sergeant-result
    ;;
  *)
    printf 'unexpected fake invocation: %s:%s\n' "$FAKE_MODE" "$turn" >&2
    exit 91
    ;;
esac
EOF
chmod +x "$fake_agent"
ln -s "$fake_agent" "$fake_claude"

wait_for_file() {
  local file="$1"
  for _ in $(seq 1 100); do
    [[ -e "$file" ]] && return 0
    sleep 0.01
  done
  printf 'timed out waiting for %s\n' "$file" >&2
  return 1
}

run_wait_resume_case() {
  local mode="$1"
  local expected_status="${2:-$mode}"
  local case_root="$TEST_ROOT/$mode"
  local worktree="$case_root/worktree"
  local repo_state="$case_root/state"
  mkdir -p "$worktree" "$repo_state"
  printf 'td-123\n' > "$repo_state/td_task"
  printf 'stale result\n' > "$repo_state/result"

  PATH="$TEST_ROOT/fake-bin:$PATH" TD_LOG="$case_root/td.log" \
    FAKE_MODE="$mode" FAKE_STATE="$case_root" SGT_WORKER_POLL_INTERVAL=0.01 \
    "$ROOT_DIR/bin/sgt-worker" "$repo_state" "$worktree" "$fake_agent" "initial mission" &
  local worker_pid=$!

  wait_for_file "$worktree/.sergeant-message"
  wait_for_file "$worktree/.sergeant-gate-generation"
  [[ ! -e "$repo_state/result" ]]
  kill -0 "$worker_pid"
  [[ "$(cat "$worktree/.sergeant-status")" == "$expected_status" ]]
  [[ "$(cat "$worktree/.sergeant-gate-generation")" == "1" ]]
  printf 'Use option A\n' > "$worktree/.sergeant-response"
  printf 'response-id-123\n' > "$worktree/.sergeant-response-id"
  printf 'response-id-123\n' > "$repo_state/response_id"
  wait "$worker_pid"

  [[ "$(cat "$worktree/.sergeant-status")" == "done" ]]
  [[ "$(cat "$worktree/.sergeant-result")" == "validated result" ]]
  [[ ! -e "$worktree/.sergeant-response" ]]
  [[ "$(cat "$repo_state/session_id")" == "ses-test-123" ]]
  [[ "$(cat "$repo_state/status")" == "done" ]]
  [[ "$(cat "$repo_state/result")" == "validated result" ]]
  [[ ! -e "$repo_state/response" ]]
  grep -Fq 'handoff td-123' "$case_root/td.log"
  grep -Fq -- "--work-dir $worktree" "$case_root/td.log"
}

run_wait_resume_case needs_input
run_wait_resume_case blocked
run_wait_resume_case poisoned_session needs_input

case_root="$TEST_ROOT/claude-needs-input"
mkdir -p "$case_root/worktree" "$case_root/state"
FAKE_MODE=claude_needs_input FAKE_STATE="$case_root" SGT_WORKER_POLL_INTERVAL=0.01 \
  "$ROOT_DIR/bin/sgt-worker" "$case_root/state" "$case_root/worktree" "$fake_claude" "initial mission" &
worker_pid=$!
wait_for_file "$case_root/worktree/.sergeant-message"
kill -0 "$worker_pid"
printf 'Use option A\n' > "$case_root/worktree/.sergeant-response"
printf 'response-id-123\n' > "$case_root/worktree/.sergeant-response-id"
printf 'response-id-123\n' > "$case_root/state/response_id"
wait "$worker_pid"
[[ "$(cat "$case_root/worktree/.sergeant-result")" == 'validated Claude result' ]]
grep -Fq -- '--dangerously-skip-permissions --resume ses-test-123' "$case_root/args"
grep -Fq -- '-p --output-format json' "$case_root/args"

case_root="$TEST_ROOT/resume-orphan"
mkdir -p "$case_root/worktree" "$case_root/state"
printf 'orphaned\n' > "$case_root/worktree/.sergeant-status"
printf 'ses-test-123\n' > "$case_root/state/session_id"
printf 'td-123\n' > "$case_root/state/td_task"
printf 'Use option A\n' > "$case_root/worktree/.sergeant-response"
printf 'response-id-123\n' > "$case_root/worktree/.sergeant-response-id"
printf 'response-id-123\n' > "$case_root/state/response_id"
PATH="$TEST_ROOT/fake-bin:$PATH" TD_LOG="$case_root/td.log" FAKE_MODE=resume_orphan FAKE_STATE="$case_root" \
  "$ROOT_DIR/bin/sgt-worker" "$case_root/state" "$case_root/worktree" "$fake_agent" "initial mission"
[[ ! -e "$case_root/worktree/.sergeant-response" ]]
[[ "$(cat "$case_root/worktree/.sergeant-result")" == 'resumed result' ]]

case_root="$TEST_ROOT/recover-without-session"
mkdir -p "$case_root/worktree" "$case_root/state"
printf 'orphaned\n' > "$case_root/worktree/.sergeant-status"
printf 'td-123\n' > "$case_root/state/td_task"
printf 'prior process exited\n' > "$case_root/state/diagnostic"
printf 'Use option A\n' > "$case_root/worktree/.sergeant-response"
printf 'response-id-123\n' > "$case_root/worktree/.sergeant-response-id"
printf 'response-id-123\n' > "$case_root/state/response_id"
PATH="$TEST_ROOT/fake-bin:$PATH" TD_LOG="$case_root/td.log" \
  FAKE_MODE=recover_without_session FAKE_STATE="$case_root" \
  "$ROOT_DIR/bin/sgt-worker" "$case_root/state" "$case_root/worktree" "$fake_agent" "initial mission"
[[ "$(cat "$case_root/worktree/.sergeant-result")" == 'recovered result' ]]

case_root="$TEST_ROOT/resume-after-submitted-response"
mkdir -p "$case_root/worktree" "$case_root/state"
printf 'orphaned\n' > "$case_root/worktree/.sergeant-status"
printf 'ses-test-123\n' > "$case_root/state/session_id"
printf 'td-123\n' > "$case_root/state/td_task"
printf 'Use option A\n' > "$case_root/worktree/.sergeant-response"
printf 'response-id-123\n' > "$case_root/worktree/.sergeant-response-id"
printf 'response-id-123\n' > "$case_root/worktree/.sergeant-response-ack"
printf 'Use option A\n' > "$case_root/state/response"
printf 'response-id-123\n' > "$case_root/state/response_id"
PATH="$TEST_ROOT/fake-bin:$PATH" TD_LOG="$case_root/td.log" \
  FAKE_MODE=resume_after_submitted_response FAKE_STATE="$case_root" \
  "$ROOT_DIR/bin/sgt-worker" "$case_root/state" "$case_root/worktree" "$fake_agent" "initial mission"
[[ "$(cat "$case_root/worktree/.sergeant-result")" == 'resumed without replay result' ]]
[[ ! -e "$case_root/worktree/.sergeant-response" && ! -e "$case_root/state/response" ]]

case_root="$TEST_ROOT/submitted-response-missing-session"
mkdir -p "$case_root/worktree" "$case_root/state"
printf 'orphaned\n' > "$case_root/worktree/.sergeant-status"
printf 'td-123\n' > "$case_root/state/td_task"
printf 'Use option A\n' > "$case_root/worktree/.sergeant-response"
printf 'response-id-123\n' > "$case_root/worktree/.sergeant-response-id"
printf 'Use option A\n' > "$case_root/state/response"
printf 'response-id-123\n' > "$case_root/state/response_id"
set +e
PATH="$TEST_ROOT/fake-bin:$PATH" TD_LOG="$case_root/td.log" \
  FAKE_MODE=submitted_response_missing_session FAKE_STATE="$case_root" \
  "$ROOT_DIR/bin/sgt-worker" "$case_root/state" "$case_root/worktree" "$fake_agent" "initial mission"
status=$?
set -e
[[ "$status" -ne 0 ]]
[[ "$(cat "$case_root/worktree/.sergeant-status")" == 'orphaned' ]]
[[ "$(cat "$case_root/worktree/.sergeant-response")" == 'Use option A' ]]
[[ "$(cat "$case_root/state/response")" == 'Use option A' ]]
[[ ! -e "$case_root/worktree/.sergeant-response-ack" ]]
grep -Fq 'OpenCode turn did not provide a resumable session ID' "$case_root/state/diagnostic"

case_root="$TEST_ROOT/legacy-response-cleanup"
mkdir -p "$case_root/worktree" "$case_root/state"
printf 'orphaned\n' > "$case_root/worktree/.sergeant-status"
printf 'ses-test-123\n' > "$case_root/state/session_id"
printf 'Use option A\n' > "$case_root/worktree/.sergeant-response"
printf 'Use option A\n' > "$case_root/state/response"
PATH="$TEST_ROOT/fake-bin:$PATH" TD_LOG="$case_root/td.log" \
  FAKE_MODE=legacy_response_cleanup FAKE_STATE="$case_root" \
  "$ROOT_DIR/bin/sgt-worker" "$case_root/state" "$case_root/worktree" "$fake_agent" "initial mission"
[[ "$(cat "$case_root/worktree/.sergeant-result")" == 'legacy cleanup result' ]]
[[ ! -e "$case_root/worktree/.sergeant-response" && ! -e "$case_root/state/response" ]]
[[ ! -e "$case_root/worktree/.sergeant-response-ack" ]]

case_root="$TEST_ROOT/serialized-response"
mkdir -p "$case_root/worktree" "$case_root/state/response.lock"
printf '%s\n' "$$" > "$case_root/state/response.lock/pid"
printf 'orphaned\n' > "$case_root/worktree/.sergeant-status"
printf 'ses-test-123\n' > "$case_root/state/session_id"
printf 'old response\n' > "$case_root/worktree/.sergeant-response"
printf 'response-id-old\n' > "$case_root/worktree/.sergeant-response-id"
printf 'response-id-old\n' > "$case_root/state/response_id"
FAKE_MODE=serialized_response FAKE_STATE="$case_root" SGT_WORKER_POLL_INTERVAL=0.01 \
  "$ROOT_DIR/bin/sgt-worker" "$case_root/state" "$case_root/worktree" "$fake_agent" "initial mission" &
worker_pid=$!
sleep 0.05
kill -0 "$worker_pid"
printf 'new response\n' > "$case_root/worktree/.sergeant-response.tmp"
mv "$case_root/worktree/.sergeant-response.tmp" "$case_root/worktree/.sergeant-response"
printf 'response-id-new\n' > "$case_root/worktree/.sergeant-response-id"
printf 'response-id-new\n' > "$case_root/state/response_id"
rm "$case_root/state/response.lock/pid"
rmdir "$case_root/state/response.lock"
wait "$worker_pid"
[[ "$(cat "$case_root/worktree/.sergeant-result")" == 'serialized result' ]]

case_root="$TEST_ROOT/missing-session"
mkdir -p "$case_root/worktree" "$case_root/state"
set +e
FAKE_MODE=missing_session FAKE_STATE="$case_root" \
  "$ROOT_DIR/bin/sgt-worker" "$case_root/state" "$case_root/worktree" "$fake_agent" "initial mission"
status=$?
set -e
[[ "$status" -ne 0 ]]
[[ "$(cat "$case_root/worktree/.sergeant-status")" == 'orphaned' ]]
grep -Fq 'OpenCode turn did not provide a resumable session ID' "$case_root/state/diagnostic"

case_root="$TEST_ROOT/claude-missing-session"
mkdir -p "$case_root/worktree" "$case_root/state"
set +e
FAKE_MODE=claude_missing_session FAKE_STATE="$case_root" \
  "$ROOT_DIR/bin/sgt-worker" "$case_root/state" "$case_root/worktree" "$fake_claude" "initial mission"
status=$?
set -e
[[ "$status" -ne 0 ]]
[[ "$(cat "$case_root/worktree/.sergeant-status")" == 'orphaned' ]]
grep -Fq 'Claude did not provide a resumable session ID' "$case_root/state/diagnostic"

case_root="$TEST_ROOT/done-without-result"
mkdir -p "$case_root/worktree" "$case_root/state"
set +e
FAKE_MODE=done_without_result FAKE_STATE="$case_root" \
  "$ROOT_DIR/bin/sgt-worker" "$case_root/state" "$case_root/worktree" "$fake_agent" "initial mission"
status=$?
set -e
[[ "$status" -ne 0 ]]
[[ "$(cat "$case_root/worktree/.sergeant-status")" == "orphaned" ]]
grep -Fq 'terminal status done requires .sergeant-result' "$case_root/state/diagnostic"

case_root="$TEST_ROOT/unexpected-exit"
mkdir -p "$case_root/worktree" "$case_root/state"
printf 'td-123\n' > "$case_root/state/td_task"
set +e
PATH="$TEST_ROOT/fake-bin:$PATH" TD_LOG="$case_root/td.log" FAKE_MODE=unexpected_exit FAKE_STATE="$case_root" \
  "$ROOT_DIR/bin/sgt-worker" "$case_root/state" "$case_root/worktree" "$fake_agent" "initial mission"
status=$?
set -e
[[ "$status" -eq 23 ]]
[[ "$(cat "$case_root/worktree/.sergeant-status")" == "orphaned" ]]
grep -Fq 'exit code: 23' "$case_root/state/diagnostic"
grep -Fq 'agent diagnostic output' "$case_root/state/worker.log"
grep -Fq 'handoff td-123' "$case_root/td.log"
grep -Fq 'Read fleet state at' "$case_root/td.log"
grep -Fq 'reconcile with current git state' "$case_root/td.log"

case_root="$TEST_ROOT/launch-failure"
mkdir -p "$case_root/worktree" "$case_root/state"
set +e
"$ROOT_DIR/bin/sgt-worker" "$case_root/state" "$case_root/worktree" "$case_root/missing-agent" "initial mission"
status=$?
set -e
[[ "$status" -eq 127 ]]
[[ "$(cat "$case_root/worktree/.sergeant-status")" == "orphaned" ]]
grep -Fq 'exit code: 127' "$case_root/state/diagnostic"

printf 'sgt-worker lifecycle: ok\n'
