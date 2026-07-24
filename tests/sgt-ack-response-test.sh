#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fleet="$TEST_ROOT/fleet"
repo_state="$fleet/task-1/app"
worktree="$TEST_ROOT/worktree"
fake_bin="$TEST_ROOT/bin"
mkdir -p "$repo_state" "$worktree" "$fake_bin"
printf '%s\n' "$worktree" > "$repo_state/worktree"
printf '%%42\n' > "$repo_state/pane"
printf '0|%%42|4242|123456|worker-command\n' > "$repo_state/pane_identity"

cat > "$fake_bin/tmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${PANE_IDENTITY:-0|%42|4242|123456|worker-command}"
EOF
chmod +x "$fake_bin/tmux"

publish_fixture() {
  printf 'approved response\n' > "$repo_state/response"
  printf 'response-123\n' > "$repo_state/response_id"
  printf 'approved response\n' > "$worktree/.sergeant-response"
  printf 'response-123\n' > "$worktree/.sergeant-response-id"
  printf '1\n' > "$repo_state/response_generation"
  printf '1\n' > "$worktree/.sergeant-response-generation"
  printf '1\n' > "$worktree/.sergeant-gate-generation"
  printf 'needs_input\n' > "$worktree/.sergeant-status"
}

publish_fixture
set +e
output="$(PATH="$fake_bin:$PATH" TMUX_PANE=%42 SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-ack-response" task-1 app wrong-id 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 && "$output" == *'response ID does not match'* ]]
[[ -f "$repo_state/response" && -f "$worktree/.sergeant-response" ]]

set +e
output="$(PATH="$fake_bin:$PATH" TMUX_PANE=%99 SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-ack-response" task-1 app response-123 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 && "$output" == *'worker pane identity'* ]]
[[ -f "$repo_state/response" && -f "$worktree/.sergeant-response" ]]

set +e
output="$(PATH="$fake_bin:$PATH" TMUX_PANE=%42 SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-ack-response" task-1 app response-123 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 && "$output" == *'post-application proof'* ]]
[[ -f "$repo_state/response" && -f "$worktree/.sergeant-response" ]]

printf 'done\n' > "$worktree/.sergeant-status"
cat > "$worktree/.sergeant-response-applied" <<'EOF'
response_id=response-123
gate_generation=1
status=done
EOF
set +e
output="$(PATH="$fake_bin:$PATH" TMUX_PANE=%42 SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-ack-response" task-1 app response-123 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 && "$output" == *'non-empty result'* ]]

printf 'failed: \n' > "$worktree/.sergeant-status"
cat > "$worktree/.sergeant-response-applied" <<'EOF'
response_id=response-123
gate_generation=1
status=failed: 
EOF
set +e
output="$(PATH="$fake_bin:$PATH" TMUX_PANE=%42 SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-ack-response" task-1 app response-123 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 && "$output" == *'nonblank reason'* ]]

printf 'in_progress\n' > "$worktree/.sergeant-status"
cat > "$worktree/.sergeant-response-applied" <<'EOF'
response_id=response-123
gate_generation=1
status=in_progress
EOF
PATH="$fake_bin:$PATH" TMUX_PANE=%42 SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-ack-response" task-1 app response-123 >/dev/null
[[ "$(cat "$worktree/.sergeant-response-ack")" == 'response-123' ]]
[[ "$(cat "$repo_state/response_ack")" == 'response-123' ]]
[[ ! -e "$repo_state/response" && ! -e "$worktree/.sergeant-response" ]]
[[ ! -e "$worktree/.sergeant-response-id" ]]
[[ ! -e "$worktree/.sergeant-response-applied" ]]
archive="$repo_state/response-archive/response-123"
[[ "$(cat "$archive/body")" == 'approved response' ]]
[[ "$(cat "$archive/gate_generation")" == '1' ]]
[[ "$(cat "$archive/applied_status")" == 'in_progress' ]]
grep -Fq 'response_id=response-123' "$archive/proof"
archive_mode="$(stat -c '%a' "$archive" 2>/dev/null || stat -f '%Lp' "$archive")"
body_mode="$(stat -c '%a' "$archive/body" 2>/dev/null || stat -f '%Lp' "$archive/body")"
[[ "$archive_mode" == '700' ]]
[[ "$body_mode" == '600' ]]
printf '2\n' > "$repo_state/response_generation"
[[ "$(cat "$archive/gate_generation")" == '1' ]]

printf 'sgt-ack-response consumption: ok\n'
