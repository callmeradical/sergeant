#!/usr/bin/env bash

set -Eeuo pipefail

# ── Diagnostics ───────────────────────────────────────────────────────────────
# Every failure in this suite must name itself.  A bare `[[ ... ]]` under
# `set -e` exits 1 with no stdout and no stderr, and this suite is the only
# coverage for _same_filesystem_pair (bin/sgt-cleanup) — so a silent exit left
# cross-filesystem cleanup with no readable evidence at all, on main as well as
# on branches (td-c08471).  Assertions that compare values carry their own
# message below; the ERR trap is the backstop that names file, line, scenario,
# and expression for every remaining assertion, including future ones.
CASE_LABEL="startup"

# Compact one-line listing of a directory, for failure messages.
_list_entries() {
  local root="$1"

  if [[ ! -d "$root" ]]; then
    printf '<absent>'
    return 0
  fi
  (cd "$root" && find . -mindepth 1 -maxdepth 1 | LC_ALL=C sort | \
    sed 's|^\./||' | tr '\n' ' ')
}

_fail() {
  local line
  printf 'FAIL: %s\n' "$1" >&2
  printf '  case: %s\n' "$CASE_LABEL" >&2
  shift
  for line in "$@"; do
    printf '  %s\n' "$line" >&2
  done
  exit 1
}

# Reported only for assertions, never for the deliberate failures this suite
# provokes: those run under `set +e`, and bash still fires ERR for them.
_on_err() {
  local status="$1" line="$2" command="$3"
  case "$-" in
    *e*) ;;
    *) return 0 ;;
  esac
  printf 'FAIL: %s:%s: assertion failed (exit %s)\n' \
    "${BASH_SOURCE[0]}" "$line" "$status" >&2
  printf '  case:      %s\n' "$CASE_LABEL" >&2
  printf '  assertion: %s\n' "$command" >&2
}
trap '_on_err "$?" "$LINENO" "$BASH_COMMAND"' ERR

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
REAL_GIT="$(command -v git)"
REAL_CP="$(command -v cp)"
export REAL_CP REAL_GIT
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/config" "$TEST_ROOT/fake-bin" "$TEST_ROOT/fleet"

cat > "$TEST_ROOT/fake-bin/git" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" worktree remove "*)
    printf 'git|%s\n' "${!#}" >> "$FAKE_REMOVER_LOG"
    [[ "${FAKE_REMOVER_SUCCESS:-}" != true ]] || exec "$REAL_GIT" "$@"
    exit 1
    ;;
esac
"$REAL_GIT" "$@"
EOF

cat > "$TEST_ROOT/fake-bin/treehouse" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == status && "$2" == --json ]]; then
  python3 - "$SERGEANT_FLEET" <<'PY'
import json
from pathlib import Path
import sys

entries = []
for state in Path(sys.argv[1]).glob("*/*"):
    if not (state / "wt_type").is_file() or \
            (state / "wt_type").read_text().strip() != "treehouse":
        continue
    entries.append({
        "path": (state / "worktree").read_text().strip(),
        "lease_id": (state / "wt_lease_id").read_text().strip(),
        "lease_holder": (state / "wt_holder").read_text().strip(),
    })
print(json.dumps(entries))
PY
  exit 0
fi
printf 'treehouse|%s\n' "$7" >> "$FAKE_REMOVER_LOG"
if [[ "${FAKE_REMOVER_SUCCESS:-}" == true ]]; then
  rm -rf "$7"
  exit 0
fi
exit 1
EOF

cat > "$TEST_ROOT/fake-bin/stat" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${FAKE_STAT_COUNT_FILE:-}" && \
  "${!#}" == "$FAKE_CROSS_DEVICE_PATH" ]]; then
  count=0
  [[ ! -f "$FAKE_STAT_COUNT_FILE" ]] || count="$(cat "$FAKE_STAT_COUNT_FILE")"
  count=$((count + 1))
  printf '%s\n' "$count" > "$FAKE_STAT_COUNT_FILE"
fi
case "${!#}" in
  "$FAKE_CROSS_DEVICE_PATH")
    if [[ -z "${FAKE_CROSS_DEVICE_AFTER:-}" || \
      "${count:-0}" -gt "$FAKE_CROSS_DEVICE_AFTER" ]]; then
      printf '200\n'
    else
      printf '100\n'
    fi
    ;;
  *) printf '100\n' ;;
esac
EOF
cat > "$TEST_ROOT/fake-bin/cp" <<'EOF'
#!/usr/bin/env bash
if [[ "${FAKE_RESTORE_FAILURE:-}" == true && "${!#}" == *.restore.* ]]; then
  exit 1
fi
# Fail a LATER entry so earlier entries — including directory ledgers — are
# already published when the rollback runs.
if [[ -n "${FAKE_RESTORE_FAILURE_MATCH:-}" && \
  "${!#}" == *"$FAKE_RESTORE_FAILURE_MATCH"*.restore.* ]]; then
  exit 1
fi
# Race a directory into the destination between the copy and the publication, so
# the publication has to prove absence again instead of nesting into it.
if [[ -n "${FAKE_RESTORE_COLLIDE_MATCH:-}" && \
  "${!#}" == *"$FAKE_RESTORE_COLLIDE_MATCH"*.restore.* ]]; then
  collide="${!#}"
  mkdir -p "${collide%%.restore.*}"
fi
"$REAL_CP" "$@"
EOF
chmod +x "$TEST_ROOT/fake-bin/cp" "$TEST_ROOT/fake-bin/git" "$TEST_ROOT/fake-bin/stat" \
  "$TEST_ROOT/fake-bin/treehouse"

init_case() {
  local mode="$1" task_id="$2"
  local repo_root="$TEST_ROOT/$task_id-main"
  local repo_state="$TEST_ROOT/fleet/$task_id/app"
  local worktree="$TEST_ROOT/$task_id-linked-worktree"

  mkdir -p "$repo_state"
  git -C "$TEST_ROOT" init -q "$repo_root"
  git -C "$repo_root" config user.name Test
  git -C "$repo_root" config user.email test@example.invalid
  printf 'fixture\n' > "$repo_root/README.md"
  git -C "$repo_root" add README.md
  git -C "$repo_root" commit -qm fixture
  git -C "$repo_root" worktree add -q -b "$task_id-worker" "$worktree"

  cat > "$TEST_ROOT/config/$task_id.yaml" <<EOF
name: $task_id
repos:
  - name: app
    path: $repo_root
EOF
  printf 'Project: %s\n' "$task_id" > "$TEST_ROOT/fleet/$task_id/brief.md"
  printf '%s\n' "$worktree" > "$repo_state/worktree"
  printf 'done\n' > "$repo_state/status"
  printf 'result\n' > "$repo_state/result"
  printf 'done\n' > "$worktree/.sergeant-status"
  printf 'result\n' > "$worktree/.sergeant-result"
  # GH #169: real workers publish notification ledgers and review gates as
  # directories, so every cross-filesystem boundary must handle them too.
  mkdir -p "$worktree/.sergeant-notification-acks" \
    "$worktree/.sergeant-notification-accepts" \
    "$worktree/.sergeant-notification-complete" \
    "$worktree/.sergeant-review-gates/nested"
  printf 'nid|nonce\n' > "$worktree/.sergeant-notification-acks/nonce"
  printf 'nid|nonce\n' > "$worktree/.sergeant-notification-accepts/nonce"
  printf 'nid|nonce\n' > "$worktree/.sergeant-notification-complete/nonce"
  printf 'standards passed\n' > "$worktree/.sergeant-review-gates/standards"
  printf 'spec passed\n' > "$worktree/.sergeant-review-gates/nested/spec"
  printf '%s\n' "$mode" > "$repo_state/wt_type"
  if [[ "$mode" == treehouse ]]; then
    printf 'sgt-%s-app\n' "$task_id" > "$repo_state/wt_holder"
    printf 'lease-%s\n' "$task_id" > "$repo_state/wt_lease_id"
  fi
}

snapshot_state() {
  local root

  for root in "$@"; do
    [[ ! -e "$root" ]] || find "$root" -type f -exec cksum {} +
  done | LC_ALL=C sort
}

CLEANUP_LAYOUT_REJECTION="Unsupported cleanup layout: fleet state and worktree must be on the same filesystem; move SERGEANT_FLEET or the worktree before retrying: app"

# The response-lock transition gate is lock infrastructure, not fleet evidence,
# and it is the ONE addition a rejected cleanup may leave behind.
#
# _sgt_response_lock_transition (bin/_sgt-response-lock.sh) flocks
# "<fleet-state>/response.lock.transition" to serialize the non-atomic
# compare/retire/install sequence that installs response.lock.  That anchor has
# to stay linked: a holder keeps its lock on an unlinked inode while the next
# opener creates a fresh inode and acquires it immediately, so unlinking the gate
# would let two processes run the sequence at once and install two lock owners.
# tests/sgt-response-lock-gate-test.sh pins that persistence invariant directly.
#
# sgt-cleanup must hold the response lock (bin/sgt-cleanup) before it may read
# response state, and a device change that appears after the layout preflight is
# only caught by a later revalidation — so a cleanup rejected at that point has
# necessarily already created the gate.  It is exempted by exact name, only where
# the response lock is genuinely acquired, and only as an empty regular file.
# Every other difference, in either direction, is a mutation failure.
LOCK_GATE_NAME="response.lock.transition"

# comm needs both sides as files, and an empty snapshot must produce an empty
# file rather than one blank line.
_write_snapshot() {
  local text="$1" file="$2"

  if [[ -n "$text" ]]; then
    printf '%s\n' "$text" > "$file"
  else
    : > "$file"
  fi
}

# assert_state_unchanged <before> <state-dir> <worktree|""> <lock-gate|no-lock-gate>
assert_state_unchanged() {
  local expected="$1" state="$2" worktree="$3" gate_policy="$4"
  local actual added removed gate_line
  local expected_file="$TEST_ROOT/snapshot-expected" \
    actual_file="$TEST_ROOT/snapshot-actual"

  if [[ -n "$worktree" ]]; then
    actual="$(snapshot_state "$state" "$worktree")"
  else
    actual="$(snapshot_state "$state")"
  fi
  [[ "$actual" != "$expected" ]] || return 0

  _write_snapshot "$expected" "$expected_file"
  _write_snapshot "$actual" "$actual_file"
  removed="$(LC_ALL=C comm -23 "$expected_file" "$actual_file")"
  added="$(LC_ALL=C comm -13 "$expected_file" "$actual_file")"
  rm -f "$expected_file" "$actual_file"

  [[ -z "$removed" ]] || _fail \
    "a rejected cleanup removed or rewrote fleet state or worktree evidence" \
    "state:   $state" "worktree: ${worktree:-<not snapshotted>}" \
    "missing or changed before the run:" "$removed" \
    "added by the run:" "${added:-<none>}"

  [[ "$gate_policy" == lock-gate ]] || _fail \
    "a cleanup rejected before the response lock is acquired added fleet state" \
    "state: $state" "added by the run:" "$added"

  gate_line="$(cksum "$state/$LOCK_GATE_NAME" 2>/dev/null || true)"
  [[ -n "$gate_line" && "$added" == "$gate_line" ]] || _fail \
    "a rejected cleanup added fleet state beyond the response-lock transition gate" \
    "state: $state" "tolerated: ${gate_line:-<gate absent>}" \
    "added by the run:" "$added"
  [[ -f "$state/$LOCK_GATE_NAME" && ! -L "$state/$LOCK_GATE_NAME" && \
    ! -s "$state/$LOCK_GATE_NAME" ]] || _fail \
    "the response-lock transition gate is not an empty regular file" \
    "gate: $state/$LOCK_GATE_NAME" "$(ls -ld "$state/$LOCK_GATE_NAME")"
}

# assert_rejected <status> <output>
assert_rejected() {
  local status="$1" output="$2"

  [[ "$status" -ne 0 ]] || _fail \
    "cross-filesystem cleanup succeeded instead of refusing" \
    "output:" "${output:-<no output>}"
  [[ "$output" == *"$CLEANUP_LAYOUT_REJECTION"* ]] || _fail \
    "cross-filesystem cleanup was not rejected actionably" \
    "expected to contain: $CLEANUP_LAYOUT_REJECTION" \
    "output:" "${output:-<no output>}"
}

# assert_remover_calls <remover-log> <expected-count>
assert_remover_calls() {
  local log="$1" expected="$2" actual

  actual="$(wc -l < "$log" | tr -d ' ')"
  [[ "$actual" == "$expected" ]] || _fail \
    "the worktree remover was called an unexpected number of times" \
    "expected calls: $expected" "observed calls: $actual" \
    "remover log:" "$(cat "$log")"
}

assert_cross_filesystem_rejected() {
  local mode="$1" phase="$2" task_id
  local marker output removals_before repo_root repo_state state_before status worktree

  task_id="crossfs-$mode-$phase"
  CASE_LABEL="cross-filesystem rejection: $task_id"

  init_case "$mode" "$task_id"
  repo_root="$TEST_ROOT/$task_id-main"
  repo_state="$TEST_ROOT/fleet/$task_id/app"
  worktree="$TEST_ROOT/$task_id-linked-worktree"
  marker="$repo_root/.git/sergeant-instance"
  : > "$TEST_ROOT/$task_id-removals"

  if [[ "$phase" == retry ]]; then
    set +e
    PATH="$TEST_ROOT/fake-bin:$PATH" \
      FAKE_REMOVER_LOG="$TEST_ROOT/$task_id-removals" \
      SERGEANT_CONFIG="$TEST_ROOT/config" \
      SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
      "$ROOT_DIR/bin/sgt-cleanup" "$task_id" >/dev/null 2>&1
    status=$?
    set -e
    [[ "$status" -ne 0 ]] || _fail \
      "the interrupted first removal was expected to fail but succeeded"
    [[ -f "$repo_state/cleanup-owner" && -f "$repo_state/cleanup-phase" ]] || _fail \
      "the interrupted first removal published no retry ledger" \
      "state: $(_list_entries "$repo_state")"
  fi

  state_before="$(snapshot_state "$repo_state" "$worktree")"
  removals_before="$(wc -l < "$TEST_ROOT/$task_id-removals" | tr -d ' ')"
  set +e
  output="$(PATH="$TEST_ROOT/fake-bin:$PATH" \
    FAKE_CROSS_DEVICE_PATH="$worktree" \
    FAKE_REMOVER_LOG="$TEST_ROOT/$task_id-removals" \
    SERGEANT_CONFIG="$TEST_ROOT/config" \
    SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
    "$ROOT_DIR/bin/sgt-cleanup" "$task_id" 2>&1)"
  status=$?
  set -e

  assert_rejected "$status" "$output"
  # A layout that is already wrong at the preflight is refused before the
  # response lock is acquired, so not even the lock gate may appear here.
  assert_state_unchanged "$state_before" "$repo_state" "$worktree" no-lock-gate
  assert_remover_calls "$TEST_ROOT/$task_id-removals" "$removals_before"
  if [[ "$phase" == initial ]]; then
    [[ ! -e "$marker" ]] || _fail \
      "a rejected initial cleanup published the repository instance marker" \
      "marker: $marker"
    [[ ! -e "$repo_state/cleanup-owner" && ! -e "$repo_state/cleanup-phase" && \
      ! -e "$repo_state/terminal-evidence" ]] || _fail \
      "a rejected initial cleanup published lifecycle evidence" \
      "state: $(_list_entries "$repo_state")"
  fi
}

assert_cross_filesystem_rejected git initial
assert_cross_filesystem_rejected treehouse initial
assert_cross_filesystem_rejected git retry
assert_cross_filesystem_rejected treehouse retry

CASE_LABEL="device change after the layout preflight: crossfs-device-change"
init_case git crossfs-device-change
: > "$TEST_ROOT/crossfs-device-change-removals"
device_change_state="$TEST_ROOT/fleet/crossfs-device-change/app"
device_change_worktree="$TEST_ROOT/crossfs-device-change-linked-worktree"
device_change_before="$(snapshot_state "$device_change_state" \
  "$device_change_worktree")"
set +e
device_change_output="$(PATH="$TEST_ROOT/fake-bin:$PATH" \
  FAKE_CROSS_DEVICE_PATH="$device_change_worktree" \
  FAKE_CROSS_DEVICE_AFTER=2 \
  FAKE_STAT_COUNT_FILE="$TEST_ROOT/crossfs-device-change-stat-count" \
  FAKE_REMOVER_LOG="$TEST_ROOT/crossfs-device-change-removals" \
  SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" crossfs-device-change 2>&1)"
device_change_status=$?
set -e
assert_rejected "$device_change_status" "$device_change_output"
# The drift only becomes visible to a revalidation inside the publication
# transaction, which runs under the response lock, so this cleanup has already
# created the lock gate before it refuses.
assert_state_unchanged "$device_change_before" "$device_change_state" \
  "$device_change_worktree" lock-gate
assert_remover_calls "$TEST_ROOT/crossfs-device-change-removals" 0
[[ ! -e "$device_change_state/cleanup-owner" ]] || _fail \
  "a rejected cleanup published a cleanup owner" \
  "state: $(_list_entries "$device_change_state")"

CASE_LABEL="absent worktree on retry: crossfs-absent-retry"
init_case git crossfs-absent-retry
: > "$TEST_ROOT/crossfs-absent-retry-removals"
PATH="$TEST_ROOT/fake-bin:$PATH" \
  FAKE_REMOVER_LOG="$TEST_ROOT/crossfs-absent-retry-removals" \
  SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" crossfs-absent-retry >/dev/null 2>&1 || true
absent_repo="$TEST_ROOT/crossfs-absent-retry-main"
absent_state="$TEST_ROOT/fleet/crossfs-absent-retry/app"
absent_worktree="$TEST_ROOT/crossfs-absent-retry-linked-worktree"
"$REAL_GIT" -C "$absent_repo" worktree remove --force "$absent_worktree"
absent_before="$(snapshot_state "$absent_state")"
absent_removals_before="$(wc -l < "$TEST_ROOT/crossfs-absent-retry-removals" | \
  tr -d ' ')"
set +e
absent_output="$(PATH="$TEST_ROOT/fake-bin:$PATH" \
  FAKE_CROSS_DEVICE_PATH="$TEST_ROOT" \
  FAKE_REMOVER_LOG="$TEST_ROOT/crossfs-absent-retry-removals" \
  SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" crossfs-absent-retry 2>&1)"
absent_status=$?
set -e
assert_rejected "$absent_status" "$absent_output"
# The absent worktree resolves to its parent device, so this retry is refused at
# the layout preflight, before the response lock is acquired.
assert_state_unchanged "$absent_before" "$absent_state" "" no-lock-gate
assert_remover_calls "$TEST_ROOT/crossfs-absent-retry-removals" \
  "$absent_removals_before"

assert_boundary_change_rejected() {
  local boundary="$3" mode="$1" phase="$2" task_id
  local before calls_before marker output state status worktree

  task_id="crossfs-boundary-$mode-$phase-$boundary"
  CASE_LABEL="device change at revalidation boundary $boundary: $task_id"
  init_case "$mode" "$task_id"
  state="$TEST_ROOT/fleet/$task_id/app"
  worktree="$TEST_ROOT/$task_id-linked-worktree"
  marker="$TEST_ROOT/$task_id-main/.git/sergeant-instance"
  : > "$TEST_ROOT/$task_id-removals"
  if [[ "$phase" == retry ]]; then
    PATH="$TEST_ROOT/fake-bin:$PATH" \
      FAKE_REMOVER_LOG="$TEST_ROOT/$task_id-removals" \
      SERGEANT_CONFIG="$TEST_ROOT/config" \
      SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
      "$ROOT_DIR/bin/sgt-cleanup" "$task_id" >/dev/null 2>&1 || true
  fi
  before="$(snapshot_state "$state" "$worktree")"
  calls_before="$(wc -l < "$TEST_ROOT/$task_id-removals" | tr -d ' ')"
  set +e
  output="$(PATH="$TEST_ROOT/fake-bin:$PATH" \
    FAKE_CROSS_DEVICE_PATH="$worktree" \
    FAKE_CROSS_DEVICE_AFTER="$boundary" \
    FAKE_STAT_COUNT_FILE="$TEST_ROOT/$task_id-stat-count" \
    FAKE_REMOVER_LOG="$TEST_ROOT/$task_id-removals" \
    SERGEANT_CONFIG="$TEST_ROOT/config" \
    SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
    "$ROOT_DIR/bin/sgt-cleanup" "$task_id" 2>&1)"
  status=$?
  set -e
  assert_rejected "$status" "$output"
  # Boundary 1 already survives the layout preflight, so every boundary here is
  # refused after the response lock — and therefore after the lock gate exists.
  assert_state_unchanged "$before" "$state" "$worktree" lock-gate
  assert_remover_calls "$TEST_ROOT/$task_id-removals" "$calls_before"
  if compgen -G "$state/*.tmp.*" >/dev/null; then
    _fail "boundary rollback left a staging artifact" \
      "artifacts: $(echo "$state"/*.tmp.*)"
  fi
  if [[ "$phase" == initial ]]; then
    [[ ! -e "$marker" ]] || _fail \
      "a rejected initial cleanup published the repository instance marker" \
      "marker: $marker"
    [[ ! -e "$state/cleanup-owner" && ! -e "$state/cleanup-phase" && \
      ! -e "$state/terminal-evidence" ]] || _fail \
      "a rejected initial cleanup published lifecycle evidence" \
      "state: $(_list_entries "$state")"
  fi
}

for boundary_mode in git treehouse; do
  for boundary_phase in initial retry; do
    for boundary_number in 1 2 3 4 5 6; do
      # Treehouse's retry-safe protocol rechecks its conditional lease identity
      # during replay, so the old stat-call ordinal no longer names a stable
      # pre-return boundary. Treehouse replay interruption is covered by the
      # lease-specific cleanup test.
      if [[ "$boundary_mode" == treehouse && "$boundary_phase" == retry ]]; then
        continue
      fi
      assert_boundary_change_rejected "$boundary_mode" "$boundary_phase" \
        "$boundary_number"
    done
  done
done

for phase_mode in git treehouse; do
  for phase_retry in initial retry; do
    phase_task="crossfs-phase-$phase_mode-$phase_retry"
    CASE_LABEL="device change after the worktree is gone: $phase_task"
    init_case "$phase_mode" "$phase_task"
    phase_state="$TEST_ROOT/fleet/$phase_task/app"
    phase_worktree="$TEST_ROOT/$phase_task-linked-worktree"
    : > "$TEST_ROOT/$phase_task-removals"
    if [[ "$phase_retry" == retry ]]; then
      PATH="$TEST_ROOT/fake-bin:$PATH" \
        FAKE_REMOVER_LOG="$TEST_ROOT/$phase_task-removals" \
        SERGEANT_CONFIG="$TEST_ROOT/config" \
        SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
        "$ROOT_DIR/bin/sgt-cleanup" "$phase_task" >/dev/null 2>&1 || true
    fi
    phase_calls_before="$(wc -l < "$TEST_ROOT/$phase_task-removals" | tr -d ' ')"
    set +e
    phase_output="$(PATH="$TEST_ROOT/fake-bin:$PATH" \
      FAKE_CROSS_DEVICE_PATH="$TEST_ROOT" \
      FAKE_REMOVER_SUCCESS=true \
      FAKE_REMOVER_LOG="$TEST_ROOT/$phase_task-removals" \
      SERGEANT_CONFIG="$TEST_ROOT/config" \
      SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
      "$ROOT_DIR/bin/sgt-cleanup" "$phase_task" 2>&1)"
    phase_status=$?
    set -e
    assert_rejected "$phase_status" "$phase_output"
    [[ ! -e "$phase_worktree" ]] || _fail \
      "the worktree survived a removal the remover reported as successful" \
      "worktree: $phase_worktree"
    expected_phase=removing
    [[ "$phase_mode" != treehouse ]] || expected_phase=returning
    observed_phase="$(sed -n '1p' "$phase_state/cleanup-phase" 2>/dev/null || true)"
    [[ "$observed_phase" == "$expected_phase" ]] || _fail \
      "the cleanup phase ledger does not record the interrupted phase" \
      "expected: $expected_phase" "observed: ${observed_phase:-<absent>}"
    [[ -f "$phase_state/cleanup-owner" ]] || _fail \
      "the interrupted cleanup published no owner" \
      "state: $(_list_entries "$phase_state")"
    [[ -f "$phase_state/terminal-evidence/.sergeant-status" ]] || _fail \
      "the interrupted cleanup did not persist terminal evidence" \
      "state: $(_list_entries "$phase_state")"
    assert_remover_calls "$TEST_ROOT/$phase_task-removals" \
      "$((phase_calls_before + 1))"
    if compgen -G "$phase_state/*.tmp.*" >/dev/null; then
      _fail "the interrupted cleanup left a staging artifact" \
        "artifacts: $(echo "$phase_state"/*.tmp.*)"
    fi
  done
done

CASE_LABEL="evidence restore fails during rollback: crossfs-rollback-failure"
init_case git crossfs-rollback-failure
: > "$TEST_ROOT/crossfs-rollback-failure-removals"
set +e
rollback_failure_output="$(PATH="$TEST_ROOT/fake-bin:$PATH" \
  FAKE_CROSS_DEVICE_PATH="$TEST_ROOT/crossfs-rollback-failure-linked-worktree" \
  FAKE_CROSS_DEVICE_AFTER=6 \
  FAKE_STAT_COUNT_FILE="$TEST_ROOT/crossfs-rollback-failure-stat-count" \
  FAKE_RESTORE_FAILURE=true \
  FAKE_REMOVER_LOG="$TEST_ROOT/crossfs-rollback-failure-removals" \
  SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" crossfs-rollback-failure 2>&1)"
rollback_failure_status=$?
set -e
[[ "$rollback_failure_status" -ne 0 ]] || _fail \
  "a failed rollback was reported as success" \
  "output:" "${rollback_failure_output:-<no output>}"
[[ "$rollback_failure_output" == *"CRITICAL: cross-filesystem cleanup rollback failed; inspect preserved backup:"* ]] || _fail \
  "a failed rollback did not report a preserved backup" \
  "output:" "${rollback_failure_output:-<no output>}"
[[ "$rollback_failure_output" != *"ERROR: Unsupported cleanup layout:"* ]] || _fail \
  "a failed rollback was masked by the layout rejection" \
  "output:" "$rollback_failure_output"
compgen -G "$TEST_ROOT/fleet/crossfs-rollback-failure/app/live-evidence.tmp.*" \
  >/dev/null || _fail "a failed rollback discarded the live evidence backup" \
  "state: $(_list_entries "$TEST_ROOT/fleet/crossfs-rollback-failure/app")"
assert_remover_calls "$TEST_ROOT/crossfs-rollback-failure-removals" 0

# A cross-filesystem restore that fails on a later entry cannot republish the
# evidence, so CRITICAL with a preserved backup is the correct outcome.  What must
# not survive is a partial publication: every entry it already put back —
# including whole directory ledgers — has to be removed again.
CASE_LABEL="rollback must unpublish partial evidence: crossfs-directory-rollback"
init_case git crossfs-directory-rollback
: > "$TEST_ROOT/crossfs-directory-rollback-removals"
directory_rollback_state="$TEST_ROOT/fleet/crossfs-directory-rollback/app"
directory_rollback_worktree="$TEST_ROOT/crossfs-directory-rollback-linked-worktree"
set +e
directory_rollback_output="$(PATH="$TEST_ROOT/fake-bin:$PATH" \
  FAKE_CROSS_DEVICE_PATH="$directory_rollback_worktree" \
  FAKE_CROSS_DEVICE_AFTER=6 \
  FAKE_STAT_COUNT_FILE="$TEST_ROOT/crossfs-directory-rollback-stat-count" \
  FAKE_RESTORE_FAILURE_MATCH=.sergeant-status \
  FAKE_REMOVER_LOG="$TEST_ROOT/crossfs-directory-rollback-removals" \
  SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" crossfs-directory-rollback 2>&1)"
directory_rollback_status=$?
set -e
[[ "$directory_rollback_status" -ne 0 ]] || _fail \
  "a failed directory rollback was reported as success" \
  "output:" "${directory_rollback_output:-<no output>}"
[[ "$directory_rollback_output" == *"CRITICAL: cross-filesystem cleanup rollback failed; inspect preserved backup:"* ]] || _fail \
  "a failed directory rollback did not report a preserved backup" \
  "output:" "${directory_rollback_output:-<no output>}"
if compgen -G "$directory_rollback_worktree/.sergeant-*" >/dev/null; then
  _fail "a failed directory rollback left published evidence behind" \
    "worktree: $(_list_entries "$directory_rollback_worktree")"
fi
compgen -G "$directory_rollback_state/live-evidence.tmp.*" >/dev/null || _fail \
  "a failed directory rollback discarded the live evidence backup" \
  "state: $(_list_entries "$directory_rollback_state")"
[[ -f "$directory_rollback_state/terminal-evidence/.sergeant-status" && \
  -f "$directory_rollback_state/terminal-evidence/.sergeant-review-gates/nested/spec" ]] || _fail \
  "a failed directory rollback damaged persisted terminal evidence" \
  "terminal evidence: $(_list_entries "$directory_rollback_state/terminal-evidence")"

# A directory racing into the destination between the copy and the publication
# must be refused by name, never merged into: nesting there would destroy the only
# remaining copy when the backup is discarded at the end of the restore.
CASE_LABEL="raced destination must be refused: crossfs-directory-collide"
init_case git crossfs-directory-collide
: > "$TEST_ROOT/crossfs-directory-collide-removals"
directory_collide_state="$TEST_ROOT/fleet/crossfs-directory-collide/app"
directory_collide_worktree="$TEST_ROOT/crossfs-directory-collide-linked-worktree"
set +e
directory_collide_output="$(PATH="$TEST_ROOT/fake-bin:$PATH" \
  FAKE_CROSS_DEVICE_PATH="$directory_collide_worktree" \
  FAKE_CROSS_DEVICE_AFTER=6 \
  FAKE_STAT_COUNT_FILE="$TEST_ROOT/crossfs-directory-collide-stat-count" \
  FAKE_RESTORE_COLLIDE_MATCH=.sergeant-review-gates \
  FAKE_REMOVER_LOG="$TEST_ROOT/crossfs-directory-collide-removals" \
  SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" crossfs-directory-collide 2>&1)"
directory_collide_status=$?
set -e
[[ "$directory_collide_status" -ne 0 ]] || _fail \
  "a restore that raced a directory into the destination was reported as success" \
  "output:" "${directory_collide_output:-<no output>}"
[[ "$directory_collide_output" == *"collides with an existing path: $directory_collide_worktree/.sergeant-review-gates"* ]] || _fail \
  "a cross-filesystem restore merged into a raced destination" \
  "output:" "${directory_collide_output:-<no output>}"
[[ ! -e "$directory_collide_worktree/.sergeant-review-gates/.sergeant-review-gates" ]] || _fail \
  "a cross-filesystem restore nested evidence inside the raced destination" \
  "destination: $(_list_entries "$directory_collide_worktree/.sergeant-review-gates")"
compgen -G "$directory_collide_state/live-evidence.tmp.*" >/dev/null || _fail \
  "a refused cross-filesystem restore discarded the only remaining evidence copy" \
  "state: $(_list_entries "$directory_collide_state")"

printf 'sgt-cleanup cross-filesystem preflight: ok\n'
