#!/usr/bin/env bash

set -euo pipefail

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
printf 'treehouse|%s\n' "$2" >> "$FAKE_REMOVER_LOG"
if [[ "${FAKE_REMOVER_SUCCESS:-}" == true ]]; then
  rm -rf "$2"
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
  fi
}

snapshot_state() {
  local root

  for root in "$@"; do
    [[ ! -e "$root" ]] || find "$root" -type f -exec cksum {} +
  done | LC_ALL=C sort
}

assert_cross_filesystem_rejected() {
  local mode="$1" phase="$2" task_id
  local marker output removals_before repo_root repo_state state_before status worktree

  task_id="crossfs-$mode-$phase"

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
    [[ "$status" -ne 0 ]]
    [[ -f "$repo_state/cleanup-owner" && -f "$repo_state/cleanup-phase" ]]
  fi

  state_before="$(snapshot_state "$repo_state" "$worktree")"
  removals_before="$(wc -l < "$TEST_ROOT/$task_id-removals")"
  set +e
  output="$(PATH="$TEST_ROOT/fake-bin:$PATH" \
    FAKE_CROSS_DEVICE_PATH="$worktree" \
    FAKE_REMOVER_LOG="$TEST_ROOT/$task_id-removals" \
    SERGEANT_CONFIG="$TEST_ROOT/config" \
    SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
    "$ROOT_DIR/bin/sgt-cleanup" "$task_id" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]]
  [[ "$output" == *"Unsupported cleanup layout: fleet state and worktree must be on the same filesystem; move SERGEANT_FLEET or the worktree before retrying: app"* ]] || {
    printf 'cross-filesystem %s %s cleanup was not rejected actionably:\n%s\n' \
      "$mode" "$phase" "$output" >&2
    exit 1
  }
  [[ "$(snapshot_state "$repo_state" "$worktree")" == "$state_before" ]]
  [[ "$(wc -l < "$TEST_ROOT/$task_id-removals")" == "$removals_before" ]]
  if [[ "$phase" == initial ]]; then
    [[ ! -e "$marker" ]]
    [[ ! -e "$repo_state/cleanup-owner" ]]
    [[ ! -e "$repo_state/cleanup-phase" ]]
    [[ ! -e "$repo_state/terminal-evidence" ]]
  fi
}

assert_cross_filesystem_rejected git initial
assert_cross_filesystem_rejected treehouse initial
assert_cross_filesystem_rejected git retry
assert_cross_filesystem_rejected treehouse retry

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
[[ "$device_change_status" -ne 0 ]]
[[ "$device_change_output" == *"Unsupported cleanup layout: fleet state and worktree must be on the same filesystem; move SERGEANT_FLEET or the worktree before retrying: app"* ]]
[[ "$(snapshot_state "$device_change_state" "$device_change_worktree")" == \
  "$device_change_before" ]]
[[ ! -s "$TEST_ROOT/crossfs-device-change-removals" ]]
[[ ! -e "$device_change_state/cleanup-owner" ]]

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
absent_removals_before="$(wc -l < "$TEST_ROOT/crossfs-absent-retry-removals")"
set +e
absent_output="$(PATH="$TEST_ROOT/fake-bin:$PATH" \
  FAKE_CROSS_DEVICE_PATH="$TEST_ROOT" \
  FAKE_REMOVER_LOG="$TEST_ROOT/crossfs-absent-retry-removals" \
  SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-cleanup" crossfs-absent-retry 2>&1)"
absent_status=$?
set -e
[[ "$absent_status" -ne 0 ]]
[[ "$absent_output" == *"Unsupported cleanup layout: fleet state and worktree must be on the same filesystem; move SERGEANT_FLEET or the worktree before retrying: app"* ]]
[[ "$(snapshot_state "$absent_state")" == "$absent_before" ]]
[[ "$(wc -l < "$TEST_ROOT/crossfs-absent-retry-removals")" == \
  "$absent_removals_before" ]]

assert_boundary_change_rejected() {
  local boundary="$3" mode="$1" phase="$2" task_id
  local before calls_before marker output state status worktree

  task_id="crossfs-boundary-$mode-$phase-$boundary"
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
  calls_before="$(wc -l < "$TEST_ROOT/$task_id-removals")"
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
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"Unsupported cleanup layout: fleet state and worktree must be on the same filesystem; move SERGEANT_FLEET or the worktree before retrying: app"* ]]
  [[ "$(snapshot_state "$state" "$worktree")" == "$before" ]]
  [[ "$(wc -l < "$TEST_ROOT/$task_id-removals")" == "$calls_before" ]]
  if compgen -G "$state/*.tmp.*" >/dev/null; then
    printf 'boundary rollback left an artifact: %s %s %s\n' \
      "$mode" "$phase" "$boundary" >&2
    exit 1
  fi
  if [[ "$phase" == initial ]]; then
    [[ ! -e "$marker" ]]
    [[ ! -e "$state/cleanup-owner" ]]
    [[ ! -e "$state/cleanup-phase" ]]
    [[ ! -e "$state/terminal-evidence" ]]
  fi
}

for boundary_mode in git treehouse; do
  for boundary_phase in initial retry; do
    for boundary_number in 1 2 3 4 5 6; do
      assert_boundary_change_rejected "$boundary_mode" "$boundary_phase" \
        "$boundary_number"
    done
  done
done

for phase_mode in git treehouse; do
  for phase_retry in initial retry; do
    phase_task="crossfs-phase-$phase_mode-$phase_retry"
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
    phase_calls_before="$(wc -l < "$TEST_ROOT/$phase_task-removals")"
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
    [[ "$phase_status" -ne 0 ]]
    [[ "$phase_output" == *"Unsupported cleanup layout: fleet state and worktree must be on the same filesystem; move SERGEANT_FLEET or the worktree before retrying: app"* ]]
    [[ ! -e "$phase_worktree" ]]
    [[ "$(sed -n '1p' "$phase_state/cleanup-phase")" == removing ]]
    [[ -f "$phase_state/cleanup-owner" ]]
    [[ -f "$phase_state/terminal-evidence/.sergeant-status" ]]
    [[ "$(wc -l < "$TEST_ROOT/$phase_task-removals")" -eq \
      $((phase_calls_before + 1)) ]]
    if compgen -G "$phase_state/*.tmp.*" >/dev/null; then
      printf 'phase-boundary failure left an artifact: %s %s\n' \
        "$phase_mode" "$phase_retry" >&2
      exit 1
    fi
  done
done

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
[[ "$rollback_failure_status" -ne 0 ]]
[[ "$rollback_failure_output" == *"CRITICAL: cross-filesystem cleanup rollback failed; inspect preserved backup:"* ]]
[[ "$rollback_failure_output" != *"ERROR: Unsupported cleanup layout:"* ]]
compgen -G "$TEST_ROOT/fleet/crossfs-rollback-failure/app/live-evidence.tmp.*" \
  >/dev/null
[[ ! -s "$TEST_ROOT/crossfs-rollback-failure-removals" ]]

# A cross-filesystem restore that fails on a later entry cannot republish the
# evidence, so CRITICAL with a preserved backup is the correct outcome.  What must
# not survive is a partial publication: every entry it already put back —
# including whole directory ledgers — has to be removed again.
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
[[ "$directory_rollback_status" -ne 0 ]]
[[ "$directory_rollback_output" == *"CRITICAL: cross-filesystem cleanup rollback failed; inspect preserved backup:"* ]] || {
  printf 'cross-filesystem directory rollback was not reported actionably:\n%s\n' \
    "$directory_rollback_output" >&2
  exit 1
}
if compgen -G "$directory_rollback_worktree/.sergeant-*" >/dev/null; then
  printf 'cross-filesystem directory rollback left published evidence behind:\n%s\n' \
    "$(ls -A "$directory_rollback_worktree")" >&2
  exit 1
fi
compgen -G "$directory_rollback_state/live-evidence.tmp.*" >/dev/null || {
  printf 'cross-filesystem directory rollback discarded the live evidence backup\n' >&2
  exit 1
}
[[ -f "$directory_rollback_state/terminal-evidence/.sergeant-status" && \
  -f "$directory_rollback_state/terminal-evidence/.sergeant-review-gates/nested/spec" ]] || {
  printf 'cross-filesystem directory rollback damaged persisted terminal evidence\n' >&2
  exit 1
}

# A directory racing into the destination between the copy and the publication
# must be refused by name, never merged into: nesting there would destroy the only
# remaining copy when the backup is discarded at the end of the restore.
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
[[ "$directory_collide_status" -ne 0 ]]
[[ "$directory_collide_output" == *"collides with an existing path: $directory_collide_worktree/.sergeant-review-gates"* ]] || {
  printf 'cross-filesystem restore merged into a raced destination:\n%s\n' \
    "$directory_collide_output" >&2
  exit 1
}
[[ ! -e "$directory_collide_worktree/.sergeant-review-gates/.sergeant-review-gates" ]] || {
  printf 'cross-filesystem restore nested evidence inside the raced destination\n' >&2
  exit 1
}
compgen -G "$directory_collide_state/live-evidence.tmp.*" >/dev/null || {
  printf 'cross-filesystem restore discarded the only remaining evidence copy\n' >&2
  exit 1
}

printf 'sgt-cleanup cross-filesystem preflight: ok\n'
