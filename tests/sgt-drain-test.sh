#!/usr/bin/env bash
# Tests for sgt-drain / sgt-undrain — persistent drain state and reevaluation.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

config_dir="$TEST_ROOT/config"
export SERGEANT_CONFIG="$config_dir"
mkdir -p "$config_dir"

# ── Slice 1: no drain — admits everything ────────────────────────────────────

# shellcheck source=bin/_sgt-drain.sh
source "$ROOT_DIR/bin/_sgt-drain.sh"

_sgt_is_drained "myproject" && { printf '_sgt_is_drained should return 1 when no drain files exist\n' >&2; exit 1; }
_sgt_is_drained "" && { printf '_sgt_is_drained should return 1 for empty project and no global drain\n' >&2; exit 1; }
printf 'sgt-drain no-drain admits all: ok\n'

# ── Slice 2: global drain blocks all projects ────────────────────────────────

mkdir -p "$config_dir/drain"
printf 'reason=maintenance\ncreated=2025-01-01T00:00:00Z\n' > "$config_dir/drain/global"

_sgt_is_drained "myproject" || { printf '_sgt_is_drained should return 0 with global drain\n' >&2; exit 1; }
_sgt_is_drained "otherproject" || { printf '_sgt_is_drained should drain all projects when global drain active\n' >&2; exit 1; }
_sgt_is_drained "" || { printf '_sgt_is_drained should return 0 for empty project with global drain\n' >&2; exit 1; }
rm "$config_dir/drain/global"
printf 'sgt-drain global drain blocks all: ok\n'

# ── Slice 3: project drain blocks only that project ──────────────────────────

printf 'reason=feature-gate\ncreated=2025-01-01T00:00:00Z\n' > "$config_dir/drain/myproject"

_sgt_is_drained "myproject" || { printf '_sgt_is_drained should return 0 for matching project drain\n' >&2; exit 1; }
_sgt_is_drained "otherproject" && { printf '_sgt_is_drained should return 1 for non-matching project drain\n' >&2; exit 1; }
_sgt_is_drained "" && { printf '_sgt_is_drained should return 1 for empty project when only project drain active\n' >&2; exit 1; }
rm "$config_dir/drain/myproject"
printf 'sgt-drain project drain scopes correctly: ok\n'

# ── Slice 4: sgt-drain --global sets global drain ────────────────────────────

"$ROOT_DIR/bin/sgt-drain" --global --reason "test global" >/dev/null
[[ -f "$config_dir/drain/global" ]] || { printf 'sgt-drain --global should create global drain file\n' >&2; exit 1; }
grep -q 'reason=test global' "$config_dir/drain/global" || { printf 'global drain file should contain reason\n' >&2; exit 1; }
grep -qE 'created(_at)?=' "$config_dir/drain/global" || { printf 'global drain file should contain created timestamp\n' >&2; exit 1; }
_sgt_is_drained "anyproject" || { printf 'global drain should be active after sgt-drain --global\n' >&2; exit 1; }
printf 'sgt-drain --global creates drain: ok\n'

# ── Slice 5: sgt-undrain --global removes global drain ───────────────────────

"$ROOT_DIR/bin/sgt-drain" --undrain --global >/dev/null
[[ ! -f "$config_dir/drain/global" ]] || { printf 'sgt-drain --undrain --global should remove global drain file\n' >&2; exit 1; }
_sgt_is_drained "anyproject" && { printf 'global drain should be inactive after undrain\n' >&2; exit 1; }
printf 'sgt-drain --undrain --global removes drain: ok\n'

# ── Slice 6: sgt-drain <project> sets project drain ─────────────────────────

"$ROOT_DIR/bin/sgt-drain" myproject --reason "feature pause" >/dev/null
[[ -f "$config_dir/drain/myproject" ]] || { printf 'sgt-drain myproject should create project drain file\n' >&2; exit 1; }
grep -q 'reason=feature pause' "$config_dir/drain/myproject" || { printf 'project drain file should contain reason\n' >&2; exit 1; }
_sgt_is_drained "myproject" || { printf 'project drain should be active after sgt-drain myproject\n' >&2; exit 1; }
_sgt_is_drained "otherproject" && { printf 'sgt-drain myproject should not drain other projects\n' >&2; exit 1; }
printf 'sgt-drain project sets drain: ok\n'

# ── Slice 7: sgt-drain --undrain <project> removes project drain ─────────────

"$ROOT_DIR/bin/sgt-drain" --undrain myproject >/dev/null
[[ ! -f "$config_dir/drain/myproject" ]] || { printf 'sgt-drain --undrain myproject should remove drain file\n' >&2; exit 1; }
_sgt_is_drained "myproject" && { printf 'project drain should be inactive after undrain\n' >&2; exit 1; }
printf 'sgt-drain --undrain project removes drain: ok\n'

# ── Slice 8: sgt-drain idempotent — double drain is ok ──────────────────────

"$ROOT_DIR/bin/sgt-drain" --global --reason "first" >/dev/null
"$ROOT_DIR/bin/sgt-drain" --global --reason "second" >/dev/null
[[ -f "$config_dir/drain/global" ]] || { printf 'double drain should still have drain file\n' >&2; exit 1; }
grep -q 'reason=second' "$config_dir/drain/global" || { printf 'second drain should overwrite reason\n' >&2; exit 1; }
"$ROOT_DIR/bin/sgt-drain" --undrain --global >/dev/null
printf 'sgt-drain idempotent double drain: ok\n'

# ── Slice 9: sgt-drain --undrain no-op when not drained ─────────────────────

# Should not fail
"$ROOT_DIR/bin/sgt-drain" --undrain myproject >/dev/null
"$ROOT_DIR/bin/sgt-drain" --undrain --global >/dev/null
printf 'sgt-drain --undrain no-op when not drained: ok\n'

# ── Slice 10: drain without reason ──────────────────────────────────────────

"$ROOT_DIR/bin/sgt-drain" --global >/dev/null
[[ -f "$config_dir/drain/global" ]] || { printf 'drain without reason should still create file\n' >&2; exit 1; }
grep -qE 'created(_at)?=' "$config_dir/drain/global" || { printf 'drain without reason should have created timestamp\n' >&2; exit 1; }
"$ROOT_DIR/bin/sgt-drain" --undrain --global >/dev/null
printf 'sgt-drain without reason: ok\n'

printf 'sgt-drain: all tests passed\n'

# ── Slice 11 (bug #82): sgt-drain --status shows active drain state ──────────

# No drain active: --status should exit 0 and print "no active drain"
if ! output="$("$ROOT_DIR/bin/sgt-drain" --status 2>&1)"; then
  printf 'sgt-drain --status should exit 0 when no drain active\n' >&2
  exit 1
fi
printf '%s\n' "$output" | grep -qi "no.*drain\|inactive\|none" || \
  { printf 'sgt-drain --status should report no active drain, got: %s\n' "$output" >&2; exit 1; }
printf 'sgt-drain --status no drain: ok\n'

# Global drain active: --status should show it
"$ROOT_DIR/bin/sgt-drain" --global --reason "maintenance" >/dev/null
if ! output="$("$ROOT_DIR/bin/sgt-drain" --status 2>&1)"; then
  printf 'sgt-drain --status should exit 0 with active drain\n' >&2
  exit 1
fi
printf '%s\n' "$output" | grep -qi "global\|active\|maintenance" || \
  { printf 'sgt-drain --status should report global drain, got: %s\n' "$output" >&2; exit 1; }
"$ROOT_DIR/bin/sgt-drain" --undrain --global >/dev/null
printf 'sgt-drain --status global drain: ok\n'

# Project drain active: --status --global should show no drain, --status should show project
"$ROOT_DIR/bin/sgt-drain" myproject --reason "testing" >/dev/null
if ! output="$("$ROOT_DIR/bin/sgt-drain" --status myproject 2>&1)"; then
  printf 'sgt-drain --status <project> should exit 0\n' >&2
  exit 1
fi
printf '%s\n' "$output" | grep -qi "myproject\|active\|testing" || \
  { printf 'sgt-drain --status <project> should report project drain, got: %s\n' "$output" >&2; exit 1; }
"$ROOT_DIR/bin/sgt-drain" --undrain myproject >/dev/null
printf 'sgt-drain --status project drain: ok\n'

# ── Slice 12 (bug #81): drain lock helpers are callable ──────────────────────

# _sgt_drain_lock_acquire_fd, _sgt_drain_check_admission_locked,
# and _sgt_drain_lock_release_fd must exist in _sgt-drain.sh.

source "$ROOT_DIR/bin/_sgt-drain.sh"

# Acquire lock on fd 9 — must succeed and return 0
exec 9>/dev/null
_sgt_drain_lock_acquire_fd 9 || { printf '_sgt_drain_lock_acquire_fd should return 0\n' >&2; exit 1; }

# No drain: check_admission_locked must return 0 (admission allowed)
_sgt_drain_check_admission_locked "" || { printf '_sgt_drain_check_admission_locked should allow when no drain\n' >&2; exit 1; }

# Release lock — must succeed
_sgt_drain_lock_release_fd 9 || { printf '_sgt_drain_lock_release_fd should return 0\n' >&2; exit 1; }
exec 9>&-
printf 'drain lock helpers callable: ok\n'

# Drain active: check_admission_locked must return non-0 (admission refused)
exec 9>/dev/null
"$ROOT_DIR/bin/sgt-drain" --global >/dev/null
_sgt_drain_lock_acquire_fd 9 || { printf '_sgt_drain_lock_acquire_fd should return 0 even when drained\n' >&2; exit 1; }
_sgt_drain_check_admission_locked "" && \
  { printf '_sgt_drain_check_admission_locked should refuse when globally drained\n' >&2; exit 1; }
_sgt_drain_lock_release_fd 9
exec 9>&-
"$ROOT_DIR/bin/sgt-drain" --undrain --global >/dev/null
printf 'drain lock helpers refuse when drained: ok\n'

# ── Slice 13 (td-a21178): the three lock outcomes are distinguishable ────────
#
# acquired (0), timeout (2), and unavailable (3) must be told apart, and a
# failed acquisition must never let a caller proceed as if the lock were held.

lock_dir="$(_sgt_drain_lock_dir)"

rc=0
SERGEANT_DRAIN_LOCK_TIMEOUT_SECS=1 _sgt_drain_lock_acquire_fd 9 "drain-test" || rc=$?
[[ $rc -eq 0 ]] || { printf 'acquire should return 0 when uncontended, got %s\n' "$rc" >&2; exit 1; }
[[ "$SGT_DRAIN_LOCK_STATE" == "acquired" ]] || \
  { printf 'acquire should report state=acquired, got %s\n' "$SGT_DRAIN_LOCK_STATE" >&2; exit 1; }
printf 'drain lock acquired outcome: ok\n'

# The lock record must carry proven owner state for stale-lock recovery.
[[ -f "$lock_dir/owner" ]] || \
  { printf 'lock record %s/owner should exist while held\n' "$lock_dir" >&2; exit 1; }
for field in owner_pid owner_host owner_user owner_purpose created_at created_epoch; do
  grep -q "^${field}=" "$lock_dir/owner" || \
    { printf 'lock record should carry %s\n' "$field" >&2; exit 1; }
done
grep -q '^owner_purpose=drain-test$' "$lock_dir/owner" || \
  { printf 'lock record should carry the caller purpose\n' >&2; exit 1; }
printf 'drain lock owner record: ok\n'

# A second acquisition, in a separate process, must time out — not succeed.
contend_out="$TEST_ROOT/contend.out"
SERGEANT_DRAIN_LOCK_TIMEOUT_SECS=1 bash -c '
  source "$1/bin/_sgt-drain.sh"
  rc=0
  _sgt_drain_lock_acquire_fd 8 "contender" || rc=$?
  printf "rc=%s state=%s\n" "$rc" "${SGT_DRAIN_LOCK_STATE:-}"
' _ "$ROOT_DIR" > "$contend_out" 2>"$TEST_ROOT/contend.err" || true
grep -q 'rc=2 state=timeout' "$contend_out" || \
  { printf 'contended acquire should report rc=2 state=timeout, got: %s\n' \
      "$(cat "$contend_out")" >&2; exit 1; }
# The timeout diagnostic must identify the owner well enough to recover.
grep -q "owner_pid=$$\|pid=$$" "$TEST_ROOT/contend.err" || \
  { printf 'timeout diagnostic should name the lock owner pid, got: %s\n' \
      "$(cat "$TEST_ROOT/contend.err")" >&2; exit 1; }
grep -qi 'purpose' "$TEST_ROOT/contend.err" || \
  { printf 'timeout diagnostic should name the lock purpose, got: %s\n' \
      "$(cat "$TEST_ROOT/contend.err")" >&2; exit 1; }
printf 'drain lock timeout outcome: ok\n'

# Fail closed: sgt-drain must not mutate drain state when it cannot lock.
rc=0
SERGEANT_DRAIN_LOCK_TIMEOUT_SECS=1 "$ROOT_DIR/bin/sgt-drain" --global \
  --reason "should not apply" >/dev/null 2>&1 || rc=$?
[[ $rc -ne 0 ]] || { printf 'sgt-drain should fail while the admission lock is held\n' >&2; exit 1; }
[[ ! -f "$config_dir/drain/global" ]] || \
  { printf 'sgt-drain must not create drain state when the lock was not acquired\n' >&2; exit 1; }
printf 'drain lock fails closed: ok\n'

_sgt_drain_lock_release_fd 9

# After release the same command must succeed.
"$ROOT_DIR/bin/sgt-drain" --global --reason "after release" >/dev/null
[[ -f "$config_dir/drain/global" ]] || \
  { printf 'sgt-drain should succeed after the lock is released\n' >&2; exit 1; }
"$ROOT_DIR/bin/sgt-drain" --undrain --global >/dev/null
[[ ! -d "$lock_dir" ]] || \
  { printf 'lock directory should not be left behind after release\n' >&2; exit 1; }
printf 'drain lock release: ok\n'

# ── Slice 14 (td-a21178): a stale lock owned by a dead process is reclaimed ──

# Produce a genuinely dead pid.
bash -c 'exit 0' & dead_pid=$!
wait "$dead_pid" 2>/dev/null || true

mkdir -p "$lock_dir"
{
  printf 'owner_pid=%s\n' "$dead_pid"
  printf 'owner_host=%s\n' "$(_sgt_drain_host_id)"
  printf 'owner_user=%s\n' "someone"
  printf 'owner_purpose=%s\n' "crashed-holder"
  printf 'created_at=%s\n' "2025-01-01T00:00:00Z"
  printf 'created_epoch=%s\n' "0"
} > "$lock_dir/owner"

rc=0
SERGEANT_DRAIN_LOCK_TIMEOUT_SECS=1 _sgt_drain_lock_acquire_fd 9 "reclaimer" || rc=$?
[[ $rc -eq 0 ]] || { printf 'a lock owned by a dead pid should be reclaimed, got rc=%s\n' "$rc" >&2; exit 1; }
grep -q '^owner_purpose=reclaimer$' "$lock_dir/owner" || \
  { printf 'reclaimed lock should record the new owner\n' >&2; exit 1; }
_sgt_drain_lock_release_fd 9
printf 'drain lock stale reclamation: ok\n'

# A lock whose owner cannot be verified must NOT be stolen (fail closed).
mkdir -p "$lock_dir"
{
  printf 'owner_pid=1\n'
  printf 'owner_host=%s\n' "some-other-host"
  printf 'owner_user=someone\n'
  printf 'owner_purpose=remote-holder\n'
  printf 'created_at=2025-01-01T00:00:00Z\n'
  printf 'created_epoch=0\n'
} > "$lock_dir/owner"
rc=0
SERGEANT_DRAIN_LOCK_TIMEOUT_SECS=1 _sgt_drain_lock_acquire_fd 9 "thief" 2>/dev/null || rc=$?
[[ $rc -eq 2 ]] || { printf 'an unverifiable foreign lock must not be stolen, got rc=%s\n' "$rc" >&2; exit 1; }
grep -q '^owner_purpose=remote-holder$' "$lock_dir/owner" || \
  { printf 'an unverifiable foreign lock must be left intact\n' >&2; exit 1; }
rm -rf "$lock_dir"
printf 'drain lock refuses to steal unverifiable locks: ok\n'

# ── Slice 15 (td-929656): drain never depends on flock ──────────────────────
#
# The library documents a no-flock fallback for minimal installs and macOS
# system Bash.  A broken or absent flock must not break drain or undrain.

fake_bin="$TEST_ROOT/nofl0ck-bin"
mkdir -p "$fake_bin"
printf '#!/usr/bin/env bash\nexit 1\n' > "$fake_bin/flock"
chmod +x "$fake_bin/flock"

PATH="$fake_bin:$PATH" "$ROOT_DIR/bin/sgt-drain" --global --reason "no flock" >/dev/null
[[ -f "$config_dir/drain/global" ]] || \
  { printf 'sgt-drain must work when flock is unusable\n' >&2; exit 1; }
PATH="$fake_bin:$PATH" "$ROOT_DIR/bin/sgt-drain" --undrain --global >/dev/null
[[ ! -f "$config_dir/drain/global" ]] || \
  { printf 'sgt-drain --undrain must work when flock is unusable\n' >&2; exit 1; }
printf 'drain works without usable flock: ok\n'

# ── Slice 16 (td-a21178): an unusable lock location reports "unavailable" ────
#
# Distinct from a timeout: there is no locking primitive to use at all.
# Root bypasses directory permissions, so this case is only observable as an
# unprivileged user.

if [[ "$(id -u)" != "0" ]]; then
  readonly_root="$TEST_ROOT/readonly"
  mkdir -p "$readonly_root"
  chmod 500 "$readonly_root"
  rc=0
  ( SERGEANT_DRAIN_DIR="$readonly_root/drain" \
      SERGEANT_DRAIN_LOCK_TIMEOUT_SECS=1 \
      _sgt_drain_lock_acquire_fd 9 "unavailable-probe" 2>/dev/null ) || rc=$?
  chmod 700 "$readonly_root"
  [[ $rc -eq 3 ]] || \
    { printf 'an unusable lock location should report rc=3 (unavailable), got rc=%s\n' "$rc" >&2; exit 1; }
  printf 'drain lock unavailable outcome: ok\n'
else
  printf 'drain lock unavailable outcome: skipped (running as root)\n'
fi

# ── Slice 19 (td-a21178 / GH #167): documented bounded --wait is accepted ────
#
# AGENTS.md advertises `sgt-drain --global|<project> [--wait [--timeout <s>]]`.
# The parser used to reject both flags outright.

fleet_dir="$TEST_ROOT/fleet"
export SERGEANT_FLEET="$fleet_dir"
mkdir -p "$fleet_dir"

# _mk_fleet_worker <task> <repo> <project> <status> [pid]
#
# Creates fleet state for one worker.  When a pid is given it is recorded with
# its process start time, exactly as sgt-interactive-worker records identity.
_mk_fleet_worker() {
  local task="$1" repo="$2" project="$3" status="$4" pid="${5:-}"
  local dir="$fleet_dir/$task/$repo"
  mkdir -p "$dir"
  printf '%s\n' "$status"  > "$dir/status"
  printf '%s\n' "$project" > "$dir/project"
  if [[ -n "$pid" ]]; then
    printf '%s\n' "$pid" > "$dir/worker_pid"
    # A dead pid yields no start time; record whatever ps reports.
    { ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^ *//;s/ *$//' \
      > "$dir/worker_process_start"; } || true
  fi
  return 0
}

# No workers at all: the bounded wait has nothing to wait for.
rc=0
out="$("$ROOT_DIR/bin/sgt-drain" --global --wait --timeout 2 2>&1)" || rc=$?
[[ $rc -eq 0 ]] || { printf 'sgt-drain --global --wait --timeout 2 should succeed with an empty fleet, got rc=%s: %s\n' "$rc" "$out" >&2; exit 1; }
[[ -f "$config_dir/drain/global" ]] || \
  { printf '--wait should still activate the drain\n' >&2; exit 1; }
"$ROOT_DIR/bin/sgt-drain" --undrain --global >/dev/null
printf 'sgt-drain --wait --timeout accepted as documented: ok\n'

# --wait without --timeout is also documented.
rc=0
"$ROOT_DIR/bin/sgt-drain" myproject --wait >/dev/null 2>&1 || rc=$?
[[ $rc -eq 0 ]] || { printf 'sgt-drain <project> --wait should be accepted, got rc=%s\n' "$rc" >&2; exit 1; }
"$ROOT_DIR/bin/sgt-drain" --undrain myproject >/dev/null
printf 'sgt-drain --wait without --timeout accepted: ok\n'

# Misuse must still be rejected, and must not activate a drain.
rc=0
"$ROOT_DIR/bin/sgt-drain" --global --timeout 5 >/dev/null 2>&1 || rc=$?
[[ $rc -ne 0 ]] || { printf '--timeout without --wait should be rejected\n' >&2; exit 1; }
[[ ! -f "$config_dir/drain/global" ]] || \
  { printf 'a rejected invocation must not activate a drain\n' >&2; exit 1; }
rc=0
"$ROOT_DIR/bin/sgt-drain" --global --wait --timeout abc >/dev/null 2>&1 || rc=$?
[[ $rc -ne 0 ]] || { printf 'a non-numeric --timeout should be rejected\n' >&2; exit 1; }
rc=0
"$ROOT_DIR/bin/sgt-drain" --status --wait >/dev/null 2>&1 || rc=$?
[[ $rc -ne 0 ]] || { printf '--wait with --status should be rejected\n' >&2; exit 1; }
rc=0
"$ROOT_DIR/bin/sgt-drain" --undrain --global --wait >/dev/null 2>&1 || rc=$?
[[ $rc -ne 0 ]] || { printf '--wait with --undrain should be rejected\n' >&2; exit 1; }
printf 'sgt-drain --wait misuse rejected: ok\n'

# ── Slice 20 (td-a21178 / GH #167): resolved workers do not block the wait ───
#
# done, drained, and failed workers are finished, and a nonterminal worker whose
# process is gone has already stopped — none of them can still be drained.

bash -c 'exit 0' & gone_pid=$!
wait "$gone_pid" 2>/dev/null || true

_mk_fleet_worker "task-a" "repo1" "myproject" "done"
_mk_fleet_worker "task-a" "repo2" "myproject" "drained"
_mk_fleet_worker "task-b" "repo1" "myproject" "failed: build broke"
_mk_fleet_worker "task-b" "repo2" "myproject" "in_progress" "$gone_pid"
_mk_fleet_worker "task-c" "repo1" "otherproject" "in_progress"

rc=0
out="$("$ROOT_DIR/bin/sgt-drain" myproject --wait --timeout 2 2>&1)" || rc=$?
[[ $rc -eq 0 ]] || \
  { printf 'resolved and exited workers should not block the wait, got rc=%s: %s\n' "$rc" "$out" >&2; exit 1; }
"$ROOT_DIR/bin/sgt-drain" --undrain myproject >/dev/null
printf 'sgt-drain --wait ignores resolved workers: ok\n'

# ── Slice 21 (td-a21178 / GH #167): timeout is truthful and non-destructive ──
#
# On timeout the drain must remain active, the command must fail, unresolved
# workers must be named, and none of them may be terminated.

sleep 30 & live_pid=$!
_mk_fleet_worker "task-d" "busy-repo" "myproject" "in_progress" "$live_pid"

rc=0
out="$("$ROOT_DIR/bin/sgt-drain" myproject --wait --timeout 1 2>&1)" || rc=$?
[[ $rc -ne 0 ]] || \
  { printf 'an unresolved worker should make the bounded wait fail\n' >&2; exit 1; }
[[ -f "$config_dir/drain/myproject" ]] || \
  { printf 'the drain must remain active after a wait timeout\n' >&2; exit 1; }
printf '%s\n' "$out" | grep -q 'task-d/busy-repo' || \
  { printf 'timeout should name the unresolved worker, got: %s\n' "$out" >&2; exit 1; }
kill -0 "$live_pid" 2>/dev/null || \
  { printf 'a wait timeout must not terminate unresolved workers\n' >&2; exit 1; }

# The other project's still-running worker must not be reported for this scope.
printf '%s\n' "$out" | grep -q 'task-c' && \
  { printf 'a project-scoped wait must not report other projects, got: %s\n' "$out" >&2; exit 1; }

# Once the worker resolves, the same wait succeeds.
printf 'drained\n' > "$fleet_dir/task-d/busy-repo/status"
rc=0
out="$("$ROOT_DIR/bin/sgt-drain" myproject --wait --timeout 2 2>&1)" || rc=$?
[[ $rc -eq 0 ]] || \
  { printf 'the wait should succeed once workers drain, got rc=%s: %s\n' "$rc" "$out" >&2; exit 1; }
kill "$live_pid" 2>/dev/null || true
wait "$live_pid" 2>/dev/null || true
"$ROOT_DIR/bin/sgt-drain" --undrain myproject >/dev/null
printf 'sgt-drain --wait timeout is truthful and non-destructive: ok\n'

# ── Slice 22 (td-a21178 / GH #167): a global wait spans every project ────────

sleep 30 & live_pid=$!
_mk_fleet_worker "task-e" "any-repo" "otherproject" "in_progress" "$live_pid"
rc=0
out="$("$ROOT_DIR/bin/sgt-drain" --global --wait --timeout 1 2>&1)" || rc=$?
[[ $rc -ne 0 ]] || { printf 'a global wait should observe every project\n' >&2; exit 1; }
printf '%s\n' "$out" | grep -q 'task-e/any-repo' || \
  { printf 'a global wait should name workers from any project, got: %s\n' "$out" >&2; exit 1; }
[[ -f "$config_dir/drain/global" ]] || \
  { printf 'the global drain must remain active after a wait timeout\n' >&2; exit 1; }
kill "$live_pid" 2>/dev/null || true
wait "$live_pid" 2>/dev/null || true
"$ROOT_DIR/bin/sgt-drain" --undrain --global >/dev/null
rm -rf "$fleet_dir"
mkdir -p "$fleet_dir"
printf 'sgt-drain --global --wait spans projects: ok\n'

# ── Slice 17: --reason is data, never shell code ─────────────────────────────
#
# The locked mutation used to be built as a shell string and eval'd, so a
# reason containing a command substitution executed while holding the lock.

canary="$TEST_ROOT/reason-injection-canary"
"$ROOT_DIR/bin/sgt-drain" --global --reason "maintenance \$(touch $canary) done" >/dev/null
[[ ! -e "$canary" ]] || \
  { printf '--reason must not be evaluated as shell code\n' >&2; exit 1; }
# shellcheck disable=SC2016  # The literal, unexpanded text is exactly what must be stored.
grep -q 'reason=maintenance \$(touch' "$config_dir/drain/global" || \
  { printf '--reason should be recorded verbatim, got: %s\n' \
      "$(cat "$config_dir/drain/global")" >&2; exit 1; }
"$ROOT_DIR/bin/sgt-drain" --undrain --global >/dev/null
printf 'drain reason is data not code: ok\n'

# ── Slice 18 (td-39252c): the dead admission helper is gone ──────────────────
#
# _sgt_drain_check_admission was exported but never called; the locked variant
# is the real gate.  Keeping an uncalled second admission path invites drift.

if declare -f _sgt_drain_check_admission >/dev/null 2>&1; then
  printf '_sgt_drain_check_admission should not exist (dead code)\n' >&2
  exit 1
fi
grep -q '_sgt_drain_check_admission,\|_sgt_drain_check_admission$' \
  "$ROOT_DIR/bin/_sgt-drain.sh" && \
  { printf 'exports comment should no longer advertise _sgt_drain_check_admission\n' >&2; exit 1; }
declare -f _sgt_drain_check_admission_locked >/dev/null 2>&1 || \
  { printf '_sgt_drain_check_admission_locked must remain\n' >&2; exit 1; }
printf 'dead admission helper removed: ok\n'

printf 'sgt-drain: all tests passed\n'
