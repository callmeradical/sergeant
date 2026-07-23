#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/config" "$TEST_ROOT/fleet" "$TEST_ROOT/fake-bin" "$TEST_ROOT/repo"

cat > "$TEST_ROOT/config/test.yaml" <<EOF
name: test
repos:
  - name: app
    path: $TEST_ROOT/repo
EOF
cat > "$TEST_ROOT/fake-bin/tmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TMUX_LOG"
case "$1" in
  has-session) exit 0 ;;
  new-window)
    [[ "${FAIL_WINDOW:-0}" == 0 ]] || exit 7
    printf '%%42\n'
    ;;
esac
EOF
chmod +x "$TEST_ROOT/fake-bin/tmux"
cat > "$TEST_ROOT/fake-bin/td" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

if [[ "${1:-}" == "--version" ]]; then
  printf 'td version v0.1.0\n'
  exit 0
fi
if [[ "${1:-}" == "create" && "${2:-}" == "--help" ]]; then
  printf '%s\n' '--description --json --work-dir'
  exit 0
fi

args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --work-dir|-w)
      shift 2
      ;;
    --json)
      shift
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done

set -- "${args[@]}"
case "${1:-}" in
  list)
    printf '[]\n'
    ;;
  create)
    printf '{"id":"td-app-1"}\n'
    ;;
  delete)
    printf '{"id":"td-app-1","deleted":true}\n'
    ;;
  *)
    exit 1
    ;;
esac
EOF
chmod +x "$TEST_ROOT/fake-bin/td"
git -C "$TEST_ROOT/repo" init -q
git -C "$TEST_ROOT/repo" config user.name Test
git -C "$TEST_ROOT/repo" config user.email test@example.invalid
touch "$TEST_ROOT/repo/README.md"
git -C "$TEST_ROOT/repo" add README.md
git -C "$TEST_ROOT/repo" commit -qm fixture
git -C "$TEST_ROOT/repo" remote add origin git@github.com:org/test.git

PATH="$TEST_ROOT/fake-bin:$PATH" TMUX_LOG="$TEST_ROOT/success.log" \
SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-dispatch" test 'Supervise worker' --repos app >/dev/null
repo_state="$(printf '%s\n' "$TEST_ROOT"/fleet/*/app)"
[[ "$(cat "$repo_state/pane")" == "%42" ]]
[[ "$(cat "$repo_state/agent")" == "${SERGEANT_AGENT:-opencode}" ]]
[[ "$(cat "$repo_state/initial_message")" == 'Read the .sergeant-brief.md file and execute the mission.' ]]
[[ -s "$repo_state/tmux_session" && -s "$repo_state/window_name" ]]
grep -Fq "$ROOT_DIR/bin/sgt-worker" "$TEST_ROOT/success.log"
brief="$(cat "$repo_state/worktree")/.sergeant-brief.md"
grep -Fq 'persistent supervisor' "$brief"
grep -Fq 'Do not use sleep to keep the agent process alive' "$brief"
grep -Fq 'orphaned' "$brief"
grep -Fq 'sgt-respond' "$brief"
grep -Fq 'requires both .sergeant-status=done and a non-empty .sergeant-result' "$brief"

set +e
PATH="$TEST_ROOT/fake-bin:$PATH" TMUX_LOG="$TEST_ROOT/failure.log" FAIL_WINDOW=1 \
SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-dispatch" test 'Fail worker launch' --repos app >/dev/null 2>&1
status=$?
set -e
[[ "$status" -ne 0 ]]
failed_state="$(printf '%s\n' "$TEST_ROOT"/fleet/fail-worker-launch-*/app)"
[[ "$(cat "$failed_state/status")" == "orphaned" ]]
grep -Fq 'tmux failed to launch worker supervisor' "$failed_state/diagnostic"

removed_flag="--""remote"
before_count="$(find "$TEST_ROOT/fleet" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
rm -f "$TEST_ROOT/removed-option-tmux.log"
set +e
output="$(PATH="$TEST_ROOT/fake-bin:$PATH" TMUX_LOG="$TEST_ROOT/removed-option-tmux.log" \
  SERGEANT_CONFIG="$TEST_ROOT/config" SERGEANT_FLEET="$TEST_ROOT/fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-dispatch" test 'Removed option' --repos app "$removed_flag" 2>&1)"
status=$?
set -e
after_count="$(find "$TEST_ROOT/fleet" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
[[ "$status" -ne 0 ]]
[[ "$output" == *"Unknown option"* ]]
[[ "$before_count" == "$after_count" ]]
[[ ! -e "$TEST_ROOT/removed-option-tmux.log" ]]

printf 'sgt-dispatch supervisor launch: ok\n'
