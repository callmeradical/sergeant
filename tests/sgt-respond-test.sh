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
printf '0|%%42|4242|123456|sgt-interactive-worker:%s\n' "$repo_state" > "$repo_state/pane_identity"
printf 'sgt\n' > "$repo_state/tmux_session"
printf 'task/app\n' > "$repo_state/window_name"
printf 'fake-opencode\n' > "$repo_state/agent"
printf 'initial mission\n' > "$repo_state/initial_message"
printf 'needs_input\n' > "$worktree/.sergeant-status"
printf 'needs_input\n' > "$repo_state/status"
printf '1\n' > "$worktree/.sergeant-gate-generation"
cat > "$fleet/task-1/.sergeant-intent.md" <<'EOF'
## Objective

Resume safely.
EOF
cp "$fleet/task-1/.sergeant-intent.md" "$repo_state/.sergeant-intent.md"
cp "$fleet/task-1/.sergeant-intent.md" "$worktree/.sergeant-intent.md"
bash -c 'source "$1"; _sgt_intent_revision "$2"' _ \
  "$ROOT_DIR/bin/_sgt-intent.sh" "$fleet/task-1/.sergeant-intent.md" \
  > "$fleet/task-1/intent_revision"
cp "$fleet/task-1/intent_revision" "$repo_state/intent_revision"

cat > "$fake_bin/tmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TMUX_LOG"
case "$1" in
  display-message)
    [[ "${PANE_ALIVE:-0}" == 1 ]] || exit 1
    printf '%s\n' "${PANE_IDENTITY:-0|%42|4242|123456|sgt-interactive-worker:$EXPECTED_WORKER}"
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

respond() {
  local response_body="$1"
  printf '%s' "$response_body" | "$ROOT_DIR/bin/sgt-respond" task-1 app
}

set +e
output="$(SERGEANT_FLEET="$fleet" "$ROOT_DIR/bin/sgt-respond" task-1 app 'argv body rejected' 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 && "$output" == *'reads the response from standard input'* ]]
[[ ! -e "$repo_state/response" && ! -e "$worktree/.sergeant-response" ]]

# shellcheck disable=SC2016
# Literal metacharacters verify response data is never evaluated.
response='Use option A; $(touch should-not-exist)'
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/live.log" TD_LOG="$TEST_ROOT/td.log" \
TD_RESPONSE_FILE="$worktree/.sergeant-response" PANE_ALIVE=1 EXPECTED_WORKER="$repo_state" SERGEANT_FLEET="$fleet" \
  respond "$response" >/dev/null
[[ "$(cat "$repo_state/response")" == "$response" ]]
[[ "$(cat "$worktree/.sergeant-response")" == "$response" ]]
[[ "$(cat "$repo_state/pane")" == "%42" ]]
grep -Fq 'send-keys -t %42 -l -- Sergeant response available in .sergeant-response' \
  "$TEST_ROOT/live.log"
if grep -Fq "$response" "$TEST_ROOT/live.log"; then
  printf 'response body leaked into tmux process arguments\n' >&2
  exit 1
fi
[[ ! -e "$ROOT_DIR/should-not-exist" ]]
grep -Fq 'log td-123' "$TEST_ROOT/td.log"
grep -Fq -- '--decision' "$TEST_ROOT/td.log"
grep -Eq 'response-id=[a-f0-9]{32}' "$TEST_ROOT/td.log"
[[ "$(cat "$repo_state/response_id")" =~ ^[a-f0-9]{32}$ ]]
[[ "$(cat "$worktree/.sergeant-response-id")" == "$(cat "$repo_state/response_id")" ]]
[[ "$(cat "$repo_state/response_generation")" == "1" ]]
[[ "$(cat "$worktree/.sergeant-response-generation")" == "1" ]]
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
  respond 'Use option B' >/dev/null 2>&1
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
  respond 'serialized response' >/dev/null &
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
  respond 'late response' >/dev/null 2>&1
late_status=$?
set -e
[[ "$late_status" -ne 0 ]]
[[ ! -e "$worktree/.sergeant-response" && ! -e "$repo_state/response" ]]

printf 'in_progress\n' > "$worktree/.sergeant-status"
printf 'in_progress\n' > "$repo_state/status"
set +e
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/active.log" TD_LOG="$TEST_ROOT/active-td.log" \
TD_RESPONSE_FILE="$worktree/.sergeant-response" PANE_ALIVE=1 EXPECTED_WORKER="$repo_state" SERGEANT_FLEET="$fleet" \
  respond 'active response' >/dev/null 2>&1
active_status=$?
set -e
[[ "$active_status" -ne 0 ]]
[[ ! -e "$worktree/.sergeant-response" && ! -e "$repo_state/response" ]]

printf 'needs_input\n' > "$worktree/.sergeant-status"
printf 'needs_input\n' > "$repo_state/status"

rm -f "$worktree/.sergeant-response"
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/dead.log" TD_LOG="$TEST_ROOT/td.log" \
TD_RESPONSE_FILE="$worktree/.sergeant-response" PANE_ALIVE=1 \
  PANE_IDENTITY="0|%42|4242|123456|bash sgt-interactive-worker:$repo_state" \
  EXPECTED_WORKER="$repo_state" SERGEANT_FLEET="$fleet" \
  respond 'resume dead worker' >/dev/null
[[ "$(cat "$repo_state/pane")" == "%99" ]]
grep -Fq 'new-window -P -F #{pane_id} -t sgt: -n task/app' "$TEST_ROOT/dead.log"
grep -Fq "$ROOT_DIR/bin/sgt-interactive-worker" "$TEST_ROOT/dead.log"
grep -Fq 'send-keys -t %99 -l -- Sergeant response available in .sergeant-response' \
  "$TEST_ROOT/dead.log"

rm "$worktree/.sergeant-response" "$repo_state/response"
cat > "$fake_bin/td" <<'EOF'
#!/usr/bin/env bash
exit 19
EOF
chmod +x "$fake_bin/td"
set +e
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/td-failure-tmux.log" PANE_ALIVE=1 \
SERGEANT_FLEET="$fleet" respond 'must not publish' >/dev/null 2>&1
status=$?
set -e
[[ "$status" -ne 0 ]]
[[ ! -e "$worktree/.sergeant-response" && ! -e "$repo_state/response" ]]
if compgen -G "$worktree/.sergeant-response.tmp.*" >/dev/null; then
  printf 'atomic response temporary file was retained\n' >&2
  exit 1
fi
cat > "$fake_bin/td" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TD_LOG"
EOF
chmod +x "$fake_bin/td"

printf 'needs_input\n' > "$repo_state/status"
printf 'needs_input\n' > "$worktree/.sergeant-status"
rm -f "$worktree/.sergeant-response" "$repo_state/response"
set +e
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/relaunch-fail.log" TD_LOG="$TEST_ROOT/relaunch-fail-td.log" PANE_ALIVE=0 FAIL_WINDOW=1 \
SERGEANT_FLEET="$fleet" respond 'relaunch fails' >/dev/null 2>&1
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
  respond 'empty pane' >/dev/null 2>&1
status=$?
set -e
[[ "$status" -ne 0 ]]
[[ "$(cat "$worktree/.sergeant-status")" == 'orphaned' ]]
grep -Fq 'tmux returned no pane for relaunched worker supervisor' "$repo_state/diagnostic"
grep -Fq 'handoff td-123' "$TEST_ROOT/empty-pane-td.log"

printf 'orphaned\n' > "$repo_state/status"
printf 'orphaned\n' > "$worktree/.sergeant-status"
rm -f "$worktree/.sergeant-gate-generation" "$worktree/.sergeant-response" \
  "$worktree/.sergeant-response-generation" "$repo_state/response" \
  "$repo_state/response_generation" "$repo_state/response_id"
set +e
PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/orphan-no-gate.log" \
  TD_LOG="$TEST_ROOT/orphan-no-gate-td.log" PANE_ALIVE=0 FAIL_WINDOW=1 \
  SERGEANT_FLEET="$fleet" respond 'recover orphan without gate' >/dev/null 2>&1
status=$?
set -e
[[ "$status" -ne 0 ]]
[[ "$(cat "$worktree/.sergeant-gate-generation")" == '1' ]]
[[ "$(cat "$repo_state/response_generation")" == '1' ]]

printf 'needs_input\n' > "$repo_state/status"
printf 'needs_input\n' > "$worktree/.sergeant-status"
rm -f "$worktree/.sergeant-response" "$worktree/.sergeant-response-generation" \
  "$repo_state/response" "$repo_state/response_generation" "$repo_state/response_id"
printf '\nSilent drift.\n' >> "$worktree/.sergeant-intent.md"
set +e
output="$(PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/intent-drift.log" TD_LOG="$TEST_ROOT/intent-drift-td.log" \
  PANE_ALIVE=0 SERGEANT_FLEET="$fleet" \
  respond 'must not resume drifted intent' 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 && "$output" == *'canonical intent revision mismatch'* ]] || {
  printf 'recovery did not reject silent intent drift: %s\n' "$output" >&2
  exit 1
}
[[ ! -e "$worktree/.sergeant-response" && ! -e "$repo_state/response" ]] || {
  printf 'recovery published a response after intent drift\n' >&2
  exit 1
}

printf 'sgt-respond resumes workers: ok\n'
