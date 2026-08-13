#!/usr/bin/env bash
# Public regression for GH #203: an identity-mismatch diagnostic must name a
# bounded command that safely retires stale pane ownership evidence.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fleet="$TEST_ROOT/fleet"
state="$fleet/task-mismatch/app"
worktree="$TEST_ROOT/preserved-worktree"
fake_bin="$TEST_ROOT/bin"
kill_log="$TEST_ROOT/kills"
mkdir -p "$state" "$worktree" "$fake_bin"
: > "$kill_log"

cat > "$fake_bin/tmux" <<'TMUX'
#!/usr/bin/env bash
case "$1" in
  display-message)
    case "${!#}" in
      '#{pane_id}') printf '%%61\n' ;;
      *) printf '0|%%61|88888888|222222|unrelated-process\n' ;;
    esac
    ;;
  kill-pane) printf '%s\n' "$*" >> "$KILL_LOG" ;;
esac
TMUX
chmod +x "$fake_bin/tmux"

cat > "$fake_bin/python3" <<'PYTHON'
#!/usr/bin/env bash
if [[ "${1:-}" == */_sgt-process-token.py && "${2:-}" == holders ]]; then
  [[ -z "${FAKE_HOLDERS:-}" ]] || printf '%s\n' "$FAKE_HOLDERS"
  exit 0
fi
exec /usr/bin/python3 "$@"
PYTHON
chmod +x "$fake_bin/python3"

cat > "$fake_bin/td" <<'TD'
#!/usr/bin/env bash
exit 0
TD
chmod +x "$fake_bin/td"

printf 'Brief: stale pane ownership\n' > "$fleet/task-mismatch/brief.md"
printf '%s\n' "$worktree" > "$state/worktree"
printf 'done\n' > "$state/status"
printf 'done\n' > "$worktree/.sergeant-status"
printf 'result\n' > "$worktree/.sergeant-result"
printf '%%61\n' > "$state/pane"
printf '0|%%61|99999999|111111|original-worker\n' > "$state/pane_identity"
printf '99999999\n' > "$state/worker_pid"
printf '99999999\n' > "$state/worker_process_group"
printf '99999999\n' > "$state/worker_session_id"
printf 'linux:999999999999999\n' > "$state/worker_process_start"
printf '%032d|1:1|198|/gone\n' 1 > "$state/worker_process_marker"
printf '%032d|1:1|999999999999999\n' 1 > "$state/worker_process_markers"
printf 'version=1\nidentity=0|%%61|99999999|111111|original-worker\nprocess_group=99999999\nsession_id=99999999\nprocess_marker=%032d|1:1|198|/gone\nphase=retiring\n' \
  1 > "$state/worker_recycle_phase"
chmod 600 "$state/pane_identity" "$state/worker_process_marker" \
  "$state/worker_process_markers" "$state/worker_recycle_phase"

# Preserve pristine variants for the fail-closed slices below.
mkdir -p "$fleet/task-conflict" "$fleet/task-recycle-conflict" \
  "$fleet/task-live-holder"
cp -R "$state" "$fleet/task-conflict/app"
cp -R "$state" "$fleet/task-recycle-conflict/app"
cp -R "$state" "$fleet/task-live-holder/app"

sync_error="$TEST_ROOT/sync.err"
env PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" KILL_LOG="$kill_log" \
  "$ROOT_DIR/bin/sgt-watch" --sync task-mismatch >/dev/null 2>"$sync_error" || true
grep -Fq 'sgt-watch --retire-stale-pane task-mismatch --repo app' "$sync_error"
grep -Fq 'sgt-watch --retire-stale-pane task-mismatch --repo app' \
  "$state/diagnostic"

env PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" KILL_LOG="$kill_log" \
  "$ROOT_DIR/bin/sgt-watch" --retire-stale-pane task-mismatch --repo app \
  >/dev/null
[[ ! -s "$kill_log" ]]
[[ -d "$worktree" ]]
grep -Fq 'recorded_identity=0|%61|99999999|111111|original-worker' \
  "$state/worker_stale_pane_retirement"
grep -Fq 'observed_identity=0|%61|88888888|222222|unrelated-process' \
  "$state/worker_stale_pane_retirement"

receipt="$(cat "$state/worker_stale_pane_retirement")"
recycled="$(cat "$state/worker_recycled")"
env PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" KILL_LOG="$kill_log" \
  "$ROOT_DIR/bin/sgt-watch" --retire-stale-pane task-mismatch --repo app \
  >/dev/null
env PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" KILL_LOG="$kill_log" \
  "$ROOT_DIR/bin/sgt-watch" --sync task-mismatch >/dev/null
[[ "$(cat "$state/worker_stale_pane_retirement")" == "$receipt" ]]
[[ "$(cat "$state/worker_recycled")" == "$recycled" ]]
[[ ! -s "$kill_log" && -d "$worktree" ]]

conflict_state="$fleet/task-conflict/app"
printf 'version=1\npane=%%61\nrecorded_identity=conflicting-generation\n' \
  > "$conflict_state/worker_stale_pane_retirement"
chmod 600 "$conflict_state/worker_stale_pane_retirement"
if conflict_output="$(env PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" \
  KILL_LOG="$kill_log" "$ROOT_DIR/bin/sgt-watch" --retire-stale-pane \
  task-conflict --repo app 2>&1)"; then
  printf 'conflicting stale-pane receipt was accepted\n' >&2
  exit 1
fi
[[ "$conflict_output" == *'Stale-pane retirement evidence conflicts with the current recorded and observed identities'* ]]
grep -Fq 'recorded_identity=conflicting-generation' \
  "$conflict_state/worker_stale_pane_retirement"

recycle_conflict_state="$fleet/task-recycle-conflict/app"
printf 'version=1\npane=%%61\nrecorded_identity=0|%%61|99999999|111111|original-worker\nobserved_identity=0|%%61|88888888|222222|unrelated-process\noutcome=marker_holders_retired\nretired_at=2026-08-13T12:00:00Z\n' \
  > "$recycle_conflict_state/worker_stale_pane_retirement"
printf 'unbound stale evidence\n' > "$recycle_conflict_state/worker_recycled"
chmod 600 "$recycle_conflict_state/worker_stale_pane_retirement" \
  "$recycle_conflict_state/worker_recycled"
if recycle_conflict_output="$(env PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" \
  KILL_LOG="$kill_log" "$ROOT_DIR/bin/sgt-watch" --retire-stale-pane \
  task-recycle-conflict --repo app 2>&1)"; then
  printf 'conflicting recycle evidence was accepted\n' >&2
  exit 1
fi
[[ "$recycle_conflict_output" == *'Existing recycle evidence is invalid or conflicts with stale-pane retirement'* ]]
grep -Fqx 'unbound stale evidence' "$recycle_conflict_state/worker_recycled"

if holder_output="$(env PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" \
  KILL_LOG="$kill_log" FAKE_HOLDERS='777|linux:333' \
  "$ROOT_DIR/bin/sgt-watch" --retire-stale-pane task-live-holder \
  --repo app 2>&1)"; then
  printf 'live original worker holder was accepted\n' >&2
  exit 1
fi
[[ "$holder_output" == *'Original worker marker holders remain live; stale-pane retirement refused: 777|linux:333'* ]]
[[ ! -e "$fleet/task-live-holder/app/worker_stale_pane_retirement" ]]
[[ ! -s "$kill_log" && -d "$worktree" ]]

printf 'sgt-watch stale-pane retirement: ok\n'
