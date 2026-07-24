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

real_mv="$(command -v mv)"
real_rm="$(command -v rm)"
real_mkdir="$(command -v mkdir)"
real_cp="$(command -v cp)"
real_chmod="$(command -v chmod)"
cat > "$fake_bin/mv" <<'EOF'
#!/usr/bin/env bash
count=0
[[ ! -f "$FAIL_COUNTER" ]] || count="$(cat "$FAIL_COUNTER")"
count=$((count + 1))
printf '%s\n' "$count" > "$FAIL_COUNTER"
if [[ -n "${FAIL_MV_AT:-}" && "$count" -eq "$FAIL_MV_AT" ]]; then
  exit 75
fi
exec "$REAL_MV" "$@"
EOF
cat > "$fake_bin/rm" <<'EOF'
#!/usr/bin/env bash
real_rm="${REAL_RM:-/bin/rm}"
transport_cleanup=false
for path in "$@"; do
  [[ -n "${FAIL_TRANSPORT_PATH:-}" && "$path" == "$FAIL_TRANSPORT_PATH" ]] && transport_cleanup=true
done
if [[ "$transport_cleanup" == true ]]; then
  case "${FAIL_RM_MODE:-}" in
    before) exit 75 ;;
    partial)
      "$real_rm" -f "$FAIL_TRANSPORT_PATH"
      exit 75
      ;;
    after)
      "$real_rm" "$@"
      exit 75
      ;;
  esac
fi
exec "$real_rm" "$@"
EOF
for operation in mkdir cp chmod; do
  cat > "$fake_bin/$operation" <<'EOF'
#!/usr/bin/env bash
operation="${0##*/}"
case "$operation" in
  mkdir) real_operation="${REAL_MKDIR:-/bin/mkdir}" ;;
  cp) real_operation="${REAL_CP:-/bin/cp}" ;;
  chmod) real_operation="${REAL_CHMOD:-/bin/chmod}" ;;
esac
counter="$FAIL_COUNTER.$operation"
count=0
[[ ! -f "$counter" ]] || count="$(cat "$counter")"
count=$((count + 1))
printf '%s\n' "$count" > "$counter"
if [[ "${FAIL_STAGE_OP:-}" == "$operation" && "$count" -eq "${FAIL_STAGE_AT:-0}" ]]; then
  if [[ "$operation" == chmod && "${ASSERT_STAGE_FILES_PRIVATE:-}" == 1 ]]; then
    shift
    for path in "$@"; do
      mode="$(stat -c '%a' "$path" 2>/dev/null || stat -f '%Lp' "$path")"
      [[ "$mode" == 600 ]] || exit 76
    done
    : > "$STAGE_MODE_MARKER"
  fi
  exit 75
fi
exec "$real_operation" "$@"
EOF
done
chmod +x "$fake_bin/mv" "$fake_bin/rm" "$fake_bin/mkdir" "$fake_bin/cp" "$fake_bin/chmod"

setup_retry_fixture() {
  local name="$1"
  repo_state="$fleet/task-$name/app"
  worktree="$TEST_ROOT/worktree-$name"
  mkdir -p "$repo_state" "$worktree"
  printf '%s\n' "$worktree" > "$repo_state/worktree"
  printf '%%42\n' > "$repo_state/pane"
  printf '0|%%42|4242|123456|worker-command\n' > "$repo_state/pane_identity"
  publish_fixture
  printf 'in_progress\n' > "$worktree/.sergeant-status"
  cat > "$worktree/.sergeant-response-applied" <<'EOF'
response_id=response-123
gate_generation=1
status=in_progress
EOF
}

assert_retry_converges() {
  local task_id="$1"
  local expected_body="${2:-}"
  local archive="$repo_state/response-archive/response-123"
  PATH="$fake_bin:$PATH" REAL_MV="$real_mv" REAL_RM="$real_rm" \
    FAIL_COUNTER="$TEST_ROOT/mv-count-$task_id" TMUX_PANE=%42 SERGEANT_FLEET="$fleet" \
    "$ROOT_DIR/bin/sgt-ack-response" "$task_id" app response-123 >/dev/null
  [[ "$(cat "$worktree/.sergeant-response-ack")" == 'response-123' ]]
  [[ "$(cat "$repo_state/response_ack")" == 'response-123' ]]
  if [[ -n "$expected_body" ]]; then
    cmp -s "$expected_body" "$archive/body"
  else
    [[ "$(cat "$archive/body")" == 'approved response' ]]
  fi
  [[ ! -e "$repo_state/response" && ! -e "$worktree/.sergeant-response" ]]
  [[ ! -e "$worktree/.sergeant-response-id" ]]
  [[ ! -e "$worktree/.sergeant-response-generation" ]]
  [[ ! -e "$worktree/.sergeant-response-applied" ]]
}

for fail_at in 2 3; do
  name="mv-$fail_at"
  setup_retry_fixture "$name"
  counter="$TEST_ROOT/mv-count-task-$name"
  set +e
  PATH="$fake_bin:$PATH" REAL_MV="$real_mv" REAL_RM="$real_rm" \
    FAIL_COUNTER="$counter" FAIL_MV_AT="$fail_at" TMUX_PANE=%42 SERGEANT_FLEET="$fleet" \
    "$ROOT_DIR/bin/sgt-ack-response" "task-$name" app response-123 >/dev/null 2>&1
  status=$?
  set -e
  [[ "$status" -ne 0 ]]
  [[ -d "$repo_state/response-archive/response-123" ]]
  assert_retry_converges "task-$name"
done

for failure in archive-directory:mkdir:1 staging-directory:mkdir:2 body-file:cp:1 \
  archive-permission:chmod:1 staging-permission:chmod:2 staging-files-permission:chmod:3 \
  archive-rename:mv:1; do
  IFS=: read -r label operation fail_at <<< "$failure"
  name="stage-$label"
  setup_retry_fixture "$name"
  counter="$TEST_ROOT/stage-count-$name"
  set +e
  PATH="$fake_bin:$PATH" REAL_MV="$real_mv" REAL_RM="$real_rm" \
    REAL_MKDIR="$real_mkdir" REAL_CP="$real_cp" REAL_CHMOD="$real_chmod" \
    FAIL_COUNTER="$counter" FAIL_STAGE_OP="$operation" FAIL_STAGE_AT="$fail_at" \
    ASSERT_STAGE_FILES_PRIVATE="$([[ "$label" == staging-files-permission ]] && printf 1)" \
    STAGE_MODE_MARKER="$TEST_ROOT/stage-mode-$name" \
    FAIL_MV_AT="$([[ "$operation" == mv ]] && printf '%s' "$fail_at")" \
    TMUX_PANE=%42 SERGEANT_FLEET="$fleet" \
    "$ROOT_DIR/bin/sgt-ack-response" "task-$name" app response-123 >/dev/null 2>&1
  status=$?
  set -e
  [[ "$status" -ne 0 ]]
  [[ -f "$repo_state/response" && -f "$worktree/.sergeant-response" ]]
  [[ ! -e "$repo_state/response-archive/response-123" ]]
  if [[ "$label" == staging-files-permission ]]; then
    [[ -f "$TEST_ROOT/stage-mode-$name" ]]
  fi
  if compgen -G "$repo_state/response-archive/response-123.tmp.*" >/dev/null; then
    printf 'staging failure left temporary archive state: %s\n' "$label" >&2
    exit 1
  fi
  assert_retry_converges "task-$name"
done

for fail_mode in before partial after; do
  name="rm-$fail_mode"
  setup_retry_fixture "$name"
  counter="$TEST_ROOT/mv-count-task-$name"
  set +e
  PATH="$fake_bin:$PATH" REAL_MV="$real_mv" REAL_RM="$real_rm" \
    FAIL_COUNTER="$counter" FAIL_RM_MODE="$fail_mode" \
    FAIL_TRANSPORT_PATH="$repo_state/response" TMUX_PANE=%42 SERGEANT_FLEET="$fleet" \
    "$ROOT_DIR/bin/sgt-ack-response" "task-$name" app response-123 >/dev/null 2>&1
  status=$?
  set -e
  [[ "$status" -ne 0 ]]
  [[ -d "$repo_state/response-archive/response-123" ]]
  assert_retry_converges "task-$name"
done

for newline_case in zero multiple; do
  name="newlines-$newline_case"
  setup_retry_fixture "$name"
  expected="$TEST_ROOT/expected-$name"
  case "$newline_case" in
    zero) printf 'response without newline' > "$expected" ;;
    multiple) printf 'response with newlines\n\n\n' > "$expected" ;;
  esac
  cp "$expected" "$repo_state/response"
  cp "$expected" "$worktree/.sergeant-response"
  counter="$TEST_ROOT/mv-count-task-$name"
  set +e
  PATH="$fake_bin:$PATH" REAL_MV="$real_mv" REAL_RM="$real_rm" \
    FAIL_COUNTER="$counter" FAIL_MV_AT=2 TMUX_PANE=%42 SERGEANT_FLEET="$fleet" \
    "$ROOT_DIR/bin/sgt-ack-response" "task-$name" app response-123 >/dev/null 2>&1
  status=$?
  set -e
  [[ "$status" -ne 0 ]]
  cmp -s "$expected" "$repo_state/response-archive/response-123/body"
  assert_retry_converges "task-$name" "$expected"
  cmp -s "$expected" "$repo_state/response-archive/response-123/body"
done

printf 'sgt-ack-response consumption: ok\n'
