#!/usr/bin/env bash
# Tests for drain admission in sgt-respond (td-e6ea03)
# Drain must block worker relaunch before process/pane side effects.
# Response must be stored generation-safely even when relaunch is blocked.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

drain_dir="$TEST_ROOT/drains"
fleet="$TEST_ROOT/fleet"
source_repo="$TEST_ROOT/source"
worktree="$TEST_ROOT/worktree"
repo_state="$fleet/task-1/app"
fake_bin="$TEST_ROOT/fake-bin"
config_dir="$TEST_ROOT/config"

mkdir -p "$repo_state" "$source_repo" "$fake_bin" "$config_dir" "$drain_dir"
export SERGEANT_CONFIG="$config_dir"

git -C "$source_repo" init -q
git -C "$source_repo" config user.name Test
git -C "$source_repo" config user.email test@example.invalid
touch "$source_repo/README.md"
git -C "$source_repo" add README.md
git -C "$source_repo" commit -qm fixture
git -C "$source_repo" worktree add -q -b respond-drain-test "$worktree"
cat > "$config_dir/test.yaml" <<EOF
repos:
  - name: app
    path: $source_repo
EOF

printf 'Project: test\nBrief: fixture\nBranch: respond-drain-test\nRepos: app\n' \
  > "$fleet/task-1/brief.md"
printf '%s\n' "$worktree" > "$repo_state/worktree"
cat "$worktree/.git" > "$repo_state/worktree_git_pointer"
worktree_git_dir="$(sed 's/^gitdir: //' "$worktree/.git")"
printf '%s\n' "$(cd "$worktree_git_dir" && pwd -P)" > "$repo_state/worktree_git_dir"

cat > "$fleet/task-1/.sergeant-intent.md" <<'EOF'
## Objective
Drain test.
EOF
cp "$fleet/task-1/.sergeant-intent.md" "$repo_state/.sergeant-intent.md"
cp "$fleet/task-1/.sergeant-intent.md" "$worktree/.sergeant-intent.md"
bash -c 'source "$1"; _sgt_intent_revision "$2"' _ \
  "$ROOT_DIR/bin/_sgt-intent.sh" "$fleet/task-1/.sergeant-intent.md" \
  > "$fleet/task-1/intent_revision"
cp "$fleet/task-1/intent_revision" "$repo_state/intent_revision"
cat > "$worktree/.sergeant-brief.md" <<EOF
**Task ID:** task-1
**Project:** test
EOF

# Dead pane: display-message exits 1 (not the expected supervisor)
printf '%%42\n' > "$repo_state/pane"
printf '0|%%99|9999|123|other-worker:%s\n' "$repo_state" > "$repo_state/pane_identity"
chmod 600 "$repo_state/pane_identity"
printf 'sgt\n' > "$repo_state/tmux_session"
printf 'task/app\n' > "$repo_state/window_name"
printf 'opencode\n' > "$repo_state/agent"
printf 'test\n' > "$repo_state/project"
printf '1\n' > "$worktree/.sergeant-gate-generation"
printf 'td-test-1\n' > "$repo_state/td_task"

cat > "$fake_bin/tmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TMUX_LOG:-/dev/null}"
case "$1" in
  display-message)
    # Pane is dead / wrong supervisor
    exit 1
    ;;
  new-window) printf '%%99\n' ;;
  send-keys)  exit 0 ;;
esac
EOF
chmod +x "$fake_bin/tmux"

cat > "$fake_bin/td" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TD_LOG:-/dev/null}"
EOF
chmod +x "$fake_bin/td"

_respond() {
  local response="$1"
  printf '%s' "$response" | PATH="$fake_bin:$ROOT_DIR/bin:$PATH" \
    TMUX_LOG="$TEST_ROOT/tmux.log" TD_LOG="$TEST_ROOT/td.log" \
    SERGEANT_FLEET="$fleet" SERGEANT_DRAIN_DIR="$drain_dir" \
    "$ROOT_DIR/bin/sgt-respond" task-1 app
}

_drain() {
  SERGEANT_DRAIN_DIR="$drain_dir" "$ROOT_DIR/bin/sgt-drain" "$@"
}

_undrain() {
  SERGEANT_DRAIN_DIR="$drain_dir" "$ROOT_DIR/bin/sgt-undrain" "$@"
}

# ── 1. Global drain: dead-pane relaunch is blocked; response is stored ────────

printf 'needs_input\n' > "$worktree/.sergeant-status"
printf 'needs_input\n' > "$repo_state/status"
rm -f "$worktree/.sergeant-response" "$repo_state/response"

_drain --global --reason "respond drain test" --actor "test"

set +e
output="$(_respond "drain blocked response" 2>&1)"
status=$?
set -e

_undrain --global

[[ "$status" -ne 0 ]] || { echo "relaunch should be blocked when drain active; got 0"; exit 1; }
[[ "$output" == *"drain"* ]] || \
  { echo "expected drain message; got: $output"; exit 1; }
if grep -q 'new-window' "$TEST_ROOT/tmux.log" 2>/dev/null; then
  echo "tmux new-window was called despite drain"
  exit 1
fi
# Response MUST be stored (spec: "responses may be stored generation-safely")
[[ -f "$worktree/.sergeant-response" ]] || \
  { echo "response should be stored even when drain blocks relaunch"; exit 1; }
[[ "$(cat "$worktree/.sergeant-response")" == "drain blocked response" ]] || \
  { echo "stored response content wrong"; exit 1; }
rm -f "$worktree/.sergeant-response" "$repo_state/response"

# ── 2. Project drain: matching project blocks relaunch ────────────────────────

printf 'needs_input\n' > "$worktree/.sergeant-status"
printf 'needs_input\n' > "$repo_state/status"
rm -f "$worktree/.sergeant-response" "$repo_state/response" "$TEST_ROOT/tmux.log"

_drain test --reason "project drain test"

set +e
output="$(_respond "project drained response" 2>&1)"
status=$?
set -e
_undrain test

[[ "$status" -ne 0 ]] || { echo "project drain should block matching project relaunch"; exit 1; }
[[ "$output" == *"drain"* ]] || \
  { echo "expected drain message for project drain; got: $output"; exit 1; }
if grep -q 'new-window' "$TEST_ROOT/tmux.log" 2>/dev/null; then
  echo "tmux new-window called during project drain"
  exit 1
fi
rm -f "$worktree/.sergeant-response" "$repo_state/response"

printf 'sgt-respond drain admission: ok\n'
