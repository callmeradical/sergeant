#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
REAL_GIT="$(command -v git)"
export REAL_GIT

cleanup_fixture() {
  rm -rf "$TEST_ROOT"
}
trap cleanup_fixture EXIT

init_repo() {
  local repo_root="$1"

  mkdir -p "$repo_root"
  git -C "$repo_root" init -q
  git -C "$repo_root" config user.name Test
  git -C "$repo_root" config user.email test@example.invalid
  printf 'fixture\n' > "$repo_root/README.md"
  git -C "$repo_root" add README.md
  git -C "$repo_root" commit -qm fixture
}

record_task() {
  local task_id="$1" repo_root="$2" worktree="$3" wt_type="$4"
  local state="$TEST_ROOT/fleet/$task_id/app"

  mkdir -p "$state" "$TEST_ROOT/config"
  cat > "$TEST_ROOT/config/$task_id.yaml" <<EOF
name: $task_id
repos:
  - name: app
    path: $repo_root
EOF
  printf 'Project: %s\n' "$task_id" > "$TEST_ROOT/fleet/$task_id/brief.md"
  printf '%s\n' "$worktree" > "$state/worktree"
  printf '%s\n' "$wt_type" > "$state/wt_type"
  if [[ "$wt_type" == treehouse ]]; then
    printf 'sgt-%s-app\n' "$task_id" > "$state/wt_holder"
  fi
  printf 'done\n' > "$state/status"
  printf 'result\n' > "$state/result"
  printf 'done\n' > "$worktree/.sergeant-status"
  printf 'result\n' > "$worktree/.sergeant-result"
}

mkdir -p "$TEST_ROOT/fleet" "$TEST_ROOT/fake-bin" "$TEST_ROOT/home"

init_repo "$TEST_ROOT/treehouse-main"
git -C "$TEST_ROOT/treehouse-main" worktree add -q -b treehouse-worker \
  "$TEST_ROOT/treehouse-pool-checkout"
record_task treehouse-pool "$TEST_ROOT/treehouse-main" \
  "$TEST_ROOT/treehouse-pool-checkout" treehouse

cat > "$TEST_ROOT/fake-bin/treehouse" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == return && -d "$2" ]]
printf '%s|%s\n' "$PWD" "$2" >> "$FAKE_TREEHOUSE_LOG"
printf 'Worktree returned to pool.\n'
EOF
chmod +x "$TEST_ROOT/fake-bin/treehouse"

set +e
treehouse_output="$(
  HOME="$TEST_ROOT/home" PATH="$TEST_ROOT/fake-bin:$PATH" \
    FAKE_TREEHOUSE_LOG="$TEST_ROOT/treehouse-return.log" \
    SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" \
    SGT_WIKI_DISABLED=1 \
    "$ROOT_DIR/bin/sgt-cleanup" treehouse-pool 2>&1
)"
treehouse_status=$?
set -e
if [[ "$treehouse_status" -ne 0 ]]; then
  printf 'Treehouse pool cleanup failed:\n%s\n' "$treehouse_output" >&2
  exit 1
fi
[[ "$treehouse_output" == *"Worktree returned to pool."* ]]
[[ -d "$TEST_ROOT/treehouse-pool-checkout" ]]
[[ ! -e "$TEST_ROOT/fleet/treehouse-pool" ]]
[[ "$(wc -l < "$TEST_ROOT/treehouse-return.log")" -eq 1 ]]
printf 'sgt-cleanup accepts a successful Treehouse pool return: ok\n'

init_repo "$TEST_ROOT/unowned-treehouse-main"
git -C "$TEST_ROOT/unowned-treehouse-main" worktree add -q \
  -b unowned-treehouse-worker "$TEST_ROOT/unowned-treehouse-pool-checkout"
record_task unowned-treehouse "$TEST_ROOT/unowned-treehouse-main" \
  "$TEST_ROOT/unowned-treehouse-pool-checkout" treehouse
printf 'another-holder\n' > \
  "$TEST_ROOT/fleet/unowned-treehouse/app/wt_holder"

set +e
unowned_output="$(
  HOME="$TEST_ROOT/home" PATH="$TEST_ROOT/fake-bin:$PATH" \
    FAKE_TREEHOUSE_LOG="$TEST_ROOT/treehouse-return.log" \
    SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" \
    SGT_WIKI_DISABLED=1 \
    "$ROOT_DIR/bin/sgt-cleanup" unowned-treehouse 2>&1
)"
unowned_status=$?
set -e
[[ "$unowned_status" -ne 0 ]]
[[ "$unowned_output" == *"treehouse lease does not match its owner"* ]]
[[ "$(wc -l < "$TEST_ROOT/treehouse-return.log")" -eq 1 ]]
[[ -d "$TEST_ROOT/unowned-treehouse-pool-checkout" ]]
[[ -d "$TEST_ROOT/fleet/unowned-treehouse" ]]
printf 'sgt-cleanup rejects an unverified Treehouse holder before return: ok\n'

init_repo "$TEST_ROOT/git-main"
git -C "$TEST_ROOT/git-main" worktree add -q -b git-worker \
  "$TEST_ROOT/git-worktree"
record_task git-remains "$TEST_ROOT/git-main" "$TEST_ROOT/git-worktree" git

cat > "$TEST_ROOT/fake-bin/git" <<'EOF'
#!/usr/bin/env bash
if [[ " $* " == *" worktree remove "* ]]; then
  exit 0
fi
exec "$REAL_GIT" "$@"
EOF
chmod +x "$TEST_ROOT/fake-bin/git"

set +e
git_output="$(
  HOME="$TEST_ROOT/home" PATH="$TEST_ROOT/fake-bin:$PATH" \
    SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" \
    SGT_WIKI_DISABLED=1 \
    "$ROOT_DIR/bin/sgt-cleanup" git-remains 2>&1
)"
git_status=$?
set -e
[[ "$git_status" -ne 0 ]]
[[ "$git_output" == *"Worktree removal reported success but the directory remains"* ]]
[[ -d "$TEST_ROOT/git-worktree" ]]
[[ -d "$TEST_ROOT/fleet/git-remains" ]]
printf 'sgt-cleanup rejects an incomplete ordinary git removal: ok\n'
