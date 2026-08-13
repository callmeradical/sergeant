#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
export SERGEANT_FLEET="$TEST_ROOT/fleet"
export SERGEANT_CONFIG="$TEST_ROOT/config"
export SERGEANT_DRAIN_DIR="$TEST_ROOT/drain"
mkdir -p "$SERGEANT_FLEET/task-race/app" "$SERGEANT_CONFIG" \
  "$SERGEANT_DRAIN_DIR" "$TEST_ROOT/bin" "$TEST_ROOT/worktree"
state="$SERGEANT_FLEET/task-race/app"
git -C "$TEST_ROOT/worktree" init -q
git -C "$TEST_ROOT/worktree" -c user.name=Test -c user.email=t@t \
  commit -q --allow-empty -m fixture
cat > "$SERGEANT_CONFIG/test.yaml" <<EOF
repos:
  - name: app
    path: $TEST_ROOT/worktree
EOF
printf 'Project: test\nBrief: race\nBranch: main\nRepos: app\n' \
  > "$SERGEANT_FLEET/task-race/brief.md"
printf 'orphaned\n' > "$state/status"
printf 'main\n' > "$state/branch"
printf '%s\n' "$TEST_ROOT/worktree" > "$state/worktree"
printf 'opencode\n' > "$state/agent"
printf 'test\n' > "$state/project"
printf 'sgt-race\n' > "$state/tmux_session"
printf '%%88\n' > "$state/pane"

cat > "$TEST_ROOT/bin/opencode" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$TEST_ROOT/bin/tmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  new-session) exit 0 ;;
  new-window)
    printf 'launch\n' >> "$LAUNCH_LOG"
    command="${!#}"
    printf '%s\n' "$command" > "$PANE_COMMAND"
    sleep 0.2
    printf '%%99\n'
    ;;
  display-message)
    [[ "$*" == *'-t %99'* ]] || exit 1
    identity="0|%99|9999|123456|$(cat "$PANE_COMMAND")"
    if [[ -s "$TEST_REPO_STATE/notification_id" && \
      -s "$TEST_REPO_STATE/notification_target" ]]; then
      notification_id="$(cat "$TEST_REPO_STATE/notification_id")"
      nonce="$(cat "$TEST_REPO_STATE/notification_target")"
      target="$TEST_REPO_STATE/notifications/$notification_id/targets/$nonce"
      token="$notification_id|$nonce"
      printf '%s\n' "$token" > "$target/accepted"
      printf '%s\n' "$token" > "$target/delivered"
    fi
    printf '%s\n' "$identity"
    ;;
  kill-pane|send-keys) exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$TEST_ROOT/bin/opencode" "$TEST_ROOT/bin/tmux"

run_resume() {
  PATH="$TEST_ROOT/bin:$PATH" LAUNCH_LOG="$TEST_ROOT/launch.log" \
    PANE_COMMAND="$TEST_ROOT/pane-command" TEST_REPO_STATE="$state" \
    SGT_NOTIFICATION_ACK_TIMEOUT=2 \
    "$ROOT_DIR/bin/sgt-session-resume" task-race app --force >/dev/null 2>&1
}
run_resume & first=$!
run_resume & second=$!
wait "$first"
wait "$second"
[[ "$(wc -l < "$TEST_ROOT/launch.log")" -eq 1 ]]
[[ "$(cat "$state/status")" == in_progress ]]
printf 'sgt-session-resume concurrent ownership: ok\n'
