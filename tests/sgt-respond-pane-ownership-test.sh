#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fleet="$TEST_ROOT/fleet"
task_dir="$fleet/task-1"
repo_state="$task_dir/app"
source_repo="$TEST_ROOT/source"
worktree="$TEST_ROOT/worktree"
fake_bin="$TEST_ROOT/fake-bin"
config_dir="$TEST_ROOT/config"
mkdir -p "$repo_state" "$source_repo" "$fake_bin" "$config_dir"

git -C "$source_repo" init -q
git -C "$source_repo" config user.name Test
git -C "$source_repo" config user.email test@example.invalid
touch "$source_repo/README.md"
git -C "$source_repo" add README.md
git -C "$source_repo" commit -qm fixture
git -C "$source_repo" worktree add -q -b ownership-test "$worktree"
worktree="$(cd "$worktree" && pwd -P)"

cat > "$config_dir/test.yaml" <<EOF
repos:
  - name: app
    path: $source_repo
EOF
printf 'Project: test\nBrief: pane ownership\nBranch: ownership-test\nRepos: app\n' \
  > "$task_dir/brief.md"
printf '%s\n' "$worktree" > "$repo_state/worktree"
cat "$worktree/.git" > "$repo_state/worktree_git_pointer"
worktree_git_dir="$(sed 's/^gitdir: //' "$worktree/.git")"
printf '%s\n' "$(cd "$worktree_git_dir" && pwd -P)" > "$repo_state/worktree_git_dir"
printf '%%42\n' > "$repo_state/pane"
printf '0|%%42|4242|123456|expected-worker\n' > "$repo_state/pane_identity"
chmod 600 "$repo_state/pane_identity"
printf 'sgt\n' > "$repo_state/tmux_session"
printf 'task/app\n' > "$repo_state/window_name"
printf 'opencode\n' > "$repo_state/agent"
printf 'td-123\n' > "$repo_state/td_task"
printf 'needs_input\n' > "$repo_state/status"
printf 'needs_input\n' > "$worktree/.sergeant-status"
printf '1\n' > "$worktree/.sergeant-gate-generation"

cat > "$task_dir/.sergeant-intent.md" <<'EOF'
## Objective

Resume only the owned worker.
EOF
cp "$task_dir/.sergeant-intent.md" "$repo_state/.sergeant-intent.md"
cp "$task_dir/.sergeant-intent.md" "$worktree/.sergeant-intent.md"
bash -c 'source "$1"; _sgt_intent_revision "$2"' _ \
  "$ROOT_DIR/bin/_sgt-intent.sh" "$task_dir/.sergeant-intent.md" \
  > "$task_dir/intent_revision"
cp "$task_dir/intent_revision" "$repo_state/intent_revision"

cat > "$fake_bin/tmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TMUX_LOG"
case "$1" in
  display-message)
    [[ "${NO_SERVER:-0}" != "1" ]] || exit 1
    [[ "${STALE_WORKER:-0}" != "1" ]] || exit 1
    [[ "${QUERY_FAIL:-0}" != "1" ]] || exit 8
    printf '0|%%42|4242|123456|different-live-worker\n'
    ;;
  list-panes)
    if [[ "${NO_SERVER:-0}" == "1" ]]; then
      printf 'no server running on /tmp/tmux-test/default\n' >&2
      exit 1
    fi
    if [[ "${PANE_ABSENT_FAIL:-0}" == "1" && "$4" == '#{pane_id}' ]]; then
      printf 'lost server\n' >&2
      exit 1
    fi
    if [[ "${STALE_WORKER:-0}" == "1" ]]; then
      printf '%s\n' "$STALE_IDENTITY"
    else
      printf '%%42\n'
    fi
    ;;
  new-window)
    [[ "${NO_SERVER:-0}" != "1" ]] || exit 1
    : > "$NEW_WINDOW_MARKER"
    printf '%%99\n'
    ;;
  *) exit 0 ;;
esac
EOF
cat > "$fake_bin/td" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$fake_bin/tmux" "$fake_bin/td"

set +e
output="$(printf 'Do not replace a live mismatched pane.\n' | \
  PATH="$fake_bin:$PATH" SERGEANT_CONFIG="$config_dir" SERGEANT_FLEET="$fleet" \
  TMUX_LOG="$TEST_ROOT/tmux.log" NEW_WINDOW_MARKER="$TEST_ROOT/new-window" \
  "$ROOT_DIR/bin/sgt-respond" task-1 app 2>&1)"
status=$?
set -e

[[ "$status" -ne 0 ]]
[[ "$output" == *'live but its identity does not match'* ]]
[[ ! -e "$TEST_ROOT/new-window" ]]
[[ ! -e "$repo_state/response" && ! -e "$worktree/.sergeant-response" ]]
[[ "$(cat "$repo_state/pane")" == '%42' ]]
[[ "$(cat "$repo_state/pane_identity")" == '0|%42|4242|123456|expected-worker' ]]

set +e
query_output="$(printf 'Do not replace an unverifiable pane.\n' | \
  PATH="$fake_bin:$PATH" SERGEANT_CONFIG="$config_dir" SERGEANT_FLEET="$fleet" \
  TMUX_LOG="$TEST_ROOT/query-tmux.log" NEW_WINDOW_MARKER="$TEST_ROOT/query-new-window" \
  QUERY_FAIL=1 "$ROOT_DIR/bin/sgt-respond" task-1 app 2>&1)"
query_status=$?
set -e

[[ "$query_status" -ne 0 ]]
[[ "$query_output" == *'exists but its identity could not be verified'* ]]
[[ ! -e "$TEST_ROOT/query-new-window" ]]
[[ ! -e "$repo_state/response" && ! -e "$worktree/.sergeant-response" ]]

set +e
absent_fail_output="$(printf 'Do not relaunch when absence is unverifiable.\n' | \
  PATH="$fake_bin:$PATH" SERGEANT_CONFIG="$config_dir" SERGEANT_FLEET="$fleet" \
  TMUX_LOG="$TEST_ROOT/absent-fail-tmux.log" NEW_WINDOW_MARKER="$TEST_ROOT/absent-fail-window" \
  QUERY_FAIL=1 PANE_ABSENT_FAIL=1 "$ROOT_DIR/bin/sgt-respond" task-1 app 2>&1)"
absent_fail_status=$?
set -e

[[ "$absent_fail_status" -ne 0 ]]
[[ "$absent_fail_output" == *'Could not verify whether recorded worker pane %42 is absent'* ]]
[[ "$absent_fail_output" != *'exists but its identity could not be verified'* ]]
[[ ! -e "$TEST_ROOT/absent-fail-window" ]]
[[ ! -e "$repo_state/response" && ! -e "$worktree/.sergeant-response" ]]

printf -v stale_command '%q %q %q %q' \
  "$ROOT_DIR/bin/sgt-interactive-worker" "$repo_state" "$worktree" opencode
stale_identity="0|%41|4141|123455|\"$stale_command\""
set +e
stale_output="$(printf 'Do not duplicate a stale worker.\n' | \
  PATH="$fake_bin:$PATH" SERGEANT_CONFIG="$config_dir" SERGEANT_FLEET="$fleet" \
  TMUX_LOG="$TEST_ROOT/stale-tmux.log" NEW_WINDOW_MARKER="$TEST_ROOT/stale-new-window" \
  STALE_WORKER=1 STALE_IDENTITY="$stale_identity" \
  "$ROOT_DIR/bin/sgt-respond" task-1 app 2>&1)"
stale_status=$?
set -e

[[ "$stale_status" -ne 0 ]]
[[ "$stale_output" == *'Another live worker pane %41 owns this fleet state'* ]]
[[ ! -e "$TEST_ROOT/stale-new-window" ]]
[[ ! -e "$repo_state/response" && ! -e "$worktree/.sergeant-response" ]]

set +e
no_server_output="$(printf 'Journal while tmux is stopped.\n' | \
  PATH="$fake_bin:$PATH" SERGEANT_CONFIG="$config_dir" SERGEANT_FLEET="$fleet" \
  TMUX_LOG="$TEST_ROOT/no-server-tmux.log" NEW_WINDOW_MARKER="$TEST_ROOT/no-server-window" \
  NO_SERVER=1 "$ROOT_DIR/bin/sgt-respond" task-1 app 2>&1)"
no_server_status=$?
set -e

[[ "$no_server_status" -ne 0 ]]
[[ "$no_server_output" != *'enumerate live worker panes'* ]]
[[ "$(cat "$repo_state/response")" == 'Journal while tmux is stopped.' ]]
[[ ! -e "$TEST_ROOT/no-server-window" ]]

printf 'sgt-respond live pane ownership mismatch: ok\n'
