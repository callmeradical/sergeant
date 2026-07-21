#!/usr/bin/env bash

set -euo pipefail

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
printf '%s\n' "$*" >> "$TMUX_LOG"
case "$1" in
  has-session) exit 0 ;;
  new-window)
    [[ "${FAIL_WINDOW:-0}" == 0 ]] || exit 7
    printf '%%42\n'
    ;;
esac
EOF
chmod +x "$TEST_ROOT/fake-bin/tmux"
cat > "$TEST_ROOT/fake-bin/babydriver" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BABYDRIVER_LOG"
case "$1" in
  start)
    [[ "${FAIL_START:-0}" == 0 ]] || exit 17
    if [[ -n "${BABYDRIVER_START_JSON:-}" ]]; then
      printf '%s\n' "$BABYDRIVER_START_JSON"
    else
      printf '%s\n' '{"session":"test-drive","tasks":[{"window":"unknown","task_id":"td-remote-123"}]}'
    fi
    ;;
esac
EOF
chmod +x "$TEST_ROOT/fake-bin/babydriver"
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
[[ "$(cat "$repo_state/pane")" == "%42" ]]
[[ "$(cat "$repo_state/agent")" == "${SERGEANT_AGENT:-opencode}" ]]
[[ "$(cat "$repo_state/initial_message")" == 'Read the .sergeant-brief.md file and execute the mission.' ]]
[[ -s "$repo_state/tmux_session" && -s "$repo_state/window_name" ]]
grep -Fq "$ROOT_DIR/bin/sgt-worker" "$TEST_ROOT/success.log"
brief="$(cat "$repo_state/worktree")/.sergeant-brief.md"
grep -Fq 'persistent supervisor' "$brief"
grep -Fq 'Do not use sleep to keep the agent process alive' "$brief"
grep -Fq 'orphaned' "$brief"
grep -Fq 'sgt-respond' "$brief"
grep -Fq 'requires both .sergeant-status=done and a non-empty .sergeant-result' "$brief"

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

PATH="$TEST_ROOT/fake-bin:$PATH" TMUX_LOG="$TEST_ROOT/remote-tmux.log" BABYDRIVER_LOG="$TEST_ROOT/babydriver.log" \
BABYDRIVER_START_JSON='{"session":"test-drive","project_dir":"/remote/project","tasks":[{"window":"remote-window","task_id":"td-remote-123"}]}' \
SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-dispatch" test 'Supervise remote' --repos app --remote >/dev/null
remote_state="$(printf '%s\n' "$TEST_ROOT"/fleet/supervise-remote-*/app)"
[[ "$(cat "$remote_state/backend")" == "remote-babydriver" ]]
[[ "$(cat "$remote_state/remote_session")" == "test-drive" ]]
[[ "$(cat "$remote_state/remote_window")" == "remote-window" ]]
[[ "$(cat "$remote_state/remote_td_task")" == "td-remote-123" ]]
[[ "$(cat "$remote_state/remote_project_dir")" == "/remote/project" ]]
[[ ! -e "$remote_state/pane" ]]
grep -Fq 'start --repo org/test --task ' "$TEST_ROOT/babydriver.log"
grep -Fq 'Supervise remote [sgt:' "$TEST_ROOT/babydriver.log"

set +e
PATH="$TEST_ROOT/fake-bin:$PATH" TMUX_LOG="$TEST_ROOT/remote-failure-tmux.log" BABYDRIVER_LOG="$TEST_ROOT/babydriver-failure.log" \
FAIL_START=1 SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-dispatch" test 'Fail remote worker' --repos app --remote >/dev/null 2>&1
status=$?
set -e
[[ "$status" -ne 0 ]]
remote_failed_state="$(printf '%s\n' "$TEST_ROOT"/fleet/fail-remote-worker-*/app)"
[[ "$(cat "$remote_failed_state/status")" == "orphaned" ]]
grep -Fq 'babydriver start failed' "$remote_failed_state/diagnostic"

printf 'sgt-dispatch supervisor launch: ok\n'
