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
  "$TEST_ROOT/recovery/state" "$TEST_ROOT/recovery/worktree" \
  "$TEST_ROOT/replacement/state" "$TEST_ROOT/replacement/worktree" \
  "$TEST_ROOT/race/state" "$TEST_ROOT/race/worktree" \
  "$TEST_ROOT/failure-bin" \
  "$TEST_ROOT/rejected" \
  "$TEST_ROOT/orphan/state" "$TEST_ROOT/orphan/worktree"

cat > "$TEST_ROOT/fake-bin/opencode" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${RACE_ROLE:-}" ]]; then
  IFS= read -r notification
  [[ "$notification" == *"$RACE_NOTIFICATION_ID"* ]] || exit 41
  printf '%s\n' "$RACE_NOTIFICATION_ID" >> "$RACE_RECEIVED_LOG"
  touch "$RACE_PROMPT_FILE"
  while [[ ! -e "$RACE_ACK_RELEASE" ]]; do sleep 0.01; done
  printf '%s\n' "$RACE_NOTIFICATION_ID" > .sergeant-notification-ack
  touch "$RACE_ACK_FILE"
  while [[ ! -e "$RACE_EXIT_FILE" ]]; do sleep 0.01; done
  printf 'needs_input\n' > .sergeant-status
  exit 0
fi
notification_count="${EXPECT_NOTIFICATION_COUNT:-0}"
for notification_number in $(seq 1 "$notification_count"); do
  [[ "$notification_number" != 1 ]] || sleep "${FAKE_STARTUP_DELAY:-0}"
  IFS= read -r notification
  notification_id="$(cat "$NOTIFICATION_STATE/notification_id")"
  [[ "$notification" == *"$notification_id"* ]] || exit 18
  printf '%s\n' "$notification_id" >> "${RECEIVED_LOG:-/dev/null}"
  printf '%s\n' "$notification_id" > .sergeant-notification-ack
  for _ in $(seq 1 100); do
    [[ "$(cat "$NOTIFICATION_STATE/notification_delivered" 2>/dev/null || true)" == "$notification_id" ]] && break
    sleep 0.01
  done
  [[ "$(cat "$NOTIFICATION_STATE/notification_delivered" 2>/dev/null || true)" == "$notification_id" ]] || exit 19
done
if [[ "${EXPECT_RECOVERY:-0}" == 1 ]]; then
  notification_id="$(cat "$NOTIFICATION_STATE/notification_id")"
  for _ in $(seq 1 100); do
    [[ "$(cat "$NOTIFICATION_STATE/notification_delivered" 2>/dev/null || true)" == "$notification_id" ]] && break
    sleep 0.01
  done
  [[ "$(cat "$NOTIFICATION_STATE/notification_delivered" 2>/dev/null || true)" == "$notification_id" ]] || exit 20
fi
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
target_worker_pane() {
  local state="$1" window="$2" pane identity
  pane="$(tmux display-message -p -t "$TMUX_SESSION:$window" '#{pane_id}')"
  identity="$(tmux display-message -p -t "$pane" \
    '#{pane_dead}|#{pane_id}|#{pane_pid}|#{pane_created}|#{pane_start_command}')"
  printf '%s\n' "$pane" > "$state/pane"
  printf '%s\n' "$identity" > "$state/pane_identity"
  printf '%s\n' "$identity" > "$state/notification_target_pane_identity"
}

race_state="$TEST_ROOT/race/state"
race_worktree="$TEST_ROOT/race/worktree"
printf 'in_progress\n' > "$race_worktree/.sergeant-status"
printf 'old-notification\n' > "$race_state/notification_id"
cat > "$race_worktree/.sergeant-notification" <<'EOF'
notification_id=old-notification
kind=response
instruction=Apply the pending response.
EOF
tmux new-window -d -t "$TMUX_SESSION:" -n race-old \
  "env RACE_ROLE=old RACE_NOTIFICATION_ID=old-notification \
  RACE_RECEIVED_LOG='$TEST_ROOT/race-received.log' RACE_PROMPT_FILE='$TEST_ROOT/race-old-prompt' \
  RACE_ACK_RELEASE='$TEST_ROOT/race-old-release' RACE_ACK_FILE='$TEST_ROOT/race-old-ack' \
  RACE_EXIT_FILE='$TEST_ROOT/race-old-exit' \
  '$ROOT_DIR/bin/sgt-interactive-worker' '$race_state' '$race_worktree' '$TEST_ROOT/fake-bin/opencode'"
target_worker_pane "$race_state" race-old
for _ in $(seq 1 200); do
  [[ -e "$TEST_ROOT/race-old-prompt" ]] && break
  sleep 0.01
done
[[ -e "$TEST_ROOT/race-old-prompt" ]]

printf 'new-notification\n' > "$race_state/notification_id"
cat > "$race_worktree/.sergeant-notification" <<'EOF'
notification_id=new-notification
kind=response
instruction=Apply the pending response.
EOF
tmux new-window -d -t "$TMUX_SESSION:" -n race-new \
  "env RACE_ROLE=new RACE_NOTIFICATION_ID=new-notification \
  RACE_RECEIVED_LOG='$TEST_ROOT/race-received.log' RACE_PROMPT_FILE='$TEST_ROOT/race-new-prompt' \
  RACE_ACK_RELEASE='$TEST_ROOT/race-new-release' RACE_ACK_FILE='$TEST_ROOT/race-new-ack' \
  RACE_EXIT_FILE='$TEST_ROOT/race-new-exit' \
  '$ROOT_DIR/bin/sgt-interactive-worker' '$race_state' '$race_worktree' '$TEST_ROOT/fake-bin/opencode'"
target_worker_pane "$race_state" race-new
old_race_pane="$(tmux display-message -p -t "$TMUX_SESSION:race-old" '#{pane_id}')"
new_race_pane="$(tmux display-message -p -t "$TMUX_SESSION:race-new" '#{pane_id}')"
tmux display-message -p -t "$old_race_pane" '#{pane_id}' >/dev/null
tmux display-message -p -t "$new_race_pane" '#{pane_id}' >/dev/null
for _ in $(seq 1 200); do
  [[ -e "$TEST_ROOT/race-new-prompt" ]] && break
  sleep 0.01
done
[[ -e "$TEST_ROOT/race-new-prompt" ]]

touch "$TEST_ROOT/race-old-release"
for _ in $(seq 1 200); do
  [[ -e "$TEST_ROOT/race-old-ack" ]] && break
  sleep 0.01
done
[[ -e "$TEST_ROOT/race-old-ack" ]]
sleep 0.05
[[ "$(cat "$race_state/notification_delivered" 2>/dev/null || true)" != new-notification ]]

touch "$TEST_ROOT/race-new-release"
for _ in $(seq 1 200); do
  [[ "$(cat "$race_state/notification_delivered" 2>/dev/null || true)" == new-notification ]] && break
  sleep 0.01
done
[[ "$(cat "$race_state/notification_delivered")" == new-notification ]]
[[ "$(cat "$race_state/notification_delivered_pane_identity")" == \
   "$(cat "$race_state/notification_target_pane_identity")" ]]
[[ "$(grep -Fc old-notification "$TEST_ROOT/race-received.log")" == 1 ]]
[[ "$(grep -Fc new-notification "$TEST_ROOT/race-received.log")" == 1 ]]
touch "$TEST_ROOT/race-old-exit" "$TEST_ROOT/race-new-exit"

printf 'initial-notification-1\n' > "$TEST_ROOT/done/state/notification_id"
cat > "$TEST_ROOT/done/worktree/.sergeant-notification" <<'EOF'
notification_id=initial-notification-1
kind=initial
instruction=Read the .sergeant-brief.md file and execute the mission.
EOF
tmux new-window -d -t "$TMUX_SESSION:" -n "done" \
  "env ARG_LOG='$TEST_ROOT/done.args' EXPECT_NOTIFICATION_COUNT=1 FAKE_STARTUP_DELAY=0.2 \
  NOTIFICATION_STATE='$TEST_ROOT/done/state' SGT_NOTIFICATION_RETRY_INTERVAL=0.01 FAKE_MODE=done \
  '$ROOT_DIR/bin/sgt-interactive-worker' '$TEST_ROOT/done/state' \
  '$TEST_ROOT/done/worktree' '$TEST_ROOT/fake-bin/opencode'"
target_worker_pane "$TEST_ROOT/done/state" "done"
for _ in $(seq 1 100); do
  [[ -f "$TEST_ROOT/done/state/result" ]] && break
  sleep 0.02
done
[[ "$(cat "$TEST_ROOT/done.args")" == "1|--dangerously-skip-permissions" ]]
[[ "$(cat "$TEST_ROOT/done/state/status")" == "done" ]]
[[ "$(cat "$TEST_ROOT/done/state/worker_mode")" == "interactive" ]]
[[ "$(cat "$TEST_ROOT/done/state/notification_delivered")" == "initial-notification-1" ]]
[[ -s "$TEST_ROOT/done/state/notification_delivered_pane_identity" ]]
[[ -s "$TEST_ROOT/done/state/result" ]]

printf 'recovered-notification-1\n' > "$TEST_ROOT/recovery/state/notification_id"
printf 'recovered-notification-1\n' > "$TEST_ROOT/recovery/worktree/.sergeant-notification-ack"
cat > "$TEST_ROOT/recovery/worktree/.sergeant-notification" <<'EOF'
notification_id=recovered-notification-1
kind=initial
instruction=Read the .sergeant-brief.md file and execute the mission.
EOF
tmux new-window -d -t "$TMUX_SESSION:" -n recovery \
  "env ARG_LOG='$TEST_ROOT/recovery.args' EXPECT_RECOVERY=1 \
  NOTIFICATION_STATE='$TEST_ROOT/recovery/state' SGT_NOTIFICATION_RETRY_INTERVAL=0.01 FAKE_MODE=done \
  '$ROOT_DIR/bin/sgt-interactive-worker' '$TEST_ROOT/recovery/state' \
  '$TEST_ROOT/recovery/worktree' '$TEST_ROOT/fake-bin/opencode'"
target_worker_pane "$TEST_ROOT/recovery/state" recovery
for _ in $(seq 1 100); do
  [[ -f "$TEST_ROOT/recovery/state/result" ]] && break
  sleep 0.02
done
[[ "$(cat "$TEST_ROOT/recovery/state/notification_delivered")" == "recovered-notification-1" ]]
[[ -s "$TEST_ROOT/recovery/state/notification_delivered_pane_identity" ]]
[[ "$(cat "$TEST_ROOT/recovery/state/status")" == "done" ]]

real_mv="$(command -v mv)"
cat > "$TEST_ROOT/failure-bin/mv" <<'EOF'
#!/usr/bin/env bash
target=""
for argument in "$@"; do target="$argument"; done
case "${FAIL_NOTIFICATION_MUTATION:-}" in
  state) [[ "$target" == */notifications/*/notification ]] && exit 31 ;;
  acknowledged) [[ "$target" == */acknowledged ]] && exit 32 ;;
  delivered) [[ "$target" == */notifications/*/delivered ]] && exit 33 ;;
  id) [[ "$target" == */notification_id ]] && exit 34 ;;
  active) [[ "$target" == */.sergeant-notification ]] && exit 35 ;;
esac
exec "$REAL_MV" "$@"
EOF
chmod +x "$TEST_ROOT/failure-bin/mv"

publish_replacement_notification() {
  local notification_id="$1"
  PATH="${PUBLISH_PATH:-$PATH}" REAL_MV="$real_mv" \
    bash -c 'source "$1"; _sgt_publish_worker_notification "$2" "$3" "$4" test "Apply once."' _ \
      "$ROOT_DIR/bin/_sgt-lib.sh" "$TEST_ROOT/replacement/state" \
      "$TEST_ROOT/replacement/worktree" "$notification_id"
}

publish_replacement_notification replace-0
tmux new-window -d -t "$TMUX_SESSION:" -n replacement \
  "env ARG_LOG='$TEST_ROOT/replacement.args' EXPECT_NOTIFICATION_COUNT=6 \
  RECEIVED_LOG='$TEST_ROOT/replacement-received.log' NOTIFICATION_STATE='$TEST_ROOT/replacement/state' \
  SGT_NOTIFICATION_RETRY_INTERVAL=0.01 FAKE_MODE=done \
  '$ROOT_DIR/bin/sgt-interactive-worker' '$TEST_ROOT/replacement/state' \
  '$TEST_ROOT/replacement/worktree' '$TEST_ROOT/fake-bin/opencode'"
target_worker_pane "$TEST_ROOT/replacement/state" replacement
for _ in $(seq 1 100); do
  [[ "$(cat "$TEST_ROOT/replacement/state/notification_delivered" 2>/dev/null || true)" == replace-0 ]] && break
  sleep 0.02
done
previous_id=replace-0
replacement_number=1
for failure_mode in state acknowledged delivered id active; do
  next_id="replace-$replacement_number"
  [[ "$failure_mode" != acknowledged ]] || \
    rm -f "$TEST_ROOT/replacement/state/notifications/$previous_id/acknowledged"
  [[ "$failure_mode" != delivered ]] || \
    rm -f "$TEST_ROOT/replacement/state/notifications/$previous_id/delivered"
  set +e
  PUBLISH_PATH="$TEST_ROOT/failure-bin:$PATH" FAIL_NOTIFICATION_MUTATION="$failure_mode" \
    publish_replacement_notification "$next_id" >/dev/null 2>&1
  publish_status=$?
  set -e
  [[ "$publish_status" -ne 0 ]]
  [[ "$(cat "$TEST_ROOT/replacement/worktree/.sergeant-notification-ack")" == "$previous_id" ]]
  [[ "$(cat "$TEST_ROOT/replacement/state/notification_delivered")" == "$previous_id" ]]
  if [[ "$failure_mode" == active ]]; then
    [[ "$(cat "$TEST_ROOT/replacement/state/notification_id")" == "$next_id" ]]
  else
    [[ "$(cat "$TEST_ROOT/replacement/state/notification_id")" == "$previous_id" ]]
  fi
  publish_replacement_notification "$next_id"
  for _ in $(seq 1 100); do
    [[ "$(cat "$TEST_ROOT/replacement/state/notification_delivered" 2>/dev/null || true)" == "$next_id" ]] && break
    sleep 0.02
  done
  [[ "$(cat "$TEST_ROOT/replacement/state/notification_delivered")" == "$next_id" ]]
  [[ -f "$TEST_ROOT/replacement/state/notifications/$previous_id/acknowledged" ]]
  [[ -f "$TEST_ROOT/replacement/state/notifications/$previous_id/delivered" ]]
  previous_id="$next_id"
  replacement_number=$((replacement_number + 1))
done
for _ in $(seq 1 100); do
  [[ -f "$TEST_ROOT/replacement/state/result" ]] && break
  sleep 0.02
done
[[ "$(wc -l < "$TEST_ROOT/replacement-received.log" | tr -d ' ')" == 6 ]]
[[ "$(cat "$TEST_ROOT/replacement/state/status")" == "done" ]]

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
