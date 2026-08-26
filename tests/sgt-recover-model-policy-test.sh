#!/usr/bin/env bash
# Regression test for Deloitte support #29: a stall recovery relaunch reused
# whatever model/effort tuple the stalled worker's fleet record already held,
# with no chance for the coordinator's current SERGEANT_MODEL policy to apply
# — unlike sgt-dispatch and sgt-session-resume, which both resolve
# SERGEANT_MODEL over the durable fleet record and validate before launch.

set -euo pipefail
export FAKE_TMUX_OWNER_PID="$$"

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

mkdir -p "$repo_state" "$source_repo" "$fake_bin" "$config_dir"
git -C "$source_repo" init -q
git -C "$source_repo" config user.name Test
git -C "$source_repo" config user.email test@example.invalid
touch "$source_repo/README.md"
git -C "$source_repo" add README.md
git -C "$source_repo" commit -qm fixture

worktree="$TEST_ROOT/worktree"
git -C "$source_repo" worktree add -q -b recover-policy-test "$worktree"

cat > "$config_dir/test.yaml" <<EOF
repos:
  - name: app
    path: $source_repo
EOF
printf 'Project: test\nBrief: recover policy test\nBranch: recover-policy-test\nRepos: app\n' \
  > "$task_dir/brief.md"

_setup_stalled_worker() {
  local repo_dir="$1" wt="$2" pane="${3:-%42}"
  mkdir -p "$repo_dir"
  printf '%s\n' "$wt" > "$repo_dir/worktree"
  printf 'in_progress\n' > "$repo_dir/status"
  printf 'in_progress\n' > "$wt/.sergeant-status"
  printf 'live worker stalled: no progress for 401s (grace=300s); last event at epoch 1000\n' \
    > "$repo_dir/diagnostic"
  printf '%s\n' "$pane" > "$repo_dir/pane"
  printf '0|%s|4242|123456|sgt-interactive-worker:%s\n' "$pane" "$repo_dir" \
    > "$repo_dir/pane_identity"
  chmod 600 "$repo_dir/pane_identity"
  printf 'sgt\n' > "$repo_dir/tmux_session"
  printf 'task/app\n' > "$repo_dir/window_name"
  printf 'opencode\n' > "$repo_dir/agent"
  printf 'td-123\n' > "$repo_dir/td_task"
  printf 'anthropic/claude-haiku-4-5\n' > "$repo_dir/agent_model"
  printf 'dispatch\n' > "$repo_dir/agent_model_source"
  rm -f "$repo_dir/response_relaunch_transaction" \
    "$repo_dir/recovery_successor_notification" "$repo_dir/stall_recovery_attempted"
}

# Fake tmux, matching sgt-recover-test.sh's fixture exactly: scenario 1 dies
# before any call beyond `command -v`; scenarios 2/3 set FAIL_WINDOW=1 so
# new-window fails immediately and escalation happens without ever reaching
# display-message's @sergeant_replacement_token/proc-based branch (Linux-only,
# unrelated to this fix).
cat > "$fake_bin/tmux" <<'TMUX'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TMUX_LOG:-/dev/null}"
case "$1" in
  list-panes)
    if [[ "${LIST_REPLACEMENT_PANE:-0}" == 1 ]]; then
      printf '%s\n' "${NEW_PANE:-%99}"
    fi
    exit 0
    ;;
  display-message)
    [[ "${PANE_ALIVE:-1}" == 1 ]] || exit 1
    printf '%s\n' "${PANE_IDENTITY:-0|%42|4242|123456|sgt-interactive-worker:$EXPECTED_WORKER}"
    ;;
  new-window)
    [[ "${FAIL_WINDOW:-0}" == 0 ]] || exit 7
    printf '%s\n' "${NEW_PANE:-%99}"
    ;;
  kill-pane)
    target_pane=""
    previous=""
    for arg in "$@"; do
      [[ "$previous" == -t ]] && target_pane="$arg"
      previous="$arg"
    done
    [[ -z "${KILL_LOG:-}" ]] || printf '%s\n' "$target_pane" >> "$KILL_LOG"
    ;;
  send-keys) exit 0 ;;
  *)
    printf 'unexpected tmux subcommand: %s\n' "$1" >&2
    exit 1
    ;;
esac
TMUX
chmod +x "$fake_bin/tmux"

cat > "$fake_bin/td" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TD_LOG:-/dev/null}"
EOF
chmod +x "$fake_bin/td"

# ── Scenario 1: a malformed current policy refuses closed, touches nothing ──

_setup_stalled_worker "$repo_state" "$worktree"
cp "$repo_state/agent_model" "$TEST_ROOT/model-before-1"
cp "$repo_state/agent_model_source" "$TEST_ROOT/model-source-before-1"

set +e
EXPECTED_WORKER="$repo_state" SERGEANT_MODEL="not a valid tuple" \
  KILL_LOG="$TEST_ROOT/kill1.log" \
  PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-recover" task-1 app >/dev/null 2>&1
status1=$?
set -e

[[ "$status1" -ne 0 ]] || {
  printf 'FAIL: recovery should refuse a malformed SERGEANT_MODEL policy\n' >&2
  exit 1
}
cmp -s "$TEST_ROOT/model-before-1" "$repo_state/agent_model" || {
  printf 'FAIL: agent_model must not change when the policy tuple is malformed\n' >&2
  exit 1
}
cmp -s "$TEST_ROOT/model-source-before-1" "$repo_state/agent_model_source" || {
  printf 'FAIL: agent_model_source must not change when the policy tuple is malformed\n' >&2
  exit 1
}
[[ ! -s "$TEST_ROOT/kill1.log" ]] || {
  printf 'FAIL: old pane must not be killed when the policy tuple is malformed\n' >&2
  exit 1
}
fleet_status1="$(cat "$repo_state/status")"
[[ "$fleet_status1" == "needs_input" || "$fleet_status1" == "blocked" ]] || {
  printf 'FAIL: worker should be escalated when the policy tuple is malformed, got: %s\n' \
    "$fleet_status1" >&2
  exit 1
}

printf 'sgt-recover refuses a malformed current-policy tuple without touching state: ok\n'

# ── Scenario 2: a valid current policy overrides the stale stored effort ────
# before any launch is attempted, even though the launch itself then fails for
# an unrelated reason (new-window failure) -- proving the durable record is
# updated as part of preflight, not as a side effect of a successful launch.

_setup_stalled_worker "$repo_state" "$worktree"

set +e
EXPECTED_WORKER="$repo_state" SERGEANT_MODEL="anthropic/claude-opus-5" FAIL_WINDOW=1 \
  KILL_LOG="$TEST_ROOT/kill2.log" \
  PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-recover" task-1 app >/dev/null 2>&1
status2=$?
set -e

[[ "$status2" -ne 0 ]] || {
  printf 'FAIL: this scenario forces new-window to fail; recovery must not report success\n' >&2
  exit 1
}
[[ "$(cat "$repo_state/agent_model")" == "anthropic/claude-opus-5" ]] || {
  printf 'FAIL: agent_model should be overridden by the current SERGEANT_MODEL policy, got: %s\n' \
    "$(cat "$repo_state/agent_model")" >&2
  exit 1
}
[[ "$(cat "$repo_state/agent_model_source")" == "env" ]] || {
  printf 'FAIL: agent_model_source should record the env source, got: %s\n' \
    "$(cat "$repo_state/agent_model_source")" >&2
  exit 1
}
[[ ! -s "$TEST_ROOT/kill2.log" ]] || {
  printf 'FAIL: old pane must not be killed when the replacement launch fails\n' >&2
  exit 1
}

printf 'sgt-recover applies the current SERGEANT_MODEL policy before attempting relaunch: ok\n'

# ── Scenario 3: no current policy set leaves the stored record untouched ────

_setup_stalled_worker "$repo_state" "$worktree"
cp "$repo_state/agent_model" "$TEST_ROOT/model-before-3"
cp "$repo_state/agent_model_source" "$TEST_ROOT/model-source-before-3"

set +e
EXPECTED_WORKER="$repo_state" FAIL_WINDOW=1 KILL_LOG="$TEST_ROOT/kill3.log" \
  PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-recover" task-1 app >/dev/null 2>&1
set -e

cmp -s "$TEST_ROOT/model-before-3" "$repo_state/agent_model" || {
  printf 'FAIL: agent_model must stay untouched when no SERGEANT_MODEL policy is set\n' >&2
  exit 1
}
cmp -s "$TEST_ROOT/model-source-before-3" "$repo_state/agent_model_source" || {
  printf 'FAIL: agent_model_source must stay untouched when no SERGEANT_MODEL policy is set\n' >&2
  exit 1
}

printf 'sgt-recover leaves the durable record untouched with no current policy set: ok\n'

printf 'sgt-recover-model-policy: all tests passed\n'
