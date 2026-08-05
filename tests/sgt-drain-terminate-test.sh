#!/usr/bin/env bash
# Regression: a cooperative drain actually stops the worker (td-f57072 / GH #152).
#
# _do_drain ran `kill -TERM "$BASHPID"`, but it is only ever reached from
# _watch_drain, which is itself backgrounded. BASHPID therefore resolved to the
# watcher subshell, so only the watcher died: the worker shell, the agent process,
# the notification loop and the progress loop all survived, and the tmux pane
# stayed open. Field evidence was 11 workers marked `drained` still holding live
# panes and agent processes more than a day later.
#
# Drain must publish its durable handoff and finalize the action lease BEFORE
# terminating, then leave nothing of the worker's process group behind and no pane.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
TMUX_SESSION="sgt-drain-terminate-test-$$"
# Run against a private tmux server.  Sharing the developer's server makes these
# tests contend with every other pane on it — including ones leaked by other
# suites — which turns pane operations slow enough to blow the per-test budget,
# and it leaks panes back the other way.  Child `tmux` calls inside the worker
# follow $TMUX, so they reach this same private server.
export TMUX_TMPDIR="$TEST_ROOT/tmux"
mkdir -p "$TMUX_TMPDIR"

trap 'tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true; rm -rf "$TEST_ROOT"' EXIT

command -v tmux >/dev/null 2>&1 || {
  printf 'tmux is required for the drain termination regression\n' >&2
  exit 1
}

drain_dir="$TEST_ROOT/drains"
state="$TEST_ROOT/task/app"
worktree="$TEST_ROOT/worktree"
fake_bin="$TEST_ROOT/fake-bin"
config_dir="$TEST_ROOT/config"
mkdir -p "$drain_dir" "$state" "$worktree/.sergeant-notification-complete" \
  "$fake_bin" "$config_dir"
export SERGEANT_CONFIG="$config_dir"
export SERGEANT_DRAIN_DIR="$drain_dir"

cat > "$fake_bin/td" <<'TD'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TD_LOG:-/dev/null}"
exit 0
TD
chmod +x "$fake_bin/td"

# A harness that renders, records its own pid, spawns a lingering grandchild, and
# never exits on its own.  The grandchild proves the whole process group is swept,
# not just the direct child.
cat > "$fake_bin/opencode" <<'HARNESS'
#!/usr/bin/env bash
printf 'harness up\n'
printf '%s\n' "$$" > "$HARNESS_PID_FILE"
( while :; do sleep 1; done ) &
printf '%s\n' "$!" > "$GRANDCHILD_PID_FILE"
while :; do sleep 1; done
HARNESS
chmod +x "$fake_bin/opencode"

NOTIFY="drain-notification-1"
NONCE="eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
target_dir="$state/notifications/$NOTIFY/targets/$NONCE"
mkdir -p "$target_dir"

printf 'Project: drainproject\n' > "$TEST_ROOT/task/brief.md"
printf 'td-drain-1\n' > "$state/td_task"
printf 'in_progress\n' > "$worktree/.sergeant-status"
printf '1\n' > "$worktree/.sergeant-gate-generation"
printf '%s\n' "$worktree" > "$state/worktree"
# An accepted turn the agent has proved complete: drain must finalize it.
printf '%s\n' "$NOTIFY" > "$state/notification_id"
printf '%s\n' "$NONCE" > "$state/notification_target"
printf '%s\n' "$NONCE" > "$state/notifications/$NOTIFY/action_lease"
printf '%s|%s\n' "$NOTIFY" "$NONCE" > "$target_dir/acknowledged"
printf '%s|%s\n' "$NOTIFY" "$NONCE" > "$target_dir/accepted"
printf '%s|%s\n' "$NOTIFY" "$NONCE" > "$target_dir/delivered"
printf '%s|%s\n' "$NOTIFY" "$NONCE" > \
  "$worktree/.sergeant-notification-complete/$NONCE"

tmux new-session -d -s "$TMUX_SESSION" -n keepalive "while :; do sleep 1; done"
tmux new-window -d -t "$TMUX_SESSION:" -n drained \
  "env PATH='$fake_bin:$PATH' SERGEANT_CONFIG='$config_dir' \
  SERGEANT_DRAIN_DIR='$drain_dir' \
  TD_LOG='$TEST_ROOT/td.log' \
  HARNESS_PID_FILE='$TEST_ROOT/harness.pid' \
  GRANDCHILD_PID_FILE='$TEST_ROOT/grandchild.pid' \
  SGT_DRAIN_CHECK_INTERVAL=0.05 SGT_PROGRESS_INTERVAL=600 \
  SGT_NOTIFICATION_RETRY_INTERVAL=600 \
  '$ROOT_DIR/bin/sgt-interactive-worker' '$state' '$worktree' \
  '$fake_bin/opencode'"

pane="$(tmux display-message -p -t "$TMUX_SESSION:drained" '#{pane_id}')"

for _ in $(seq 1 500); do
  [[ -s "$TEST_ROOT/harness.pid" && -s "$TEST_ROOT/grandchild.pid" && \
     -s "$state/worker_process_group" ]] && break
  sleep 0.02
done
harness_pid="$(cat "$TEST_ROOT/harness.pid" 2>/dev/null || true)"
grandchild_pid="$(cat "$TEST_ROOT/grandchild.pid" 2>/dev/null || true)"
worker_pid="$(cat "$state/worker_pid" 2>/dev/null || true)"
pgid="$(cat "$state/worker_process_group" 2>/dev/null || true)"
[[ -n "$harness_pid" && -n "$grandchild_pid" && -n "$worker_pid" && -n "$pgid" ]] || {
  printf 'worker did not record its identity: harness=%s grandchild=%s worker=%s pgid=%s\n' \
    "$harness_pid" "$grandchild_pid" "$worker_pid" "$pgid" >&2
  exit 1
}
kill -0 "$harness_pid"
kill -0 "$grandchild_pid"
kill -0 "$worker_pid"

# ── Activate a global drain ───────────────────────────────────────────────────

bash -c 'source "$1"; _sgt_drain_write "$(_sgt_drain_global_file)" "regression" "test"' \
  _ "$ROOT_DIR/bin/_sgt-drain.sh"

# ── 1. The worker publishes drained state ─────────────────────────────────────

for _ in $(seq 1 1500); do
  [[ "$(cat "$state/status" 2>/dev/null || true)" == "drained" ]] && break
  sleep 0.02
done
[[ "$(cat "$state/status")" == "drained" ]] || {
  printf 'drain did not publish drained fleet status, got %s\n' \
    "$(cat "$state/status" 2>/dev/null || true)" >&2
  exit 1
}
[[ "$(cat "$worktree/.sergeant-status")" == "drained" ]]
[[ -f "$worktree/.sergeant-drained" ]]

# ── 2. The durable handoff and the lease were settled BEFORE termination ──────

grep -Fq 'handoff' "$TEST_ROOT/td.log" || {
  printf 'drain terminated without publishing a durable td handoff:\n%s\n' \
    "$(cat "$TEST_ROOT/td.log" 2>/dev/null || true)" >&2
  exit 1
}
[[ "$(cat "$target_dir/completed")" == "$NOTIFY|$NONCE" ]] || {
  printf 'drain terminated without finalizing the accepted action lease\n' >&2
  exit 1
}
grep -Fq 'drain_handoff' "$state/notifications/$NOTIFY/action_lease_finalized" || {
  printf 'the lease was not finalized by the drain handoff:\n%s\n' \
    "$(cat "$state/notifications/$NOTIFY/action_lease_finalized" 2>/dev/null || true)" >&2
  exit 1
}

# ── 3. Nothing of the worker's process group survives ─────────────────────────

_gone() {
  local pid="$1" attempt
  for attempt in $(seq 1 1500); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.02
  done
  return 1
}

_gone "$worker_pid" || {
  printf 'the worker shell survived the drain: pid %s\n%s\n' "$worker_pid" \
    "$(ps -o pid=,ppid=,pgid=,args= -p "$worker_pid" 2>/dev/null || true)" >&2
  exit 1
}
_gone "$harness_pid" || {
  printf 'the agent process survived the drain: pid %s\n%s\n' "$harness_pid" \
    "$(ps -o pid=,ppid=,pgid=,args= -p "$harness_pid" 2>/dev/null || true)" >&2
  exit 1
}
_gone "$grandchild_pid" || {
  printf 'an agent grandchild survived the drain: pid %s\n%s\n' "$grandchild_pid" \
    "$(ps -o pid=,ppid=,pgid=,args= -p "$grandchild_pid" 2>/dev/null || true)" >&2
  exit 1
}

# No process at all remains in the recorded process group.
for _ in $(seq 1 1500); do
  survivors="$(ps -o pid= -g "$pgid" 2>/dev/null | tr -d ' ' | grep . || true)"
  [[ -z "$survivors" ]] && break
  sleep 0.02
done
[[ -z "$survivors" ]] || {
  printf 'processes survived in the drained worker process group %s:\n%s\n' "$pgid" \
    "$(ps -o pid=,ppid=,pgid=,args= -g "$pgid" 2>/dev/null || true)" >&2
  exit 1
}

# ── 4. The tmux pane is removed ──────────────────────────────────────────────
# `display-message -t <gone>` silently falls back to the default target, so the
# returned pane id must be compared rather than the exit status trusted.

_pane_present() {
  [[ "$(tmux display-message -p -t "$1" '#{pane_id}' 2>/dev/null || true)" == "$1" ]]
}

for _ in $(seq 1 1500); do
  _pane_present "$pane" || break
  sleep 0.02
done
if _pane_present "$pane"; then
  printf 'the drained worker pane %s is still present\n' "$pane" >&2
  exit 1
fi

# ── 5. Drain did not discard unfinished work ─────────────────────────────────
# The result file must not be invented, and the drained state must remain
# nonterminal-honest: no `done`, no fabricated result.

[[ ! -e "$state/result" ]] || {
  printf 'drain invented a result for unfinished work\n' >&2
  exit 1
}
[[ "$(cat "$state/status")" == "drained" ]]

printf 'cooperative drain terminates the worker process group: ok\n'
