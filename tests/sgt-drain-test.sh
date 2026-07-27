#!/usr/bin/env bash
# tests/sgt-drain-test.sh — Behavioral tests for sgt-drain / sgt-undrain
# and the dispatch admission seam.
#
# Coverage:
#   1.  global drain created and persists
#   2.  project drain created
#   3.  undrain --global removes drain
#   4.  undrain <project> removes drain
#   5.  global drain blocks dispatch for any project (zero side effects)
#   6.  project drain blocks only matching project
#   7.  unrelated project passes project drain
#   8.  drain state persists across processes
#   9.  idempotent drain (drain twice == drain once)
#  10.  idempotent undrain (undrain when not drained is no-op)
#  11.  malformed drain file fails closed
#  12.  expired deadline fails closed (no auto-undrain)
#  13.  race — drain wins: dispatch has zero side effects (no td/fleet/worktree)
#  14.  race — dispatch wins: drain set afterward blocks next dispatch only
#  15.  status output is privacy-safe

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

# ── Shared test fixtures ──────────────────────────────────────────────────────

drain_dir="$TEST_ROOT/drains"
fleet_dir="$TEST_ROOT/fleet"
config_dir="$TEST_ROOT/config"
repo="$TEST_ROOT/repo"
fake_bin="$TEST_ROOT/fake-bin"
td_counter="$TEST_ROOT/td-counter"

mkdir -p "$drain_dir" "$fleet_dir" "$config_dir" "$repo" "$fake_bin" "$td_counter"

# Minimal git repo so dispatch can create a worktree
git -C "$repo" init -q
git -C "$repo" config user.name Test
git -C "$repo" config user.email test@example.invalid
printf 'fixture\n' > "$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" commit -qm fixture

cat > "$config_dir/test.yaml" <<EOF
name: test
repos:
  - name: app
    path: $repo
EOF
cat > "$config_dir/other.yaml" <<EOF
name: other
repos:
  - name: app
    path: $repo
EOF

TMUX_LOG="$TEST_ROOT/tmux.log"
# Fake tmux: handles pane identity (for dispatch) and new-window
cat > "$fake_bin/tmux" <<'TMUX'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TMUX_LOG:-/dev/null}"
case "${1:-}" in
  display-message)
    # Return a second pane identity line for new notification deliveries
    for repo_state in "${SERGEANT_FLEET:-}"/*/*; do
      [[ -d "$repo_state" ]] || continue
      nonce="$(cat "$repo_state/notification_target" 2>/dev/null || true)"
      notification_id="$(cat "$repo_state/notification_id" 2>/dev/null || true)"
      [[ "$nonce" =~ ^[a-f0-9]{32}$ && -n "$notification_id" ]] || continue
      target_dir="$repo_state/notifications/$notification_id/targets/$nonce"
      token="$notification_id|$nonce"
      printf '%s\n' "$token" > "$target_dir/accepted"
      printf '%s\n' "$token" > "$target_dir/delivered"
    done
    # Return coordinator pane identity (matches TMUX_PANE=%42)
    printf '0|%%42|4242|1234567890|fake-agent\n'
    ;;
  has-session) exit 0 ;;
  new-session) exit 0 ;;
  new-window)
    [[ "${FAIL_WINDOW:-0}" == "0" ]] || exit 1
    printf '%%42\n'
    ;;
esac
exit 0
TMUX
chmod +x "$fake_bin/tmux"

# Fake td: handles version, create --help, create, list
cat > "$fake_bin/td" <<'TD'
#!/usr/bin/env bash
set -euo pipefail

# Version check
if [[ "${1:-}" == "--version" ]]; then
  printf 'td version 0.51.0\n'
  exit 0
fi

# Help for _require_marcus_td
if [[ "${1:-}" == "create" && "${2:-}" == "--help" ]]; then
  printf 'Usage: td create TITLE --description TEXT --priority P1 --json --work-dir DIR\n'
  exit 0
fi

work_dir=""
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --work-dir|-w) work_dir="$2"; shift 2 ;;
    --json)        shift ;;
    *)             args+=("$1"); shift ;;
  esac
done
set -- "${args[@]:-}"
cmd="${1:-}"
repo_name="$(basename "$work_dir")"
[[ "$repo_name" == "repo" ]] && repo_name="app"

next_id() {
  local n="$TD_COUNTER_DIR/$repo_name"
  local c=0; [[ -f "$n" ]] && c="$(cat "$n")"
  c=$((c+1)); printf '%s\n' "$c" > "$n"
  printf 'td-%s-%s\n' "$repo_name" "$c"
}

case "$cmd" in
  create)
    tid="$(next_id)"
    # sgt-td-create expects a JSON object with "id" field from td create.
    # Do NOT write to SGT_TD_STATE_FILE here; sgt-td-create manages that itself.
    printf '{"id":"%s"}\n' "$tid"
    ;;
  list)   printf '[]\n' ;;
  delete) printf '{"deleted":true}\n' ;;
  *)      printf '[]\n' ;;
esac
TD
chmod +x "$fake_bin/td"

# Fake opencode: interactive agent stub
cat > "$fake_bin/opencode" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$fake_bin/opencode"

# ── Helpers ───────────────────────────────────────────────────────────────────

# run_drain: invoke sgt-drain in test environment
run_drain() {
  SERGEANT_DRAIN_DIR="$drain_dir" \
    "$ROOT_DIR/bin/sgt-drain" "$@"
}

# run_undrain: invoke sgt-undrain in test environment
run_undrain() {
  SERGEANT_DRAIN_DIR="$drain_dir" \
    "$ROOT_DIR/bin/sgt-undrain" "$@"
}

# run_dispatch: invoke sgt-dispatch in test environment (needs TMUX context)
run_dispatch() {
  TMUX="fake-tmux" TMUX_PANE="%42" \
  SERGEANT_DRAIN_DIR="$drain_dir" \
  SERGEANT_CONFIG="$config_dir" \
  SERGEANT_FLEET="$fleet_dir" \
  SGT_WIKI_DISABLED=1 \
  TD_COUNTER_DIR="$td_counter" \
  TMUX_LOG="$TMUX_LOG" \
  PATH="$fake_bin:$ROOT_DIR/bin:$PATH" \
    "$ROOT_DIR/bin/sgt-dispatch" "$@"
}

# reset: wipe drain dir and fleet dir between tests
reset_state() {
  rm -rf "$drain_dir" "$fleet_dir" "$td_counter"
  mkdir -p "$drain_dir" "$fleet_dir" "$td_counter"
}

# ── Test 1: global drain created and persists ─────────────────────────────────

reset_state
run_drain --global --reason "maintenance window" --actor "ops"
global_drain="$drain_dir/global/drain"
[[ -f "$global_drain" ]] || { printf 'FAIL test1: global drain file not created\n' >&2; exit 1; }
grep -q '^reason=maintenance window' "$global_drain" || \
  { printf 'FAIL test1: reason not stored\n' >&2; exit 1; }
grep -q '^actor=ops' "$global_drain" || \
  { printf 'FAIL test1: actor not stored\n' >&2; exit 1; }
grep -q '^created_at=' "$global_drain" || \
  { printf 'FAIL test1: created_at not stored\n' >&2; exit 1; }
printf 'test1 global drain created: ok\n'

# ── Test 2: project drain created ────────────────────────────────────────────

reset_state
run_drain test --reason "hot fix deploy" --actor "admin"
project_drain="$drain_dir/projects/test/drain"
[[ -f "$project_drain" ]] || { printf 'FAIL test2: project drain file not created\n' >&2; exit 1; }
grep -q '^reason=hot fix deploy' "$project_drain" || \
  { printf 'FAIL test2: reason not stored\n' >&2; exit 1; }
grep -q '^actor=admin' "$project_drain" || \
  { printf 'FAIL test2: actor not stored\n' >&2; exit 1; }
printf 'test2 project drain created: ok\n'

# ── Test 3: undrain --global removes drain ────────────────────────────────────

reset_state
run_drain --global --reason "test" --actor "test"
[[ -f "$drain_dir/global/drain" ]] || { printf 'FAIL test3: setup failed\n' >&2; exit 1; }
run_undrain --global
[[ ! -f "$drain_dir/global/drain" ]] || { printf 'FAIL test3: global drain not removed\n' >&2; exit 1; }
printf 'test3 undrain global: ok\n'

# ── Test 4: undrain <project> removes drain ───────────────────────────────────

reset_state
run_drain test --reason "test" --actor "test"
[[ -f "$drain_dir/projects/test/drain" ]] || { printf 'FAIL test4: setup failed\n' >&2; exit 1; }
run_undrain test
[[ ! -f "$drain_dir/projects/test/drain" ]] || \
  { printf 'FAIL test4: project drain not removed\n' >&2; exit 1; }
printf 'test4 undrain project: ok\n'

# ── Test 5: global drain blocks dispatch (zero side effects) ──────────────────
# Dispatch must fail before creating td tasks, fleet dirs, or worktrees.

reset_state
run_drain --global --reason "infra freeze" --actor "sre"

set +e
run_dispatch test "Add feature" --repos app 2>/dev/null
dispatch_exit=$?
set -e

[[ "$dispatch_exit" -ne 0 ]] || \
  { printf 'FAIL test5: dispatch should have been rejected (exit was 0)\n' >&2; exit 1; }

# Zero side effects: no fleet task dirs, no td tasks, no worktrees
fleet_task_count="$(find "$fleet_dir" -mindepth 2 -name status 2>/dev/null | wc -l | tr -d ' ')"
[[ "$fleet_task_count" -eq 0 ]] || \
  { printf 'FAIL test5: fleet dirs created despite drain (count=%s)\n' \
      "$fleet_task_count" >&2; exit 1; }

td_task_count="$(find "$td_counter" -type f 2>/dev/null | wc -l | tr -d ' ')"
[[ "$td_task_count" -eq 0 ]] || \
  { printf 'FAIL test5: td tasks created despite drain (count=%s)\n' \
      "$td_task_count" >&2; exit 1; }

worktree_count="$(find "$(dirname "$repo")" -maxdepth 1 -name 'repo-sgt-*' -type d 2>/dev/null | wc -l | tr -d ' ')"
[[ "$worktree_count" -eq 0 ]] || \
  { printf 'FAIL test5: worktrees created despite drain (count=%s)\n' \
      "$worktree_count" >&2; exit 1; }

printf 'test5 global drain blocks dispatch with zero side effects: ok\n'

# ── Test 6: project drain blocks only matching project ────────────────────────

reset_state
run_drain test --reason "test project freeze" --actor "admin"

set +e
run_dispatch test "Add feature" --repos app 2>/dev/null
dispatch_exit=$?
set -e

[[ "$dispatch_exit" -ne 0 ]] || \
  { printf 'FAIL test6: dispatch to drained project should have been rejected\n' >&2; exit 1; }

fleet_task_count="$(find "$fleet_dir" -mindepth 2 -name status 2>/dev/null | wc -l | tr -d ' ')"
[[ "$fleet_task_count" -eq 0 ]] || \
  { printf 'FAIL test6: fleet dirs created despite project drain\n' >&2; exit 1; }

printf 'test6 project drain blocks matching project: ok\n'

# ── Test 7: unrelated project passes project drain ────────────────────────────

reset_state
run_drain test --reason "test project freeze" --actor "admin"

# Dispatch to OTHER project — should NOT be blocked
run_dispatch other "Add feature" --repos app > /dev/null

fleet_task_count="$(find "$fleet_dir" -mindepth 2 -name status 2>/dev/null | wc -l | tr -d ' ')"
[[ "$fleet_task_count" -gt 0 ]] || \
  { printf 'FAIL test7: unrelated project was wrongly blocked by project drain\n' >&2; exit 1; }

printf 'test7 project drain permits unrelated project: ok\n'

# ── Test 8: drain state persists across processes ─────────────────────────────

reset_state
run_drain --global --reason "persist test" --actor "bot"

# Read in a fresh subshell (simulates process restart)
result="$(
  SERGEANT_DRAIN_DIR="$drain_dir" bash -c '
    source "'"$ROOT_DIR"'/bin/_sgt-drain.sh"
    if _sgt_drain_is_drained "$(_sgt_drain_global_file)"; then
      printf "drained\n"
    else
      printf "not_drained\n"
    fi
  '
)"
[[ "$result" == "drained" ]] || \
  { printf 'FAIL test8: global drain not found in new process (got: %s)\n' "$result" >&2; exit 1; }
printf 'test8 drain state persists across processes: ok\n'

# ── Test 9: idempotent drain ──────────────────────────────────────────────────

reset_state
run_drain --global --reason "first" --actor "a"
[[ -f "$drain_dir/global/drain" ]] || { printf 'FAIL test9: first drain not created\n' >&2; exit 1; }
# Draining again should succeed (exit 0) and file should still exist
run_drain --global --reason "second" --actor "b"
[[ -f "$drain_dir/global/drain" ]] || \
  { printf 'FAIL test9: global drain removed by second drain\n' >&2; exit 1; }
printf 'test9 idempotent drain: ok\n'

# ── Test 10: idempotent undrain ───────────────────────────────────────────────

reset_state
# Undrain when not drained should succeed (exit 0)
run_undrain --global
run_undrain test
printf 'test10 idempotent undrain: ok\n'

# ── Test 11: malformed drain file fails closed ────────────────────────────────

reset_state
mkdir -p "$drain_dir/global"
# Write a malformed drain file (no expected fields)
printf 'totally garbled content with no fields\n' > "$drain_dir/global/drain"

set +e
run_dispatch test "Add feature" --repos app 2>/dev/null
dispatch_exit=$?
set -e

[[ "$dispatch_exit" -ne 0 ]] || \
  { printf 'FAIL test11: malformed drain should fail closed (block dispatch)\n' >&2; exit 1; }

printf 'test11 malformed drain file fails closed: ok\n'

# ── Test 12: expired deadline fails closed ────────────────────────────────────

reset_state
mkdir -p "$drain_dir/global"
# Set a drain with a deadline in the past
cat > "$drain_dir/global/drain" <<EOF
reason=expired test
actor=test
created_at=2000-01-01T00:00:00Z
deadline=2000-01-02T00:00:00Z
EOF

set +e
run_dispatch test "Add feature" --repos app 2>/dev/null
dispatch_exit=$?
set -e

[[ "$dispatch_exit" -ne 0 ]] || \
  { printf 'FAIL test12: expired deadline should fail closed (block dispatch)\n' >&2; exit 1; }

printf 'test12 expired deadline fails closed: ok\n'

# ── Test 13: sequential ordering — drain wins: dispatch has zero side effects ──
# Proves: when drain is active before dispatch, dispatch is rejected and
# produces zero side effects (no td tasks, no fleet dirs, no worktrees).
# This covers the AC7 "drain wins" ordering deterministically.

reset_state
run_drain test --reason "ordering test drain wins" --actor "test"

set +e
run_dispatch test "Should be blocked" --repos app 2>/dev/null
dispatch_exit=$?
set -e

[[ "$dispatch_exit" -ne 0 ]] || \
  { printf 'FAIL test13: drain should have blocked dispatch\n' >&2; exit 1; }

# No td tasks left behind
td_created="$(find "$td_counter" -type f 2>/dev/null | wc -l | tr -d ' ')"
[[ "$td_created" -eq 0 ]] || \
  { printf 'FAIL test13: td tasks created despite drain (count=%s)\n' "$td_created" >&2; exit 1; }

# No fleet dirs
fleet_dirs="$(find "$fleet_dir" -mindepth 2 -name status 2>/dev/null | wc -l | tr -d ' ')"
[[ "$fleet_dirs" -eq 0 ]] || \
  { printf 'FAIL test13: fleet dirs created despite drain (count=%s)\n' "$fleet_dirs" >&2; exit 1; }

printf 'test13 ordering drain-wins zero side effects: ok\n'

# ── Test 14: sequential ordering — dispatch wins: drain set afterward ──────────
# Proves: when dispatch commits admission before drain is set, the dispatch
# completes successfully. Drain set afterward blocks only subsequent dispatches.
# This covers the AC7 "dispatch commits before drain" ordering deterministically.

reset_state

# Dispatch succeeds (no drain active at admission time)
run_dispatch test "Dispatch commits first" --repos app > /dev/null

# Set drain after dispatch committed admission
run_drain test --reason "set after dispatch" --actor "test"

# Subsequent dispatch is now blocked
set +e
run_dispatch test "This one should be blocked" --repos app 2>/dev/null
second_exit=$?
set -e

[[ "$second_exit" -ne 0 ]] || \
  { printf 'FAIL test14: second dispatch should be blocked by drain\n' >&2; exit 1; }

# First dispatch completed: fleet dir must exist
first_fleet_dirs="$(find "$fleet_dir" -mindepth 2 -name status 2>/dev/null | wc -l | tr -d ' ')"
[[ "$first_fleet_dirs" -gt 0 ]] || \
  { printf 'FAIL test14: first dispatch should have created fleet state\n' >&2; exit 1; }

printf 'test14 ordering dispatch-wins drain blocks next only: ok\n'

# ── Test 16: concurrent admission lock race ───────────────────────────────────
# Proves: the flock-based lock ensures that a concurrent drain and dispatch
# produce exactly one of the two legal outcomes (both run simultaneously,
# exactly one wins the lock first).
#
# Strategy: spawn drain and dispatch concurrently; wait for both to finish;
# then assert exactly one of the two legal outcomes:
#   a) dispatch committed: fleet dir exists, no drain record (or drain is set
#      but dispatch already completed)
#   b) drain won: drain record exists, fleet dir absent
#
# Note: because the admission check fires before td creation, if drain wins,
# zero td tasks or fleet dirs are created. If dispatch wins, it completes
# before drain takes effect.

reset_state

dispatch_result_file="$TEST_ROOT/dispatch.exit"

# Run drain concurrently with dispatch
(
  # Small delay makes the race window real — either process may win the lock
  sleep 0.05
  run_drain test --reason "concurrent race" --actor "race-test" 2>/dev/null
) &
drain_pid=$!

(
  run_dispatch test "Concurrent dispatch" --repos app 2>/dev/null
  printf '%s\n' "$?" > "$dispatch_result_file"
) &
dispatch_pid=$!

wait "$drain_pid" || true
wait "$dispatch_pid" || true

dispatch_result=1
[[ -f "$dispatch_result_file" ]] && dispatch_result="$(cat "$dispatch_result_file")"

drain_exists=false
[[ -f "$drain_dir/projects/test/drain" ]] && drain_exists=true

fleet_count="$(find "$fleet_dir" -mindepth 2 -name status 2>/dev/null | wc -l | tr -d ' ')"

if [[ "$dispatch_result" -eq 0 ]]; then
  # Dispatch won the lock first — fleet dir must exist
  [[ "$fleet_count" -gt 0 ]] || \
    { printf 'FAIL test16: dispatch reported success but no fleet dir exists\n' >&2; exit 1; }
  printf 'test16 concurrent race dispatch-won outcome verified: ok\n'
else
  # Drain won the lock first — fleet dir must be absent
  $drain_exists || \
    { printf 'FAIL test16: drain reported win but no drain file exists\n' >&2; exit 1; }
  [[ "$fleet_count" -eq 0 ]] || \
    { printf 'FAIL test16: drain won but fleet dirs exist (count=%s)\n' "$fleet_count" >&2; exit 1; }
  printf 'test16 concurrent race drain-won outcome verified: ok\n'
fi

# ── Test 15: status output is privacy-safe ────────────────────────────────────

reset_state
run_drain --global --reason "SECRET_REASON_NEVER_IN_STATUS" --actor "SECRET_ACTOR"

status_out="$(SERGEANT_DRAIN_DIR="$drain_dir" "$ROOT_DIR/bin/sgt-drain" --status 2>&1)"

# Status must acknowledge drain state
printf '%s' "$status_out" | grep -qi "drain" || \
  { printf 'FAIL test15: status output has no drain indication\n' >&2; exit 1; }

# Status must NOT expose reason or actor
if printf '%s' "$status_out" | grep -q "SECRET_REASON_NEVER_IN_STATUS"; then
  { printf 'FAIL test15: status output exposes reason\n' >&2; exit 1; }
fi

if printf '%s' "$status_out" | grep -q "SECRET_ACTOR"; then
  { printf 'FAIL test15: status output exposes actor\n' >&2; exit 1; }
fi

printf 'test15 status output is privacy-safe: ok\n'

printf '\nsgt-drain: all tests passed\n'

# ── Test 16–21: sgt-drain --wait fleet monitoring ─────────────────────────────
#  16.  --wait exits immediately when all workers are terminal (done)
#  17.  --wait exits immediately when all workers are drained
#  18.  --wait exits immediately when all workers are unreachable (orphaned)
#  19.  --wait returns when in-progress workers update to drained
#  20.  --wait times out without killing workers
#  21.  --wait with project scope only waits for matching workers

printf '\n# sgt-drain --wait tests\n'

_mk_fleet_task() {
  local task_id="$1" project="$2"
  local task_dir="$fleet_dir/$task_id"
  mkdir -p "$task_dir"
  printf 'Project: %s\nBrief:   test\n' "$project" > "$task_dir/brief.md"
  printf '%s\n' "$task_dir"
}

_mk_fleet_repo() {
  local task_dir="$1" repo_name="$2" status="$3"
  local repo_dir="$task_dir/$repo_name"
  local worktree_path
  worktree_path="$TEST_ROOT/wt-$(basename "$task_dir")-$repo_name"
  mkdir -p "$repo_dir" "$worktree_path"
  printf '%s\n' "$status" > "$repo_dir/status"
  printf '%s\n' "$status" > "$worktree_path/.sergeant-status"
  printf '%s\n' "$worktree_path" > "$repo_dir/worktree"
  printf '%s\n' "$repo_dir"
}

_run_drain_wait() {
  SERGEANT_DRAIN_DIR="$drain_dir" SERGEANT_FLEET="$fleet_dir" \
    "$ROOT_DIR/bin/sgt-drain" "$@"
}

# Reset fleet between wait tests
fleet_dir_wait="$TEST_ROOT/fleet-wait"
mkdir -p "$fleet_dir_wait"

# ── Test 16: --wait exits immediately when all workers terminal ───────────────
td16="$fleet_dir_wait/task-t16"
mkdir -p "$td16"
printf 'Project: waitproject\nBrief: test\n' > "$td16/brief.md"
repo16="$td16/myrepo"; mkdir -p "$repo16"
printf 'done\n' > "$repo16/status"

reset_state

SERGEANT_DRAIN_DIR="$drain_dir" SERGEANT_FLEET="$fleet_dir_wait" \
  "$ROOT_DIR/bin/sgt-drain" --global --wait --timeout 5 \
  || { printf 'FAIL test16: expected exit 0 with terminal workers\n' >&2; exit 1; }

printf 'test16 --wait exits with terminal workers: ok\n'
reset_state

# ── Test 17: --wait exits immediately when all workers drained ────────────────
td17="$fleet_dir_wait/task-t17"
mkdir -p "$td17"
printf 'Project: waitproject\nBrief: test\n' > "$td17/brief.md"
repo17="$td17/myrepo"; mkdir -p "$repo17"
printf 'drained\n' > "$repo17/status"

SERGEANT_DRAIN_DIR="$drain_dir" SERGEANT_FLEET="$fleet_dir_wait" \
  "$ROOT_DIR/bin/sgt-drain" --global --wait --timeout 5 \
  || { printf 'FAIL test17: expected exit 0 with pre-drained workers\n' >&2; exit 1; }

printf 'test17 --wait exits with pre-drained workers: ok\n'
reset_state

# ── Test 18: --wait exits immediately for orphaned (unreachable) workers ──────
td18="$fleet_dir_wait/task-t18"
mkdir -p "$td18"
printf 'Project: waitproject\nBrief: test\n' > "$td18/brief.md"
repo18="$td18/myrepo"; mkdir -p "$repo18"
printf 'orphaned\n' > "$repo18/status"

SERGEANT_DRAIN_DIR="$drain_dir" SERGEANT_FLEET="$fleet_dir_wait" \
  "$ROOT_DIR/bin/sgt-drain" --global --wait --timeout 5 \
  || { printf 'FAIL test18: expected exit 0 with unreachable workers\n' >&2; exit 1; }

printf 'test18 --wait exits with unreachable workers: ok\n'
reset_state

# ── Test 19: --wait returns when in-progress worker updates to drained ────────
td19="$fleet_dir_wait/task-t19"
mkdir -p "$td19"
printf 'Project: waitproject\nBrief: test\n' > "$td19/brief.md"
repo19="$td19/myrepo"
wt19="$TEST_ROOT/wt-t19"
mkdir -p "$repo19" "$wt19"
printf 'in_progress\n' > "$repo19/status"
printf 'in_progress\n' > "$wt19/.sergeant-status"
printf '%s\n' "$wt19" > "$repo19/worktree"

SERGEANT_DRAIN_DIR="$drain_dir" SERGEANT_FLEET="$fleet_dir_wait" \
  SERGEANT_DRAIN_POLL_INTERVAL=0.1 \
  "$ROOT_DIR/bin/sgt-drain" --global --wait --timeout 10 &
drain_wait_pid=$!
sleep 0.2

# Simulate worker draining
printf 'drained\n' > "$wt19/.sergeant-status"
printf 'drained\n' > "$repo19/status"

wait "$drain_wait_pid"
wait_rc=$?
[[ "$wait_rc" -eq 0 ]] || { printf 'FAIL test19: expected exit 0, got %d\n' "$wait_rc" >&2; exit 1; }

printf 'test19 --wait returns when worker drains: ok\n'
reset_state

# ── Test 20: --wait times out without killing workers ─────────────────────────
td20="$fleet_dir_wait/task-t20"
mkdir -p "$td20"
printf 'Project: waitproject\nBrief: test\n' > "$td20/brief.md"
repo20="$td20/myrepo"; mkdir -p "$repo20"
printf 'in_progress\n' > "$repo20/status"

start_ts="$(date +%s)"
set +e
SERGEANT_DRAIN_DIR="$drain_dir" SERGEANT_FLEET="$fleet_dir_wait" \
  "$ROOT_DIR/bin/sgt-drain" --global --wait --timeout 2
wait_rc=$?
set -e
end_ts="$(date +%s)"
elapsed=$(( end_ts - start_ts ))

[[ "$wait_rc" -ne 0 ]] || { printf 'FAIL test20: expected non-zero exit on timeout\n' >&2; exit 1; }
[[ "$elapsed" -ge 1 ]] || { printf 'FAIL test20: exited too quickly (%ds)\n' "$elapsed" >&2; exit 1; }
# Worker status unchanged
[[ "$(cat "$repo20/status")" == "in_progress" ]] || { printf 'FAIL test20: worker status changed\n' >&2; exit 1; }

printf 'test20 --wait times out without killing workers: ok\n'
reset_state

# ── Test 21: --wait project scope only waits for matching workers ─────────────
fleet_dir_scope="$TEST_ROOT/fleet-scope"
mkdir -p "$fleet_dir_scope"

td21a="$fleet_dir_scope/task-projA"
mkdir -p "$td21a"
printf 'Project: projA\nBrief: test\n' > "$td21a/brief.md"
repo21a="$td21a/myrepo"; mkdir -p "$repo21a"
printf 'in_progress\n' > "$repo21a/status"

td21b="$fleet_dir_scope/task-projB"
mkdir -p "$td21b"
printf 'Project: projB\nBrief: test\n' > "$td21b/brief.md"
repo21b="$td21b/myrepo"; mkdir -p "$repo21b"
printf 'in_progress\n' > "$repo21b/status"

# Drain projA only
SERGEANT_DRAIN_DIR="$drain_dir" SERGEANT_FLEET="$fleet_dir_scope" \
  SERGEANT_DRAIN_POLL_INTERVAL=0.1 \
  "$ROOT_DIR/bin/sgt-drain" projA --wait --timeout 10 &
scope_pid=$!
sleep 0.2

# Mark projA worker as drained
printf 'drained\n' > "$repo21a/status"

wait "$scope_pid"
scope_rc=$?
[[ "$scope_rc" -eq 0 ]] || { printf 'FAIL test21: expected exit 0, got %d\n' "$scope_rc" >&2; exit 1; }

# projB worker should be untouched
[[ "$(cat "$repo21b/status")" == "in_progress" ]] || { printf 'FAIL test21: projB worker affected\n' >&2; exit 1; }

printf 'test21 --wait project scope only: ok\n'

printf '\nsgt-drain --wait: all tests passed\n'
