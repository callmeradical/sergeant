#!/usr/bin/env bash

set -euo pipefail
export TMUX=fixture TMUX_PANE=%11

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/config" "$TEST_ROOT/fleet" "$TEST_ROOT/fake-bin" "$TEST_ROOT/repo"

cat > "$TEST_ROOT/config/test.yaml" <<EOF
name: test
repos:
  - name: app
    path: $TEST_ROOT/repo
EOF
cat > "$TEST_ROOT/fake-bin/tmux" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "display-message" ]] || printf '%s\n' "$*" >> "$TMUX_LOG"
case "$1" in
  has-session) exit 0 ;;
  display-message)
    if [[ "$*" == *'-t %11'* ]]; then
      printf '0|%%11|1111|111111|coordinator-command\n'
    else
      printf '0|%%42|4242|123456|fixture-worker-command\n'
    fi
    ;;
  new-window)
    [[ "${FAIL_WINDOW:-0}" == 0 ]] || exit 7
    printf '%%42\n'
    ;;
  send-keys)
    [[ "${FAIL_SEND:-0}" == 0 ]] || exit 8
    ;;
  kill-pane) ;;
esac
EOF
chmod +x "$TEST_ROOT/fake-bin/tmux"
cat > "$TEST_ROOT/fake-bin/td" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

if [[ "${1:-}" == "--version" ]]; then
  printf 'td version v0.1.0\n'
  exit 0
fi
if [[ "${1:-}" == "create" && "${2:-}" == "--help" ]]; then
  printf '%s\n' '--description --json --work-dir'
  exit 0
fi

args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --work-dir|-w)
      shift 2
      ;;
    --json)
      shift
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done

set -- "${args[@]}"
case "${1:-}" in
  list)
    printf '[]\n'
    ;;
  create)
    printf '{"id":"td-app-1"}\n'
    ;;
  delete)
    printf '{"id":"td-app-1","deleted":true}\n'
    ;;
  *)
    exit 1
    ;;
esac
EOF
chmod +x "$TEST_ROOT/fake-bin/td"
for agent in opencode goose claude; do
  cat > "$TEST_ROOT/fake-bin/$agent" <<'EOF'
#!/usr/bin/env bash
if [[ "$(basename "$0")" == "goose" && "${FAIL_GOOSE_CAPABILITY:-0}" == "1" ]]; then
  exit 9
fi
exit 0
EOF
  chmod +x "$TEST_ROOT/fake-bin/$agent"
done
git -C "$TEST_ROOT/repo" init -q
git -C "$TEST_ROOT/repo" config user.name Test
git -C "$TEST_ROOT/repo" config user.email test@example.invalid
touch "$TEST_ROOT/repo/README.md"
git -C "$TEST_ROOT/repo" add README.md
git -C "$TEST_ROOT/repo" commit -qm fixture
git -C "$TEST_ROOT/repo" remote add origin git@github.com:org/test.git

PATH="$TEST_ROOT/fake-bin:$PATH" TMUX_LOG="$TEST_ROOT/success.log" \
SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-dispatch" test 'Supervise worker' --repos app >/dev/null
repo_state="$(printf '%s\n' "$TEST_ROOT"/fleet/*/app)"
task_id="$(basename "$(dirname "$repo_state")")"
[[ "$(cat "$repo_state/pane")" == "%42" ]]
[[ "$(cat "$repo_state/pane_identity")" == '0|%42|4242|123456|fixture-worker-command' ]]
[[ "$(cat "$repo_state/agent")" == "${SERGEANT_AGENT:-opencode}" ]]
[[ "$(cat "$repo_state/stage")" == "implementation" ]]
[[ "$(cat "$repo_state/window_name")" == "implementation-app-$task_id" ]]
[[ ! -e "$repo_state/initial_message" ]]
[[ -s "$repo_state/tmux_session" && -s "$repo_state/window_name" ]]
grep -Fq "$ROOT_DIR/bin/sgt-interactive-worker" "$TEST_ROOT/success.log"
if grep -Fq "$ROOT_DIR/bin/sgt-worker " "$TEST_ROOT/success.log" || \
  grep -Fq 'run --auto' "$TEST_ROOT/success.log" || \
  grep -Fq -- '--prompt' "$TEST_ROOT/success.log"; then
  printf 'dispatch used a prohibited non-interactive worker mode\n' >&2
  exit 1
fi
new_window_line="$(grep '^new-window ' "$TEST_ROOT/success.log")"
[[ "$new_window_line" != *'Read the .sergeant-brief.md file and execute the mission.'* ]]
grep -Fq 'send-keys -t %42 -l -- Read the .sergeant-brief.md file and execute the mission.' \
  "$TEST_ROOT/success.log"
grep -Fq 'send-keys -t %42 Enter' "$TEST_ROOT/success.log"
brief="$(cat "$repo_state/worktree")/.sergeant-brief.md"
grep -Fq 'persistent interactive agent session' "$brief"
grep -Fq 'Non-interactive agent modes are prohibited' "$brief"
grep -Fq 'orphaned' "$brief"
grep -Fq 'sgt-respond' "$brief"
grep -Fq 'requires both .sergeant-status=done and a non-empty .sergeant-result' "$brief"

for agent in goose claude; do
  PATH="$TEST_ROOT/fake-bin:$PATH" TMUX_LOG="$TEST_ROOT/$agent.log" \
  SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
    "$ROOT_DIR/bin/sgt-dispatch" test "Supervise $agent worker" --repos app \
      --agent "$agent" >/dev/null
  agent_state="$(printf '%s\n' "$TEST_ROOT"/fleet/supervise-$agent-worker-*/app)"
  [[ "$(cat "$agent_state/agent")" == "$agent" ]]
  grep -Fq "$ROOT_DIR/bin/sgt-interactive-worker" "$TEST_ROOT/$agent.log"
  if grep -Fq 'goose run' "$TEST_ROOT/$agent.log" || \
    grep -Fq -- '--print' "$TEST_ROOT/$agent.log"; then
    printf 'dispatch used a prohibited %s one-shot mode\n' "$agent" >&2
    exit 1
  fi
done

PATH="$TEST_ROOT/fake-bin:$PATH" TMUX_LOG="$TEST_ROOT/stage.log" \
SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-dispatch" test 'Review stage worker' --repos app \
    --agent goose --stage spec >/dev/null
stage_state="$(printf '%s\n' "$TEST_ROOT"/fleet/review-stage-worker-*/app)"
stage_task_id="$(basename "$(dirname "$stage_state")")"
[[ "$(cat "$stage_state/stage")" == "spec" ]]
[[ "$(cat "$stage_state/window_name")" == "spec-app-$stage_task_id" ]]
grep -Fq -- "-n spec-app-$stage_task_id" "$TEST_ROOT/stage.log"

before_count="$(find "$TEST_ROOT/fleet" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
set +e
output="$(PATH="$TEST_ROOT/fake-bin:$PATH" TMUX_LOG="$TEST_ROOT/invalid-stage.log" \
  SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-dispatch" test 'Invalid stage worker' --repos app \
    --stage 'spec/review' 2>&1)"
status=$?
set -e
after_count="$(find "$TEST_ROOT/fleet" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
[[ "$status" -ne 0 && "$output" == *"stage must be a lowercase slug"* ]]
[[ "$before_count" == "$after_count" ]]
[[ ! -e "$TEST_ROOT/invalid-stage.log" ]]

env -u SERGEANT_AGENT -u OPENCODE -u OPENCODE_PID \
  PATH="$TEST_ROOT/fake-bin:$PATH" TMUX_LOG="$TEST_ROOT/claude-detected.log" \
  CLAUDE_CODE_SESSION_ID=claude-session SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-dispatch" test 'Detect Claude worker' --repos app >/dev/null
detected_state="$(printf '%s\n' "$TEST_ROOT"/fleet/detect-claude-worker-*/app)"
[[ "$(cat "$detected_state/agent")" == "claude" ]]

before_count="$(find "$TEST_ROOT/fleet" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
set +e
output="$(PATH="$TEST_ROOT/fake-bin:$PATH" TMUX_LOG="$TEST_ROOT/goose-capability.log" \
  FAIL_GOOSE_CAPABILITY=1 SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-dispatch" test 'Missing Goose capability' --repos app \
    --agent goose 2>&1)"
status=$?
set -e
after_count="$(find "$TEST_ROOT/fleet" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
[[ "$status" -ne 0 && "$output" == *"does not support interactive sessions"* ]]
[[ "$before_count" == "$after_count" ]]
[[ ! -e "$TEST_ROOT/goose-capability.log" ]]

set +e
PATH="$TEST_ROOT/fake-bin:$PATH" TMUX_LOG="$TEST_ROOT/failure.log" FAIL_WINDOW=1 \
SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-dispatch" test 'Fail worker launch' --repos app >/dev/null 2>&1
status=$?
set -e
[[ "$status" -ne 0 ]]
failed_state="$(printf '%s\n' "$TEST_ROOT"/fleet/fail-worker-launch-*/app)"
[[ "$(cat "$failed_state/status")" == "orphaned" ]]
grep -Fq 'tmux failed to launch worker supervisor' "$failed_state/diagnostic"

set +e
PATH="$TEST_ROOT/fake-bin:$PATH" TMUX_LOG="$TEST_ROOT/send-failure.log" FAIL_SEND=1 \
SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-dispatch" test 'Fail brief delivery' --repos app >/dev/null 2>&1
status=$?
set -e
[[ "$status" -ne 0 ]]
send_failed_state="$(printf '%s\n' "$TEST_ROOT"/fleet/fail-brief-delivery-*/app)"
[[ "$(cat "$send_failed_state/status")" == "orphaned" ]]
grep -Fq 'tmux failed to deliver interactive worker brief' "$send_failed_state/diagnostic"
grep -Fq 'kill-pane -t %42' "$TEST_ROOT/send-failure.log"

before_count="$(find "$TEST_ROOT/fleet" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
set +e
output="$(PATH="$TEST_ROOT/fake-bin:$PATH" TMUX_LOG="$TEST_ROOT/unsupported.log" \
  SERGEANT_AGENT=fake-agent SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-dispatch" test 'Unsupported agent' --repos app 2>&1)"
status=$?
set -e
after_count="$(find "$TEST_ROOT/fleet" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
[[ "$status" -ne 0 && "$output" == *"unsupported interactive agent"* ]]
[[ "$before_count" == "$after_count" ]]
[[ ! -e "$TEST_ROOT/unsupported.log" ]]

removed_flag="--""remote"
before_count="$(find "$TEST_ROOT/fleet" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
rm -f "$TEST_ROOT/removed-option-tmux.log"
set +e
output="$(PATH="$TEST_ROOT/fake-bin:$PATH" TMUX_LOG="$TEST_ROOT/removed-option-tmux.log" \
  SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-dispatch" test 'Removed option' --repos app "$removed_flag" 2>&1)"
status=$?
set -e
after_count="$(find "$TEST_ROOT/fleet" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
[[ "$status" -ne 0 ]]
[[ "$output" == *"Unknown option"* ]]
[[ "$before_count" == "$after_count" ]]
[[ ! -e "$TEST_ROOT/removed-option-tmux.log" ]]

printf 'sgt-dispatch supervisor launch: ok\n'
