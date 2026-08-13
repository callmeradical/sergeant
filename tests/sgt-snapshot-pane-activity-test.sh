#!/usr/bin/env bash
# Public-boundary regression for GH #206. Run this test in Docker so every
# activity and identity observation comes from the supported tmux runtime, not
# from a host installation or a fake tmux shim.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
export TMUX_TMPDIR="$TEST_ROOT/tmux"
mkdir -p "$TMUX_TMPDIR"
trap 'tmux kill-server >/dev/null 2>&1 || true; rm -rf "$TEST_ROOT"' EXIT

fleet="$TEST_ROOT/fleet"
fake_bin="$TEST_ROOT/fake-bin"
export SERGEANT_CONFIG="$TEST_ROOT/config"
export SERGEANT_DRAIN_DIR="$TEST_ROOT/drain"
mkdir -p "$fleet" "$fake_bin" "$SERGEANT_CONFIG" "$SERGEANT_DRAIN_DIR"

cat > "$fake_bin/opencode" <<'AGENT'
#!/usr/bin/env bash
case "${FAKE_AGENT_MODE:-idle}" in
  child)
    sleep 60 &
    wait "$!"
    ;;
  idle)
    while IFS= read -r _line; do :; done
    ;;
esac
AGENT
chmod +x "$fake_bin/opencode"

field() {
  python3 -c 'import json,sys; print(eval(sys.argv[1], {"d":json.load(sys.stdin), "repr":repr}))' \
    "$2" <<< "$1"
}

snapshot() {
  local task="$1"
  shift
  env SERGEANT_FLEET="$fleet" "$@" "$ROOT_DIR/bin/sgt-watch" \
    --snapshot "$task" --repo app
}

pane_identity() {
  tmux display-message -p -t "$1" \
    '#{pane_dead}|#{pane_id}|#{pane_pid}|#{pane_created}|#{pane_start_command}'
}

publish_pane() {
  local task="$1" pane="$2" state identity
  state="$fleet/$task/app"
  identity="$(pane_identity "$pane")"
  mkdir -p "$state"
  printf 'in_progress\n' > "$state/status"
  printf '%s\n' "$pane" > "$state/pane"
  printf '%s\n' "$identity" > "$state/pane_identity"
  chmod 600 "$state/pane_identity"
  printf '%s\n' "$(( $(date +%s) - 1000 ))" > "$state/progress_ts"
  printf '%s\n' "$state"
}

start_worker() {
  local task="$1" mode="$2" progress_interval="$3" state wt pane worker_command
  state="$fleet/$task/app"
  wt="$TEST_ROOT/$task-wt"
  mkdir -p "$state" "$wt"
  printf 'Project: sergeant\n' > "$fleet/$task/brief.md"
  printf 'in_progress\n' > "$wt/.sergeant-status"
  printf '%s\n' "$wt" > "$state/worktree"
  worker_command="$(bash -c '
    source "$1/bin/_sgt-lib.sh"
    _sgt_prepare_worker_process_marker "$2"
    _sgt_worker_command "$1/bin/sgt-interactive-worker" "$2" "$3" "$4"
  ' bash "$ROOT_DIR" "$state" "$wt" "$fake_bin/opencode")"
  pane="$(tmux new-session -d -P -F '#{pane_id}' -s "$task" \
    "export FAKE_AGENT_MODE=$mode SGT_PROGRESS_INTERVAL=$progress_interval SGT_ACTIVITY_INTERVAL=0.1; $worker_command")"
  # Mirror dispatch's publication order after tmux has created the pane.
  printf '%s\n' "$pane" > "$state/pane"
  printf '%s\n' "$(pane_identity "$pane")" > "$state/pane_identity"
  chmod 600 "$state/pane_identity"
  for _attempt in $(seq 1 100); do
    [[ -s "$state/worker_pid" ]] && break
    sleep 0.05
  done
  [[ -s "$state/worker_pid" ]] || {
    tmux capture-pane -p -t "$pane" >&2 || true
    find "$state" -maxdepth 1 -type f -print -exec sh -c 'printf "%s\\n" "--- $1 ---"; cat "$1"' sh {} \; >&2
    return 1
  }
  printf '%s %s\n' "$state" "$pane"
}

assert_busy() {
  local json="$1" expected="$2" label="$3" actual
  actual="$(field "$json" 'repr(d["busy"])')"
  [[ "$actual" == "$expected" ]] || {
    printf 'FAIL: %s: expected busy=%s, got %s\n%s\n' \
      "$label" "$expected" "$actual" "$json" >&2
    exit 1
  }
}

# 1. tmux 3.7b can leave pane_activity empty. A recent window activity is
# attributable to the worker only while exact identity and one-pane ownership
# are both verified.
pane_output="$(tmux new-session -d -P -F '#{pane_id}' -s output \
  'bash --noprofile --norc')"
publish_pane task-output "$pane_output" >/dev/null
tmux send-keys -t "$pane_output" "printf 'active-output\\n'" Enter
sleep 0.1
json="$(snapshot task-output SERGEANT_SNAPSHOT_RECENT_SECONDS=5)"
assert_busy "$json" True 'active output with pane_activity unavailable'

# A second pane makes window activity ambiguous. Output from it must not be
# attributed to the worker pane.
tmux split-window -d -t "$pane_output" 'bash --noprofile --norc'
other_pane="$(tmux list-panes -t output -F '#{pane_id}' | tail -1)"
tmux send-keys -t "$other_pane" "printf 'unrelated-output\\n'" Enter
sleep 0.1
json="$(snapshot task-output SERGEANT_SNAPSHOT_RECENT_SECONDS=5 \
  SGT_TEST_HOOKS=1 SGT_TEST_TMUX_ACTIVITY_UNAVAILABLE=1)"
assert_busy "$json" None 'ambiguous window activity'

# 2. A newly observed exact descendant of the recorded agent is a bounded
# operation witness. The supervisor and harness parent alone are not enough.
child_worker="$(start_worker task-child child 100)"
state_child="${child_worker%% *}"
for _attempt in $(seq 1 100); do
  [[ -s "$state_child/activity_witness" ]] && break
  sleep 0.05
done
[[ -s "$state_child/activity_witness" ]]
printf '%s\n' "$(( $(date +%s) - 1000 ))" > "$state_child/progress_ts"
json="$(snapshot task-child SERGEANT_SNAPSHOT_RECENT_SECONDS=5 \
  SGT_TEST_HOOKS=1 SGT_TEST_TMUX_ACTIVITY_UNAVAILABLE=1)"
assert_busy "$json" True 'active child operation'

# 3. The old implementation refreshed progress_ts merely because the status
# remained in_progress. A silent live supervisor must become inconclusive.
idle_worker="$(start_worker task-idle idle 0.1)"
state_idle="${idle_worker%% *}"
sleep 2
json="$(snapshot task-idle SERGEANT_SNAPSHOT_RECENT_SECONDS=1 \
  SGT_TEST_HOOKS=1 SGT_TEST_TMUX_ACTIVITY_UNAVAILABLE=1)"
assert_busy "$json" None 'silent idle live worker'

# A real artifact transition restores a bounded witness without a heartbeat.
idle_witness_before="$(cat "$state_idle/activity_witness")"
idle_worktree="$(cat "$state_idle/worktree")"
printf 'Human decision required.\n' > "$idle_worktree/.sergeant-message"
for _attempt in $(seq 1 100); do
  [[ "$(cat "$state_idle/activity_witness" 2>/dev/null || true)" != \
    "$idle_witness_before" ]] && break
  sleep 0.05
done
json="$(snapshot task-idle SERGEANT_SNAPSHOT_RECENT_SECONDS=5 \
  SGT_TEST_HOOKS=1 SGT_TEST_TMUX_ACTIVITY_UNAVAILABLE=1)"
assert_busy "$json" True 'status or artifact transition'

# 4. A witness is bound to the exact pane generation. Killing and restarting a
# pane cannot carry its output/operation witness forward.
old_witness="$(cat "$state_child/activity_witness")"
tmux kill-session -t task-child
replacement="$(tmux new-session -d -P -F '#{pane_id}' -s task-child-restarted \
  'bash --noprofile --norc')"
printf '%s\n' "$replacement" > "$state_child/pane"
printf '%s\n' "$(pane_identity "$replacement")" > "$state_child/pane_identity"
chmod 600 "$state_child/pane_identity"
printf '%s\n' "$old_witness" > "$state_child/activity_witness"
chmod 600 "$state_child/activity_witness"
json="$(snapshot task-child SERGEANT_SNAPSHOT_RECENT_SECONDS=5 \
  SGT_TEST_HOOKS=1 SGT_TEST_TMUX_ACTIVITY_UNAVAILABLE=1)"
assert_busy "$json" None 'interrupted worker generation'

# A forged/reused agent PID with a different birth identity also fails closed.
printf 'version=1\nkind=child\nobserved_at=%s\npane=%s\npane_identity=%s\nsubject_pid=%s\nsubject_identity=linux:1\n' \
  "$(date +%s)" "$replacement" "$(pane_identity "$replacement")" "$$" \
  > "$state_child/activity_witness"
chmod 600 "$state_child/activity_witness"
json="$(snapshot task-child SERGEANT_SNAPSHOT_RECENT_SECONDS=5 \
  SGT_TEST_HOOKS=1 SGT_TEST_TMUX_ACTIVITY_UNAVAILABLE=1)"
assert_busy "$json" None 'PID reuse mismatch'

printf 'snapshot meaningful activity witnesses: ok\n'
