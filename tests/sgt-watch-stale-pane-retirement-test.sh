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
    if [[ -n "${PANE_ABSENT_FILE:-}" && -e "$PANE_ABSENT_FILE" ]]; then
      exit 1
    fi
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
  if [[ "${FAIL_HOLDER_SCAN:-}" == 1 ]]; then
    [[ -z "${HOLDER_SCAN_REACHED:-}" ]] || : > "$HOLDER_SCAN_REACHED"
    exit 1
  fi
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
  "$fleet/task-live-holder" "$fleet/task-malformed-identity" \
  "$fleet/task-missing-status" "$fleet/task-receipt-race" \
  "$fleet/task-recycle-race" "$fleet/task-marker-race" \
  "$fleet/task-lifecycle-race" "$fleet/task-post-status-race" \
  "$fleet/task-post-marker-race" "$fleet/task-absent-worktree" \
  "$fleet/task-receipt-publication-race" "$fleet/task-receipt-retry"
mkdir -p "$fleet/task-peer-race"
cp -R "$state" "$fleet/task-conflict/app"
cp -R "$state" "$fleet/task-recycle-conflict/app"
cp -R "$state" "$fleet/task-live-holder/app"
cp -R "$state" "$fleet/task-malformed-identity/app"
cp -R "$state" "$fleet/task-missing-status/app"
cp -R "$state" "$fleet/task-receipt-race/app"
cp -R "$state" "$fleet/task-recycle-race/app"
cp -R "$state" "$fleet/task-marker-race/app"
cp -R "$state" "$fleet/task-lifecycle-race/app"
cp -R "$state" "$fleet/task-post-status-race/app"
cp -R "$state" "$fleet/task-post-marker-race/app"
cp -R "$state" "$fleet/task-absent-worktree/app"
cp -R "$state" "$fleet/task-receipt-publication-race/app"
cp -R "$state" "$fleet/task-receipt-retry/app"
cp -R "$state" "$fleet/task-peer-race/app"

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
[[ -s "$state/worker_stale_pane_retirement_validated" ]]

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

malformed_state="$fleet/task-malformed-identity/app"
printf 'malformed-exact-identity\n' > "$malformed_state/pane_identity"
chmod 600 "$malformed_state/pane_identity"
if malformed_output="$(env PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" \
  KILL_LOG="$kill_log" "$ROOT_DIR/bin/sgt-watch" --retire-stale-pane \
  task-malformed-identity --repo app 2>&1)"; then
  printf 'malformed recorded pane identity was accepted\n' >&2
  exit 1
fi
[[ "$malformed_output" == *'Recorded pane identity is malformed or does not name the recorded pane'* ]]

missing_status_state="$fleet/task-missing-status/app"
missing_status_worktree="$TEST_ROOT/missing-status-worktree"
mkdir -p "$missing_status_worktree"
printf '%s\n' "$missing_status_worktree" > "$missing_status_state/worktree"
if missing_status_output="$(env PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" \
  KILL_LOG="$kill_log" "$ROOT_DIR/bin/sgt-watch" --retire-stale-pane \
  task-missing-status --repo app 2>&1)"; then
  printf 'missing preserved worktree status was accepted\n' >&2
  exit 1
fi
[[ "$missing_status_output" == *'Preserved worktree status is missing or unsafe; stale-pane retirement refused'* ]]

wait_for_barrier() {
  local barrier="$1"
  for _ in $(seq 1 200); do
    [[ -e "$barrier.ready" ]] && return 0
    sleep 0.01
  done
  return 1
}

receipt_race_state="$fleet/task-receipt-race/app"
receipt_barrier="$TEST_ROOT/receipt-race"
env PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" KILL_LOG="$kill_log" \
  SGT_TEST_HOOKS=1 SGT_TEST_STALE_PANE_BARRIER="$receipt_barrier" \
  "$ROOT_DIR/bin/sgt-watch" --retire-stale-pane task-receipt-race --repo app \
  > "$TEST_ROOT/receipt-race.out" 2>&1 &
receipt_pid=$!
wait_for_barrier "$receipt_barrier"
printf 'version=1\npane=%%61\nrecorded_identity=concurrent-conflict\n' \
  > "$receipt_race_state/worker_stale_pane_retirement"
chmod 600 "$receipt_race_state/worker_stale_pane_retirement"
: > "$receipt_barrier.release"
if wait "$receipt_pid"; then
  printf 'concurrent conflicting receipt was accepted\n' >&2
  exit 1
fi
grep -Fq 'concurrent-conflict' "$receipt_race_state/worker_stale_pane_retirement"
[[ ! -e "$receipt_race_state/worker_recycled" ]]

recycle_race_state="$fleet/task-recycle-race/app"
recycle_barrier="$TEST_ROOT/recycle-race"
env PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" KILL_LOG="$kill_log" \
  SGT_TEST_HOOKS=1 SGT_TEST_STALE_PANE_BARRIER="$recycle_barrier" \
  "$ROOT_DIR/bin/sgt-watch" --retire-stale-pane task-recycle-race --repo app \
  > "$TEST_ROOT/recycle-race.out" 2>&1 &
recycle_pid=$!
wait_for_barrier "$recycle_barrier"
printf 'concurrent recycle conflict\n' > "$recycle_race_state/worker_recycled"
chmod 600 "$recycle_race_state/worker_recycled"
: > "$recycle_barrier.release"
if wait "$recycle_pid"; then
  printf 'concurrent conflicting recycle evidence was accepted\n' >&2
  exit 1
fi
grep -Fqx 'concurrent recycle conflict' "$recycle_race_state/worker_recycled"

marker_race_state="$fleet/task-marker-race/app"
marker_barrier="$TEST_ROOT/marker-race"
env PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" KILL_LOG="$kill_log" \
  SGT_TEST_HOOKS=1 SGT_TEST_STALE_PANE_BARRIER="$marker_barrier" \
  "$ROOT_DIR/bin/sgt-watch" --retire-stale-pane task-marker-race --repo app \
  > "$TEST_ROOT/marker-race.out" 2>&1 &
marker_pid=$!
wait_for_barrier "$marker_barrier"
printf '%032d|2:2|198|/gone\n' 2 > "$marker_race_state/worker_process_marker"
printf '%032d|2:2|999999999999999\n' 2 > "$marker_race_state/worker_process_markers"
chmod 600 "$marker_race_state/worker_process_marker" \
  "$marker_race_state/worker_process_markers"
: > "$marker_barrier.release"
if wait "$marker_pid"; then
  printf 'rotated marker generation was accepted\n' >&2
  exit 1
fi
grep -Fq 'Terminal worker lifecycle or pane identity changed during stale-pane retirement' \
  "$TEST_ROOT/marker-race.out"
[[ ! -e "$marker_race_state/worker_stale_pane_retirement" ]]
[[ ! -e "$marker_race_state/worker_recycled" ]]
[[ ! -s "$kill_log" && -d "$worktree" ]]

lifecycle_race_state="$fleet/task-lifecycle-race/app"
lifecycle_worktree="$TEST_ROOT/lifecycle-race-worktree"
lifecycle_barrier="$TEST_ROOT/lifecycle-race"
mkdir -p "$lifecycle_worktree"
printf 'done\n' > "$lifecycle_worktree/.sergeant-status"
printf '%s\n' "$lifecycle_worktree" > "$lifecycle_race_state/worktree"
env PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" KILL_LOG="$kill_log" \
  SGT_TEST_HOOKS=1 SGT_TEST_STALE_PANE_BARRIER="$lifecycle_barrier" \
  "$ROOT_DIR/bin/sgt-watch" --retire-stale-pane task-lifecycle-race --repo app \
  > "$TEST_ROOT/lifecycle-race.out" 2>&1 &
lifecycle_pid=$!
wait_for_barrier "$lifecycle_barrier"
[[ -s "$lifecycle_race_state/response.lock" ]] || {
  printf 'stale-pane retirement did not hold the canonical lifecycle lock\n' >&2
  exit 1
}
printf 'in_progress\n' > "$lifecycle_race_state/status"
printf 'in_progress\n' > "$lifecycle_worktree/.sergeant-status"
printf '0|%%61|77777777|333333|replacement-worker\n' \
  > "$lifecycle_race_state/pane_identity"
chmod 600 "$lifecycle_race_state/pane_identity"
: > "$lifecycle_barrier.release"
if wait "$lifecycle_pid"; then
  printf 'concurrent lifecycle generation rotation was accepted\n' >&2
  exit 1
fi
grep -Fq 'Terminal worker lifecycle or pane identity changed during stale-pane retirement' \
  "$TEST_ROOT/lifecycle-race.out"
[[ ! -e "$lifecycle_race_state/worker_stale_pane_retirement" ]]
[[ ! -e "$lifecycle_race_state/worker_recycled" ]]
[[ ! -e "$lifecycle_race_state/response.lock" ]]
[[ ! -s "$kill_log" && -d "$lifecycle_worktree" ]]

post_status_state="$fleet/task-post-status-race/app"
post_status_worktree="$TEST_ROOT/post-status-worktree"
post_status_barrier="$TEST_ROOT/post-status-race"
mkdir -p "$post_status_worktree"
printf 'done\n' > "$post_status_worktree/.sergeant-status"
printf '%s\n' "$post_status_worktree" > "$post_status_state/worktree"
env PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" KILL_LOG="$kill_log" \
  SGT_TEST_HOOKS=1 SGT_TEST_STALE_PANE_POST_EVIDENCE_BARRIER="$post_status_barrier" \
  "$ROOT_DIR/bin/sgt-watch" --retire-stale-pane task-post-status-race --repo app \
  > "$TEST_ROOT/post-status-race.out" 2>&1 &
post_status_pid=$!
wait_for_barrier "$post_status_barrier"
printf 'in_progress\n' > "$post_status_state/status"
printf 'in_progress\n' > "$post_status_worktree/.sergeant-status"
: > "$post_status_barrier.release"
if wait "$post_status_pid"; then
  printf 'post-publication nonterminal rotation was accepted\n' >&2
  exit 1
fi
grep -Fq 'changed after recycle evidence publication' "$TEST_ROOT/post-status-race.out"
[[ -s "$post_status_state/worker_recycled" ]]
[[ ! -e "$post_status_state/worker_stale_pane_retirement" ]]

post_marker_state="$fleet/task-post-marker-race/app"
post_marker_barrier="$TEST_ROOT/post-marker-race"
env PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" KILL_LOG="$kill_log" \
  SGT_TEST_HOOKS=1 SGT_TEST_STALE_PANE_POST_EVIDENCE_BARRIER="$post_marker_barrier" \
  "$ROOT_DIR/bin/sgt-watch" --retire-stale-pane task-post-marker-race --repo app \
  > "$TEST_ROOT/post-marker-race.out" 2>&1 &
post_marker_pid=$!
wait_for_barrier "$post_marker_barrier"
printf '%032d|3:3|198|/gone\n' 3 > "$post_marker_state/worker_process_marker"
printf '%032d|3:3|999999999999999\n' 3 > "$post_marker_state/worker_process_markers"
chmod 600 "$post_marker_state/worker_process_marker" \
  "$post_marker_state/worker_process_markers"
: > "$post_marker_barrier.release"
if wait "$post_marker_pid"; then
  printf 'post-publication marker rotation was accepted\n' >&2
  exit 1
fi
grep -Fq 'changed after recycle evidence publication' "$TEST_ROOT/post-marker-race.out"
[[ -s "$post_marker_state/worker_recycled" ]]
[[ ! -e "$post_marker_state/worker_stale_pane_retirement" ]]
[[ -s "$post_marker_state/worker_stale_pane_retirement_pending" ]]
pending_pane_absent="$TEST_ROOT/pending-pane-absent"
: > "$pending_pane_absent"
if env PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" KILL_LOG="$kill_log" \
  PANE_ABSENT_FILE="$pending_pane_absent" "$ROOT_DIR/bin/sgt-watch" \
  --sync task-post-marker-race > /dev/null \
  2> "$TEST_ROOT/post-marker-pending-sync.err"; then
  printf 'sync bypassed pending stale evidence after pane disappeared\n' >&2
  exit 1
fi
grep -Fq 'sgt-watch --retire-stale-pane task-post-marker-race --repo app' \
  "$TEST_ROOT/post-marker-pending-sync.err"
[[ ! -s "$kill_log" && -d "$post_status_worktree" && -d "$worktree" ]]

absent_state="$fleet/task-absent-worktree/app"
printf '%s\n' "$TEST_ROOT/recorded-worktree-is-absent" > "$absent_state/worktree"
env PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" KILL_LOG="$kill_log" \
  "$ROOT_DIR/bin/sgt-watch" --sync task-absent-worktree \
  >/dev/null 2> "$TEST_ROOT/absent-worktree.err" || true
grep -Fq 'sgt-watch --retire-stale-pane task-absent-worktree --repo app' \
  "$TEST_ROOT/absent-worktree.err"
env PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" KILL_LOG="$kill_log" \
  "$ROOT_DIR/bin/sgt-watch" --retire-stale-pane task-absent-worktree --repo app \
  >/dev/null
[[ -s "$absent_state/worker_stale_pane_retirement" ]]
[[ -s "$absent_state/worker_recycled" ]]

receipt_publication_state="$fleet/task-receipt-publication-race/app"
receipt_publication_worktree="$TEST_ROOT/receipt-publication-worktree"
receipt_publication_barrier="$TEST_ROOT/receipt-publication-race"
mkdir -p "$receipt_publication_worktree"
printf 'done\n' > "$receipt_publication_worktree/.sergeant-status"
printf '%s\n' "$receipt_publication_worktree" > "$receipt_publication_state/worktree"
env PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" KILL_LOG="$kill_log" \
  SGT_TEST_HOOKS=1 SGT_TEST_STALE_PANE_RECEIPT_BARRIER="$receipt_publication_barrier" \
  "$ROOT_DIR/bin/sgt-watch" --retire-stale-pane task-receipt-publication-race \
  --repo app > "$TEST_ROOT/receipt-publication-race.out" 2>&1 &
receipt_publication_pid=$!
wait_for_barrier "$receipt_publication_barrier"
printf 'in_progress\n' > "$receipt_publication_state/status"
printf 'in_progress\n' > "$receipt_publication_worktree/.sergeant-status"
printf '%032d|4:4|198|/gone\n' 4 > "$receipt_publication_state/worker_process_marker"
printf '%032d|4:4|999999999999999\n' 4 \
  > "$receipt_publication_state/worker_process_markers"
chmod 600 "$receipt_publication_state/worker_process_marker" \
  "$receipt_publication_state/worker_process_markers"
: > "$receipt_publication_barrier.release"
if wait "$receipt_publication_pid"; then
  printf 'lifecycle rotation during receipt publication was accepted\n' >&2
  exit 1
fi
grep -Fq 'changed during receipt publication' \
  "$TEST_ROOT/receipt-publication-race.out"
[[ ! -e "$receipt_publication_state/worker_stale_pane_retirement" ]]
find "$receipt_publication_state" -maxdepth 1 -type f \
  -name 'worker_stale_pane_retirement.incomplete.*' | grep -q .
[[ -s "$receipt_publication_state/worker_recycled" ]]
[[ ! -s "$kill_log" && -d "$receipt_publication_worktree" ]]

receipt_retry_state="$fleet/task-receipt-retry/app"
if env PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" KILL_LOG="$kill_log" \
  SGT_TEST_HOOKS=1 SGT_TEST_STALE_PANE_FAIL_AFTER_RECEIPT=1 \
  "$ROOT_DIR/bin/sgt-watch" --retire-stale-pane task-receipt-retry --repo app \
  > "$TEST_ROOT/receipt-retry-interrupted.out" 2>&1; then
  printf 'injected post-receipt interruption succeeded unexpectedly\n' >&2
  exit 1
fi
[[ -s "$receipt_retry_state/worker_stale_pane_retirement" ]]
[[ -s "$receipt_retry_state/worker_recycled" ]]
retry_receipt="$(cat "$receipt_retry_state/worker_stale_pane_retirement")"
[[ ! -e "$receipt_retry_state/worker_stale_pane_retirement_validated" ]]
if env PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" KILL_LOG="$kill_log" \
  FAKE_HOLDERS='778|linux:334' "$ROOT_DIR/bin/sgt-watch" \
  --sync task-receipt-retry > /dev/null 2> "$TEST_ROOT/receipt-retry-sync.err"; then
  printf 'sync trusted an interrupted stale-pane receipt\n' >&2
  exit 1
fi
grep -Fq 'sgt-watch --retire-stale-pane task-receipt-retry --repo app' \
  "$TEST_ROOT/receipt-retry-sync.err"
absent_after_receipt="$TEST_ROOT/absent-after-receipt"
: > "$absent_after_receipt"
if env PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" KILL_LOG="$kill_log" \
  PANE_ABSENT_FILE="$absent_after_receipt" "$ROOT_DIR/bin/sgt-watch" \
  --sync task-receipt-retry > /dev/null \
  2> "$TEST_ROOT/receipt-retry-absent-sync.err"; then
  printf 'sync bypassed interrupted receipt after pane disappeared\n' >&2
  exit 1
fi
grep -Fq 'sgt-watch --retire-stale-pane task-receipt-retry --repo app' \
  "$TEST_ROOT/receipt-retry-absent-sync.err"
if retry_holder_output="$(env PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" \
  KILL_LOG="$kill_log" FAKE_HOLDERS='778|linux:334' \
  "$ROOT_DIR/bin/sgt-watch" --retire-stale-pane task-receipt-retry \
  --repo app 2>&1)"; then
  printf 'retry trusted an unvalidated receipt without rescanning holders\n' >&2
  exit 1
fi
[[ "$retry_holder_output" == *'Original worker marker holders remain live; stale-pane retirement refused: 778|linux:334'* ]]
[[ "$(cat "$receipt_retry_state/worker_stale_pane_retirement")" == "$retry_receipt" ]]
env PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" KILL_LOG="$kill_log" \
  "$ROOT_DIR/bin/sgt-watch" --retire-stale-pane task-receipt-retry --repo app \
  >/dev/null
[[ "$(cat "$receipt_retry_state/worker_stale_pane_retirement")" == "$retry_receipt" ]]
[[ -s "$receipt_retry_state/worker_stale_pane_retirement_validated" ]]
[[ ! -s "$kill_log" && -d "$worktree" ]]

peer_race_state="$fleet/task-peer-race/app"
peer_pre_barrier="$TEST_ROOT/peer-race-pre"
peer_post_barrier="$TEST_ROOT/peer-race-post"
peer_scan_reached="$TEST_ROOT/peer-scan-reached"
env PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" KILL_LOG="$kill_log" \
  SGT_TEST_HOOKS=1 SGT_TEST_STALE_PANE_BARRIER="$peer_pre_barrier" \
  SGT_TEST_STALE_PANE_POST_EVIDENCE_BARRIER="$peer_post_barrier" \
  "$ROOT_DIR/bin/sgt-watch" --retire-stale-pane task-peer-race --repo app \
  > "$TEST_ROOT/peer-race-retire.out" 2>&1 &
peer_retire_pid=$!
wait_for_barrier "$peer_pre_barrier"
env PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" KILL_LOG="$kill_log" \
  FAIL_HOLDER_SCAN=1 HOLDER_SCAN_REACHED="$peer_scan_reached" \
  SGT_RECYCLE_PEER_ATTEMPTS=1 \
  "$ROOT_DIR/bin/sgt-watch" --sync task-peer-race \
  > /dev/null 2> "$TEST_ROOT/peer-race-sync.err" &
peer_sync_pid=$!
for _ in $(seq 1 200); do
  [[ -e "$peer_scan_reached" ]] && break
  sleep 0.01
done
[[ -e "$peer_scan_reached" ]]
: > "$peer_pre_barrier.release"
wait_for_barrier "$peer_post_barrier"
if wait "$peer_sync_pid"; then
  printf 'peer recycler accepted pending staged stale evidence\n' >&2
  exit 1
fi
[[ -s "$peer_race_state/worker_stale_pane_retirement_pending" ]]
[[ -s "$peer_race_state/worker_recycled" ]]
[[ ! -e "$peer_race_state/worker_stale_pane_retirement" ]]
: > "$peer_post_barrier.release"
wait "$peer_retire_pid"
[[ -s "$peer_race_state/worker_stale_pane_retirement_validated" ]]
[[ ! -e "$peer_race_state/worker_stale_pane_retirement_pending" ]]
[[ ! -s "$kill_log" && -d "$worktree" ]]

printf 'sgt-watch stale-pane retirement: ok\n'
