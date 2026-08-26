#!/usr/bin/env bash
# Regression test: sgt-cleanup's _git_worktree_removal_proven dedup-checked
# every newly-parsed `git worktree list --porcelain` entry against
# registered_paths[@] before that array had its first element added, which
# throws "unbound variable" under this script's `set -euo pipefail` on the
# very first entry of every call -- discovered live while cleaning up a
# genuinely failed dispatch task, not from existing test coverage (no
# existing test exercises this function).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Canonicalized immediately: on macOS, mktemp -d returns a path under /var/...
# that itself resolves through a further /private/var/... symlink hop, and
# sgt-cleanup's _configured_repo_root deliberately requires the configured
# path to already equal its own `pwd -P` resolution (rejecting anything else
# as unproven). An uncanonicalized TEST_ROOT would fail that check for a
# reason having nothing to do with what this test actually exercises.
TEST_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TEST_ROOT"' EXIT

config_dir="$TEST_ROOT/config"
fleet="$TEST_ROOT/fleet"
source_repo="$TEST_ROOT/source"
mkdir -p "$config_dir" "$fleet" "$source_repo"
chmod 700 "$fleet"

git -C "$source_repo" init -q
git -C "$source_repo" config user.name Test
git -C "$source_repo" config user.email test@example.invalid
touch "$source_repo/README.md"
git -C "$source_repo" add README.md
git -C "$source_repo" commit -qm fixture

cat > "$config_dir/test-project.yaml" <<EOF
repos:
  - name: app
    path: $source_repo
EOF

task_id="cleanup-registry-entry-test"
task_dir="$fleet/$task_id"
repo_dir="$task_dir/app"
worktree="$TEST_ROOT/worktree"
mkdir -p "$repo_dir"
git -C "$source_repo" worktree add -q -b "$task_id-app" "$worktree"

printf 'Project: test-project\nBrief: registry entry test\nBranch: %s\nRepos: app\n' \
  "$task_id-app" > "$task_dir/brief.md"
printf 'failed: fixture-induced failure\n' > "$repo_dir/status"
printf '%s\n' "$worktree" > "$repo_dir/worktree"
printf 'git\n' > "$repo_dir/wt_type"
printf 'failed: fixture-induced failure\n' > "$worktree/.sergeant-status"

if command -v td >/dev/null 2>&1; then
  :
else
  fake_bin="$TEST_ROOT/fake-bin"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/td" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  close|update) exit 0 ;;
  list) echo '[]' ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$fake_bin/td"
  export PATH="$fake_bin:$PATH"
fi

set +e
output="$(SERGEANT_CONFIG="$config_dir" SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-cleanup" "$task_id" 2>&1)"
status=$?
set -e

if grep -q 'unbound variable' <<<"$output"; then
  printf 'FAIL: sgt-cleanup crashed with an unbound-variable error:\n%s\n' \
    "$output" >&2
  exit 1
fi

[[ "$status" -eq 0 ]] || {
  printf 'FAIL: sgt-cleanup exited %s (expected 0):\n%s\n' "$status" "$output" >&2
  exit 1
}

[[ ! -d "$worktree" ]] || {
  printf 'FAIL: worktree was not removed: %s\n' "$worktree" >&2
  exit 1
}

printf 'sgt-cleanup removes the first registered worktree without an unbound-variable crash: ok\n'
