#!/usr/bin/env bash
# Public-CLI regression: terminal sync retires the owned worker process group.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
TMUX_SESSION="sgt-watch-process-convergence-$$"
FIXTURE_PGIDS=""
export TMUX_TMPDIR="$TEST_ROOT/tmux"
mkdir -p "$TMUX_TMPDIR"

cleanup_fixture() {
  local pgid pid pid_file
  tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
  for pgid in $FIXTURE_PGIDS; do
    kill -KILL -- -"$pgid" 2>/dev/null || true
  done
  for pid_file in "$TEST_ROOT/fork.pid" "$TEST_ROOT/existing-setsid.pid"; do
    [[ -e "$pid_file" ]] || continue
    while read -r pid; do
      if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
        kill -KILL "$pid" 2>/dev/null || true
      fi
    done < "$pid_file"
  done
  rm -rf "$TEST_ROOT"
}
trap cleanup_fixture EXIT

command -v tmux >/dev/null 2>&1 || {
  printf 'sgt-watch process convergence: skipped (tmux unavailable)\n'
  exit 0
}

pid_is_running() {
  local state
  state="$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ' || true)"
  [[ -n "$state" && "$state" != Z* ]]
}

state="$TEST_ROOT/fleet/task/app"
worktree="$TEST_ROOT/worktree"
mkdir -p "$state" "$worktree"
make_test_marker() {
  local marker_state="$1"
  marker_path="$(mktemp "$marker_state/.marker.XXXXXX")"
  chmod 400 "$marker_path"
  marker_identity="$(stat -Lc '%d:%i' "$marker_path")"
  marker_generation="$(printf '%032x' "$RANDOM")"
  marker_floor="$(awk '{ line=$0; sub(/^.*\) /, "", line); split(line,f," "); print f[20] }' "/proc/$$/stat")"
  printf '%s|%s|198|%s\n' "$marker_generation" "$marker_identity" "$marker_path" \
    > "$marker_state/worker_process_marker"
  printf '%s|%s|%s\n' "$marker_generation" "$marker_identity" "$marker_floor" \
    >> "$marker_state/worker_process_markers"
  chmod 600 "$marker_state/worker_process_marker" "$marker_state/worker_process_markers"
}
make_test_marker "$state"
printf '%s\n' "$worktree" > "$state/worktree"
printf 'done\n' > "$state/status"
printf 'result\n' > "$state/result"
printf 'done\n' > "$worktree/.sergeant-status"
printf 'result\n' > "$worktree/.sergeant-result"

cat > "$TEST_ROOT/sgt-interactive-worker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state="$1"
pid="$$"
pgid="$(ps -o pgid= -p "$pid" | tr -d ' ')"
sid="$(ps -o sid= -p "$pid" | tr -d ' ')"
# shellcheck source=bin/_sgt-process.sh
source "$PROCESS_ADAPTER"
start="$(_sgt_process_identity "$pid")"
printf '%s\n' "$pid" > "$state/worker_pid"
printf '%s\n' "$pgid" > "$state/worker_process_group"
printf '%s\n' "$sid" > "$state/worker_session_id"
printf '%s\n' "$start" > "$state/worker_process_start"
"$RESISTANT_HELPER" &
printf '%s\n' "$!" > "$state/helper_pid"
wait
EOF
chmod +x "$TEST_ROOT/sgt-interactive-worker"
cat > "$TEST_ROOT/resistant-helper" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == child ]]; then
  trap '' TERM HUP
elif [[ "${1:-}" == forker ]]; then
  trap '' TERM HUP
  while [[ ! -e "$STOP_RACE_MARKER" ]]; do :; done
  setsid "$0" child & printf '%s\n' "$!" >> "$FORK_PID_FILE"
  exit 0
else
  if [[ "${CREATE_EXISTING_SETSID:-0}" == 1 ]]; then
    setsid "$0" child & printf '%s\n' "$!" >> "$EXISTING_SETSID_PID_FILE"
  fi
  if [[ "${CREATE_FORK_RACE:-0}" == 1 ]]; then
    "$0" forker &
  fi
  trap '( setsid "$0" child & ) & printf "ran\n" >> "$TERM_HANDLER_FILE"' TERM
  trap '' HUP
fi
while :; do :; done
EOF
chmod +x "$TEST_ROOT/resistant-helper"
export RESISTANT_HELPER="$TEST_ROOT/resistant-helper"
export FORK_PID_FILE="$TEST_ROOT/fork.pid"
export EXISTING_SETSID_PID_FILE="$TEST_ROOT/existing-setsid.pid"
export TERM_HANDLER_FILE="$TEST_ROOT/term-handler-ran"
export PROCESS_ADAPTER="$ROOT_DIR/bin/_sgt-process.sh"
export STOP_RACE_MARKER="$TEST_ROOT/stop-race"

tmux new-session -d -s "$TMUX_SESSION" -n keepalive 'while :; do sleep 1; done'
pane="$(tmux new-window -d -P -F '#{pane_id}' -t "$TMUX_SESSION:" -n worker \
  "exec 198<'$marker_path'; rm -f '$marker_path'; exec env RESISTANT_HELPER='$RESISTANT_HELPER' FORK_PID_FILE='$FORK_PID_FILE' EXISTING_SETSID_PID_FILE='$EXISTING_SETSID_PID_FILE' TERM_HANDLER_FILE='$TERM_HANDLER_FILE' PROCESS_ADAPTER='$PROCESS_ADAPTER' STOP_RACE_MARKER='$STOP_RACE_MARKER' CREATE_EXISTING_SETSID=1 CREATE_FORK_RACE=1 \
  '$TEST_ROOT/sgt-interactive-worker' '$state'")"
printf '%s\n' "$pane" > "$state/pane"
for _ in $(seq 1 100); do
  [[ -s "$state/helper_pid" && -s "$state/worker_process_start" ]] && break
  sleep 0.02
done
[[ -s "$state/helper_pid" && -s "$state/worker_process_start" ]]
tmux display-message -p -t "$pane" \
  '#{pane_dead}|#{pane_id}|#{pane_pid}|#{pane_created}|#{pane_start_command}' \
  > "$state/pane_identity"
chmod 600 "$state/pane_identity"
helper_pid="$(cat "$state/helper_pid")"
worker_pid="$(cat "$state/worker_pid")"
worker_sid="$(cat "$state/worker_session_id")"
FIXTURE_PGIDS+=" $(cat "$state/worker_process_group")"
kill -0 "$helper_pid" 2>/dev/null || {
  tmux capture-pane -p -t "$pane" >&2 || true
  exit 1
}
[[ -n "$(pgrep -g "$(cat "$state/worker_process_group")" 2>/dev/null || true)" ]]
pgrep -g "$(cat "$state/worker_process_group")" | grep -Fxq "$(cat "$state/worker_pid")"

if SGT_WATCH_RECYCLE_FAIL_POINT=after-pane-kill SERGEANT_FLEET="$TEST_ROOT/fleet" \
  "$ROOT_DIR/bin/sgt-watch" --sync task >/dev/null 2>&1; then
  printf 'terminal sync reported success across an interrupted retirement\n' >&2
  exit 1
fi

if ! kill -0 "$helper_pid" 2>/dev/null; then
  printf 'injected interruption did not preserve the resistant child for retry\n' >&2
  exit 1
fi
for _ in $(seq 1 100); do
  ps -p "$worker_pid" >/dev/null 2>&1 || break
  sleep 0.01
done
if ps -p "$worker_pid" >/dev/null 2>&1; then
  printf 'pane kill did not exit the recorded session leader\n' >&2
  exit 1
fi
[[ "$(ps -o sid= -p "$helper_pid" | tr -d ' ')" == "$worker_sid" ]]
[[ -s "$state/worker_recycle_phase" ]] || {
  printf 'retirement phase missing: %s\n' "$(cat "$state/diagnostic" 2>/dev/null || true)" >&2
  exit 1
}
awk -F '|' '/^member=/{ if (NF < 5) bad=1; found=1 } END { exit bad || !found }' \
  "$state/worker_recycle_phase"
[[ ! -e "$state/worker_recycled" ]]

if ! SGT_WATCH_RECYCLE_FAIL_POINT=before-first-stop \
  SGT_WATCH_RECYCLE_RACE_MARKER="$STOP_RACE_MARKER" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" "$ROOT_DIR/bin/sgt-watch" --sync task >/dev/null; then
  cat "$state/diagnostic" >&2
  exit 1
fi
[[ ! -e "$state/worker_recycle_phase" ]]
[[ ! -e "$state/diagnostic" ]]
existing_setsid_pid="$(tail -n 1 "$EXISTING_SETSID_PID_FILE" 2>/dev/null || true)"
[[ -n "$existing_setsid_pid" ]]
if [[ -e "$TERM_HANDLER_FILE" ]]; then
  printf 'terminal retirement executed a TERM handler before quiescence\n' >&2
  exit 1
fi
if pid_is_running "$existing_setsid_pid"; then
  printf 'existing setsid descendant survived lineage retirement: %s\n' "$existing_setsid_pid" >&2
  exit 1
fi

if pid_is_running "$helper_pid"; then
  printf 'terminal sync left owned helper process alive: %s\n' "$helper_pid" >&2
  exit 1
fi
if [[ "$(tmux display-message -p -t "$pane" '#{pane_id}' 2>/dev/null || true)" == \
  "$pane" ]]; then
  printf 'terminal sync left owned worker pane alive: %s\n' "$pane" >&2
  exit 1
fi

launch_fixture() {
  local name="$1" status="${2:-done}"
  launched_state="$TEST_ROOT/fleet/$name/app"
  launched_worktree="$TEST_ROOT/$name-worktree"
  mkdir -p "$launched_state" "$launched_worktree"
  make_test_marker "$launched_state"
  printf '%s\n' "$launched_worktree" > "$launched_state/worktree"
  printf '%s\n' "$status" > "$launched_state/status"
  printf '%s\n' "$status" > "$launched_worktree/.sergeant-status"
  if [[ "$status" == "done" ]]; then
    printf 'result\n' > "$launched_state/result"
    printf 'result\n' > "$launched_worktree/.sergeant-result"
  fi
  launched_pane="$(tmux new-window -d -P -F '#{pane_id}' -t "$TMUX_SESSION:" \
    -n "$name" "exec 198<'$marker_path'; rm -f '$marker_path'; exec env RESISTANT_HELPER='$RESISTANT_HELPER' FORK_PID_FILE='$FORK_PID_FILE' EXISTING_SETSID_PID_FILE='$EXISTING_SETSID_PID_FILE' TERM_HANDLER_FILE='$TERM_HANDLER_FILE' PROCESS_ADAPTER='$PROCESS_ADAPTER' CREATE_EXISTING_SETSID=0 CREATE_FORK_RACE=0 \
    '$TEST_ROOT/sgt-interactive-worker' '$launched_state'")"
  printf '%s\n' "$launched_pane" > "$launched_state/pane"
  for _ in $(seq 1 100); do
    [[ -s "$launched_state/helper_pid" && -s "$launched_state/worker_process_start" ]] && break
    sleep 0.02
  done
  tmux display-message -p -t "$launched_pane" \
    '#{pane_dead}|#{pane_id}|#{pane_pid}|#{pane_created}|#{pane_start_command}' \
    > "$launched_state/pane_identity"
  chmod 600 "$launched_state/pane_identity"
  launched_pid="$(cat "$launched_state/helper_pid")"
  launched_pgid="$(cat "$launched_state/worker_process_group")"
  FIXTURE_PGIDS+=" $launched_pgid"
}

# Missing provenance is actionable and cannot be reported as converged.
launch_fixture task-no-provenance
rm -f "$launched_state/worker_pid" "$launched_state/worker_process_group" \
  "$launched_state/worker_process_start" "$launched_state/worker_session_id" \
  "$launched_state/worker_process_marker" "$launched_state/worker_process_markers"
if SERGEANT_FLEET="$TEST_ROOT/fleet" "$ROOT_DIR/bin/sgt-watch" \
  --sync task-no-provenance >/dev/null 2>&1; then exit 1; fi
kill -0 "$launched_pid"
grep -Fq 'process provenance is incomplete' "$launched_state/diagnostic"
set +e
foreground_output="$(POLL_INTERVAL=0.01 SERGEANT_FLEET="$TEST_ROOT/fleet" \
  "$ROOT_DIR/bin/sgt-watch" task-no-provenance 2>&1)"
foreground_status=$?
SERGEANT_FLEET="$TEST_ROOT/fleet" "$ROOT_DIR/bin/sgt-watch" \
  --sync-all >/dev/null 2>&1
sync_all_status=$?
set -e
[[ "$foreground_status" -ne 0 && "$sync_all_status" -ne 0 ]]
[[ "$foreground_output" != *'All repos done.'* ]]
kill -KILL -- -"$launched_pgid" 2>/dev/null || true

# Terminal state with neither worktree nor pane cannot be reported successful.
missing_state="$TEST_ROOT/fleet/task-missing/app"
mkdir -p "$missing_state"
printf 'done\n' > "$missing_state/status"
if SERGEANT_FLEET="$TEST_ROOT/fleet" "$ROOT_DIR/bin/sgt-watch" \
  --sync task-missing >/dev/null 2>&1; then
  printf 'terminal task without resource retirement proof reported success\n' >&2
  exit 1
fi
[[ ! -e "$missing_state/worker_recycled" ]]

# PID reuse evidence and a non-leading/shared PGID both fail closed.
launch_fixture task-reused-pid
saved_start="$(cat "$launched_state/worker_process_start")"
printf 'stale start identity\n' > "$launched_state/worker_process_start"
if SERGEANT_FLEET="$TEST_ROOT/fleet" "$ROOT_DIR/bin/sgt-watch" \
  --sync task-reused-pid >/dev/null 2>&1; then exit 1; fi
kill -0 "$launched_pid"
grep -Fq 'process identity does not match' "$launched_state/diagnostic"
printf '%s\n' "$saved_start" > "$launched_state/worker_process_start"
if ! SERGEANT_FLEET="$TEST_ROOT/fleet" "$ROOT_DIR/bin/sgt-watch" \
  --sync task-reused-pid >/dev/null; then
  cat "$launched_state/diagnostic" >&2
  exit 1
fi

launch_fixture task-token-conflict
saved_token="$(cat "$launched_state/worker_process_marker")"
printf 'malformed\n' > "$launched_state/worker_process_marker"
if SERGEANT_FLEET="$TEST_ROOT/fleet" "$ROOT_DIR/bin/sgt-watch" \
  --sync task-token-conflict >/dev/null 2>&1; then
  printf 'conflicting durable token was accepted as worker ownership\n' >&2
  exit 1
fi
pid_is_running "$launched_pid"
printf '%s\n' "$saved_token" > "$launched_state/worker_process_marker"
SERGEANT_FLEET="$TEST_ROOT/fleet" "$ROOT_DIR/bin/sgt-watch" \
  --sync task-token-conflict >/dev/null

launch_fixture task-shared-pgid
saved_pgid="$launched_pgid"
keepalive_pid="$(tmux display-message -p -t "$TMUX_SESSION:keepalive" '#{pane_pid}')"
keepalive_pgid="$(ps -o pgid= -p "$keepalive_pid" | tr -d ' ')"
printf '%s\n' "$keepalive_pgid" > "$launched_state/worker_process_group"
if SERGEANT_FLEET="$TEST_ROOT/fleet" "$ROOT_DIR/bin/sgt-watch" \
  --sync task-shared-pgid >/dev/null 2>&1; then exit 1; fi
kill -0 "$launched_pid"
kill -0 "$keepalive_pid"
printf '%s\n' "$saved_pgid" > "$launched_state/worker_process_group"
SERGEANT_FLEET="$TEST_ROOT/fleet" "$ROOT_DIR/bin/sgt-watch" \
  --sync task-shared-pgid >/dev/null

# Two recyclers racing the same exact owned pane both converge. The loser of
# kill-pane must consume the peer's durable process-retirement evidence rather
# than report a false failure after the peer completed.
launch_fixture task-concurrent
SERGEANT_FLEET="$TEST_ROOT/fleet" "$ROOT_DIR/bin/sgt-watch" \
  --sync task-concurrent >"$TEST_ROOT/concurrent-a.out" 2>&1 & recycler_a=$!
SERGEANT_FLEET="$TEST_ROOT/fleet" "$ROOT_DIR/bin/sgt-watch" \
  --sync task-concurrent >"$TEST_ROOT/concurrent-b.out" 2>&1 & recycler_b=$!
set +e
wait "$recycler_a"; recycler_a_status=$?
wait "$recycler_b"; recycler_b_status=$?
set -e
if [[ "$recycler_a_status" -ne 0 || "$recycler_b_status" -ne 0 ]]; then
  cat "$TEST_ROOT/concurrent-a.out" "$TEST_ROOT/concurrent-b.out" >&2
  printf 'concurrent recycler statuses: %s %s\n' "$recycler_a_status" "$recycler_b_status" >&2
  exit 1
fi
[[ -s "$launched_state/worker_recycled" ]]
pid_is_running "$launched_pid" && {
  printf 'concurrent recyclers left owned helper alive\n' >&2
  exit 1
}

# Waiting remains resumable and retains its exact worker pane/process group.
launch_fixture task-waiting waiting
SERGEANT_FLEET="$TEST_ROOT/fleet" "$ROOT_DIR/bin/sgt-watch" \
  --sync task-waiting >/dev/null
kill -0 "$launched_pid"
[[ "$(tmux display-message -p -t "$launched_pane" '#{pane_id}')" == "$launched_pane" ]]
kill -KILL -- -"$launched_pgid" 2>/dev/null || true

printf 'sgt-watch process convergence: ok\n'
