#!/usr/bin/env bash
# Tests for sgt-recover drain admission — stall recovery refused when drained.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fleet="$TEST_ROOT/fleet"
task_dir="$fleet/task-1"
repo_state="$task_dir/app"
source_repo="$TEST_ROOT/source"
fake_bin="$TEST_ROOT/fake-bin"
config_dir="$TEST_ROOT/config"
export SERGEANT_CONFIG="$config_dir"
export SERGEANT_FLEET="$fleet"

mkdir -p "$repo_state" "$source_repo" "$fake_bin" "$config_dir"
git -C "$source_repo" init -q
git -C "$source_repo" config user.name Test
git -C "$source_repo" config user.email test@example.invalid
touch "$source_repo/README.md"
git -C "$source_repo" add README.md
git -C "$source_repo" commit -qm fixture
worktree="$TEST_ROOT/worktree"
git -C "$source_repo" worktree add -q -b drain-recover-test "$worktree"

printf 'Project: test\nBrief: drain recover test\nBranch: drain-recover-test\nRepos: app\n' \
  > "$task_dir/brief.md"

cat > "$fake_bin/tmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TMUX_LOG:-/dev/null}"
case "$1" in
  display-message)
    [[ "${PANE_ALIVE:-1}" == 1 ]] || exit 1
    target=""
    previous=""
    for arg in "$@"; do
      [[ "$previous" == -t ]] && target="$arg"
      previous="$arg"
    done
    pane_identity="${PANE_IDENTITY:-0|%42|4242|123456|sgt-interactive-worker:$EXPECTED_WORKER}"
    if [[ "$target" == "${NEW_PANE:-%99}" ]]; then
      pane_identity="0|$target|9999|654321|sgt-interactive-worker:$EXPECTED_WORKER"
      if [[ "${AUTO_DELIVER:-1}" == 1 && -s "$EXPECTED_WORKER/notification_id" ]]; then
        notification_id="$(cat "$EXPECTED_WORKER/notification_id")"
        notification_worktree="$(cat "$EXPECTED_WORKER/worktree")"
        nonce="$(cat "$EXPECTED_WORKER/notification_target" 2>/dev/null || true)"
        if [[ "$nonce" =~ ^[a-f0-9]{32}$ ]]; then
          token="$notification_id|$nonce"
          target_dir="$EXPECTED_WORKER/notifications/$notification_id/targets/$nonce"
          mkdir -p "$notification_worktree/.sergeant-notification-acks" \
            "$notification_worktree/.sergeant-notification-accepts"
          printf '%s\n' "$token" > "$notification_worktree/.sergeant-notification-acks/$nonce"
          printf '%s\n' "$token" > "$notification_worktree/.sergeant-notification-accepts/$nonce"
          printf '%s\n' "$token" > "$target_dir/accepted"
          printf '%s\n' "$token" > "$target_dir/delivered"
          printf '%s\n' "$pane_identity" > "$EXPECTED_WORKER/notification_delivered_pane_identity"
          printf '%s\n' "$notification_id" > "$EXPECTED_WORKER/notification_delivered"
        fi
      fi
    fi
    printf '%s\n' "$pane_identity"
    ;;
  new-window)
    [[ "${FAIL_WINDOW:-0}" == 0 ]] || exit 7
    printf '%s\n' "${NEW_PANE:-%99}"
    ;;
  kill-pane) exit 0 ;;
  send-keys) exit 0 ;;
esac
EOF
chmod +x "$fake_bin/tmux"

cat > "$fake_bin/td" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TD_LOG:-/dev/null}"
EOF
chmod +x "$fake_bin/td"

_setup_stalled_worker() {
  local wt="$1"
  local pane="${2:-%42}"
  mkdir -p "$repo_state"
  printf '%s\n' "$wt" > "$repo_state/worktree"
  printf 'in_progress\n' > "$repo_state/status"
  printf 'in_progress\n' > "$wt/.sergeant-status"
  printf 'live worker stalled: no progress for 401s (grace=300s); last event at epoch 1000\n' \
    > "$repo_state/diagnostic"
  printf '%s\n' "$pane" > "$repo_state/pane"
  printf '0|%s|4242|123456|sgt-interactive-worker:%s\n' "$pane" "$repo_state" \
    > "$repo_state/pane_identity"
  chmod 600 "$repo_state/pane_identity"
  printf 'sgt\n' > "$repo_state/tmux_session"
  printf 'task/app\n' > "$repo_state/window_name"
  printf 'opencode\n' > "$repo_state/agent"
  printf 'td-123\n' > "$repo_state/td_task"
  rm -f "$repo_state/stall_recovery_attempted"
  rm -rf "$config_dir/drain"
}

TMUX_LOG="$TEST_ROOT/tmux.log"
TD_LOG="$TEST_ROOT/td.log"

# ── Slice 1: Global drain — stall recovery refused, escalated to needs_input ──

_setup_stalled_worker "$worktree"
mkdir -p "$config_dir/drain"
printf 'reason=maintenance\ncreated=2025-01-01T00:00:00Z\n' > "$config_dir/drain/global"

set +e
EXPECTED_WORKER="$repo_state" KILL_LOG="$TEST_ROOT/killed-drain.log" \
  TMUX_LOG="$TMUX_LOG" TD_LOG="$TD_LOG" \
  PATH="$fake_bin:$PATH" \
  "$ROOT_DIR/bin/sgt-recover" task-1 app >/dev/null 2>&1
drain_exit=$?
set -e

# Should exit non-zero (drain admission refused)
[[ "$drain_exit" -ne 0 ]] || {
  printf 'sgt-recover global drain: should return non-zero when drained\n' >&2; exit 1
}
# No new-window call
! grep -qF 'new-window' "$TMUX_LOG" || {
  printf 'sgt-recover global drain: new-window should not be called\n' >&2; exit 1
}
# Worker escalated to needs_input with drain message
wt_drain_status="$(cat "$worktree/.sergeant-status")"
[[ "$wt_drain_status" == "needs_input" ]] || {
  printf 'sgt-recover global drain: status should be needs_input, got: %s\n' \
    "$wt_drain_status" >&2; exit 1
}
fleet_drain_status="$(cat "$repo_state/status")"
[[ "$fleet_drain_status" == "needs_input" ]] || {
  printf 'sgt-recover global drain: fleet status should be needs_input, got: %s\n' \
    "$fleet_drain_status" >&2; exit 1
}
# Message contains drain context
[[ -f "$worktree/.sergeant-message" ]] || {
  printf 'sgt-recover global drain: .sergeant-message should be written\n' >&2; exit 1
}
grep -qi 'drain' "$worktree/.sergeant-message" || {
  printf 'sgt-recover global drain: message should mention drain\n' >&2; exit 1
}
# Old pane NOT killed (we never launched a new one)
[[ ! -f "$TEST_ROOT/killed-drain.log" ]] || ! grep -qF '%42' "$TEST_ROOT/killed-drain.log" || {
  printf 'sgt-recover global drain: old pane should not be killed\n' >&2; exit 1
}
printf 'sgt-recover global drain holds recovery: ok\n'

# ── Slice 2: Project drain — matching project holds recovery ─────────────────

rm -f "$TMUX_LOG" "$TEST_ROOT/killed-drain2.log"
_setup_stalled_worker "$worktree"
mkdir -p "$config_dir/drain"
printf 'reason=feature-gate\ncreated=2025-01-01T00:00:00Z\n' > "$config_dir/drain/test"

set +e
EXPECTED_WORKER="$repo_state" KILL_LOG="$TEST_ROOT/killed-drain2.log" \
  TMUX_LOG="$TMUX_LOG" TD_LOG="$TD_LOG" \
  PATH="$fake_bin:$PATH" \
  "$ROOT_DIR/bin/sgt-recover" task-1 app >/dev/null 2>&1
project_drain_exit=$?
set -e

[[ "$project_drain_exit" -ne 0 ]] || {
  printf 'sgt-recover project drain: should return non-zero\n' >&2; exit 1
}
! grep -qF 'new-window' "$TMUX_LOG" || {
  printf 'sgt-recover project drain: new-window should not be called\n' >&2; exit 1
}
[[ "$(cat "$worktree/.sergeant-status")" == "needs_input" ]] || {
  printf 'sgt-recover project drain: status should be needs_input\n' >&2; exit 1
}
printf 'sgt-recover project drain holds recovery: ok\n'

# ── Slice 3: Unrelated project drain — recovery proceeds normally ─────────────

rm -f "$TMUX_LOG"
_setup_stalled_worker "$worktree"
mkdir -p "$config_dir/drain"
printf 'reason=other\ncreated=2025-01-01T00:00:00Z\n' > "$config_dir/drain/otherproject"

EXPECTED_WORKER="$repo_state" KILL_LOG="$TEST_ROOT/killed-other.log" \
  TMUX_LOG="$TMUX_LOG" TD_LOG="$TD_LOG" \
  PATH="$fake_bin:$PATH" \
  "$ROOT_DIR/bin/sgt-recover" task-1 app >/dev/null 2>&1

# new-window should be called
grep -qF 'new-window' "$TMUX_LOG" || {
  printf 'sgt-recover unrelated drain: new-window should be called\n' >&2; exit 1
}
[[ "$(cat "$repo_state/status")" == "in_progress" ]] || {
  printf 'sgt-recover unrelated drain: status should remain in_progress\n' >&2; exit 1
}
printf 'sgt-recover unrelated project drain allows recovery: ok\n'

printf 'sgt-recover drain: all tests passed\n'
