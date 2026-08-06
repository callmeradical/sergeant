#!/usr/bin/env bash
# sgt-watch --background tests
# Covers: active, terminal, duplicate/idempotent, failed-start, stale-unit,
#         cleanup TOCTOU, and unsupported-platform behavior.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fleet="$TEST_ROOT/fleet"
task_id="task-bg-1"
task="$fleet/$task_id"
worktree="$TEST_ROOT/worktree"
repo="$task/app"
fake_bin="$TEST_ROOT/bin"
fake_systemd_state="$TEST_ROOT/systemd-state"
no_systemd_bin="$TEST_ROOT/no-systemd-bin"
config_dir="$TEST_ROOT/config"

mkdir -p "$repo" "$worktree" "$fake_bin" "$fake_systemd_state" "$no_systemd_bin" "$config_dir"
printf '%s\n' "$worktree" > "$repo/worktree"
printf 'in_progress\n' > "$repo/status"
printf 'in_progress\n' > "$worktree/.sergeant-status"

write_test_task_brief() {
  cat > "$1/brief.md" <<'EOF'
Brief: test cleanup task
Project: test
EOF
}

write_test_project_config() {
  cat > "$config_dir/test.yaml" <<EOF
name: test
repos:
  - name: app
    path: $1
    role: Test fixture
EOF
}

# ── Fake service manager ──────────────────────────────────────────────────────
# SGT_FAKE_SYSTEMD_STATE: directory holding per-unit state files
# SGT_FAKE_SYSTEMD_MODE: ok (default) | fail | unavailable
# SGT_FAKE_INVOCATION_ID: fixed invocation ID for reproducibility

cat > "$fake_bin/systemd-run" <<'FAKEEOF'
#!/usr/bin/env bash
set -euo pipefail
# When SGT_FAKE_ARGS_LOG is set, record all arguments (one per line) for
# inspection by tests that need to verify what was passed to systemd-run.
[[ -n "${SGT_FAKE_ARGS_LOG:-}" ]] && printf '%s\n' "$@" > "$SGT_FAKE_ARGS_LOG"
state="${SGT_FAKE_SYSTEMD_STATE}"
unit=""
for arg in "$@"; do
  if [[ "$arg" == --unit=* ]]; then
    unit="${arg#--unit=}"
    break
  fi
done
[[ -n "$unit" ]] || { printf 'systemd-run: no --unit given\n' >&2; exit 1; }
mkdir -p "$state"
case "${SGT_FAKE_SYSTEMD_MODE:-ok}" in
  ok)
    inv="${SGT_FAKE_INVOCATION_ID:-fake-invocation-$(printf '%04x' $((RANDOM % 65536)))}"
    printf 'active\n' > "$state/${unit}.status"
    printf '%s\n' "$inv" > "$state/${unit}.invocation_id"
    ;;
  fail)
    printf 'Failed to start managed monitor unit %s\n' "$unit" >&2
    exit 1
    ;;
  *)
    printf 'systemd-run: unknown mode: %s\n' "${SGT_FAKE_SYSTEMD_MODE:-}" >&2
    exit 1
    ;;
esac
FAKEEOF
chmod +x "$fake_bin/systemd-run"

cat > "$fake_bin/systemctl" <<'FAKEEOF'
#!/usr/bin/env bash
set -euo pipefail
state="${SGT_FAKE_SYSTEMD_STATE}"
# Filter --user and bare-option flags; collect positional args
args=()
for a in "$@"; do
  [[ "$a" == "--user" || "$a" == "--quiet" || "$a" == "--value" || "$a" == "--no-ask-password" ]] && continue
  [[ "$a" == --property=* ]] && continue
  args+=("$a")
done

subcommand="${args[0]:-}"
# Last positional arg is the unit (for subcommands that take one)
unit="${args[-1]:-}"
[[ "$unit" != "$subcommand" ]] || unit=""

case "$subcommand" in
  is-active)
    [[ -n "$unit" ]] || { printf 'systemctl: is-active: no unit\n' >&2; exit 1; }
    status="$(cat "$state/${unit}.status" 2>/dev/null || printf 'inactive')"
    [[ "$status" == "active" ]] && exit 0 || exit 3
    ;;
  show)
    [[ -n "$unit" ]] || { printf 'systemctl: show: no unit\n' >&2; exit 1; }
    cat "$state/${unit}.invocation_id" 2>/dev/null || true
    ;;
  stop)
    [[ -n "$unit" ]] || { printf 'systemctl: stop: no unit\n' >&2; exit 1; }
    printf 'inactive\n' > "$state/${unit}.status"
    rm -f "$state/${unit}.invocation_id"
    ;;
  show-environment)
    exit 0
    ;;
  *)
    printf 'systemctl: unhandled subcommand: %s\n' "$subcommand" >&2
    exit 1
    ;;
esac
FAKEEOF
chmod +x "$fake_bin/systemctl"

# Shared env for fake systemd
_sgt_watch_bg() {
  SERGEANT_CONFIG="$config_dir" \
  SGT_FAKE_SYSTEMD_STATE="$fake_systemd_state" \
  SERGEANT_FLEET="$fleet" \
  SERGEANT_SYSTEMCTL="$fake_bin/systemctl" \
  SERGEANT_SYSTEMD_RUN="$fake_bin/systemd-run" \
  "$ROOT/bin/sgt-watch" "$@"
}

_sgt_cleanup_bg() {
  SERGEANT_CONFIG="$config_dir" \
  SGT_FAKE_SYSTEMD_STATE="$fake_systemd_state" \
  SERGEANT_FLEET="$fleet" \
  SERGEANT_SYSTEMCTL="$fake_bin/systemctl" \
  SERGEANT_SYSTEMD_RUN="$fake_bin/systemd-run" \
  "$ROOT/bin/sgt-cleanup" "$@"
}

# ── Test 1: basic background start ───────────────────────────────────────────
# Spec-canonical form: sgt-watch <task-id> --background
output="$(SGT_FAKE_INVOCATION_ID="inv-0001" _sgt_watch_bg "$task_id" --background)"
grep -Fq 'sgt-watch-' <<< "$output"
grep -Fq 'status:' <<< "$output"
grep -Fq 'log:' <<< "$output"
grep -Fq 'stop:' <<< "$output"
[[ -f "$task/monitor_unit" ]]
[[ -f "$task/monitor_invocation_id" ]]
unit="$(cat "$task/monitor_unit")"
[[ "$unit" == sgt-watch-task-bg-1.service ]]
[[ "$(cat "$task/monitor_invocation_id")" == "inv-0001" ]]
printf 'sgt-watch <task-id> --background basic start: ok\n'

# Also verify flag-first form works (backward compat)
rm -f "$task/monitor_unit" "$task/monitor_invocation_id"
rm -f "$fake_systemd_state/$unit.status" "$fake_systemd_state/$unit.invocation_id"
output_ff="$(SGT_FAKE_INVOCATION_ID="inv-0001" _sgt_watch_bg --background "$task_id")"
grep -Fq 'sgt-watch-task-bg-1.service' <<< "$output_ff"
[[ "$(cat "$task/monitor_invocation_id")" == "inv-0001" ]]
printf 'sgt-watch --background <task-id> (flag-first) basic start: ok\n'

# ── Test 2: idempotent repeated start (active, same invocation ID) ────────────
# Unit is still active with same invocation ID — should return promptly, no new start
output2="$(SGT_FAKE_INVOCATION_ID="inv-0001" _sgt_watch_bg --background "$task_id")"
grep -Fq 'sgt-watch-task-bg-1.service' <<< "$output2"
# Invocation ID must not change (systemd-run was not called)
[[ "$(cat "$task/monitor_invocation_id")" == "inv-0001" ]]
printf 'sgt-watch --background idempotent repeated start: ok\n'

# ── Test 3: unit active with different (stale) stored invocation ID ───────────
# When the unit is running but ownership files are stale (e.g., externally
# restarted), --background must adopt the live instance rather than calling
# systemd-run (which would fail with 'unit already exists').
printf 'active\n' > "$fake_systemd_state/$unit.status"
printf 'inv-live-new\n' > "$fake_systemd_state/$unit.invocation_id"
# Ownership files still have the old ID from Test 2
output3="$(SGT_FAKE_SYSTEMD_MODE=fail _sgt_watch_bg --background "$task_id")"
grep -Fq 'sgt-watch-task-bg-1.service' <<< "$output3"
# Must adopt the live invocation ID, not the stale stored one
[[ "$(cat "$task/monitor_invocation_id")" == "inv-live-new" ]]
printf 'sgt-watch --background stale-invocation-ID adopt: ok\n'

# ── Test 4: terminal monitor (unit inactive = previously finished) ────────────
# Remove unit from fake state (simulating terminal/collected unit)
rm -f "$fake_systemd_state/$unit.status" "$fake_systemd_state/$unit.invocation_id"
output4="$(SGT_FAKE_INVOCATION_ID="inv-0003" _sgt_watch_bg --background "$task_id")"
grep -Fq 'sgt-watch-task-bg-1.service' <<< "$output4"
[[ "$(cat "$task/monitor_invocation_id")" == "inv-0003" ]]
printf 'sgt-watch --background terminal monitor restart: ok\n'

# ── Test 5: failed start ──────────────────────────────────────────────────────
rm -f "$task/monitor_unit" "$task/monitor_invocation_id"
rm -f "$fake_systemd_state/$unit.status" "$fake_systemd_state/$unit.invocation_id"
error_output="$(SGT_FAKE_SYSTEMD_MODE=fail _sgt_watch_bg --background "$task_id" 2>&1 || true)"
grep -Eq 'ERROR|[Ff]ailed|failed' <<< "$error_output"
[[ ! -f "$task/monitor_invocation_id" ]]
printf 'sgt-watch --background failed start: ok\n'

# ── Test 6: unsupported platform (no systemctl/systemd-run in PATH) ───────────
# Create a PATH without systemd-run/systemctl (but keep other tools)
# Copy bash and other needed binaries
error_output6="$(SGT_FAKE_SYSTEMD_STATE="$fake_systemd_state" \
  SERGEANT_FLEET="$fleet" \
  SERGEANT_SYSTEMCTL="$no_systemd_bin/systemctl" \
  SERGEANT_SYSTEMD_RUN="$no_systemd_bin/systemd-run" \
  "$ROOT/bin/sgt-watch" --background "$task_id" 2>&1 || true)"
grep -Eq 'ERROR.*systemd|ERROR.*not found|ERROR.*unavailable|ERROR.*requires' <<< "$error_output6"
printf 'sgt-watch --background unsupported platform: ok\n'

# ── Test 7: task ID injection prevention ──────────────────────────────────────
# Task IDs with injection-risk characters should be rejected
for bad_id in "--unit=evil" "task/../../etc" "task id with spaces"; do
  error_output_inj="$(SGT_FAKE_SYSTEMD_STATE="$fake_systemd_state" \
    SERGEANT_FLEET="$fleet" \
    SERGEANT_SYSTEMCTL="$fake_bin/systemctl" \
    SERGEANT_SYSTEMD_RUN="$fake_bin/systemd-run" \
    "$ROOT/bin/sgt-watch" --background "$bad_id" 2>&1 || true)"
  grep -Eq 'ERROR|[Ii]nvalid|[Ii]llegal' <<< "$error_output_inj"
done
printf 'sgt-watch --background task ID injection prevention: ok\n'

# ── Test 8: cleanup stops exact owned monitor (TOCTOU protection) ─────────────
# Use a dedicated git worktree so sgt-cleanup can verify it.
cleanup_repo_root="$TEST_ROOT/main-repo"
git init -q "$cleanup_repo_root"
git -C "$cleanup_repo_root" config user.email "test@test"
git -C "$cleanup_repo_root" config user.name "Test"
printf 'init\n' > "$cleanup_repo_root/README"
git -C "$cleanup_repo_root" add .
git -C "$cleanup_repo_root" commit -q -m "init"
write_test_project_config "$cleanup_repo_root"

task_c8="$fleet/task-cleanup-8"
repo_c8="$task_c8/app"
wt_c8="$cleanup_repo_root-sgt-task-cleanup-8"
unit_c8="sgt-watch-task-cleanup-8.service"
git -C "$cleanup_repo_root" worktree add -q "$wt_c8"
mkdir -p "$repo_c8"
write_test_task_brief "$task_c8"
printf '%s\n' "$wt_c8" > "$repo_c8/worktree"
printf 'done\n' > "$repo_c8/status"
printf 'https://example.invalid/pr/1\n' > "$repo_c8/result"
printf 'done\n' > "$wt_c8/.sergeant-status"
printf 'https://example.invalid/pr/1\n' > "$wt_c8/.sergeant-result"
# Register a monitor
printf '%s\n' "$unit_c8" > "$task_c8/monitor_unit"
printf 'inv-cleanup-0001\n' > "$task_c8/monitor_invocation_id"
# Simulate unit active with matching invocation ID
printf 'active\n' > "$fake_systemd_state/$unit_c8.status"
printf 'inv-cleanup-0001\n' > "$fake_systemd_state/$unit_c8.invocation_id"
# Run cleanup
_sgt_cleanup_bg "task-cleanup-8"
# Unit should be stopped
unit_status="$(cat "$fake_systemd_state/$unit_c8.status" 2>/dev/null || printf 'inactive')"
[[ "$unit_status" == "inactive" ]]
# Fleet dir should be gone
[[ ! -d "$task_c8" ]]
printf 'sgt-cleanup stops owned monitor: ok\n'

# ── Test 9: cleanup TOCTOU protection (different invocation ID) ───────────────
# Re-create task for this test
task2="$fleet/task-bg-2"
repo2="$task2/app"
wt_c9="$cleanup_repo_root-sgt-task-bg-2"
unit2="sgt-watch-task-bg-2.service"
git -C "$cleanup_repo_root" worktree add -q "$wt_c9"
worktree2="$wt_c9"
mkdir -p "$repo2"
write_test_task_brief "$task2"
printf '%s\n' "$worktree2" > "$repo2/worktree"
printf 'done\n' > "$repo2/status"
printf 'https://example.invalid/pr/2\n' > "$repo2/result"
printf 'done\n' > "$worktree2/.sergeant-status"
printf 'https://example.invalid/pr/2\n' > "$worktree2/.sergeant-result"
# Register a monitor with stored invocation ID
printf '%s\n' "$unit2" > "$task2/monitor_unit"
printf 'inv-stored-abc\n' > "$task2/monitor_invocation_id"
# Set fake systemd to show the unit active but with a DIFFERENT invocation ID
mkdir -p "$fake_systemd_state"
printf 'active\n' > "$fake_systemd_state/$unit2.status"
printf 'inv-FOREIGN\n' > "$fake_systemd_state/$unit2.invocation_id"
# Cleanup should refuse to stop the unit (TOCTOU: invocation IDs differ)
toctou_error="$(_sgt_cleanup_bg "task-bg-2" 2>&1 || true)"
grep -Eq 'ERROR.*[Ii]nvocation|ERROR.*[Tt][Oo][Cc][Tt][Oo][Uu]|ERROR.*unexpected|ERROR.*unexpected.*invocation|ERROR.*[Ff]oreign|ERROR.*[Mm]ismatch' <<< "$toctou_error"
# Unit should NOT have been stopped
unit2_status="$(cat "$fake_systemd_state/$unit2.status" 2>/dev/null || printf 'inactive')"
[[ "$unit2_status" == "active" ]]
printf 'sgt-cleanup TOCTOU protection: ok\n'

# ── Test 10: plain sgt-watch foreground mode unaffected ───────────────────────
# Verify existing foreground mode still works as before
task3="$fleet/task-fg-1"
repo3="$task3/app"
worktree3="$TEST_ROOT/worktree3"
fake_bin3="$TEST_ROOT/bin3"
mkdir -p "$repo3" "$worktree3" "$fake_bin3"
printf '%s\n' "$worktree3" > "$repo3/worktree"
printf '%%99\n' > "$repo3/pane"
printf '0|%%99|5555|111111|sgt-interactive-worker:%s\n' "$repo3" > "$repo3/pane_identity"
printf 'opencode\n' > "$repo3/agent"
printf 'done\n' > "$worktree3/.sergeant-status"
printf 'https://example.invalid/pr/fg\n' > "$worktree3/.sergeant-result"
printf 'done\n' > "$repo3/status"
printf 'https://example.invalid/pr/fg\n' > "$repo3/result"

cat > "$fake_bin3/tmux" <<'EOF'
#!/usr/bin/env bash
printf '0|%%99|5555|111111|sgt-interactive-worker:%s\n' "${EXPECTED_WORKER}"
EOF
chmod +x "$fake_bin3/tmux"

fg_output="$(SERGEANT_WATCH_INTERVAL=0 EXPECTED_WORKER="$repo3" PATH="$fake_bin3:$PATH" \
  SERGEANT_FLEET="$fleet" "$ROOT/bin/sgt-watch" "task-fg-1")"
grep -Fq 'All repos done.' <<< "$fg_output"
printf 'sgt-watch foreground unaffected: ok\n'

# ── Test 11: split-write crash window recovery ────────────────────────────────
# If monitor_unit was written but monitor_invocation_id was not (crash between
# the two old writes), sgt-cleanup must not die hard; it should either skip or
# surface an actionable error.  With the new write order (invocation_id first),
# this state (unit present, invocation absent) is the old crash state and
# must be handled gracefully: cleanup should report an error rather than
# proceeding with an unverified stop.
task_c11="$fleet/task-crash-11"
repo_c11="$task_c11/app"
unit_c11="sgt-watch-task-crash-11.service"
mkdir -p "$repo_c11"
write_test_task_brief "$task_c11"
printf '%s\n' "$unit_c11" > "$task_c11/monitor_unit"
# intentionally omit monitor_invocation_id to simulate crash-window state
# sgt-cleanup requires terminal repos; create minimal passing state
printf 'done\n' > "$repo_c11/status"
printf 'https://example.invalid/pr/11\n' > "$repo_c11/result"
crash_error="$(_sgt_cleanup_bg "task-crash-11" 2>&1 || true)"
# Cleanup must produce an error (invocation ID missing = cannot safely stop)
grep -Eq 'ERROR.*[Ii]nvocation|ERROR.*missing|ERROR.*safely' <<< "$crash_error"
printf 'sgt-cleanup split-write crash window: ok\n'

# ── Test 12: zero-GUID InvocationID treated as absent ────────────────────────
# The zero GUID (32 zeros) returned by systemd for an inactive unit must not
# be treated as a valid invocation ID.
task_c12="$fleet/task-zeroguid-12"
repo_c12="$task_c12/app"
worktree_c12="$TEST_ROOT/worktree12"
unit_c12="sgt-watch-task-zeroguid-12.service"
mkdir -p "$repo_c12" "$worktree_c12"
printf '%s\n' "$worktree_c12" > "$repo_c12/worktree"
printf 'in_progress\n' > "$repo_c12/status"
printf 'in_progress\n' > "$worktree_c12/.sergeant-status"
# Set fake systemd to return the zero GUID
printf 'active\n' > "$fake_systemd_state/$unit_c12.status"
printf '00000000000000000000000000000000\n' > "$fake_systemd_state/$unit_c12.invocation_id"
# Background start must fail because the zero GUID is treated as absent
zeroguid_error="$(SGT_FAKE_SYSTEMD_STATE="$fake_systemd_state" \
  SERGEANT_FLEET="$fleet" \
  SERGEANT_SYSTEMCTL="$fake_bin/systemctl" \
  SERGEANT_SYSTEMD_RUN="$fake_bin/systemd-run" \
  SGT_FAKE_INVOCATION_ID="00000000000000000000000000000000" \
  "$ROOT/bin/sgt-watch" "task-zeroguid-12" --background 2>&1 || true)"
grep -Eq 'ERROR.*[Ii]nvocation|ERROR.*[Ff]ailed' <<< "$zeroguid_error"
printf 'sgt-watch --background zero-GUID InvocationID rejected: ok\n'

# ── Test 13: adopt running unit when ownership files are missing ──────────────
# If monitor_unit and/or monitor_invocation_id are absent but the unit is
# already running (e.g. files deleted, or crash before monitor_unit was written),
# --background must adopt the live unit rather than calling systemd-run and
# failing with 'unit already exists'.
task_c13="$fleet/task-adopt-13"
repo_c13="$task_c13/app"
worktree_c13="$TEST_ROOT/worktree13"
unit_c13="sgt-watch-task-adopt-13.service"
mkdir -p "$repo_c13" "$worktree_c13"
printf '%s\n' "$worktree_c13" > "$repo_c13/worktree"
printf 'in_progress\n' > "$repo_c13/status"
printf 'in_progress\n' > "$worktree_c13/.sergeant-status"
# Fake systemd: unit is already active with a known invocation ID, but NO
# ownership files exist yet in the fleet directory.
printf 'active\n' > "$fake_systemd_state/$unit_c13.status"
printf 'inv-live-adopt\n' > "$fake_systemd_state/$unit_c13.invocation_id"
# Configure the fake systemd-run to FAIL if called (prove it is not called)
adopt_output="$(SGT_FAKE_SYSTEMD_MODE=fail \
  SGT_FAKE_SYSTEMD_STATE="$fake_systemd_state" \
  SERGEANT_FLEET="$fleet" \
  SERGEANT_SYSTEMCTL="$fake_bin/systemctl" \
  SERGEANT_SYSTEMD_RUN="$fake_bin/systemd-run" \
  "$ROOT/bin/sgt-watch" "task-adopt-13" --background 2>&1)"
grep -Fq 'sgt-watch-task-adopt-13.service' <<< "$adopt_output"
[[ "$(cat "$task_c13/monitor_unit")" == "$unit_c13" ]]
[[ "$(cat "$task_c13/monitor_invocation_id")" == "inv-live-adopt" ]]
printf 'sgt-watch --background adopts running unit (files missing): ok\n'

# ── Test 14: adopt running unit when stored invocation ID is stale ────────────
# Unit is running with a new InvocationID (externally restarted), but
# ownership files still have the old ID.  --background must adopt the new
# live instance rather than calling systemd-run and failing.
task_c14="$fleet/task-adopt-14"
repo_c14="$task_c14/app"
worktree_c14="$TEST_ROOT/worktree14"
unit_c14="sgt-watch-task-adopt-14.service"
mkdir -p "$repo_c14" "$worktree_c14"
printf '%s\n' "$worktree_c14" > "$repo_c14/worktree"
printf 'in_progress\n' > "$repo_c14/status"
printf 'in_progress\n' > "$worktree_c14/.sergeant-status"
# Stale ownership files
printf '%s\n' "$unit_c14" > "$task_c14/monitor_unit"
printf 'inv-stale-old\n' > "$task_c14/monitor_invocation_id"
# Fake systemd: unit active with NEW invocation ID
printf 'active\n' > "$fake_systemd_state/$unit_c14.status"
printf 'inv-new-live\n' > "$fake_systemd_state/$unit_c14.invocation_id"
adopt14_output="$(SGT_FAKE_SYSTEMD_MODE=fail \
  SGT_FAKE_SYSTEMD_STATE="$fake_systemd_state" \
  SERGEANT_FLEET="$fleet" \
  SERGEANT_SYSTEMCTL="$fake_bin/systemctl" \
  SERGEANT_SYSTEMD_RUN="$fake_bin/systemd-run" \
  "$ROOT/bin/sgt-watch" "task-adopt-14" --background 2>&1)"
grep -Fq 'sgt-watch-task-adopt-14.service' <<< "$adopt14_output"
[[ "$(cat "$task_c14/monitor_invocation_id")" == "inv-new-live" ]]
printf 'sgt-watch --background adopts running unit (stale invocation ID): ok\n'

# ── Test 15: PATH forwarded to background monitor unit ────────────────────────
# When launching the monitor, _sgt_background_watch must pass --setenv=PATH=...
# to systemd-run so user-installed tools (e.g. td from /home/linuxbrew/.linuxbrew/bin)
# remain resolvable inside the transient unit.  Without the fix the monitor runs
# with the lean systemd user-manager PATH and sgt-td-memory fails with
# "td unavailable for handoff".
# The extended fake_bin/systemd-run records args to SGT_FAKE_ARGS_LOG when set.
task_c15="$fleet/task-path-15"
repo_c15="$task_c15/app"
worktree_c15="$TEST_ROOT/worktree15"
unit_c15="sgt-watch-task-path-15.service"
mkdir -p "$repo_c15" "$worktree_c15"
printf '%s\n' "$worktree_c15" > "$repo_c15/worktree"
printf 'in_progress\n' > "$repo_c15/status"
printf 'in_progress\n' > "$worktree_c15/.sergeant-status"
rm -f "$fake_systemd_state/$unit_c15.status" "$fake_systemd_state/$unit_c15.invocation_id"

args_log="$TEST_ROOT/systemd-run-args-15.log"
custom_user_bin="/home/testuser/.linuxbrew/bin"
custom_path="${custom_user_bin}:${PATH}"
monitor_output="$(PATH="$custom_path" \
  SGT_FAKE_INVOCATION_ID="inv-path-15" \
  SGT_FAKE_ARGS_LOG="$args_log" \
  SGT_FAKE_SYSTEMD_STATE="$fake_systemd_state" \
  SERGEANT_FLEET="$fleet" \
  SERGEANT_SYSTEMCTL="$fake_bin/systemctl" \
  SERGEANT_SYSTEMD_RUN="$fake_bin/systemd-run" \
  "$ROOT/bin/sgt-watch" "task-path-15" --background 2>&1)"
# Monitor identity must be printed on success
grep -Fq 'sgt-watch-task-path-15.service' <<< "$monitor_output" || \
  { printf 'FAIL: monitor identity not printed\n' >&2; exit 1; }
[[ -f "$args_log" ]] || { printf 'FAIL: systemd-run was not called (args log missing)\n' >&2; exit 1; }
# --setenv=PATH=... must appear in the recorded args
grep -Fq -- "--setenv=PATH=" "$args_log" || \
  { printf 'FAIL: --setenv=PATH= was not passed to systemd-run\n' >&2; exit 1; }
# The forwarded PATH must include our custom directory
grep -F "$custom_user_bin" "$args_log" || \
  { printf 'FAIL: forwarded PATH does not include custom user bin dir\n' >&2; exit 1; }
printf 'sgt-watch --background PATH forwarded to monitor unit: ok\n'

# ── Test 16: sgt-td-memory handoff fails with minimal PATH ───────────────────
# This is the direct regression test for the failure mode described in #138:
# when the PATH passed to sgt-td-memory does not include td, it must write
# "td unavailable for handoff" to the diagnostic file and exit non-zero.
# After the fix, forwarding the user's PATH to the systemd unit ensures
# sgt-td-memory finds td in the service environment.
td_test_root="$TEST_ROOT/td-test"
td_repo_state="$td_test_root/state"
td_worktree="$td_test_root/worktree"
td_fake_bin="$td_test_root/bin"
mkdir -p "$td_repo_state" "$td_worktree" "$td_fake_bin"

# Fake td binary — succeeds immediately (just needs to be found via PATH)
cat > "$td_fake_bin/td" <<'FAKEEOF'
#!/usr/bin/env bash
exit 0
FAKEEOF
chmod +x "$td_fake_bin/td"

# Minimal repo state: sgt-td-memory needs the td task and the worktree the fleet
# record owns, since it refuses to attach handoff evidence to any other checkout.
printf 'fake-td-task-id\n' > "$td_repo_state/td_task"
printf '%s\n' "$td_worktree" > "$td_repo_state/worktree"

# Initialize a minimal git repo in the worktree so git commands succeed
git init -q "$td_worktree"
git -C "$td_worktree" config user.email "test@test"
git -C "$td_worktree" config user.name "Test"
printf 'init\n' > "$td_worktree/README"
git -C "$td_worktree" add .
git -C "$td_worktree" commit -q -m "init"
printf 'in_progress\n' > "$td_worktree/.sergeant-status"

# Case A: PATH that includes essential tools (bash, git) but deliberately
# excludes any directory containing td → sgt-td-memory must fail with the
# "td unavailable for handoff" diagnostic.
# /bin and /usr/bin provide bash and git; exclude /usr/local/bin where td lives.
no_td_path="/bin:/usr/bin:/sbin:/usr/sbin"
PATH="$no_td_path" "$ROOT/bin/sgt-td-memory" handoff \
  "$td_repo_state" "$td_worktree" 2>/dev/null || true
diag_a="$(cat "$td_repo_state/diagnostic" 2>/dev/null || true)"
[[ "$diag_a" == *"td unavailable for handoff"* ]] || \
  { printf 'FAIL: expected "td unavailable for handoff" diagnostic, got: %s\n' "$diag_a" >&2; exit 1; }

# Case B: PATH with fake td directory prepended → sgt-td-memory must find td
# and exit 0 (fake td exits 0, so the handoff command succeeds).
rm -f "$td_repo_state/diagnostic"
PATH="$td_fake_bin:$no_td_path" "$ROOT/bin/sgt-td-memory" handoff \
  "$td_repo_state" "$td_worktree" 2>/dev/null
[[ ! -f "$td_repo_state/diagnostic" ]] || {
  diag_b="$(cat "$td_repo_state/diagnostic")"
  [[ "$diag_b" != *"td unavailable"* ]] || \
    { printf 'FAIL: sgt-td-memory still reports td unavailable with full PATH: %s\n' "$diag_b" >&2; exit 1; }
}
printf 'sgt-td-memory handoff: minimal PATH fails, full PATH succeeds: ok\n'

printf '\nsgt-watch background mode: all tests passed\n'
