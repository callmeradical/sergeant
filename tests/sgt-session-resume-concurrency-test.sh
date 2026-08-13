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
    [[ -z "${NEW_WINDOW_BARRIER:-}" ]] || : > "$NEW_WINDOW_BARRIER"
    sleep "${NEW_WINDOW_DELAY:-0.2}"
    printf '%%99\n'
    ;;
  display-message)
    if [[ "$*" == *'-t %88'* ]]; then
      [[ "${OLD_PANE_GONE:-}" != 1 ]] || exit 1
      printf '0|%%88|8888|123455|old-worker\n'
      exit 0
    fi
    [[ "$*" == *'-t %99'* ]] || exit 1
    if [[ -n "${FAST_EXIT_FILE:-}" && -e "$FAST_EXIT_FILE" ]]; then
      exit 1
    fi
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
    [[ -z "${FAST_EXIT_FILE:-}" ]] || : > "$FAST_EXIT_FILE"
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

# The same transaction also serializes the distinct recovery CLI. Both callers
# may pass their pre-lock checks, but the loser observes the winner's exact pane
# generation and must not launch again or replace marker history.
: > "$TEST_ROOT/launch.log"
printf '%%88\n' > "$state/pane"
printf '0|%%88|8888|123455|old-worker\n' > "$state/pane_identity"
chmod 600 "$state/pane_identity"
printf 'in_progress\n' > "$state/status"
printf 'live worker stalled: fixture\n' > "$state/diagnostic"
printf 'implementation-app-task-race\n' > "$state/window_name"
run_resume & first=$!
PATH="$TEST_ROOT/bin:$PATH" LAUNCH_LOG="$TEST_ROOT/launch.log" \
  PANE_COMMAND="$TEST_ROOT/pane-command" TEST_REPO_STATE="$state" \
  SGT_NOTIFICATION_ACK_TIMEOUT=2 \
  "$ROOT_DIR/bin/sgt-recover" task-race app >/dev/null 2>&1 & second=$!
wait "$first"
wait "$second"
[[ "$(wc -l < "$TEST_ROOT/launch.log")" -eq 1 ]]
_sgt_history_lines="$(wc -l < "$state/worker_process_markers")"
[[ "$_sgt_history_lines" -ge 1 && "$_sgt_history_lines" -le 64 ]]

# A winner may publish its generation and then disappear before the loser gets
# the transaction lock. The durable generation snapshot, not pane liveness,
# suppresses the loser's second launch.
: > "$TEST_ROOT/launch.log"
rm -f "$TEST_ROOT/fast-exit"
printf '%%88\n' > "$state/pane"
printf '0|%%88|8888|123455|old-worker\n' > "$state/pane_identity"
chmod 600 "$state/pane_identity"
printf 'orphaned\n' > "$state/status"
run_resume_fast_exit() {
  local runner="$1" status
  set +e
  PATH="$TEST_ROOT/bin:$PATH" LAUNCH_LOG="$TEST_ROOT/launch.log" \
    PANE_COMMAND="$TEST_ROOT/pane-command" TEST_REPO_STATE="$state" \
    FAST_EXIT_FILE="$TEST_ROOT/fast-exit" OLD_PANE_GONE=1 \
    NEW_WINDOW_BARRIER="$TEST_ROOT/winner-in-window" NEW_WINDOW_DELAY=0.5 \
    SGT_NOTIFICATION_ACK_TIMEOUT=1 \
    "$ROOT_DIR/bin/sgt-session-resume" task-race app --force \
      >"$TEST_ROOT/fast-$runner.out" 2>&1
  status=$?
  printf '%s\n' "$status" > "$TEST_ROOT/fast-$runner.status"
}
run_resume_fast_exit one & first=$!
for _ in $(seq 1 100); do
  [[ -e "$TEST_ROOT/winner-in-window" ]] && break
  sleep 0.01
done
[[ -e "$TEST_ROOT/winner-in-window" ]]
run_resume_fast_exit two & second=$!
wait "$first"
wait "$second"
[[ "$(wc -l < "$TEST_ROOT/launch.log")" -eq 1 ]]
[[ "$(cat "$TEST_ROOT/fast-one.status")" == 0 || \
  "$(cat "$TEST_ROOT/fast-two.status")" == 0 ]]
grep -hFq 'verified peer worker-launch transaction completed' \
  "$TEST_ROOT/fast-one.out" "$TEST_ROOT/fast-two.out"

# Mere exact lock contention is not completion evidence. A peer that acquires
# and releases without publishing a nonce-bound journal must not suppress the
# real resume.
: > "$TEST_ROOT/launch.log"
rm -f "$TEST_ROOT/lock-only-ready"
printf '%%88\n' > "$state/pane"
printf '0|%%88|8888|123455|old-worker\n' > "$state/pane_identity"
chmod 600 "$state/pane_identity"
bash -c '
  source "$1/bin/_sgt-lib.sh"
  source "$1/bin/_sgt-drain.sh"
  _sgt_drain_lock_acquire_fd 8 lock-only "$2/worker-launch.lock"
  : > "$3"
  sleep 0.4
  _sgt_drain_lock_release_fd 8
' _ "$ROOT_DIR" "$state" "$TEST_ROOT/lock-only-ready" & lock_only_pid=$!
for _ in $(seq 1 100); do
  [[ -e "$TEST_ROOT/lock-only-ready" ]] && break
  sleep 0.01
done
[[ -e "$TEST_ROOT/lock-only-ready" ]]
PATH="$TEST_ROOT/bin:$PATH" LAUNCH_LOG="$TEST_ROOT/launch.log" \
  PANE_COMMAND="$TEST_ROOT/pane-command" TEST_REPO_STATE="$state" \
  OLD_PANE_GONE=1 SGT_NOTIFICATION_ACK_TIMEOUT=2 \
  "$ROOT_DIR/bin/sgt-session-resume" task-race app --force >/dev/null
wait "$lock_only_pid"
[[ "$(wc -l < "$TEST_ROOT/launch.log")" -eq 1 ]]
printf 'sgt-session-resume concurrent ownership: ok\n'
