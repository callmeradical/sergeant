#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
REAL_GIT="$(command -v git)"
export REAL_GIT
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/config" "$TEST_ROOT/fake-bin" "$TEST_ROOT/fleet"

cat > "$TEST_ROOT/fake-bin/git" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" worktree remove "*)
    printf 'git|%s\n' "${!#}" >> "$FAKE_REMOVER_LOG"
    exit 1
    ;;
esac
"$REAL_GIT" "$@"
EOF

cat > "$TEST_ROOT/fake-bin/treehouse" <<'EOF'
#!/usr/bin/env bash
printf 'treehouse|%s\n' "$2" >> "$FAKE_REMOVER_LOG"
exit 1
EOF

cat > "$TEST_ROOT/fake-bin/stat" <<'EOF'
#!/usr/bin/env bash
case "${!#}" in
  "$FAKE_CROSS_DEVICE_PATH") printf '200\n' ;;
  *) printf '100\n' ;;
esac
EOF
chmod +x "$TEST_ROOT/fake-bin/git" "$TEST_ROOT/fake-bin/stat" \
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
  printf '%s\n' "$mode" > "$repo_state/wt_type"
  if [[ "$mode" == treehouse ]]; then
    printf 'sgt-%s-app\n' "$task_id" > "$repo_state/wt_holder"
  fi
}

snapshot_state() {
  find "$1" "$2" -type f -exec cksum {} + | LC_ALL=C sort
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

printf 'sgt-cleanup cross-filesystem preflight: ok\n'
