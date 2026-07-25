#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

home="$TEST_ROOT/home"
fleet="$TEST_ROOT/fleet"
fake_bin="$TEST_ROOT/fake-bin"
mkdir -p "$home/.opencode/skills/write-to-wiki/scripts" "$fleet/task-1" "$fake_bin"
printf 'session:1.0\n' > "$fleet/task-1/primary_pane"

cat > "$fake_bin/tmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TMUX_LOG"
exit 0
EOF
chmod +x "$fake_bin/tmux"

cat > "$home/.opencode/skills/write-to-wiki/scripts/write.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$WIKI_LOG"
EOF
chmod +x "$home/.opencode/skills/write-to-wiki/scripts/write.sh"

HOME="$home" PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  WIKI_LOG="$TEST_ROOT/wiki.log" SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-notify" task-1 "needs_input [app]: choose API seam" >/dev/null 2>&1
[[ ! -e "$TEST_ROOT/tmux.log" ]]
[[ -s "$fleet/task-1/notify" ]]
[[ "$(stat -c '%a' "$fleet/task-1/notify" 2>/dev/null || stat -f '%Lp' "$fleet/task-1/notify")" == "600" ]]
grep -Fq 'event=escalation' "$fleet/task-1/notify"
if grep -Fq 'choose API seam' "$fleet/task-1/notify"; then
  printf 'durable notification marker exposed message body\n' >&2
  exit 1
fi
grep -Fq "Agent Escalation" "$TEST_ROOT/wiki.log"
grep -Fq "sgt-notify: task-1 escalation" "$TEST_ROOT/wiki.log"
if grep -Fq "Agent Completion" "$TEST_ROOT/wiki.log"; then
  printf 'nonterminal escalation was mislabeled as completion\n' >&2
  exit 1
fi

: > "$TEST_ROOT/wiki.log"
HOME="$home" PATH="$fake_bin:$PATH" WIKI_LOG="$TEST_ROOT/wiki.log" SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-notify" task-1 "done: PR https://github.com/example/repo/pull/1" >/dev/null 2>&1
grep -Fq "Agent Completion" "$TEST_ROOT/wiki.log"
grep -Fq "sgt-notify: task-1 completion" "$TEST_ROOT/wiki.log"

HOME="$home" PATH="$fake_bin:$PATH" TMUX_LOG="$TEST_ROOT/tmux.log" \
  SERGEANT_NOTIFY_TRANSPORT=tmux WIKI_LOG="$TEST_ROOT/wiki.log" SERGEANT_FLEET="$fleet" \
  "$ROOT_DIR/bin/sgt-notify" task-1 "explicit compatibility wake" >/dev/null 2>&1
grep -Fq 'Agent task task-1 update: explicit compatibility wake' "$TEST_ROOT/tmux.log"

printf 'sgt-notify event classification: ok\n'
