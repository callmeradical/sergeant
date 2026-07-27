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

mkdir -p "$repo" "$worktree" "$fake_bin" "$fake_systemd_state" "$no_systemd_bin"
printf '%s\n' "$worktree" > "$repo/worktree"
printf 'in_progress\n' > "$repo/status"
printf 'in_progress\n' > "$worktree/.sergeant-status"

# ── Fake service manager ──────────────────────────────────────────────────────
# SGT_FAKE_SYSTEMD_STATE: directory holding per-unit state files
# SGT_FAKE_SYSTEMD_MODE: ok (default) | fail | unavailable
# SGT_FAKE_INVOCATION_ID: fixed invocation ID for reproducibility

cat > "$fake_bin/systemd-run" <<'FAKEEOF'
#!/usr/bin/env bash
set -euo pipefail
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
  SGT_FAKE_SYSTEMD_STATE="$fake_systemd_state" \
  SERGEANT_FLEET="$fleet" \
  SERGEANT_SYSTEMCTL="$fake_bin/systemctl" \
  SERGEANT_SYSTEMD_RUN="$fake_bin/systemd-run" \
  "$ROOT/bin/sgt-watch" "$@"
}

_sgt_cleanup_bg() {
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

# ── Test 3: stale unit (active with different invocation ID = someone restarted
#    the unit externally) — should start a fresh monitor and update ownership ──
printf 'active\n' > "$fake_systemd_state/$unit.status"
printf 'inv-STALE\n' > "$fake_systemd_state/$unit.invocation_id"
output3="$(SGT_FAKE_INVOCATION_ID="inv-0002" _sgt_watch_bg --background "$task_id")"
grep -Fq 'sgt-watch-task-bg-1.service' <<< "$output3"
[[ "$(cat "$task/monitor_invocation_id")" == "inv-0002" ]]
printf 'sgt-watch --background stale-unit restart: ok\n'

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

task_c8="$fleet/task-cleanup-8"
repo_c8="$task_c8/app"
wt_c8="$cleanup_repo_root-sgt-task-cleanup-8"
unit_c8="sgt-watch-task-cleanup-8.service"
git -C "$cleanup_repo_root" worktree add -q "$wt_c8"
mkdir -p "$repo_c8"
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
SGT_FAKE_SYSTEMD_STATE="$fake_systemd_state" \
  SERGEANT_FLEET="$fleet" \
  SERGEANT_SYSTEMCTL="$fake_bin/systemctl" \
  SERGEANT_SYSTEMD_RUN="$fake_bin/systemd-run" \
  "$ROOT/bin/sgt-cleanup" "task-cleanup-8"
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
toctou_error="$(SGT_FAKE_SYSTEMD_STATE="$fake_systemd_state" \
  SERGEANT_FLEET="$fleet" \
  SERGEANT_SYSTEMCTL="$fake_bin/systemctl" \
  SERGEANT_SYSTEMD_RUN="$fake_bin/systemd-run" \
  "$ROOT/bin/sgt-cleanup" "task-bg-2" 2>&1 || true)"
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
printf '%s\n' "$unit_c11" > "$task_c11/monitor_unit"
# intentionally omit monitor_invocation_id to simulate crash-window state
# sgt-cleanup requires terminal repos; create minimal passing state
printf 'done\n' > "$repo_c11/status"
printf 'https://example.invalid/pr/11\n' > "$repo_c11/result"
crash_error="$(SGT_FAKE_SYSTEMD_STATE="$fake_systemd_state" \
  SERGEANT_FLEET="$fleet" \
  SERGEANT_SYSTEMCTL="$fake_bin/systemctl" \
  SERGEANT_SYSTEMD_RUN="$fake_bin/systemd-run" \
  "$ROOT/bin/sgt-cleanup" "task-crash-11" 2>&1 || true)"
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

printf '\nsgt-watch background mode: all tests passed\n'
