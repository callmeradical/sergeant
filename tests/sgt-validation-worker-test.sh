#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
TMUX_SESSION="sgt-validation-worker-test-$$"
trap 'tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true; rm -rf "$TEST_ROOT"' EXIT

state="$TEST_ROOT/state"
worktree="$TEST_ROOT/worktree"
fake_bin="$TEST_ROOT/bin"
mkdir -p "$state" "$worktree" "$fake_bin"
git -C "$worktree" init -q
git -C "$worktree" config user.name Test
git -C "$worktree" config user.email test@example.invalid
printf 'fixture\n' > "$worktree/README.md"
git -C "$worktree" add README.md
git -C "$worktree" commit -qm fixture
head_sha="$(git -C "$worktree" rev-parse HEAD)"
printf '%s\n' "$head_sha" > "$state/validation_head"
cat > "$state/validation-intent.md" <<'EOF'
## Objective

Validate only after release.
EOF
revision="$(bash -c 'source "$1"; _sgt_intent_revision "$2"' _ \
  "$ROOT_DIR/bin/_sgt-intent.sh" "$state/validation-intent.md")"

cat > "$fake_bin/no-mistakes" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$NO_MISTAKES_LOG"
EOF
chmod +x "$fake_bin/no-mistakes"

pane="$(tmux new-session -d -P -F '#{pane_id}' -s "$TMUX_SESSION" -n validation \
  -c "$worktree" \
  "env PATH='$fake_bin:$PATH' NO_MISTAKES_LOG='$TEST_ROOT/no-mistakes.log' \
  '$ROOT_DIR/bin/sgt-validation-worker' '$state' '$worktree' '$revision'")"
sleep 0.1
[[ ! -e "$TEST_ROOT/no-mistakes.log" ]]

printf '%s\n' "$pane" > "$state/validation_pane"
tmux display-message -p -t "$pane" \
  '#{pane_dead}|#{pane_id}|#{pane_pid}|#{pane_created}|#{pane_start_command}' \
  > "$state/validation_pane_identity"
printf '%s\n' "$revision" > "$state/validation-release.tmp"
mv "$state/validation-release.tmp" "$state/validation-release"

for _ in $(seq 1 100); do
  [[ -f "$TEST_ROOT/no-mistakes.log" ]] && break
  sleep 0.02
done
grep -Fq 'axi run --intent' "$TEST_ROOT/no-mistakes.log"
grep -Fq 'Validate only after release.' "$TEST_ROOT/no-mistakes.log"
if grep -Fq -- '--yes' "$TEST_ROOT/no-mistakes.log"; then
  printf 'validation worker enabled automatic gates\n' >&2
  exit 1
fi
[[ "$(cat "$state/validation_status")" == 'exited:0' ]]

printf 'sgt-validation-worker release handshake: ok\n'
