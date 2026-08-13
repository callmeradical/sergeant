#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
# ── Drain state isolation (td-79f0a8) ────────────────────────────────────────
# Commands exercised here source bin/_sgt-drain.sh, which resolves
# SERGEANT_DRAIN_DIR, else SERGEANT_CONFIG/drain, else the operator's real
# $HOME/.config/sergeant/drain.  Pin it to this suite's temporary root so the
# tests never consult — or mutate — live drain state.
export SERGEANT_DRAIN_DIR="$TEST_ROOT/drain"
export SERGEANT_CONFIG="$TEST_ROOT/sergeant-config"
mkdir -p "$SERGEANT_DRAIN_DIR" "$SERGEANT_CONFIG"
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
  "$TEST_ROOT/invalid-marker/state" "$TEST_ROOT/invalid-marker/worktree" \
  "$TEST_ROOT/wrong-generation/state" "$TEST_ROOT/wrong-generation/worktree" \
  "$TEST_ROOT/orphan/state" "$TEST_ROOT/orphan/worktree"

cat > "$TEST_ROOT/fake-bin/opencode" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${RACE_ROLE:-}" ]]; then
  printf 'Ask anything...\n'
  IFS= read -r notification
  [[ "$notification" == *"$RACE_NOTIFICATION_ID"* ]] || exit 41
  printf '%s:%s\n' "$RACE_ROLE" "$RACE_NOTIFICATION_ID" >> "$RACE_RECEIVED_LOG"
  touch "$RACE_PROMPT_FILE"
  while [[ ! -e "$RACE_ACK_RELEASE" ]]; do sleep 0.01; done
  ack_token="$(cat "$RACE_ACK_TOKEN_FILE")"
  nonce="${ack_token#*|}"
  mkdir -p .sergeant-notification-acks .sergeant-notification-complete
  printf '%s\n' "$ack_token" > ".sergeant-notification-acks/$nonce"
  touch "$RACE_ACK_FILE"
  for _ in $(seq 1 500); do
    [[ "$(cat ".sergeant-notification-accepts/$nonce" 2>/dev/null || true)" == "$ack_token" ]] && break
    if [[ -n "${RACE_STOP_FILE:-}" && -e "$RACE_STOP_FILE" ]]; then
      touch "$RACE_STOPPED_FILE"
      exit 0
    fi
    sleep 0.01
  done
  [[ "$(cat ".sergeant-notification-accepts/$nonce" 2>/dev/null || true)" == "$ack_token" ]] || exit 43
  if [[ -n "${RACE_ACCEPT_OBSERVED:-}" ]]; then
    IFS= read -r acceptance_message
    [[ "$acceptance_message" == *'Sergeant accepted'* ]] || exit 44
    [[ "$(cat ".sergeant-notification-accepts/$nonce" 2>/dev/null || true)" == "$ack_token" ]] || exit 45
    touch "$RACE_ACCEPT_OBSERVED"
    while [[ ! -e "$RACE_ACTION_RELEASE" ]]; do sleep 0.01; done
  fi
  printf '%s:%s\n' "$RACE_ROLE" "$RACE_NOTIFICATION_ID" >> "$RACE_ACTION_LOG"
  printf '%s\n' "$ack_token" > ".sergeant-notification-complete/$nonce"
  while [[ ! -e "$RACE_EXIT_FILE" ]]; do sleep 0.01; done
  printf 'needs_input\n' > .sergeant-status
  exit 0
fi
notification_count="${EXPECT_NOTIFICATION_COUNT:-0}"
  for notification_number in $(seq 1 "$notification_count"); do
    [[ "$notification_number" != 1 ]] || sleep "${FAKE_STARTUP_DELAY:-0}"
    printf 'Ask anything...\n'
    IFS= read -r notification
  notification_id="$(cat "$NOTIFICATION_STATE/notification_id")"
  [[ "$notification" == *"$notification_id"* ]] || exit 18
  printf '%s\n' "$notification_id" >> "${RECEIVED_LOG:-/dev/null}"
  nonce="$(cat "$NOTIFICATION_STATE/notification_target")"
  ack_token="$notification_id|$nonce"
  mkdir -p .sergeant-notification-acks .sergeant-notification-complete
  printf '%s\n' "$ack_token" > ".sergeant-notification-acks/$nonce"
  for _ in $(seq 1 100); do
    [[ "$(cat ".sergeant-notification-accepts/$nonce" 2>/dev/null || true)" == "$ack_token" ]] && break
    sleep 0.01
  done
  [[ "$(cat ".sergeant-notification-accepts/$nonce" 2>/dev/null || true)" == "$ack_token" ]] || exit 22
  accepted=""
  for _ in $(seq 1 100); do
    IFS= read -r -t 1 candidate || break
    if [[ "$candidate" == *"Sergeant accepted $ack_token"* ]]; then
      accepted="$candidate"
      break
    fi
  done
  [[ -n "$accepted" ]] || exit 23
  if [[ -n "${PRE_COMPLETION_REPLAY_LOG:-}" ]] && IFS= read -r -t 1 replay; then
    printf '%s\n' "$replay" > "$PRE_COMPLETION_REPLAY_LOG"
  fi
  printf '%s\n' "$ack_token" > ".sergeant-notification-complete/$nonce"
  target_dir="$NOTIFICATION_STATE/notifications/$notification_id/targets/$nonce"
  for _ in $(seq 1 100); do
    [[ "$(cat "$target_dir/delivered" 2>/dev/null || true)" == "$ack_token" ]] && break
    sleep 0.01
  done
  [[ "$(cat "$target_dir/delivered" 2>/dev/null || true)" == "$ack_token" ]] || exit 19
done
if [[ -n "${REPLAY_LOG:-}" ]] && IFS= read -r -t 1 replay; then
  printf '%s\n' "$replay" > "$REPLAY_LOG"
fi
if [[ "${EXPECT_RECOVERY:-0}" == 1 ]]; then
  notification_id="$(cat "$NOTIFICATION_STATE/notification_id")"
  for _ in $(seq 1 100); do
    [[ "$(cat "$NOTIFICATION_STATE/notification_delivered" 2>/dev/null || true)" == "$notification_id" ]] && break
    sleep 0.01
  done
  [[ "$(cat "$NOTIFICATION_STATE/notification_delivered" 2>/dev/null || true)" == "$notification_id" ]] || exit 20
fi
printf '%s|%s\n' "$#" "$*" > "$ARG_LOG"
# Wait for post-notification gate if requested (allows tests to assert on lock state
# before the agent writes its final status).
if [[ -n "${POST_NOTIFICATION_WAIT_FILE:-}" ]]; then
  for _ in $(seq 1 2000); do
    [[ ! -e "$POST_NOTIFICATION_WAIT_FILE" ]] && break
    sleep 0.01
  done
fi
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
cat > "$TEST_ROOT/fake-bin/ln" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${FAIL_LOCK_FILE:-}" && -e "$FAIL_LOCK_FILE" && "$*" == *response.lock* ]]; then
  touch "$FAIL_LOCK_MARKER"
  exit 75
fi
exec /usr/bin/ln "$@"
EOF
cat > "$TEST_ROOT/fake-bin/mktemp" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${FAIL_LEASE_WRITE_FILE:-}" && -e "$FAIL_LEASE_WRITE_FILE" && "$*" == *action_lease.tmp* ]]; then
  touch "$FAIL_LEASE_WRITE_MARKER"
  exit 75
fi
exec /usr/bin/mktemp "$@"
EOF
cat > "$TEST_ROOT/fake-bin/mv" <<'EOF'
#!/usr/bin/env bash
target="${!#}"
if [[ -n "${FAIL_LEASE_RENAME_FILE:-}" && -e "$FAIL_LEASE_RENAME_FILE" && "$target" == */action_lease ]]; then
  touch "$FAIL_LEASE_RENAME_MARKER"
  exit 75
fi
exec /usr/bin/mv "$@"
EOF
cat > "$TEST_ROOT/fake-bin/rm" <<'EOF'
#!/usr/bin/env bash
# Intercept rm -f response.lock during lock-release-failure injection tests.
for arg in "$@"; do
  [[ "$arg" == -* ]] && continue  # skip flags
  if [[ -n "${FAIL_LOCK_RELEASE_FILE:-}" && -e "${FAIL_LOCK_RELEASE_FILE}" && \
        "$arg" == */response.lock && -f "$arg" ]]; then
    touch "${FAIL_LOCK_RELEASE_MARKER:-/dev/null}"
    exit 1
  fi
done
exec /usr/bin/rm "$@"
EOF
chmod +x "$TEST_ROOT/fake-bin/ln" "$TEST_ROOT/fake-bin/mktemp" \
  "$TEST_ROOT/fake-bin/mv" "$TEST_ROOT/fake-bin/rm"
cat > "$TEST_ROOT/fake-bin/worker-launch" <<EOF
#!/usr/bin/env bash
set -euo pipefail
repo_state="\$1"
worktree="\$2"
agent="\$3"
source "$ROOT_DIR/bin/_sgt-lib.sh"
_sgt_prepare_worker_process_marker "\$repo_state"
command="\$(_sgt_worker_command "$ROOT_DIR/bin/sgt-interactive-worker" \
  "\$repo_state" "\$worktree" "\$agent")"
exec bash -c "\$command"
EOF
chmod +x "$TEST_ROOT/fake-bin/worker-launch"

# A worker that did not inherit its exact launch capability must fail before
# invoking the agent, even if it was started directly or a shell wrapper lost
# the marker FD.
printf 'in_progress\n' > "$TEST_ROOT/invalid-marker/worktree/.sergeant-status"
printf '%032d|1:2|198|%s\n' 0 "$TEST_ROOT/missing-marker" \
  > "$TEST_ROOT/invalid-marker/state/worker_process_marker"
chmod 600 "$TEST_ROOT/invalid-marker/state/worker_process_marker"
tmux new-session -d -s "$TMUX_SESSION" -n invalid-marker \
  "env ARG_LOG='$TEST_ROOT/invalid-marker.args' FAKE_MODE=done \
  '$ROOT_DIR/bin/sgt-interactive-worker' '$TEST_ROOT/invalid-marker/state' \
  '$TEST_ROOT/invalid-marker/worktree' '$TEST_ROOT/fake-bin/opencode'"
for _ in $(seq 1 100); do
  [[ -s "$TEST_ROOT/invalid-marker/state/status" ]] && break
  sleep 0.01
done
grep -Fqx 'failed: worker process marker validation failed' \
  "$TEST_ROOT/invalid-marker/state/status"
[[ ! -e "$TEST_ROOT/invalid-marker.args" ]]
tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true

wrong_generation=11111111111111111111111111111111
wrong_marker_path="$TEST_ROOT/wrong-generation/marker"
printf '22222222222222222222222222222222\n' > "$wrong_marker_path"
chmod 400 "$wrong_marker_path"
wrong_identity="$(stat -Lc '%d:%i' "$wrong_marker_path")"
printf '%s|%s|198|%s\n' "$wrong_generation" "$wrong_identity" \
  "$wrong_marker_path" > "$TEST_ROOT/wrong-generation/state/worker_process_marker"
printf '%s|%s|0\n' "$wrong_generation" "$wrong_identity" \
  > "$TEST_ROOT/wrong-generation/state/worker_process_markers"
chmod 600 "$TEST_ROOT/wrong-generation/state/worker_process_marker" \
  "$TEST_ROOT/wrong-generation/state/worker_process_markers"
printf 'in_progress\n' > "$TEST_ROOT/wrong-generation/worktree/.sergeant-status"
tmux new-session -d -s "$TMUX_SESSION" -n wrong-generation \
  "exec 198<'$wrong_marker_path' && rm -f '$wrong_marker_path' && \
  env ARG_LOG='$TEST_ROOT/wrong-generation.args' FAKE_MODE=done \
  '$ROOT_DIR/bin/sgt-interactive-worker' '$TEST_ROOT/wrong-generation/state' \
  '$TEST_ROOT/wrong-generation/worktree' '$TEST_ROOT/fake-bin/opencode'"
for _ in $(seq 1 100); do
  [[ -s "$TEST_ROOT/wrong-generation/state/status" ]] && break
  sleep 0.01
done
grep -Fqx 'failed: worker process marker validation failed' \
  "$TEST_ROOT/wrong-generation/state/status"
[[ ! -e "$TEST_ROOT/wrong-generation.args" ]]
tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true

rm "$TEST_ROOT/invalid-marker/state/worker_process_marker"
rm -f "$TEST_ROOT/invalid-marker/state/status" \
  "$TEST_ROOT/invalid-marker/worktree/.sergeant-status"
printf 'in_progress\n' > "$TEST_ROOT/invalid-marker/worktree/.sergeant-status"
tmux new-session -d -s "$TMUX_SESSION" -n missing-marker \
  "env ARG_LOG='$TEST_ROOT/missing-marker.args' FAKE_MODE=done \
  '$ROOT_DIR/bin/sgt-interactive-worker' '$TEST_ROOT/invalid-marker/state' \
  '$TEST_ROOT/invalid-marker/worktree' '$TEST_ROOT/fake-bin/opencode'"
for _ in $(seq 1 100); do
  [[ -s "$TEST_ROOT/invalid-marker/state/status" ]] && break
  sleep 0.01
done
grep -Fqx 'failed: worker process marker validation failed' \
  "$TEST_ROOT/invalid-marker/state/status"
[[ ! -e "$TEST_ROOT/missing-marker.args" ]]
tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true

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
  local state="$1" window="$2" pane identity nonce notification_id target_dir
  pane="$(tmux display-message -p -t "$TMUX_SESSION:$window" '#{pane_id}')"
  identity="$(tmux display-message -p -t "$pane" \
    '#{pane_dead}|#{pane_id}|#{pane_pid}|#{pane_created}|#{pane_start_command}')"
  printf '%s\n' "$pane" > "$state/pane"
  printf '%s\n' "$identity" > "$state/pane_identity"
  notification_id="$(cat "$state/notification_id")"
  nonce="$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')"
  target_dir="$state/notifications/$notification_id/targets/$nonce"
  mkdir -p "$target_dir"
  printf '%s\n' "$identity" > "$target_dir/pane_identity"
  printf '%s\n' "$nonce" > "$state/notification_target"
}

race_state="$TEST_ROOT/race/state"
race_worktree="$TEST_ROOT/race/worktree"
printf 'in_progress\n' > "$race_worktree/.sergeant-status"
printf 'fresh-notification\n' > "$race_state/notification_id"
cat > "$race_worktree/.sergeant-notification" <<'EOF'
notification_id=fresh-notification
kind=response
instruction=Apply the pending response.
EOF
tmux new-window -d -t "$TMUX_SESSION:" -n race-old \
  "env RACE_ROLE=old RACE_NOTIFICATION_ID=fresh-notification \
  RACE_RECEIVED_LOG='$TEST_ROOT/race-received.log' RACE_PROMPT_FILE='$TEST_ROOT/race-old-prompt' \
  RACE_ACK_RELEASE='$TEST_ROOT/race-old-release' RACE_ACK_FILE='$TEST_ROOT/race-old-ack' \
  RACE_ACK_TOKEN_FILE='$TEST_ROOT/race-old-token' \
  RACE_ACTION_LOG='$TEST_ROOT/race-action.log' \
  RACE_STOP_FILE='$TEST_ROOT/race-old-stop' RACE_STOPPED_FILE='$TEST_ROOT/race-old-stopped' \
  RACE_EXIT_FILE='$TEST_ROOT/race-old-exit' \
  PATH='$TEST_ROOT/fake-bin:$PATH' \
  '$TEST_ROOT/fake-bin/worker-launch' '$race_state' '$race_worktree' '$TEST_ROOT/fake-bin/opencode'"
target_worker_pane "$race_state" race-old
old_race_nonce="$(cat "$race_state/notification_target")"
printf 'fresh-notification|%s\n' "$(cat "$race_state/notification_target")" \
  > "$TEST_ROOT/race-old-token"
for _ in $(seq 1 200); do
  [[ -e "$TEST_ROOT/race-old-prompt" ]] && break
  sleep 0.01
done
[[ -e "$TEST_ROOT/race-old-prompt" ]]

printf 'fresh-notification\n' > "$race_state/notification_id"
cat > "$race_worktree/.sergeant-notification" <<'EOF'
notification_id=fresh-notification
kind=response
instruction=Apply the pending response.
EOF
tmux new-window -d -t "$TMUX_SESSION:" -n race-new \
  "env RACE_ROLE=new RACE_NOTIFICATION_ID=fresh-notification \
  RACE_RECEIVED_LOG='$TEST_ROOT/race-received.log' RACE_PROMPT_FILE='$TEST_ROOT/race-new-prompt' \
  RACE_ACK_RELEASE='$TEST_ROOT/race-new-release' RACE_ACK_FILE='$TEST_ROOT/race-new-ack' \
  RACE_ACK_TOKEN_FILE='$TEST_ROOT/race-new-token' \
  RACE_ACTION_LOG='$TEST_ROOT/race-action.log' \
  RACE_ACCEPT_OBSERVED='$TEST_ROOT/race-new-accepted' \
  RACE_ACTION_RELEASE='$TEST_ROOT/race-new-action-release' \
  FAIL_LOCK_FILE='$TEST_ROOT/fail-lock' FAIL_LOCK_MARKER='$TEST_ROOT/fail-lock-marker' \
  FAIL_LEASE_WRITE_FILE='$TEST_ROOT/fail-lease-write' FAIL_LEASE_WRITE_MARKER='$TEST_ROOT/fail-lease-write-marker' \
  FAIL_LEASE_RENAME_FILE='$TEST_ROOT/fail-lease-rename' FAIL_LEASE_RENAME_MARKER='$TEST_ROOT/fail-lease-rename-marker' \
  RACE_EXIT_FILE='$TEST_ROOT/race-new-exit' \
  PATH='$TEST_ROOT/fake-bin:$PATH' \
  '$TEST_ROOT/fake-bin/worker-launch' '$race_state' '$race_worktree' '$TEST_ROOT/fake-bin/opencode'"
target_worker_pane "$race_state" race-new
new_race_nonce="$(cat "$race_state/notification_target")"
printf 'fresh-notification|%s\n' "$(cat "$race_state/notification_target")" \
  > "$TEST_ROOT/race-new-token"
old_race_pane="$(tmux display-message -p -t "$TMUX_SESSION:race-old" '#{pane_id}')"
new_race_pane="$(tmux display-message -p -t "$TMUX_SESSION:race-new" '#{pane_id}')"
old_race_pid="$(tmux display-message -p -t "$old_race_pane" '#{pane_pid}')"
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
kill -0 "$old_race_pid"
[[ ! -e "$race_state/notifications/fresh-notification/targets/$new_race_nonce/delivered" ]]

touch "$TEST_ROOT/fail-lock"
touch "$TEST_ROOT/race-new-release"
for _ in $(seq 1 200); do
  [[ -e "$TEST_ROOT/fail-lock-marker" ]] && break
  sleep 0.01
done
[[ -e "$TEST_ROOT/fail-lock-marker" ]]
[[ ! -e "$race_state/notifications/fresh-notification/action_lease" ]]
[[ ! -e "$race_state/notifications/fresh-notification/targets/$new_race_nonce/accepted" ]]
rm "$TEST_ROOT/fail-lock"
touch "$TEST_ROOT/fail-lease-write"
for _ in $(seq 1 200); do
  [[ -e "$TEST_ROOT/fail-lease-write-marker" ]] && break
  sleep 0.01
done
[[ -e "$TEST_ROOT/fail-lease-write-marker" ]]
[[ ! -e "$race_state/notifications/fresh-notification/action_lease" ]]
rm "$TEST_ROOT/fail-lease-write"
touch "$TEST_ROOT/fail-lease-rename"
for _ in $(seq 1 200); do
  [[ -e "$TEST_ROOT/fail-lease-rename-marker" ]] && break
  sleep 0.01
done
[[ -e "$TEST_ROOT/fail-lease-rename-marker" ]]
[[ ! -e "$race_state/notifications/fresh-notification/action_lease" ]]
[[ ! -e "$race_state/notifications/fresh-notification/targets/$new_race_nonce/acknowledged" ]]
rm "$TEST_ROOT/fail-lease-rename"
for _ in $(seq 1 200); do
  [[ -f "$race_state/notifications/fresh-notification/targets/$new_race_nonce/delivered" ]] && break
  sleep 0.01
done
cmp -s "$TEST_ROOT/race-new-token" \
  "$race_state/notifications/fresh-notification/targets/$new_race_nonce/delivered"
for _ in $(seq 1 200); do
  [[ -f "$TEST_ROOT/race-new-accepted" ]] && break
  sleep 0.01
done
[[ -f "$TEST_ROOT/race-new-accepted" ]]
cat "$TEST_ROOT/race-old-token" > "$race_worktree/.sergeant-notification-acks/$old_race_nonce"
cmp -s "$TEST_ROOT/race-new-token" \
  "$race_state/notifications/fresh-notification/targets/$new_race_nonce/accepted"
[[ ! -e "$TEST_ROOT/race-action.log" || \
   "$(grep -Fc old:fresh-notification "$TEST_ROOT/race-action.log")" == 0 ]]
rm -f "$TEST_ROOT/fail-lock-marker"
touch "$TEST_ROOT/fail-lock"
touch "$TEST_ROOT/race-new-action-release"
for _ in $(seq 1 200); do
  [[ -f "$TEST_ROOT/race-action.log" ]] && break
  sleep 0.01
done
for _ in $(seq 1 200); do
  [[ -e "$TEST_ROOT/fail-lock-marker" ]] && break
  sleep 0.01
done
[[ -e "$TEST_ROOT/fail-lock-marker" ]]
[[ ! -e "$race_state/notifications/fresh-notification/targets/$new_race_nonce/completed" ]]
rm "$TEST_ROOT/fail-lock"
[[ "$(grep -Fc old:fresh-notification "$TEST_ROOT/race-received.log")" == 1 ]]
[[ "$(grep -Fc new:fresh-notification "$TEST_ROOT/race-received.log")" == 1 ]]
[[ ! -e "$TEST_ROOT/race-action.log" || \
   "$(grep -Fc old:fresh-notification "$TEST_ROOT/race-action.log")" == 0 ]]
[[ "$(grep -Fc new:fresh-notification "$TEST_ROOT/race-action.log")" == 1 ]]
cat "$TEST_ROOT/race-old-token" > "$race_worktree/.sergeant-notification-acks/$old_race_nonce"
cmp -s "$TEST_ROOT/race-new-token" \
  "$race_state/notifications/fresh-notification/targets/$new_race_nonce/acknowledged"
cmp -s "$TEST_ROOT/race-new-token" \
  "$race_state/notifications/fresh-notification/targets/$new_race_nonce/accepted"
for _ in $(seq 1 200); do
  [[ -f "$race_state/notifications/fresh-notification/targets/$new_race_nonce/completed" ]] && break
  sleep 0.01
done
[[ -f "$race_state/notifications/fresh-notification/targets/$new_race_nonce/completed" ]]
[[ "$(cat "$race_state/notifications/fresh-notification/action_lease")" == "$new_race_nonce" ]]
cmp -s "$TEST_ROOT/race-new-token" \
  "$race_state/notifications/fresh-notification/targets/$new_race_nonce/completed"
[[ "$(find "$race_state/notifications/fresh-notification" -name action_lease -type f | wc -l | tr -d ' ')" == 1 ]]
kill -0 "$old_race_pid"
touch "$TEST_ROOT/race-old-stop"
for _ in $(seq 1 200); do
  [[ -e "$TEST_ROOT/race-old-stopped" ]] && break
  sleep 0.01
done
[[ -e "$TEST_ROOT/race-old-stopped" ]]
for _ in $(seq 1 200); do
  kill -0 "$old_race_pid" 2>/dev/null || break
  sleep 0.01
done
if kill -0 "$old_race_pid" 2>/dev/null; then
  printf 'stale supervisor remained live after terminal barrier: %s\n' "$old_race_pid" >&2
  exit 1
fi
[[ "$(grep -Fc new:fresh-notification "$TEST_ROOT/race-received.log")" == 1 ]]
[[ "$(grep -Fc new:fresh-notification "$TEST_ROOT/race-action.log")" == 1 ]]
[[ "$(grep -Fc old:fresh-notification "$TEST_ROOT/race-action.log" 2>/dev/null || true)" == 0 ]]
touch "$TEST_ROOT/race-new-exit"
for _ in $(seq 1 200); do
  [[ ! -e "$race_state/response.lock" ]] && break
  sleep 0.01
done

printf 'initial-notification-1\n' > "$TEST_ROOT/done/state/notification_id"
cat > "$TEST_ROOT/done/worktree/.sergeant-notification" <<'EOF'
notification_id=initial-notification-1
kind=initial
instruction=Read the .sergeant-brief.md file and execute the mission.
EOF
tmux new-window -d -t "$TMUX_SESSION:" -n "done" \
  "env ARG_LOG='$TEST_ROOT/done.args' EXPECT_NOTIFICATION_COUNT=1 FAKE_STARTUP_DELAY=0.2 \
  PRE_COMPLETION_REPLAY_LOG='$TEST_ROOT/done-pre-completion-replay.log' \
  REPLAY_LOG='$TEST_ROOT/done-replay.log' \
  NOTIFICATION_STATE='$TEST_ROOT/done/state' SGT_NOTIFICATION_RETRY_INTERVAL=0.01 FAKE_MODE=done \
  '$TEST_ROOT/fake-bin/worker-launch' '$TEST_ROOT/done/state' \
  '$TEST_ROOT/done/worktree' '$TEST_ROOT/fake-bin/opencode'"
target_worker_pane "$TEST_ROOT/done/state" "done"
# The two negative replay probes each hold stdin for up to one second.
for _ in $(seq 1 250); do
  [[ -f "$TEST_ROOT/done/state/result" ]] && break
  sleep 0.02
done
[[ "$(cat "$TEST_ROOT/done.args")" == "1|--dangerously-skip-permissions" ]]
[[ "$(cat "$TEST_ROOT/done/state/status")" == "done" ]]
[[ "$(cat "$TEST_ROOT/done/state/worker_mode")" == "interactive" ]]
[[ ! -e "$TEST_ROOT/done-pre-completion-replay.log" ]]
[[ ! -e "$TEST_ROOT/done-replay.log" ]]
done_nonce="$(cat "$TEST_ROOT/done/state/notification_target")"
[[ "$(cat "$TEST_ROOT/done/state/notifications/initial-notification-1/targets/$done_nonce/delivered")" == \
   "initial-notification-1|$done_nonce" ]]
[[ -s "$TEST_ROOT/done/state/result" ]]

printf 'recovered-notification-1\n' > "$TEST_ROOT/recovery/state/notification_id"
cat > "$TEST_ROOT/recovery/worktree/.sergeant-notification" <<'EOF'
notification_id=recovered-notification-1
kind=initial
instruction=Read the .sergeant-brief.md file and execute the mission.
EOF
tmux new-window -d -t "$TMUX_SESSION:" -n recovery \
  "env ARG_LOG='$TEST_ROOT/recovery.args' EXPECT_NOTIFICATION_COUNT=1 \
  NOTIFICATION_STATE='$TEST_ROOT/recovery/state' SGT_NOTIFICATION_RETRY_INTERVAL=0.01 FAKE_MODE=done \
  '$TEST_ROOT/fake-bin/worker-launch' '$TEST_ROOT/recovery/state' \
  '$TEST_ROOT/recovery/worktree' '$TEST_ROOT/fake-bin/opencode'"
target_worker_pane "$TEST_ROOT/recovery/state" recovery
for _ in $(seq 1 100); do
  [[ -f "$TEST_ROOT/recovery/state/result" ]] && break
  sleep 0.02
done
recovery_nonce="$(cat "$TEST_ROOT/recovery/state/notification_target")"
[[ "$(cat "$TEST_ROOT/recovery/state/notifications/recovered-notification-1/targets/$recovery_nonce/delivered")" == \
   "recovered-notification-1|$recovery_nonce" ]]
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
    bash -c 'source "$1"; _sgt_publish_worker_notification "$2" "$3" "$4" test "Apply once." || exit; identity="$(cat "$2/pane_identity" 2>/dev/null || true)"; [[ -z "$identity" ]] || _sgt_notification_target_create "$2" "$4" "$identity" >/dev/null' _ \
      "$ROOT_DIR/bin/_sgt-lib.sh" "$TEST_ROOT/replacement/state" \
      "$TEST_ROOT/replacement/worktree" "$notification_id"
}

publish_replacement_notification replace-0
tmux new-window -d -t "$TMUX_SESSION:" -n replacement \
  "env ARG_LOG='$TEST_ROOT/replacement.args' EXPECT_NOTIFICATION_COUNT=1 \
  RECEIVED_LOG='$TEST_ROOT/replacement-received.log' NOTIFICATION_STATE='$TEST_ROOT/replacement/state' \
  SGT_NOTIFICATION_RETRY_INTERVAL=0.01 FAKE_MODE=done \
  '$TEST_ROOT/fake-bin/worker-launch' '$TEST_ROOT/replacement/state' \
  '$TEST_ROOT/replacement/worktree' '$TEST_ROOT/fake-bin/opencode'"
target_worker_pane "$TEST_ROOT/replacement/state" replacement
for _ in $(seq 1 100); do
  replacement_nonce="$(cat "$TEST_ROOT/replacement/state/notification_target" 2>/dev/null || true)"
  [[ -f "$TEST_ROOT/replacement/state/notifications/replace-0/targets/$replacement_nonce/delivered" ]] && break
  sleep 0.02
done
for _ in $(seq 1 100); do
  [[ -f "$TEST_ROOT/replacement/state/result" ]] && break
  sleep 0.02
done
[[ "$(wc -l < "$TEST_ROOT/replacement-received.log" | tr -d ' ')" == 1 ]]
[[ "$(cat "$TEST_ROOT/replacement/state/status")" == "done" ]]

tmux new-window -d -t "$TMUX_SESSION:" -n goose \
  "env ARG_LOG='$TEST_ROOT/goose.args' FAKE_MODE=done \
  '$TEST_ROOT/fake-bin/worker-launch' '$TEST_ROOT/goose/state' \
  '$TEST_ROOT/goose/worktree' '$TEST_ROOT/fake-bin/goose'"
tmux new-window -d -t "$TMUX_SESSION:" -n claude \
  "env ARG_LOG='$TEST_ROOT/claude.args' FAKE_MODE=done \
  '$TEST_ROOT/fake-bin/worker-launch' '$TEST_ROOT/claude/state' \
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
    '$TEST_ROOT/fake-bin/worker-launch' '$state_dir' \
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
  '$TEST_ROOT/fake-bin/worker-launch' '$TEST_ROOT/orphan/state' \
  '$TEST_ROOT/orphan/worktree' '$TEST_ROOT/fake-bin/opencode'"
for _ in $(seq 1 100); do
  [[ -f "$TEST_ROOT/orphan/state/diagnostic" ]] && break
  sleep 0.02
done
[[ "$(cat "$TEST_ROOT/orphan.args")" == "1|--dangerously-skip-permissions" ]]
[[ "$(cat "$TEST_ROOT/orphan/state/status")" == "orphaned" ]]
grep -Fq 'interactive opencode session exited before terminal completion' \
  "$TEST_ROOT/orphan/state/diagnostic"

# ── lock-release-failure scenario ─────────────────────────────────────────────
# Regression: when rm -f response.lock fails, _SGT_RESPONSE_LOCK_DIR must remain
# set so the delivery loop retries the release rather than continuing with a
# live-PID leftover lock.  The worker must eventually release the lock and
# complete after the failure is cleared.

lr_state="$TEST_ROOT/lr/state"
lr_worktree="$TEST_ROOT/lr/worktree"
mkdir -p "$lr_state" "$lr_worktree"

printf 'lr-notification-1\n' > "$lr_state/notification_id"
printf 'in_progress\n' > "$lr_worktree/.sergeant-status"
cat > "$lr_worktree/.sergeant-notification" <<'EOF'
notification_id=lr-notification-1
kind=initial
instruction=Read the .sergeant-brief.md file and execute the mission.
EOF

# Activate the release failure before launching the worker so the first
# lock-release attempt fails.
touch "$TEST_ROOT/fail-lock-release"
# Keep the agent alive after notification delivery so we can assert on the
# lock state before it writes its final status.
touch "$TEST_ROOT/lr-agent-gate"

tmux new-window -d -t "$TMUX_SESSION:" -n lr \
  "env ARG_LOG='$TEST_ROOT/lr.args' EXPECT_NOTIFICATION_COUNT=1 \
  NOTIFICATION_STATE='$lr_state' SGT_NOTIFICATION_RETRY_INTERVAL=0.01 FAKE_MODE=done \
  FAIL_LOCK_RELEASE_FILE='$TEST_ROOT/fail-lock-release' \
  FAIL_LOCK_RELEASE_MARKER='$TEST_ROOT/fail-lock-release-marker' \
  POST_NOTIFICATION_WAIT_FILE='$TEST_ROOT/lr-agent-gate' \
  PATH='$TEST_ROOT/fake-bin:$PATH' \
  '$TEST_ROOT/fake-bin/worker-launch' '$lr_state' \
  '$lr_worktree' '$TEST_ROOT/fake-bin/opencode'"
target_worker_pane "$lr_state" lr

# Wait for the release failure marker — proves the injection fired.
for _ in $(seq 1 200); do
  [[ -e "$TEST_ROOT/fail-lock-release-marker" ]] && break
  sleep 0.01
done
[[ -e "$TEST_ROOT/fail-lock-release-marker" ]]

# Lock file MUST still be present: truthful ownership preserved after failed release.
[[ -f "$lr_state/response.lock" ]]

# Clear the failure.  The worker must now retry and release the lock.
rm "$TEST_ROOT/fail-lock-release"
for _ in $(seq 1 200); do
  [[ ! -f "$lr_state/response.lock" ]] && break
  sleep 0.01
done
[[ ! -f "$lr_state/response.lock" ]]

# Ungate the agent and wait for terminal completion.
rm "$TEST_ROOT/lr-agent-gate"
for _ in $(seq 1 200); do
  [[ -f "$lr_state/result" ]] && break
  sleep 0.02
done
[[ "$(cat "$lr_state/status")" == "done" ]]

printf 'sgt-interactive-worker lifecycle: ok\n'
