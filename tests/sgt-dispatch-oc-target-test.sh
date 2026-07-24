#!/usr/bin/env bash

set -euo pipefail
export TMUX=fixture TMUX_PANE=%11

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

config="$TEST_ROOT/config"
fleet="$TEST_ROOT/fleet"
fake_bin="$TEST_ROOT/fake-bin"
repo="$TEST_ROOT/repo"
inbox="$TEST_ROOT/inbox"
mkdir -p "$config" "$fleet" "$fake_bin" "$repo" "$inbox/processes/$$"

cat > "$config/test.yaml" <<EOF
name: test
repos:
  - name: app
    path: $repo
EOF

cat > "$fake_bin/td" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  printf 'td version v0.51.2\n'
  exit 0
fi
if [[ "${1:-}" == "create" && "${2:-}" == "--help" ]]; then
  printf '%s\n' 'Usage: td create TITLE --description TEXT --json --work-dir DIR'
  exit 0
fi
case "$1" in
  list) printf '[{"id":"td-route","title":"Route coordinator notifications"}]\n' ;;
  context) printf 'Coordinator routing task\n' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$fake_bin/td"

cat > "$fake_bin/tmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  new-window)
    for repo_state in "$SERGEANT_FLEET"/*/*; do
      [[ -d "$repo_state" ]] || continue
      notification_id="$(cat "$repo_state/notification_id")"
      worktree="$(cat "$repo_state/worktree")"
      printf '%s\n' "$notification_id" > "$worktree/.sergeant-notification-ack"
      printf '%s\n' "$notification_id" > "$repo_state/notification_delivered"
    done
    printf '%%42\n'
    ;;
  display-message)
    [[ "$*" == *'-t %11'* ]] && printf '0|%%11|1111|111111|coordinator-command\n' || \
      printf '0|%%42|4242|123456|fixture-worker-command\n'
    ;;
esac
exit 0
EOF
chmod +x "$fake_bin/tmux"

git -C "$repo" init -q
git -C "$repo" config user.name Test
git -C "$repo" config user.email test@example.invalid
touch "$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" commit -qm fixture

process_start="$(ps -o lstart= -p "$$" | awk '{$1=$1; print}')"
jq -nc --argjson pid "$$" --arg session ses_coordinator --arg processStart "$process_start" \
  '{pid: $pid, processStart: $processStart, primarySession: $session, sessions: {ses_coordinator: {busy: true, queued: 0}}}' \
  > "$inbox/processes/$$/registry.json"

PATH="$fake_bin:$PATH" OPENCODE_PID="$$" OPENCODE_SESSION_ID=ses_coordinator OC_INJECT_ROOT="$inbox" \
SERGEANT_CONFIG="$config" SERGEANT_FLEET="$fleet" SGT_WIKI_DISABLED=1 \
  "$ROOT_DIR/bin/sgt-dispatch" test --td td-route --repos app >/dev/null

task_state="$(printf '%s\n' "$fleet"/*)"
jq -e --argjson pid "$$" \
  '.pid == $pid and .sessionId == "ses_coordinator"' "$task_state/oc_target.json" >/dev/null

printf 'sgt-dispatch coordinator target capture: ok\n'
