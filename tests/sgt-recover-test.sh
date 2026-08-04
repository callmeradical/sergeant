#!/usr/bin/env bash
# Tests for sgt-recover — bounded stall recovery for in-progress workers.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
race_recover_pid=""
race_watch_pid=""
_cleanup_test() {
  [[ -z "$race_watch_pid" ]] || kill "$race_watch_pid" 2>/dev/null || true
  [[ -z "$race_recover_pid" ]] || kill "$race_recover_pid" 2>/dev/null || true
  [[ -z "$race_watch_pid" ]] || wait "$race_watch_pid" 2>/dev/null || true
  [[ -z "$race_recover_pid" ]] || wait "$race_recover_pid" 2>/dev/null || true
  rm -rf "$TEST_ROOT"
}
trap '_cleanup_test' EXIT
TMUX_KILLED_DIR="$TEST_ROOT/killed-panes"
TMUX_NEW_DIR="$TEST_ROOT/new-panes"
TMUX_OLD_IDENTITY_FILE="$TEST_ROOT/old-pane-identity"
mkdir -p "$TMUX_KILLED_DIR" "$TMUX_NEW_DIR"
export TMUX_KILLED_DIR TMUX_NEW_DIR TMUX_OLD_IDENTITY_FILE

fleet="$TEST_ROOT/fleet"
task_dir="$fleet/task-1"
repo_state="$task_dir/app"
source_repo="$TEST_ROOT/source"
fake_bin="$TEST_ROOT/fake-bin"
config_dir="$TEST_ROOT/config"
export SERGEANT_CONFIG="$config_dir"

mkdir -p "$repo_state" "$source_repo" "$fake_bin" "$config_dir"
git -C "$source_repo" init -q
git -C "$source_repo" config user.name Test
git -C "$source_repo" config user.email test@example.invalid
touch "$source_repo/README.md"
git -C "$source_repo" add README.md
git -C "$source_repo" commit -qm fixture

# Create a real worktree for git integrity checks in sgt-respond
worktree="$TEST_ROOT/worktree"
git -C "$source_repo" worktree add -q -b recover-test "$worktree"

cat > "$config_dir/test.yaml" <<EOF
repos:
  - name: app
    path: $source_repo
EOF
printf 'Project: test\nBrief: recover test\nBranch: recover-test\nRepos: app\n' \
  > "$task_dir/brief.md"

# ── Fleet state helpers ──────────────────────────────────────────────────────

_setup_stalled_worker() {
  local repo_dir="$1"
  local wt="$2"
  local pane="${3:-%42}" new_pane_marker="${NEW_PANE:-%99}"

  mkdir -p "$repo_dir"
  rm -f "$TMUX_KILLED_DIR/${pane#%}"
  rm -f "$TMUX_KILLED_DIR/${new_pane_marker#%}"
  rm -f "$TMUX_NEW_DIR/${new_pane_marker#%}"
  printf '%s\n' "$wt" > "$repo_dir/worktree"
  printf 'in_progress\n' > "$repo_dir/status"
  printf 'in_progress\n' > "$wt/.sergeant-status"
  printf 'live worker stalled: no progress for 401s (grace=300s); last event at epoch 1000\n' \
    > "$repo_dir/diagnostic"
  printf '%s\n' "$pane" > "$repo_dir/pane"
  printf -v worker_command '%q %q %q %q' \
    "$ROOT_DIR/bin/sgt-interactive-worker" "$repo_dir" "$wt" opencode
  printf '0|%s|4242|123456|%s\n' "$pane" "$worker_command" > "$repo_dir/pane_identity"
  cp "$repo_dir/pane_identity" "$TMUX_OLD_IDENTITY_FILE"
  chmod 600 "$repo_dir/pane_identity"
  printf 'sgt\n' > "$repo_dir/tmux_session"
  printf 'task/app\n' > "$repo_dir/window_name"
  printf 'opencode\n' > "$repo_dir/agent"
  printf 'td-123\n' > "$repo_dir/td_task"
  printf '4242\n' > "$repo_dir/worker_pid"
  printf '4242\n' > "$repo_dir/worker_process_group"
  printf 'Mon Jan  1 00:00:00 2024\n' > "$repo_dir/worker_process_start"
  printf '%s\n' "$ROOT_DIR/bin/sgt-interactive-worker" > "$repo_dir/worker_executable"
  chmod 600 "$repo_dir/worker_pid" "$repo_dir/worker_process_group" \
    "$repo_dir/worker_process_start" "$repo_dir/worker_executable"
  rm -f "$repo_dir/replacement_phase" "$repo_dir/replacement_candidate_pane" \
    "$repo_dir/replacement_candidate_pane_identity" \
    "$repo_dir/replacement_previous_pane" \
    "$repo_dir/replacement_previous_pane_identity"
}

# ── Fake tmux ───────────────────────────────────────────────────────────────
# Handles display-message, new-window, kill-pane, send-keys.
# Env vars controlling behavior:
#   EXPECTED_WORKER  — path to repo_state dir (for pane_identity lookup)
#   NEW_PANE         — pane ID returned by new-window (default %99)
#   PANE_ALIVE       — if 0, display-message exits 1 (pane dead)
#   FAIL_WINDOW      — if 1, new-window exits 7
#   KILL_LOG         — path to append killed panes
#   WINDOW_LOG       — path to append new-window args
#   AUTO_DELIVER     — if 1 (default), auto-deliver notifications in display-message

cat > "$fake_bin/tmux" <<'TMUX'
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
    [[ ! -e "$TMUX_KILLED_DIR/${target#%}" ]] || exit 1
    if [[ -n "${RECOVERY_RACE_OLD_PANE_ABSENT:-}" &&
          -e "$RECOVERY_RACE_OLD_PANE_ABSENT" &&
          "$target" == "${RECOVERY_RACE_OLD_PANE:-%42}" ]]; then
      exit 1
    fi
    base_identity="$(cat "$TMUX_OLD_IDENTITY_FILE")"
    base_remainder="${base_identity#*|}"
    base_remainder="${base_remainder#*|}"
    base_remainder="${base_remainder#*|}"
    worker_command="${base_remainder#*|}"
    pane_identity="${PANE_IDENTITY:-0|$target|4242|123456|$worker_command}"
    if [[ "$target" == "${NEW_PANE:-%99}" ]]; then
      pane_identity="0|$target|9999|654321|$worker_command"
    fi
    # Auto-deliver notification to new pane
    if [[ "${AUTO_DELIVER:-1}" == 1 && "$target" == "${NEW_PANE:-%99}" &&
          -s "$EXPECTED_WORKER/notification_id" ]]; then
      notification_id="$(cat "$EXPECTED_WORKER/notification_id")"
      wt="$(cat "$EXPECTED_WORKER/worktree")"
      nonce="$(cat "$EXPECTED_WORKER/notification_target" 2>/dev/null || true)"
      if [[ "$nonce" =~ ^[a-f0-9]{32}$ ]]; then
        token="$notification_id|$nonce"
        target_dir="$EXPECTED_WORKER/notifications/$notification_id/targets/$nonce"
        mkdir -p "$wt/.sergeant-notification-acks" "$wt/.sergeant-notification-accepts"
        printf '%s\n' "$token" > "$wt/.sergeant-notification-acks/$nonce"
        printf '%s\n' "$token" > "$wt/.sergeant-notification-accepts/$nonce"
        printf '%s\n' "$token" > "$target_dir/accepted"
        printf '%s\n' "$token" > "$target_dir/delivered"
        printf '%s\n' "$pane_identity" > "$EXPECTED_WORKER/notification_delivered_pane_identity"
        printf '%s\n' "$notification_id" > "$EXPECTED_WORKER/notification_delivered"
      fi
    fi
    printf '%s\n' "$pane_identity"
    ;;
  new-window)
    [[ "${FAIL_WINDOW:-0}" == 0 ]] || exit 7
    [[ "${EMPTY_WINDOW:-0}" == 0 ]] || exit 0
    new_pane="${NEW_PANE:-%99}"
    : > "$TMUX_NEW_DIR/${new_pane#%}"
    printf '9999\n' > "$EXPECTED_WORKER/worker_pid"
    printf '9999\n' > "$EXPECTED_WORKER/worker_process_group"
    printf 'Tue Jan  2 00:00:00 2024\n' > "$EXPECTED_WORKER/worker_process_start"
    printf '/replacement/sgt-interactive-worker\n' > "$EXPECTED_WORKER/worker_executable"
    chmod 600 "$EXPECTED_WORKER/worker_pid" "$EXPECTED_WORKER/worker_process_group" \
      "$EXPECTED_WORKER/worker_process_start" "$EXPECTED_WORKER/worker_executable"
    [[ -z "${WINDOW_LOG:-}" ]] || printf '%s\n' "$*" >> "$WINDOW_LOG"
    printf '%s\n' "$new_pane"
    ;;
  list-panes)
    base_identity="$(cat "$TMUX_OLD_IDENTITY_FILE")"
    base_remainder="${base_identity#*|}"
    base_pane="${base_remainder%%|*}"
    if [[ ! -e "$TMUX_KILLED_DIR/${base_pane#%}" &&
          ( -z "${RECOVERY_RACE_OLD_PANE_ABSENT:-}" ||
            ! -e "$RECOVERY_RACE_OLD_PANE_ABSENT" ) ]]; then
      if [[ "${!#}" == '#{pane_id}' ]]; then
        printf '%s\n' "$base_pane"
      else
        printf '%s\n' "$base_identity"
      fi
    fi
    new_pane="${NEW_PANE:-%99}"
    if [[ -e "$TMUX_NEW_DIR/${new_pane#%}" && ! -e "$TMUX_KILLED_DIR/${new_pane#%}" ]]; then
      base_remainder="${base_identity#*|}"
      base_remainder="${base_remainder#*|}"
      base_remainder="${base_remainder#*|}"
      worker_command="${base_remainder#*|}"
      if [[ "${!#}" == '#{pane_id}' ]]; then
        printf '%s\n' "$new_pane"
      else
        printf '0|%s|9999|654321|%s\n' "$new_pane" "$worker_command"
      fi
    fi
    if [[ -n "${EXTRA_PANE_IDENTITY:-}" ]]; then
      if [[ "${!#}" == '#{pane_id}' ]]; then
        extra_remainder="${EXTRA_PANE_IDENTITY#*|}"
        printf '%s\n' "${extra_remainder%%|*}"
      else
        printf '%s\n' "$EXTRA_PANE_IDENTITY"
      fi
    fi
    ;;
  kill-pane)
    # Record which pane was killed; verify it is the exact pane, not a prefix collision
    target_pane=""
    previous=""
    for arg in "$@"; do
      [[ "$previous" == -t ]] && target_pane="$arg"
      previous="$arg"
    done
    [[ -z "${KILL_LOG:-}" ]] || printf '%s\n' "$target_pane" >> "$KILL_LOG"
    if [[ "${FAIL_KILL_PANE:-}" == "all" ||
          ( -n "${FAIL_KILL_PANE:-}" && "$target_pane" == "$FAIL_KILL_PANE" ) ]]; then
      exit 9
    fi
    : > "$TMUX_KILLED_DIR/${target_pane#%}"
    ;;
  send-keys) exit 0 ;;
  *)
    printf 'unexpected tmux subcommand: %s\n' "$1" >&2
    exit 1
    ;;
esac
TMUX
chmod +x "$fake_bin/tmux"

real_date="$(command -v date)"
cat > "$fake_bin/date" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${RECOVERY_PRE_PHASE_READY:-}" && ! -e "$RECOVERY_PRE_PHASE_READY" ]]; then
  : > "$RECOVERY_RACE_OLD_PANE_ABSENT"
  : > "$RECOVERY_PRE_PHASE_READY"
  attempt=0
  while [[ ! -e "$RECOVERY_PRE_PHASE_RELEASE" && "$attempt" -lt 500 ]]; do
    sleep 0.01
    attempt=$((attempt + 1))
  done
  [[ -e "$RECOVERY_PRE_PHASE_RELEASE" ]] || exit 71
fi
exec "$REAL_DATE" "$@"
EOF
chmod +x "$fake_bin/date"
export REAL_DATE="$real_date"

cat > "$fake_bin/td" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TD_LOG:-/dev/null}"
EOF
chmod +x "$fake_bin/td"

TMUX_LOG="$TEST_ROOT/tmux.log"
TD_LOG="$TEST_ROOT/td.log"

# ── Slice 1: Happy path — stalled worker recovered ───────────────────────────
# A worker with status=in_progress and a live-worker-stalled diagnostic is
# recovered: old pane killed, new pane launched, diagnostic cleared,
# stall_recovery_attempted written, status stays in_progress.

_setup_stalled_worker "$repo_state" "$worktree"

EXPECTED_WORKER="$repo_state" KILL_LOG="$TEST_ROOT/killed.log" \
  WINDOW_LOG="$TEST_ROOT/windows.log" TMUX_LOG="$TMUX_LOG" TD_LOG="$TD_LOG" \
  PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-recover" task-1 app >/dev/null 2>&1

# Status stays in_progress
[[ "$(cat "$repo_state/status")" == "in_progress" ]] || {
  printf 'status should stay in_progress, got: %s\n' "$(cat "$repo_state/status")" >&2
  exit 1
}
[[ "$(cat "$worktree/.sergeant-status")" == "in_progress" ]] || {
  printf 'worktree status should stay in_progress\n' >&2
  exit 1
}

# Stall diagnostic cleared
[[ ! -f "$repo_state/diagnostic" ]] || {
  printf 'diagnostic should be cleared after recovery, got: %s\n' "$(cat "$repo_state/diagnostic")" >&2
  exit 1
}

# Recovery attempted marker written
[[ -f "$repo_state/stall_recovery_attempted" ]] || {
  printf 'stall_recovery_attempted should be written\n' >&2
  exit 1
}
[[ "$(cat "$repo_state/worker_pid")" == "9999" ]]
[[ ! -e "$repo_state/replacement_phase" ]]
[[ ! -e "$repo_state/replacement_candidate_pane" ]]
[[ ! -e "$repo_state/replacement_candidate_pane_identity" ]]

# Old pane was killed
grep -Fq '%42' "$TEST_ROOT/killed.log" || {
  printf 'old pane %%42 should have been killed\n' >&2
  exit 1
}

# New pane recorded in fleet
[[ "$(cat "$repo_state/pane")" == "%99" ]] || {
  printf 'pane should be updated to %%99, got: %s\n' "$(cat "$repo_state/pane")" >&2
  exit 1
}

# Pane identity updated with new pane
grep -Fq '%99' "$repo_state/pane_identity" || {
  printf 'pane_identity should be updated with new pane\n' >&2
  exit 1
}

# Notification delivered to new pane
[[ -s "$repo_state/notification_id" ]] || {
  printf 'notification_id should be written\n' >&2
  exit 1
}

# new-window was called
grep -Fq 'new-window' "$TEST_ROOT/windows.log" || {
  printf 'new-window should have been called\n' >&2
  exit 1
}

printf 'sgt-recover happy path: ok\n'

# ── Slice 1b: watch cannot orphan recovery between verification and phase ────

_setup_stalled_worker "$repo_state" "$worktree"
rm -f "$repo_state/stall_recovery_attempted"
race_ready="$TEST_ROOT/recovery-pre-phase-ready"
race_release="$TEST_ROOT/recovery-pre-phase-release"
race_old_absent="$TEST_ROOT/recovery-old-pane-absent"
race_recover_log="$TEST_ROOT/recovery-race-recover.log"
race_watch_log="$TEST_ROOT/recovery-race-watch.log"

EXPECTED_WORKER="$repo_state" RECOVERY_PRE_PHASE_READY="$race_ready" \
  RECOVERY_PRE_PHASE_RELEASE="$race_release" \
  RECOVERY_RACE_OLD_PANE_ABSENT="$race_old_absent" \
  PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-recover" task-1 app >"$race_recover_log" 2>&1 &
race_recover_pid=$!

for _attempt in {1..500}; do
  [[ -e "$race_ready" ]] && break
  kill -0 "$race_recover_pid" 2>/dev/null || break
  sleep 0.01
done
[[ -e "$race_ready" ]] || {
  printf 'recovery did not reach the pre-phase race boundary\n' >&2
  exit 1
}

EXPECTED_WORKER="$repo_state" RECOVERY_RACE_OLD_PANE_ABSENT="$race_old_absent" \
  PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-watch" --sync task-1 >"$race_watch_log" 2>&1 &
race_watch_pid=$!

race_observed=false
for _attempt in {1..500}; do
  if ! kill -0 "$race_watch_pid" 2>/dev/null || \
     compgen -G "$repo_state/.response.lock.*" >/dev/null; then
    race_observed=true
    break
  fi
  sleep 0.01
done
$race_observed || {
  printf 'watch did not reach the recovery serialization boundary\n' >&2
  exit 1
}

: > "$race_release"
wait "$race_recover_pid"
race_recover_pid=""
wait "$race_watch_pid"
race_watch_pid=""

[[ "$(cat "$repo_state/status")" == "in_progress" ]]
[[ "$(cat "$worktree/.sergeant-status")" == "in_progress" ]]
[[ "$(cat "$repo_state/pane")" == "%99" ]]
printf 'sgt-recover serializes watch orphan classification: ok\n'

# ── Slice 2a: Refused when status is not in_progress ─────────────────────────

_setup_stalled_worker "$repo_state" "$worktree"
printf 'needs_input\n' > "$repo_state/status"
printf 'needs_input\n' > "$worktree/.sergeant-status"

set +e
EXPECTED_WORKER="$repo_state" PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-recover" task-1 app >/dev/null 2>&1
refuse_status=$?
set -e
[[ "$refuse_status" -ne 0 ]] || {
  printf 'sgt-recover should refuse when status is not in_progress\n' >&2
  exit 1
}
# Status unchanged
[[ "$(cat "$repo_state/status")" == "needs_input" ]] || {
  printf 'status should not have changed on refused recovery\n' >&2
  exit 1
}

printf 'sgt-recover refuses non-in_progress: ok\n'

# ── Slice 2b: Refused when no stall diagnostic ────────────────────────────────

_setup_stalled_worker "$repo_state" "$worktree"
rm -f "$repo_state/diagnostic"

set +e
EXPECTED_WORKER="$repo_state" PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-recover" task-1 app >/dev/null 2>&1
refuse_status=$?
set -e
[[ "$refuse_status" -ne 0 ]] || {
  printf 'sgt-recover should refuse when diagnostic is absent\n' >&2
  exit 1
}
[[ "$(cat "$repo_state/status")" == "in_progress" ]] || {
  printf 'status should not change when refused for missing diagnostic\n' >&2
  exit 1
}

printf 'sgt-recover refuses missing diagnostic: ok\n'

# ── Slice 2c: Refused when diagnostic is not a stall diagnostic ───────────────

_setup_stalled_worker "$repo_state" "$worktree"
printf 'recorded pane %%42 is dead or not the expected worker supervisor\n' \
  > "$repo_state/diagnostic"

set +e
EXPECTED_WORKER="$repo_state" PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-recover" task-1 app >/dev/null 2>&1
refuse_status=$?
set -e
[[ "$refuse_status" -ne 0 ]] || {
  printf 'sgt-recover should refuse when diagnostic is not a stall diagnostic\n' >&2
  exit 1
}

printf 'sgt-recover refuses non-stall diagnostic: ok\n'

# ── Slice 3: Second attempt escalates to needs_input (loop prevention) ────────

_setup_stalled_worker "$repo_state" "$worktree"
date -u +%Y-%m-%dT%H:%M:%SZ > "$repo_state/stall_recovery_attempted"
rm -f "$TEST_ROOT/td-second.log"

set +e
EXPECTED_WORKER="$repo_state" PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" \
  TD_LOG="$TEST_ROOT/td-second.log" \
  "$ROOT_DIR/bin/sgt-recover" task-1 app >/dev/null 2>&1
second_status=$?
set -e

# Should fail (escalation is an error from the caller's perspective)
[[ "$second_status" -ne 0 ]] || {
  printf 'sgt-recover second attempt should return non-zero\n' >&2
  exit 1
}

# Status escalated to needs_input with evidence
wt_second_status="$(cat "$worktree/.sergeant-status")"
fleet_second_status="$(cat "$repo_state/status")"
[[ "$wt_second_status" == "needs_input" || "$wt_second_status" == "blocked" ]] || {
  printf 'second attempt: worktree status should be needs_input/blocked, got: %s\n' \
    "$wt_second_status" >&2
  exit 1
}
[[ "$fleet_second_status" == "needs_input" || "$fleet_second_status" == "blocked" ]] || {
  printf 'second attempt: fleet status should be needs_input/blocked, got: %s\n' \
    "$fleet_second_status" >&2
  exit 1
}

# Message file written with evidence
[[ -f "$worktree/.sergeant-message" ]] || {
  printf 'second attempt: .sergeant-message should be written\n' >&2
  exit 1
}
grep -qiE 'stall|recover' "$worktree/.sergeant-message" || {
  printf 'second attempt: .sergeant-message should reference stall recovery\n' >&2
  exit 1
}

# Gate generation must be incremented for the escalation gate
wt_gen="$(cat "$worktree/.sergeant-gate-generation" 2>/dev/null || true)"
[[ "$wt_gen" =~ ^[1-9][0-9]*$ ]] || {
  printf 'second attempt: gate generation should be set, got: %s\n' "$wt_gen" >&2
  exit 1
}

# Message must not contain prompts, tokens, or secrets (privacy)
if grep -qiE 'prompt|token|secret' "$worktree/.sergeant-message" 2>/dev/null; then
  printf 'privacy violation: second-attempt message contains sensitive terms\n' >&2
  exit 1
fi

# Fleet diagnostic must be the escalation reason, NOT the old stall diagnostic
# (verifies that _escalate overwrites the stall diagnostic with the failure reason)
diag_after="$(cat "$repo_state/diagnostic" 2>/dev/null || true)"
[[ "$diag_after" != "live worker stalled:"* ]] || {
  printf 'second attempt: stall diagnostic should be replaced by escalation reason\n' >&2
  exit 1
}
[[ -n "$diag_after" ]] || {
  printf 'second attempt: fleet diagnostic should be non-empty after escalation\n' >&2
  exit 1
}

printf 'sgt-recover second attempt escalates: ok\n'

# ── Slice 4: tmux new-window failure → needs_input escalation ─────────────────
# Bug 2 regression: if the relaunch fails, the original stalled pane must NOT
# be killed — the worker must remain alive (stalled) rather than dead.

_setup_stalled_worker "$repo_state" "$worktree"
rm -f "$worktree/.sergeant-message" "$repo_state/message"
rm -f "$repo_state/stall_recovery_attempted" "$TEST_ROOT/kill4.log"
printf 'in_progress\n' > "$worktree/.sergeant-status"
printf 'in_progress\n' > "$repo_state/status"

set +e
EXPECTED_WORKER="$repo_state" FAIL_WINDOW=1 PANE_ALIVE=1 KILL_LOG="$TEST_ROOT/kill4.log" \
  PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-recover" task-1 app >/dev/null 2>&1
fail_status=$?
set -e

[[ "$fail_status" -ne 0 ]] || {
  printf 'sgt-recover should fail when new-window fails\n' >&2
  exit 1
}

# Worker escalated to needs_input
fail_wt="$(cat "$worktree/.sergeant-status")"
fail_fleet="$(cat "$repo_state/status")"
[[ "$fail_wt" == "needs_input" || "$fail_wt" == "blocked" ]] || {
  printf 'window-fail: worktree status should be needs_input/blocked, got: %s\n' "$fail_wt" >&2
  exit 1
}
[[ "$fail_fleet" == "needs_input" || "$fail_fleet" == "blocked" ]] || {
  printf 'window-fail: fleet status should be needs_input/blocked, got: %s\n' "$fail_fleet" >&2
  exit 1
}

# stall_recovery_attempted was written (counts as the bounded attempt)
[[ -f "$repo_state/stall_recovery_attempted" ]] || {
  printf 'window-fail: stall_recovery_attempted should be written\n' >&2
  exit 1
}

# Diagnostic describes failure reason
[[ -f "$repo_state/diagnostic" ]] || {
  printf 'window-fail: diagnostic should be written\n' >&2
  exit 1
}
grep -qiE 'tmux|relaunch|window|recover' "$repo_state/diagnostic" || {
  printf 'window-fail: diagnostic should mention recovery failure\n' >&2
  exit 1
}

# Privacy: diagnostic must not contain sensitive terms
if grep -qiE 'prompt|token|secret' "$repo_state/diagnostic" 2>/dev/null; then
  printf 'privacy violation: window-fail diagnostic contains sensitive terms\n' >&2
  exit 1
fi

# Stall diagnostic must be replaced by the failure reason (not the old stall text)
fail_diag="$(cat "$repo_state/diagnostic" 2>/dev/null || true)"
[[ "$fail_diag" != "live worker stalled:"* ]] || {
  printf 'window-fail: stall diagnostic should be replaced by failure reason\n' >&2
  exit 1
}

# Bug 2 regression: old pane (%42) must NOT be killed when new-window fails
kill4_content="$(cat "$TEST_ROOT/kill4.log" 2>/dev/null || true)"
[[ -z "$kill4_content" ]] || {
  printf 'window-fail: old pane must not be killed when new-window fails, killed: %s\n' \
    "$kill4_content" >&2
  exit 1
}
[[ ! -e "$repo_state/replacement_phase" ]]

printf 'sgt-recover tmux failure escalates: ok\n'

# ── Slice 5: Prefix-colliding panes untouched ─────────────────────────────────
# The recorded pane is %42; a sibling pane %420 must NOT be killed.
# We verify by checking the kill log only contains %42 in the happy path,
# and that pane identity verification guards against an identity mismatch
# that would occur if the wrong pane were targeted.

_setup_stalled_worker "$repo_state" "$worktree"
rm -f "$TEST_ROOT/prefix-killed.log"
printf 'in_progress\n' > "$worktree/.sergeant-status"
printf 'in_progress\n' > "$repo_state/status"
printf 'live worker stalled: no progress for 401s (grace=300s); last event at epoch 1000\n' \
  > "$repo_state/diagnostic"
rm -f "$repo_state/stall_recovery_attempted"

# Run happy-path recovery: only %42 should appear in kill log
EXPECTED_WORKER="$repo_state" KILL_LOG="$TEST_ROOT/prefix-killed.log" \
  PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-recover" task-1 app >/dev/null 2>&1

kill_log_content="$(cat "$TEST_ROOT/prefix-killed.log" 2>/dev/null || true)"
# Every line in the kill log must be exactly %42 (not %420, %421, etc.)
while IFS= read -r killed_pane; do
  [[ -z "$killed_pane" ]] && continue
  [[ "$killed_pane" == "%42" ]] || {
    printf 'prefix-collision: unexpected pane killed: %s\n' "$killed_pane" >&2
    exit 1
  }
done <<< "$kill_log_content"

printf 'sgt-recover prefix-collision panes untouched: ok\n'

# ── Slice 6: pane identity mismatch — recovery refused, wrong pane untouched ──
# If pane_identity in fleet does not match the live pane, recovery must be
# refused without killing anything.

_setup_stalled_worker "$repo_state" "$worktree"
rm -f "$repo_state/stall_recovery_attempted"
rm -f "$TEST_ROOT/mismatch-killed.log"
printf 'in_progress\n' > "$worktree/.sergeant-status"
printf 'in_progress\n' > "$repo_state/status"
printf 'live worker stalled: no progress for 401s (grace=300s); last event at epoch 1000\n' \
  > "$repo_state/diagnostic"

# Override pane_identity with mismatched content so _sgt_pane_identity_matches fails
printf '0|%%42|4242|123456|sgt-interactive-worker:/some/other/path\n' \
  > "$repo_state/pane_identity"
chmod 600 "$repo_state/pane_identity"

set +e
EXPECTED_WORKER="$repo_state" KILL_LOG="$TEST_ROOT/mismatch-killed.log" \
  PANE_IDENTITY="0|%42|9999|999999|sgt-interactive-worker:/different" \
  PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-recover" task-1 app >/dev/null 2>&1
mismatch_status=$?
set -e

# sgt-recover must fail or escalate — not silently succeed
[[ "$mismatch_status" -ne 0 ]] || {
  wt_s="$(cat "$worktree/.sergeant-status")"
  _fleet_s="$(cat "$repo_state/status")"
  [[ "$wt_s" == "needs_input" || "$wt_s" == "blocked" || "$_fleet_s" == "needs_input" ]] || {
    printf 'identity-mismatch: should have failed or escalated, exit=%d wt=%s fleet=%s\n' \
      "$mismatch_status" "$wt_s" "$_fleet_s" >&2
    exit 1
  }
}

# The wrong pane must NOT have been killed
if [[ -f "$TEST_ROOT/mismatch-killed.log" ]]; then
  mismatch_kill="$(cat "$TEST_ROOT/mismatch-killed.log")"
  [[ -z "$mismatch_kill" ]] || {
    printf 'identity-mismatch: pane should not be killed on mismatch, killed: %s\n' \
      "$mismatch_kill" >&2
    exit 1
  }
fi

printf 'sgt-recover identity mismatch — wrong pane untouched: ok\n'

_setup_stalled_worker "$repo_state" "$worktree"
rm -f "$repo_state/stall_recovery_attempted" "$TEST_ROOT/duplicate-window.log"
old_identity="$(cat "$TMUX_OLD_IDENTITY_FILE")"
old_remainder="${old_identity#*|}"
old_remainder="${old_remainder#*|}"
old_remainder="${old_remainder#*|}"
worker_command="${old_remainder#*|}"
duplicate_identity="0|%41|4141|123455|$worker_command"

set +e
EXPECTED_WORKER="$repo_state" EXTRA_PANE_IDENTITY="$duplicate_identity" \
  WINDOW_LOG="$TEST_ROOT/duplicate-window.log" PATH="$fake_bin:$PATH" \
  SERGEANT_FLEET="$fleet" "$ROOT_DIR/bin/sgt-recover" task-1 app >/dev/null 2>&1
duplicate_status=$?
set -e

[[ "$duplicate_status" -ne 0 ]]
[[ ! -e "$TEST_ROOT/duplicate-window.log" ]]
grep -Fq 'another live worker pane %41 owns this fleet state' "$repo_state/diagnostic"
printf 'sgt-recover duplicate live worker blocks replacement: ok\n'

# ── Slice 7: failed old-pane termination rolls back replacement ownership ────

_setup_stalled_worker "$repo_state" "$worktree"
rm -f "$repo_state/stall_recovery_attempted" "$TEST_ROOT/kill-rollback.log"
old_identity="$(cat "$repo_state/pane_identity")"
old_worker_pid="$(cat "$repo_state/worker_pid")"

set +e
EXPECTED_WORKER="$repo_state" KILL_LOG="$TEST_ROOT/kill-rollback.log" \
  FAIL_KILL_PANE=%42 PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-recover" task-1 app >/dev/null 2>&1
rollback_status=$?
set -e

[[ "$rollback_status" -ne 0 ]]
[[ "$(cat "$repo_state/pane")" == "%42" ]]
[[ "$(cat "$repo_state/pane_identity")" == "$old_identity" ]]
[[ "$(cat "$repo_state/worker_pid")" == "$old_worker_pid" ]]
grep -Fq '%99' "$TEST_ROOT/kill-rollback.log"
grep -Fq 'could not terminate superseded worker pane %42' "$repo_state/diagnostic"
printf 'sgt-recover failed old-pane termination restores ownership: ok\n'

_setup_stalled_worker "$repo_state" "$worktree"
rm -f "$repo_state/stall_recovery_attempted" "$TEST_ROOT/double-kill.log"
old_identity="$(cat "$repo_state/pane_identity")"

set +e
EXPECTED_WORKER="$repo_state" KILL_LOG="$TEST_ROOT/double-kill.log" \
  FAIL_KILL_PANE=all PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-recover" task-1 app >/dev/null 2>&1
double_kill_status=$?
set -e

[[ "$double_kill_status" -ne 0 ]]
[[ "$(cat "$repo_state/pane")" == "%99" ]]
[[ "$(cat "$repo_state/pane_identity")" == 0\|%99\|9999\|654321\|* ]]
[[ "$(cat "$repo_state/replacement_previous_pane")" == "%42" ]]
[[ "$(cat "$repo_state/replacement_previous_pane_identity")" == "$old_identity" ]]
[[ "$(cat "$repo_state/worker_pid")" == "9999" ]]
[[ "$(cat "$repo_state/replacement_previous_worker_pid")" == "4242" ]]
[[ "$(cat "$repo_state/replacement_phase")" == "launching" ]]
grep -Fq 'replacement pane %99 could not be terminated and remains recorded' \
  "$repo_state/diagnostic"
printf 'sgt-recover double termination failure preserves both identities: ok\n'

# ── Slice 8: Unfinished action_lease blocks recovery ──────────────────────────
# Bug 1 regression: if the stalled worker holds an unfinished notification
# action_lease (accepted a notification but died before writing 'completed'),
# recovery must refuse rather than destroy the exact-once evidence.

_setup_stalled_worker "$repo_state" "$worktree"
rm -f "$repo_state/stall_recovery_attempted" "$TEST_ROOT/kill7.log"
printf 'in_progress\n' > "$worktree/.sergeant-status"
printf 'in_progress\n' > "$repo_state/status"
printf 'live worker stalled: no progress for 401s (grace=300s); last event at epoch 1000\n' \
  > "$repo_state/diagnostic"

# Write an in-flight action_lease (no 'completed' → delivery not finished)
lease_nonce="aabbccddeeff00112233445566778899"
notif_id="deadbeef00112233445566778899aabb"
mkdir -p "$repo_state/notifications/$notif_id/targets/$lease_nonce"
printf '%s\n' "$notif_id" > "$repo_state/notification_id"
printf '%s\n' "$lease_nonce" > "$repo_state/notifications/$notif_id/action_lease"
# No targets/$lease_nonce/completed file → lease is unfinished

set +e
EXPECTED_WORKER="$repo_state" KILL_LOG="$TEST_ROOT/kill7.log" \
  PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-recover" task-1 app >/dev/null 2>&1
lease_status=$?
set -e

[[ "$lease_status" -ne 0 ]] || {
  printf 'action_lease: recovery should be refused when lease is unfinished\n' >&2
  exit 1
}

# Old pane must NOT be killed
lease_kill="$(cat "$TEST_ROOT/kill7.log" 2>/dev/null || true)"
[[ -z "$lease_kill" ]] || {
  printf 'action_lease: old pane should not be killed when lease is active, killed: %s\n' \
    "$lease_kill" >&2
  exit 1
}

# Worker must be escalated (needs_input) or at least remain non-in_progress terminal
lease_wt_status="$(cat "$worktree/.sergeant-status")"
lease_fleet_status="$(cat "$repo_state/status")"
[[ "$lease_wt_status" == "needs_input" || "$lease_wt_status" == "blocked" || \
   "$lease_fleet_status" == "needs_input" || "$lease_fleet_status" == "blocked" ]] || {
  printf 'action_lease: worker should be escalated after refused recovery, wt=%s fleet=%s\n' \
    "$lease_wt_status" "$lease_fleet_status" >&2
  exit 1
}

printf 'sgt-recover action_lease blocks recovery: ok\n'

# ── Slice 8: Completed action_lease does not block recovery ───────────────────
# A completed action_lease (completed file present) must not block recovery.

_setup_stalled_worker "$repo_state" "$worktree"
rm -f "$repo_state/stall_recovery_attempted"
printf 'in_progress\n' > "$worktree/.sergeant-status"
printf 'in_progress\n' > "$repo_state/status"
printf 'live worker stalled: no progress for 401s (grace=300s); last event at epoch 1000\n' \
  > "$repo_state/diagnostic"

completed_nonce="1122334455667788990011223344aabb"
completed_notif_id="ffaabb0011223344556677889900aabb"
mkdir -p "$repo_state/notifications/$completed_notif_id/targets/$completed_nonce"
printf '%s\n' "$completed_notif_id" > "$repo_state/notification_id"
printf '%s\n' "$completed_nonce" > "$repo_state/notifications/$completed_notif_id/action_lease"
# completed file IS present → lease is finished
printf '%s|%s\n' "$completed_notif_id" "$completed_nonce" \
  > "$repo_state/notifications/$completed_notif_id/targets/$completed_nonce/completed"

EXPECTED_WORKER="$repo_state" KILL_LOG="$TEST_ROOT/kill8.log" \
  PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-recover" task-1 app >/dev/null 2>&1

[[ "$(cat "$repo_state/status")" == "in_progress" ]] || {
  printf 'completed_lease: recovery should succeed when lease is completed, got: %s\n' \
    "$(cat "$repo_state/status")" >&2
  exit 1
}
[[ "$(cat "$repo_state/pane")" == "%99" ]] || {
  printf 'completed_lease: recovery should update pane\n' >&2
  exit 1
}

printf 'sgt-recover completed action_lease allows recovery: ok\n'

printf 'sgt-recover: all tests passed\n'
