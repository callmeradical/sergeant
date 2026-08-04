#!/usr/bin/env bash
# Tests for cooperative drain checkpoint in sgt-interactive-worker (td-6c9911)
# Verifies that a drained-status worker exits cleanly with td handoff.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
TMUX_SESSION=""
LIVE_WORKER_PGIDS=""
_cleanup() {
  local cleanup_pgid
  for cleanup_pgid in $LIVE_WORKER_PGIDS; do
    kill -TERM -- "-$cleanup_pgid" 2>/dev/null || true
  done
  sleep 0.05
  for cleanup_pgid in $LIVE_WORKER_PGIDS; do
    kill -KILL -- "-$cleanup_pgid" 2>/dev/null || true
  done
  [[ -z "$TMUX_SESSION" ]] || tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
  rm -rf "$TEST_ROOT"
}
trap _cleanup EXIT

drain_dir="$TEST_ROOT/drains"
source_repo="$TEST_ROOT/source"
worktree="$TEST_ROOT/worktree"
repo_state="$TEST_ROOT/state"
fake_bin="$TEST_ROOT/fake-bin"
config_dir="$TEST_ROOT/config"

mkdir -p "$repo_state" "$source_repo" "$worktree" "$fake_bin" "$config_dir" "$drain_dir"
export SERGEANT_CONFIG="$config_dir"

cat > "$config_dir/test.yaml" <<EOF
repos:
  - name: app
    path: $source_repo
EOF

cat > "$fake_bin/td" <<'EOF'
#!/usr/bin/env bash
[[ "${FAIL_TD:-0}" != "1" ]] || exit 7
printf '%s\n' "$*" >> "${TD_LOG:-/dev/null}"
EOF
chmod +x "$fake_bin/td"

# Fake interactive agent: just sets .sergeant-status
cat > "$fake_bin/fake-opencode" <<'EOF'
#!/usr/bin/env bash
# Minimal stub: mark drained immediately (simulates agent responding to drain signal)
printf 'drained\n' > .sergeant-status
EOF
chmod +x "$fake_bin/fake-opencode"

cat > "$fake_bin/opencode" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FAKE_AGENT_PID_FILE"
trap '' HUP
trap 'exit 0' INT TERM
while :; do sleep 1; done
EOF
chmod +x "$fake_bin/opencode"

# ── 1. Worker with drained status exits cleanly with td handoff ───────────────
# Pre-set drained status so the _finish handler sees it on agent exit.

printf 'td-drain-1\n' > "$repo_state/td_task"
printf 'myproject\n' > "$repo_state/project"
printf 'drained\n' > "$worktree/.sergeant-status"

# Interactive worker requires a terminal — simulate with script/expect not needed;
# just test _finish behavior by running with a fake TTY via `script`
# or by checking the contract directly through a subshell that sources the worker.
# Since we cannot easily fake a terminal, test the drain state contract via
# sgt-interactive-worker sourced functions.

# ── Verify _finish handles drained status via library functions ────────────────
result="$(
  # shellcheck disable=SC2097,SC2098  # Prefix re-exports outer ROOT_DIR/fake_bin for the nested bash; PATH/AGENT read the identical outer values.
  REPO_STATE="$repo_state" WORKTREE="$worktree" AGENT="$fake_bin/fake-opencode" \
  SERGEANT_DRAIN_DIR="$drain_dir" ROOT_DIR="$ROOT_DIR" fake_bin="$fake_bin" \
  PATH="$fake_bin:$ROOT_DIR/bin:$PATH" TD_LOG="$TEST_ROOT/td.log" \
  bash <<'INNER'
    set -uo pipefail
    SCRIPT_DIR="$ROOT_DIR/bin"
    source "$ROOT_DIR/bin/_sgt-response-lock.sh"
    source "$ROOT_DIR/bin/_sgt-drain.sh"
    _sgt_td_memory() { PATH="$fake_bin:$ROOT_DIR/bin:$PATH" "$ROOT_DIR/bin/sgt-td-memory" "$@"; }
    harness="fake-opencode"
    notification_pid=""
    watch_progress_pid=""

    _status() { tr -d '\n' < "$WORKTREE/.sergeant-status" 2>/dev/null || echo "in_progress"; }
    _sync_state() {
      local status; status="$(_status)"
      printf '%s\n' "$status" > "$REPO_STATE/status"
    }
    _finish() {
      local exit_code="$1" status
      trap - EXIT
      [[ -z "${notification_pid:-}" ]] || kill "$notification_pid" 2>/dev/null || true
      [[ -z "${watch_progress_pid:-}" ]] || kill "$watch_progress_pid" 2>/dev/null || true
      status="$(_status)"
      # Bash 3.2 misparses case patterns in a heredoc nested inside $().
      if [[ "$status" == "drained" ]]; then
        _sync_state
        rm -f "$REPO_STATE/diagnostic"
        "$ROOT_DIR/bin/sgt-td-memory" handoff "$REPO_STATE" "$WORKTREE" || true
        printf 'exit:0\n'
        return 0
      fi
      printf 'exit:other(%s)\n' "$status"
      return 1
    }
    _finish 0
INNER
)"
[[ "$result" == "exit:0" ]] || { echo "drained worker should exit 0; got: $result"; exit 1; }
grep -Fq "handoff td-drain-1" "$TEST_ROOT/td.log" 2>/dev/null || \
  { echo "td handoff should be written on drain checkpoint"; exit 1; }
[[ "$(cat "$repo_state/status" 2>/dev/null)" == "drained" ]] || \
  { echo "fleet status should be drained"; exit 1; }

# ── 2. _watch_progress writes drain signal when drain is active ───────────────

drain_worktree="$TEST_ROOT/drain-wt"
drain_repo="$TEST_ROOT/drain-state"
mkdir -p "$drain_worktree" "$drain_repo"
printf 'myproject\n' > "$drain_repo/project"

# Set a global drain
SERGEANT_DRAIN_DIR="$drain_dir" "$ROOT_DIR/bin/sgt-drain" --global --reason "worker signal test"

# Simulate one iteration of the drain check from _watch_progress
# shellcheck disable=SC2097,SC2098  # Prefix re-exports outer drain_dir for the nested bash; SERGEANT_DRAIN_DIR reads the identical outer value.
ROOT_DIR="$ROOT_DIR" drain_dir="$drain_dir" drain_worktree="$drain_worktree" \
drain_repo="$drain_repo" SERGEANT_DRAIN_DIR="$drain_dir" bash <<'INNER'
  source "$ROOT_DIR/bin/_sgt-drain.sh"
  WORKTREE="$drain_worktree"
  REPO_STATE="$drain_repo"
  worker_project="$(tr -d '\n' < "$REPO_STATE/project" 2>/dev/null || true)"
  if [[ ! -f "$WORKTREE/.sergeant-drain-signal" ]]; then
    if _sgt_drain_global_active || \
       { [[ -n "$worker_project" ]] && _sgt_drain_project_active "$worker_project"; }; then
      printf 'scope=global\n' > "$WORKTREE/.sergeant-drain-signal.tmp.$$" && \
        mv "$WORKTREE/.sergeant-drain-signal.tmp.$$" "$WORKTREE/.sergeant-drain-signal" || true
    fi
  fi
INNER

SERGEANT_DRAIN_DIR="$drain_dir" "$ROOT_DIR/bin/sgt-undrain" --global

[[ -f "$drain_worktree/.sergeant-drain-signal" ]] || \
  { echo "drain signal file should be written when drain is active"; exit 1; }

# ── 3. A live interactive worker exits after drain ───────────────────────────

if command -v tmux >/dev/null 2>&1; then
  live_task="$TEST_ROOT/live-task"
  live_state="$live_task/app"
  live_worktree="$TEST_ROOT/live-worktree"
  mkdir -p "$live_state" "$live_worktree"
  printf 'Project: myproject\nBrief: live drain integration\n' > "$live_task/brief.md"
  printf 'td-drain-live\n' > "$live_state/td_task"

  TMUX_SESSION="sgt-worker-drain-$$"
  tmux new-session -d -s "$TMUX_SESSION" -n worker \
    "env PATH='$fake_bin:$PATH' SERGEANT_CONFIG='$config_dir' \
    SERGEANT_DRAIN_DIR='$drain_dir' SGT_DRAIN_CHECK_INTERVAL=0.05 \
    SGT_PROGRESS_INTERVAL=0.05 SGT_NOTIFICATION_RETRY_INTERVAL=0.05 \
    TD_LOG='$TEST_ROOT/live-td.log' FAKE_AGENT_PID_FILE='$TEST_ROOT/live-agent.pid' \
    '$ROOT_DIR/bin/sgt-interactive-worker' '$live_state' '$live_worktree' '$fake_bin/opencode'"

  for _ in $(seq 1 100); do
    [[ -s "$live_state/worker_process_group" && -s "$TEST_ROOT/live-agent.pid" ]] && break
    sleep 0.02
  done
  [[ -s "$live_state/worker_process_group" && -s "$TEST_ROOT/live-agent.pid" ]] || {
    printf 'live drain worker did not start\n' >&2
    exit 1
  }
  LIVE_WORKER_PGIDS="$LIVE_WORKER_PGIDS $(cat "$live_state/worker_process_group")"

  SERGEANT_DRAIN_DIR="$drain_dir" bash -c \
    'source "$1"; _sgt_drain_write "$(_sgt_drain_global_file)" test test-actor' \
    _ "$ROOT_DIR/bin/_sgt-drain.sh"

  for _ in $(seq 1 100); do
    tmux has-session -t "$TMUX_SESSION" 2>/dev/null || break
    sleep 0.02
  done
  if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    printf 'drained interactive worker pane remained alive\n' >&2
    exit 1
  fi

  live_pgid="$(cat "$live_state/worker_process_group")"
  if pgrep -g "$live_pgid" >/dev/null 2>&1; then
    printf 'drained interactive worker process group remained alive: %s\n' "$live_pgid" >&2
    exit 1
  fi
  [[ "$(cat "$live_state/status")" == 'drained' ]]
  TMUX_SESSION=""

  failed_task="$TEST_ROOT/failed-handoff-task"
  failed_state="$failed_task/app"
  failed_worktree="$TEST_ROOT/failed-handoff-worktree"
  mkdir -p "$failed_state" "$failed_worktree"
  printf 'Project: myproject\nBrief: failed handoff integration\n' > "$failed_task/brief.md"
  printf 'td-drain-fails\n' > "$failed_state/td_task"

  TMUX_SESSION="sgt-worker-drain-failed-$$"
  tmux new-session -d -s "$TMUX_SESSION" -n worker \
    "env PATH='$fake_bin:$PATH' SERGEANT_CONFIG='$config_dir' \
    SERGEANT_DRAIN_DIR='$drain_dir' SGT_DRAIN_CHECK_INTERVAL=0.05 \
    SGT_PROGRESS_INTERVAL=0.05 SGT_NOTIFICATION_RETRY_INTERVAL=0.05 FAIL_TD=1 \
    TD_LOG='$TEST_ROOT/failed-td.log' FAKE_AGENT_PID_FILE='$TEST_ROOT/failed-agent.pid' \
    '$ROOT_DIR/bin/sgt-interactive-worker' '$failed_state' '$failed_worktree' '$fake_bin/opencode'"

  for _ in $(seq 1 100); do
    [[ -s "$failed_state/diagnostic" && -s "$failed_state/worker_process_group" ]] && break
    sleep 0.02
  done
  failed_pgid="$(cat "$failed_state/worker_process_group")"
  LIVE_WORKER_PGIDS="$LIVE_WORKER_PGIDS $failed_pgid"
  [[ "$(cat "$failed_state/status")" == 'in_progress' ]]
  grep -Fq 'drain handoff failed' "$failed_state/diagnostic"
  tmux has-session -t "$TMUX_SESSION" 2>/dev/null
  kill -TERM -- "-$failed_pgid" 2>/dev/null || true
  for _ in $(seq 1 50); do
    pgrep -g "$failed_pgid" >/dev/null 2>&1 || break
    sleep 0.02
  done
  kill -KILL -- "-$failed_pgid" 2>/dev/null || true
  tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
  TMUX_SESSION=""
else
  printf 'live tmux drain integration: skipped (tmux unavailable)\n'
fi

printf 'sgt-worker drain checkpoint: ok\n'
